//! Block storage, backed by a host file. This is how a live heap gets written
//! back out as an image: the Lisp side hands over an address and a block
//! range, and the bytes land on the host.

use crate::mach::Machine;
use crate::map::INT_DISK;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};

pub const BLOCK: u32 = 512;

pub const D_ADDR: u32 = 0x00; // memory address
pub const D_BLOCK: u32 = 0x04; // first block
pub const D_COUNT: u32 = 0x08; // blocks to move
pub const D_CMD: u32 = 0x0c; // 1 read, 2 write, 3 flush
pub const D_STATUS: u32 = 0x10; // 0 ok, non-zero error
pub const D_BLOCKS: u32 = 0x14; // r: size of the attached file, in blocks
pub const D_CTRL: u32 = 0x18; // bit0: raise INT_DISK on completion

pub const CMD_READ: u32 = 1;
pub const CMD_WRITE: u32 = 2;
pub const CMD_FLUSH: u32 = 3;
pub const CMD_TRUNC: u32 = 4; // cut the file to D_COUNT blocks

pub struct Disk {
    pub addr: u32,
    pub block: u32,
    pub count: u32,
    pub status: u32,
    pub ctrl: u32,
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

    let (addr, block, count) = (m.disk.addr, m.disk.block, m.disk.count);
    let n = (count as usize) * BLOCK as usize;
    let off = (block as u64) * BLOCK as u64;
    let mut status = 0u32;

    if m.disk.file.is_none() {
        status = 1;
    } else if !m.in_ram(addr, n as u32) && v != CMD_FLUSH && v != CMD_TRUNC {
        status = 2;
    } else {
        // Split the machine borrow: the file and the RAM live in the same
        // struct but never overlap.
        let ramp = m.ramp;
        let f = m.disk.file.as_mut().unwrap();
        let r = match v {
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
            CMD_TRUNC => f.set_len((count as u64) * BLOCK as u64),
            _ => Ok(()),
        };
        if r.is_err() {
            status = 3;
        }
    }

    m.disk.status = status;
    // Charge the transfer at a rate a real controller might manage.
    m.cycles = m.cycles.wrapping_add(n as u64 / 4 + 200);
    if m.disk.ctrl & 1 != 0 {
        m.raise(INT_DISK);
    }
}
