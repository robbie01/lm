//! Block storage, backed by a host file. A live heap is written out as an
//! image through this device: the Lisp side hands over a capability to the
//! memory and a block range, and the bytes land on the host. The controller
//! moves only what the capability covers: a read needs SD, a write LD, and
//! every byte of the transfer inside its bounds, or the command is refused
//! and moves nothing.
//!
//! A command takes time. Writing `D_CMD` latches the command and marks the
//! controller busy until `now + cost`; the transfer happens in one go when
//! that moment arrives, the way a blit does. Until then the memory a read is
//! filling holds what it held before, and the memory a write takes from can
//! still be changed under it. On hardware that would be a torn block; here it
//! is the newer data. A driver that does not wait sees wrong data.

use crate::cap::*;
use crate::dev::{refusal, REFUSE_LOAD, REFUSE_STORE, TIMER_HZ};
use crate::mach::*;
use crate::map::INT_DISK;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};

pub const BLOCK: u32 = 512;

/// A capability register: the memory a read fills or a write takes from,
/// written with a capability store. A word store writes a number, which is no
/// capability, and a transfer through it is refused.
pub const D_BUF: u32 = 0x00;
pub const D_BLOCK: u32 = 0x08; // first block
pub const D_COUNT: u32 = 0x0c; // blocks to move
pub const D_CMD: u32 = 0x10; // write starts a command: 1 read, 2 write, 3 flush, 4 trunc
pub const D_STATUS: u32 = 0x14; // STATUS_BUSY while a command runs, then its result
pub const D_BLOCKS: u32 = 0x18; // r: size of the attached file, in blocks
pub const D_CTRL: u32 = 0x1c; // bit0: raise INT_DISK on completion

/// The registers, as the Lisp side names them. The buffer register takes a
/// capability and hands none back.
pub const REGS: &[super::Reg] = &[
    super::Reg { name: "buf", off: D_BUF, read: false, write: true, cap: true },
    super::rw("block", D_BLOCK),
    super::rw("count", D_COUNT),
    super::wo("cmd", D_CMD),
    super::ro("status", D_STATUS),
    super::ro("blocks", D_BLOCKS),
    super::rw("ctrl", D_CTRL),
];

pub const CMD_READ: u32 = 1;
pub const CMD_WRITE: u32 = 2;
pub const CMD_FLUSH: u32 = 3;
pub const CMD_TRUNC: u32 = 4; // cut the file to D_COUNT blocks

/// What `D_STATUS` reads while a command is running. Once it finishes, the
/// register holds the result instead: `STATUS_OK`, `STATUS_NO_FILE`,
/// `STATUS_REFUSED` when the buffer's capability does not allow the
/// transfer, or `STATUS_IO` when the host's I/O failed.
pub const STATUS_BUSY: u32 = 0x80;
pub const STATUS_OK: u32 = 0;
pub const STATUS_NO_FILE: u32 = 1;
pub const STATUS_REFUSED: u32 = 2;
pub const STATUS_IO: u32 = 3;

// What a command takes: a rate a real controller might manage, and a fixed
// time for getting started. The disk's speed is its medium's, not the
// processor's, so these are in time, and a command costs more cycles on a
// faster clock.
pub const BYTES_PER_SEC: u64 = 80_000_000;
pub const SETUP_US: u64 = 10;

#[derive(Clone, Copy, Default)]
struct Cmd {
    op: u32,
    buf: Cap,
    block: u32,
    count: u32,
}

pub struct Disk {
    /// The buffer register, a capability.
    pub buf: Cap,
    pub block: u32,
    pub count: u32,
    pub status: u32,
    pub ctrl: u32,
    pub busy: bool,
    pub busy_until: u64,
    /// The running command, latched when it was issued: the buffer and
    /// block registers are free to be written for the next one meanwhile.
    /// Its buffer is dropped when it finishes.
    cmd: Cmd,
    file: Option<File>,
}

impl Disk {
    pub fn new() -> Disk {
        Disk {
            buf: Cap::NULL,
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
            D_BUF => self.buf.addr,
            D_BLOCK => self.block,
            D_COUNT => self.count,
            D_STATUS => self.status,
            D_BLOCKS => self.blocks(),
            D_CTRL => self.ctrl,
            _ => 0,
        }
    }
}

/// A word store to a register.
pub fn command(m: &mut Machine, reg: u32, v: u32) {
    match reg {
        D_BUF => {
            m.disk.buf = Cap::int(v);
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
    // waits for it, the way a store to a single-buffered controller stalls on
    // the bus: time moves on to when the running command finishes, and it
    // finishes. The driver waits on the status first, so this path is not
    // normally taken; a driver that does not wait is slow rather than wrong.
    if m.disk.busy {
        let due = m.disk.busy_until;
        if due > m.now {
            let d = due - m.now;
            m.cycles = m.cycles.wrapping_add(d);
            m.now = due;
        }
        finish(m);
    }

    // The command takes the buffer's capability with it and leaves the
    // register empty, so the controller holds a capability only for a
    // command it has not finished, and for no longer.
    let c = Cmd {
        op: v,
        buf: std::mem::replace(&mut m.disk.buf, Cap::NULL),
        block: m.disk.block,
        count: m.disk.count,
    };
    // The cost is charged to the controller's own clock, not to the task
    // that issued the command: time passes while the controller works, and
    // other tasks run in the meantime.
    let setup = SETUP_US * TIMER_HZ as u64 / 1_000_000;
    let cost = match v {
        CMD_READ | CMD_WRITE => (c.count as u64) * BLOCK as u64 * TIMER_HZ as u64 / BYTES_PER_SEC + setup,
        _ => setup,
    };
    m.disk.cmd = c;
    m.disk.busy = true;
    m.disk.busy_until = m.now + cost;
    m.disk.status = STATUS_BUSY;
}

/// Perform the whole latched command and return its status.
fn perform(m: &mut Machine, c: Cmd) -> u32 {
    let n = (c.count as usize) * BLOCK as usize;
    let off = (c.block as u64) * BLOCK as u64;
    if m.disk.file.is_none() {
        return STATUS_NO_FILE;
    }
    // A read writes memory and a write reads it. Checked in 64 bits: the
    // count comes from the guest, and a large one wraps a 32-bit extent back
    // into range.
    let need: &[(u32, u32)] = match c.op {
        CMD_READ => &[(P_SD, REFUSE_STORE)],
        CMD_WRITE => &[(P_LD, REFUSE_LOAD)],
        _ => &[],
    };
    let addr = c.buf.addr;
    if !need.is_empty() && refusal(m, c.buf, need, addr as u64, n as u64).is_some() {
        return STATUS_REFUSED;
    }
    // Split the machine borrow: the file and the RAM live in the same struct
    // but never overlap.
    let ramp = m.ramp;
    let f = m.disk.file.as_mut().unwrap();
    let r = match c.op {
        CMD_READ => f.seek(SeekFrom::Start(off)).and_then(|_| {
            let buf = unsafe { std::slice::from_raw_parts_mut(ramp.add(addr as usize), n) };
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
            let buf = unsafe { std::slice::from_raw_parts(ramp.add(addr as usize), n) };
            f.write_all(buf)
        }),
        CMD_FLUSH => f.flush(),
        CMD_TRUNC => f.set_len((c.count as u64) * BLOCK as u64),
        _ => Ok(()),
    };
    // What the disk wrote into RAM is data.
    if c.op == CMD_READ {
        m.clear_tags(addr, n as u32);
    }
    if r.is_err() {
        STATUS_IO
    } else {
        STATUS_OK
    }
}

/// Complete the running command: move the bytes, post the result, and raise
/// the interrupt if it was asked for.
fn finish(m: &mut Machine) {
    let c = std::mem::take(&mut m.disk.cmd);
    m.disk.busy = false;
    m.disk.status = perform(m, c);
    if m.disk.ctrl & 1 != 0 {
        m.raise(INT_DISK);
    }
}

/// Finish the running command if it is due by `now`. Called from each point
/// that can observe the controller (a status read, and each host slice), so
/// completion is never early and never later than the next observation.
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

/// Called when the machine has stopped. A command still in flight is finished
/// rather than dropped, because the file outlives the run.
pub fn settle(m: &mut Machine) {
    if m.disk.busy {
        finish(m);
    }
}
