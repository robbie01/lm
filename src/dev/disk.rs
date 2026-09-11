//! Block storage, backed by a host file. This is how a live heap gets written
//! back out as an image: the Lisp side hands over an address and a block
//! range, and the bytes land on the host.
//!
//! A command takes time. Writing `D_CMD` latches the command and marks the
//! controller busy until `now + cost`; the transfer happens in one go when
//! that moment arrives, the way a blit does. Until then the memory a read is
//! filling still holds what it held before, and the memory a write is taking
//! from can still be changed under it - which on hardware would be a torn
//! block and here is the newer data. Either is wrong in a way you notice if
//! you forget to wait, which an instantaneous disk never was.

use crate::mach::Machine;
use crate::map::INT_DISK;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};

pub const BLOCK: u32 = 512;

pub const D_ADDR: u32 = 0x00; // memory address
pub const D_BLOCK: u32 = 0x04; // first block
pub const D_COUNT: u32 = 0x08; // blocks to move
pub const D_CMD: u32 = 0x0c; // write starts a command: 1 read, 2 write, 3 flush, 4 trunc
pub const D_STATUS: u32 = 0x10; // STATUS_BUSY while a command runs, then its result
pub const D_BLOCKS: u32 = 0x14; // r: size of the attached file, in blocks
pub const D_CTRL: u32 = 0x18; // bit0: raise INT_DISK on completion

pub const CMD_READ: u32 = 1;
pub const CMD_WRITE: u32 = 2;
pub const CMD_FLUSH: u32 = 3;
pub const CMD_TRUNC: u32 = 4; // cut the file to D_COUNT blocks

/// What `D_STATUS` reads while a command is running. Once it finishes, the
/// register holds the result instead: 0 ok, 1 no file attached, 2 the range
/// is not in RAM, 3 the host's I/O failed.
pub const STATUS_BUSY: u32 = 0x80;

#[derive(Clone, Copy, Default)]
struct Cmd {
    op: u32,
    addr: u32,
    block: u32,
    count: u32,
}

pub struct Disk {
    pub addr: u32,
    pub block: u32,
    pub count: u32,
    pub status: u32,
    pub ctrl: u32,
    pub busy: bool,
    pub busy_until: u64,
    /// The running command, latched when it was issued: the address and
    /// block registers are free to be written for the next one meanwhile.
    cmd: Cmd,
    file: Option<File>,
}

impl Disk {
    pub fn new() -> Disk {
        Disk {
            addr: 0,
            block: 0,
            count: 0,
            status: 0,
            ctrl: 0,
            busy: false,
            busy_until: 0,
            cmd: Cmd::default(),
            file: None,
        }
    }

    pub fn attach(&mut self, path: &str) -> std::io::Result<()> {
        self.file = Some(
            OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .open(path)?,
        );
        Ok(())
    }

    pub fn blocks(&self) -> u32 {
        self.file
            .as_ref()
            .and_then(|f| f.metadata().ok())
            .map(|md| (md.len() / BLOCK as u64) as u32)
            .unwrap_or(0)
    }

    pub fn read(&mut self, reg: u32) -> u32 {
        match reg {
            D_ADDR => self.addr,
            D_BLOCK => self.block,
            D_COUNT => self.count,
            D_STATUS => self.status,
            D_BLOCKS => self.blocks(),
            D_CTRL => self.ctrl,
            _ => 0,
        }
    }
}

pub fn command(m: &mut Machine, reg: u32, v: u32) {
    match reg {
        D_ADDR => {
            m.disk.addr = v;
            return;
        }
        D_BLOCK => {
            m.disk.block = v;
            return;
        }
        D_COUNT => {
            m.disk.count = v;
            return;
        }
        D_CTRL => {
            m.disk.ctrl = v;
            return;
        }
        D_CMD => {}
        _ => return,
    }

    // One command at a time. A command that arrives while one is running
    // waits for it, the way a store to a single-buffered controller stalls
    // on the bus: time moves on to when the running one finishes, and it
    // finishes. The driver waits on the status first so this never happens;
    // it is here so that forgetting is slow rather than wrong.
    if m.disk.busy {
        let due = m.disk.busy_until;
        if due > m.now {
            let d = due - m.now;
            m.cycles = m.cycles.wrapping_add(d);
            m.now = due;
        }
        finish(m);
    }

    let c = Cmd {
        op: v,
        addr: m.disk.addr,
        block: m.disk.block,
        count: m.disk.count,
    };
    // A rate a real controller might manage, plus a fixed cost for getting
    // started. It is no longer charged to whoever issued the command: time
    // passes while the controller works, and the machine gets on with
    // something else.
    let cost = match v {
        CMD_READ | CMD_WRITE => (c.count as u64) * BLOCK as u64 / 4 + 200,
        _ => 200,
    };
    m.disk.cmd = c;
    m.disk.busy = true;
    m.disk.busy_until = m.now + cost;
    m.disk.status = STATUS_BUSY;
}

/// The latched command, all of it, now. Answers its status.
fn perform(m: &mut Machine, c: Cmd) -> u32 {
    let n = (c.count as usize) * BLOCK as usize;
    let off = (c.block as u64) * BLOCK as u64;
    if m.disk.file.is_none() {
        return 1;
    }
    if !m.in_ram(c.addr, n as u32) && (c.op == CMD_READ || c.op == CMD_WRITE) {
        return 2;
    }
    // Split the machine borrow: the file and the RAM live in the same struct
    // but never overlap.
    let ramp = m.ramp;
    let f = m.disk.file.as_mut().unwrap();
    let r = match c.op {
        CMD_READ => f.seek(SeekFrom::Start(off)).and_then(|_| {
            let buf = unsafe { std::slice::from_raw_parts_mut(ramp.add(c.addr as usize), n) };
            // A short read at end of file leaves the rest zeroed, which is
            // what an unwritten block should look like.
            let mut got = 0;
            while got < n {
                match f.read(&mut buf[got..]) {
                    Ok(0) => {
                        buf[got..].fill(0);
                        break;
                    }
                    Ok(k) => got += k,
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        }),
        CMD_WRITE => f.seek(SeekFrom::Start(off)).and_then(|_| {
            let buf = unsafe { std::slice::from_raw_parts(ramp.add(c.addr as usize), n) };
            f.write_all(buf)
        }),
        CMD_FLUSH => f.flush(),
        CMD_TRUNC => f.set_len((c.count as u64) * BLOCK as u64),
        _ => Ok(()),
    };
    if r.is_err() {
        3
    } else {
        0
    }
}

/// The running command's time has come: move the bytes, post the result, and
/// raise the interrupt if it was asked for.
fn finish(m: &mut Machine) {
    let c = m.disk.cmd;
    m.disk.busy = false;
    m.disk.status = perform(m, c);
    if m.disk.ctrl & 1 != 0 {
        m.raise(INT_DISK);
    }
}

/// Finish the running command if its time has come. Called from everywhere
/// that can observe the controller - a status read, and each host slice - so
/// completion is never early and never later than the next look.
pub fn poll(m: &mut Machine, now: u64) {
    if m.disk.busy && now >= m.disk.busy_until {
        finish(m);
    }
}

/// When the running command finishes, or never.
pub fn due(m: &Machine) -> u64 {
    if m.disk.busy {
        m.disk.busy_until
    } else {
        u64::MAX
    }
}

/// The machine has stopped. A write still in flight is finished rather than
/// dropped: the file is the one part of the machine that outlives the run,
/// and this is the disk's version of flushing the console on the way out.
pub fn settle(m: &mut Machine) {
    if m.disk.busy {
        finish(m);
    }
}
