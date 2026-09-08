//! Image files: a snapshot of the machine's memory.
//!
//! An image is not a program, it is a heap. It holds the symbols, the compiled
//! code, the boot list and whatever the system happened to have built by the
//! time it was written, all at the addresses they will occupy again when it is
//! loaded - which is exactly why nothing in the object memory may move.
//!
//! The file is a list of non-empty 4 KiB pages. Most of what a running machine
//! owns is zero: stacks, the mark bitmap, unfilled heap. Skipping zero pages
//! turns a 128 MiB address space into a file the size of what is actually in
//! it.

use crate::mach::Machine;
use crate::map::*;
use std::io::{Read, Write};

pub const MAGIC: &[u8; 8] = b"LMIMAGE1";
pub const PAGE: u32 = 4096;

/// The regions worth saving, as (base, end-pointer-global) pairs. Anything
/// outside them - the mark bitmap, the free area above the heap - is
/// reconstructed rather than stored.
fn regions(m: &Machine) -> Vec<(u32, u32)> {
    vec![
        (0, 0x1000),                    // nil cell, globals, object bins
        (POOL_BASE, m.peek32(LG_POOLPTR)),
        (CODE_BASE, m.peek32(LG_CODE_PTR)),
        (CONS_BASE, m.peek32(LG_CONS_PTR)),
        (OBJ_BASE, m.peek32(LG_OBJ_PTR)),
    ]
}

pub fn save(m: &Machine, path: &str, entry: u32) -> std::io::Result<(usize, usize)> {
    let mut pages: Vec<(u32, &[u8])> = Vec::new();
    let ram = m.ram();
    for (base, end) in regions(m) {
        let lo = base & !(PAGE - 1);
        let hi = (end + PAGE - 1) & !(PAGE - 1);
        let mut a = lo;
        while a < hi {
            let s = a as usize;
            let e = (a + PAGE) as usize;
            if e <= ram.len() {
                let page = &ram[s..e];
                if page.iter().any(|&b| b != 0) {
                    pages.push((a, page));
                }
            }
            a += PAGE;
        }
    }
    let mut f = std::fs::File::create(path)?;
    f.write_all(MAGIC)?;
    f.write_all(&1u32.to_le_bytes())?; // format version
    f.write_all(&entry.to_le_bytes())?;
    f.write_all(&(pages.len() as u32).to_le_bytes())?;
    for (addr, _) in &pages {
        f.write_all(&addr.to_le_bytes())?;
    }
    for (_, data) in &pages {
        f.write_all(data)?;
    }
    Ok((pages.len(), pages.len() * PAGE as usize))
}

pub struct Loaded {
    pub entry: u32,
}

/// A snapshot written by the machine itself, through the disk device. The
/// first block lists the regions; the rest is their contents.
pub const SNAP_MAGIC: u32 = 0x3153_4D4C; // "LMS1", little-endian

fn load_snapshot(m: &mut Machine, f: &mut std::fs::File) -> std::io::Result<Loaded> {
    use std::io::Seek;
    let mut head = vec![0u8; 512];
    f.rewind()?;
    f.read_exact(&mut head)?;
    let w = |i: usize| u32::from_le_bytes(head[i..i + 4].try_into().unwrap());
    let entry = w(4);
    let n = w(8) as usize;
    if n > 40 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "snapshot names an implausible number of regions",
        ));
    }
    for i in 0..n {
        let base = w(12 + i * 12);
        let len = w(16 + i * 12);
        let blk = w(20 + i * 12);
        let nblocks = (len + 511) / 512;
        f.seek(std::io::SeekFrom::Start(blk as u64 * 512))?;
        let mut buf = vec![0u8; (nblocks * 512) as usize];
        f.read_exact(&mut buf)?;
        let s = base as usize;
        let e = s + len as usize;
        let ram = m.ram_mut();
        if e <= ram.len() {
            ram[s..e].copy_from_slice(&buf[..len as usize]);
        }
    }
    Ok(Loaded { entry })
}

pub fn load(m: &mut Machine, path: &str) -> std::io::Result<Loaded> {
    let mut f = std::fs::File::open(path)?;
    let mut head = [0u8; 20];
    f.read_exact(&mut head)?;
    if u32::from_le_bytes(head[0..4].try_into().unwrap()) == SNAP_MAGIC {
        return load_snapshot(m, &mut f);
    }
    if &head[0..8] != MAGIC {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "not an LM image",
        ));
    }
    let version = u32::from_le_bytes(head[8..12].try_into().unwrap());
    if version != 1 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("image format version {version} is not supported"),
        ));
    }
    let entry = u32::from_le_bytes(head[12..16].try_into().unwrap());
    let n = u32::from_le_bytes(head[16..20].try_into().unwrap()) as usize;

    let mut addrs = vec![0u32; n];
    let mut buf = vec![0u8; n * 4];
    f.read_exact(&mut buf)?;
    for (i, a) in addrs.iter_mut().enumerate() {
        *a = u32::from_le_bytes(buf[i * 4..i * 4 + 4].try_into().unwrap());
    }
    let mut page = vec![0u8; PAGE as usize];
    for &a in &addrs {
        f.read_exact(&mut page)?;
        let s = a as usize;
        let e = s + PAGE as usize;
        let ram = m.ram_mut();
        if e <= ram.len() {
            ram[s..e].copy_from_slice(&page);
        }
    }
    Ok(Loaded { entry })
}
