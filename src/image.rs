//! Image files: a snapshot of the machine's memory and its tags.
//!
//! An image is a heap, not a program. It holds the symbols, the compiled
//! code, the boot list and whatever else the system had built when it was
//! written, at the addresses they occupy again when loaded. Every pointer in
//! it is a tagged capability, so the tags are saved with the bytes: without
//! them a pointer would come back as a number.
//!
//! The file is a list of 4 KiB pages that hold something, each followed by
//! its 512 tag bits, one per granule. Most of a running machine's memory is
//! zero: stacks, the mark bitmap, unfilled heap. Skipping those pages keeps
//! the file the size of its contents.

use crate::mach::Machine;
use crate::map::*;
use std::io::{Read, Seek, Write};

pub const MAGIC: &[u8; 8] = b"LMIMAGE1";
/// Version 2 carries tags.
pub const VERSION: u32 = 2;
pub const PAGE: u32 = 4096;
/// A page's tags: one bit per 8-byte granule, the lowest granule in bit 0
/// of the first byte.
pub const PAGE_TAG_BYTES: usize = (PAGE / 8 / 8) as usize;

/// The regions saved, from each base to as far as its allocator has reached.
/// Everything outside them (the mark bitmap, the free area above the heap)
/// is reconstructed at load rather than stored.
fn regions(m: &Machine) -> Vec<(u32, u32)> {
    let g = |off: u32| m.load_cap(off).addr;
    vec![
        (0, TRAP_BASE), // nil cell, globals, object bins
        (POOL_BASE, g(LG_POOLPTR)),
        (CODE_BASE, g(LG_CODE_PTR)),
        (CONS_BASE, g(LG_CONS_PTR)),
        (OBJ_BASE, g(LG_OBJ_PTR)),
    ]
}

/// The tags of `n` granules from `a`, packed as a page's are.
fn tags_of(m: &Machine, a: u32, n: u32) -> Vec<u8> {
    let g = (a / 8) as usize;
    let mut out = vec![0u8; (n as usize).div_ceil(8)];
    for (i, &t) in m.tags()[g..g + n as usize].iter().enumerate() {
        out[i / 8] |= (t & 1) << (i % 8);
    }
    out
}

/// Set the tags of the granules from `a` to packed bits, one granule for
/// each bit.
fn set_tags(m: &mut Machine, a: u32, bits: &[u8]) {
    let g = (a / 8) as usize;
    let tags = m.tags_mut();
    let n = (bits.len() * 8).min(tags.len().saturating_sub(g));
    for (i, t) in tags[g..g + n].iter_mut().enumerate() {
        *t = (bits[i / 8] >> (i % 8)) & 1;
    }
}

pub fn save(m: &Machine, path: &str, entry: u32) -> std::io::Result<(usize, usize)> {
    let mut pages: Vec<(u32, &[u8], Vec<u8>)> = Vec::new();
    let ram = m.ram();
    for (base, end) in regions(m) {
        let lo = base & !(PAGE - 1);
        let hi = (end + PAGE - 1) & !(PAGE - 1);
        for a in (lo..hi).step_by(PAGE as usize) {
            let (s, e) = (a as usize, (a + PAGE) as usize);
            if e > ram.len() {
                continue;
            }
            let data = &ram[s..e];
            let tags = tags_of(m, a, PAGE / 8);
            if data.iter().any(|&b| b != 0) || tags.iter().any(|&b| b != 0) {
                pages.push((a, data, tags));
            }
        }
    }
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(MAGIC)?;
    f.write_all(&VERSION.to_le_bytes())?;
    f.write_all(&entry.to_le_bytes())?;
    f.write_all(&(pages.len() as u32).to_le_bytes())?;
    for (addr, _, _) in &pages {
        f.write_all(&addr.to_le_bytes())?;
    }
    for (_, data, tags) in &pages {
        f.write_all(data)?;
        f.write_all(tags)?;
    }
    f.flush()?;
    Ok((pages.len(), pages.len() * (PAGE as usize + PAGE_TAG_BYTES)))
}

pub struct Loaded {
    pub entry: u32,
}

/// A snapshot written by the machine itself, through the disk device. The
/// first block is the header: the magic, the entry, the number of regions,
/// and then for each region its base, its length in bytes, the block its
/// bytes start at and the block its tags start at. The tags are one bit per
/// granule of the region, packed as an image page's are. The machine cannot
/// address a tag, so it writes them out as it finds them with `cgettag`.
pub const SNAP_MAGIC: u32 = 0x3253_4D4C; // "LMS2", little-endian
const SNAP_REGION_BYTES: usize = 16;
const SNAP_MAX_REGIONS: usize = (512 - 12) / SNAP_REGION_BYTES;

fn invalid(msg: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, msg.to_string())
}

fn load_snapshot(m: &mut Machine, f: &mut (impl Read + Seek)) -> std::io::Result<Loaded> {
    let mut head = vec![0u8; 512];
    f.rewind()?;
    f.read_exact(&mut head)?;
    let w = |i: usize| u32::from_le_bytes(head[i..i + 4].try_into().unwrap());
    let entry = w(4);
    let n = w(8) as usize;
    if n > SNAP_MAX_REGIONS {
        return Err(invalid("snapshot names an implausible number of regions"));
    }
    for i in 0..n {
        let e = 12 + i * SNAP_REGION_BYTES;
        let (base, len, blk, tagblk) = (w(e), w(e + 4), w(e + 8), w(e + 12));
        // The table comes from the file. A region is read straight into
        // memory, and only if it fits: a length is not a size to allocate.
        let ram = m.ram_mut();
        if base % 8 != 0 || len as usize > ram.len() || base as usize > ram.len() - len as usize {
            return Err(invalid("snapshot region lies outside memory"));
        }
        f.seek(std::io::SeekFrom::Start(blk as u64 * 512))?;
        let s = base as usize;
        f.read_exact(&mut ram[s..s + len as usize])?;
        let mut bits = vec![0u8; (len as usize / 8).div_ceil(8)];
        f.seek(std::io::SeekFrom::Start(tagblk as u64 * 512))?;
        f.read_exact(&mut bits)?;
        set_tags(m, base, &bits);
    }
    Ok(Loaded { entry })
}

pub fn load(m: &mut Machine, path: &str) -> std::io::Result<Loaded> {
    let mut f = std::io::BufReader::new(std::fs::File::open(path)?);
    load_from(m, &mut f)
}

/// Load from anything readable: a file, or bytes in memory.
pub fn load_from(m: &mut Machine, f: &mut (impl Read + Seek)) -> std::io::Result<Loaded> {
    let mut head = [0u8; 20];
    f.read_exact(&mut head)?;
    if u32::from_le_bytes(head[0..4].try_into().unwrap()) == SNAP_MAGIC {
        return load_snapshot(m, f);
    }
    if &head[0..8] != MAGIC {
        return Err(invalid("not an LM image"));
    }
    let version = u32::from_le_bytes(head[8..12].try_into().unwrap());
    if version != VERSION {
        return Err(invalid(&format!("image format version {version} is not supported")));
    }
    let entry = u32::from_le_bytes(head[12..16].try_into().unwrap());
    let n = u32::from_le_bytes(head[16..20].try_into().unwrap()) as usize;
    // Memory has this many pages, so no image has more; a count past it is
    // damage, not a size to allocate.
    if n > (RAM_SIZE / PAGE) as usize {
        return Err(invalid("image names more pages than memory holds"));
    }

    let mut buf = vec![0u8; n * 4];
    f.read_exact(&mut buf)?;
    let addrs: Vec<u32> = buf
        .chunks_exact(4)
        .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
        .collect();
    let mut page = vec![0u8; PAGE as usize];
    let mut tags = [0u8; PAGE_TAG_BYTES];
    for &a in &addrs {
        f.read_exact(&mut page)?;
        f.read_exact(&mut tags)?;
        let s = a as usize;
        let e = s + PAGE as usize;
        if a % PAGE == 0 && e <= m.ram().len() {
            m.ram_mut()[s..e].copy_from_slice(&page);
            set_tags(m, a, &tags);
        }
    }
    Ok(Loaded { entry })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::heap::*;

    /// A heap with pairs, objects and globals in it goes out and comes back
    /// with every byte and every tag where it was.
    #[test]
    fn round_trip_keeps_tags() {
        let mut m = Machine::new();
        let mut h = Heap::new(&mut m);
        h.format();
        let s = h.intern("round-trip");
        let v = h.vector(&[fix(-7), chr('x' as u32), s, NIL]);
        let l = h.list(&[v, fix(1 << 30), s]);
        h.set_gv(LG_ROOTS, l);
        let path = std::env::temp_dir().join(format!("lm-image-test-{}.img", std::process::id()));
        let path = path.to_str().unwrap();
        save(&m, path, 0x0100_0000).unwrap();

        let mut back = Machine::new();
        let loaded = load(&mut back, path).unwrap();
        let _ = std::fs::remove_file(path);
        assert_eq!(loaded.entry, 0x0100_0000);
        for (base, end) in regions(&m) {
            for a in (base..end).step_by(8) {
                assert_eq!(m.load_cap(a), back.load_cap(a), "granule {a:#x}");
            }
        }
        let h = Heap::new(&mut back);
        let l = h.gv(LG_ROOTS);
        assert!(is_cons(l));
        let v = h.car(l);
        assert!(h.is_type(v, T_VECTOR));
        assert_eq!(h.write(l), "(#(-7 #\\x round-trip nil) 1073741824 round-trip)");
    }

    /// An image of format version 1, which has no tags, is refused.
    #[test]
    fn untagged_format_is_refused() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(MAGIC);
        bytes.extend_from_slice(&1u32.to_le_bytes());
        bytes.extend_from_slice(&[0; 8]);
        let mut m = Machine::new();
        assert!(load_from(&mut m, &mut std::io::Cursor::new(bytes)).is_err());
    }
}
