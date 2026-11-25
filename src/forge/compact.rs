//! Sliding object space down, on a heap that has stopped.
//!
//! Objects are never moved by the machine's own collector, and the reason is
//! in `gc.lisp`: that collector is written in the language it collects, and
//! reaches its functions through symbol value cells and its constants through
//! its own code object. Every one of those is an object. Move them and it
//! loses the ability to run, halfway through running.
//!
//! None of that applies here. The forge is not made of Lisp objects, and by
//! the time this runs the heap has stopped: the machine is not executing and
//! no task holds a register. Every pointer is a tagged capability and the
//! tags say exactly where they are, so every one is found and none is
//! guessed at.
//!
//! Machine code is in object space and slides with everything else. A jump
//! within a function is relative to itself, and anything else reaches code
//! through a capability, a code object's entry or a return address, which is
//! rewritten like any other. The one capability to code that is not in
//! memory is MTCC, and the reset stub loads that from `lg-trap-entry` every
//! time the machine starts.
//!
//! Liveness is not recomputed. `collect-for-image` has already run a full
//! collection with the machine's own root set, and it leaves object space as
//! a walkable sequence of live blocks and `t-free` holes. The holes are the
//! answer; this only closes them.

use crate::cap::{self, Cap};
use crate::heap::*;
use crate::map::*;
use crate::mach::CTX_BYTES;

pub struct Stats {
    pub before: u32,
    pub after: u32,
    /// Bytes occupied by live blocks. Below `after` by what alignment for
    /// bounds leaves between them.
    pub used: u32,
    pub moved: u32,
}

/// A block that moves: where it was, how long it is, and where it goes.
#[derive(Clone, Copy)]
struct Move {
    from: u32,
    size: u32,
    to: u32,
}

/// The move whose block holds address `a`, if any. `moves` is in ascending
/// order of `from`.
fn mover(moves: &[Move], a: u32) -> Option<&Move> {
    let i = moves.partition_point(|m| m.from <= a);
    let m = moves.get(i.checked_sub(1)?)?;
    (a < m.from + m.size).then_some(m)
}

/// The same capability, its bounds and its address `delta` bytes further on:
/// derived again from the root, with the same permissions and the same seal.
fn slid(c: Cap, delta: u32) -> Cap {
    let n = cap_to(c.base().wrapping_add(delta), c.len() as u32, c.perms())
        .with_addr(c.addr.wrapping_add(delta));
    n.seal(c.otype())
}

/// Rewrite every tagged capability in memory whose bounds lie in a block
/// that moves, so that it names the block where it is going. One whose base
/// lies in `lo..hi` but in no block would be a pointer to nothing, and is an
/// error, except in the pool: a stack slot below a stack pointer, or one a
/// frame has not written yet, holds what an earlier call left there, and the
/// stacks of a saved image are all dead. The collector believes nothing it
/// finds there without its header, so such a capability names nothing it
/// kept, and loses its tag. One that reaches past its block names a region,
/// not a block, and stays as it is.
///
/// In object space every capability names the block holding the granule
/// below its base (`below`): a headed one's header, and one narrowed into a
/// payload, or to nothing at its end, the object it was cut from, as the
/// collector reads it. Its bounds slide with the block, which keeps them
/// representable because the block's payload keeps its alignment.
fn rewrite(h: &mut Heap, moves: &[Move], lo: u32, hi: u32, below: bool) -> Result<(), String> {
    for at in h.tagged() {
        let c = h.ldc(at);
        // A headed capability's block is the one holding its header, which
        // for an object with no payload is not the block its base is in.
        let b = if c.perms() & cap::P_HD != 0 || (below && c.base() > lo) {
            c.base().wrapping_sub(8)
        } else {
            c.base()
        };
        if b < lo || b >= hi {
            continue;
        }
        match mover(moves, b) {
            Some(m) if m.to != m.from && c.top() as u64 <= (m.from + m.size) as u64 => {
                let n = slid(c, m.to.wrapping_sub(m.from));
                h.stc(at, n);
            }
            Some(_) => {}
            None if (POOL_BASE..POOL_END).contains(&at) => h.stc(at, c.without_tag()),
            None => {
                let holder = match mover(moves, at) {
                    Some(m) => format!("in the block at {:#x}, type {}", m.from, h.ld(m.from) & 255),
                    None => "outside every block".to_string(),
                };
                return Err(format!(
                    "the capability at {at:#x} ({holder}) names {b:#x} (length {}, permissions {:#x}, header {:#x}), which nothing occupies",
                    c.len(),
                    c.perms(),
                    h.ld(b)
                ));
            }
        }
    }
    Ok(())
}

/// Every live block in object space, in address order, with its size and the
/// alignment its bounds need, as CRAM gives it. What a hole held is dead, and
/// is blanked here, so that nothing in one is taken for a pointer.
fn live_blocks(h: &mut Heap) -> Result<Vec<(u32, u32, u32)>, String> {
    let blocks = h.blocks().map_err(|p| format!("corrupt object header at {p:#x}: {:#x}", h.ld(p)))?;
    let mut out = Vec::new();
    for (p, hdr) in blocks {
        let sz = block_size(hdr);
        if hdr_type(hdr) == T_FREE {
            for a in (p + HEADER_BYTES..p + sz).step_by(8) {
                h.stc(a, Cap::NULL);
            }
        } else {
            out.push((p, sz, cap::ram(payload_bytes(hdr))));
        }
    }
    Ok(out)
}

/// Make `len` bytes at `at` a hole, and put it on its bin if it is big
/// enough to say where the next one is. Answers the bytes freed.
fn free_hole(h: &mut Heap, at: u32, len: u32) -> u32 {
    let gran = len / 8;
    h.hole(at, len);
    if gran >= 2 {
        let bin = OBJ_BINS + (if gran < OBJ_BIN_COUNT { gran } else { 0 }) * VALUE_BYTES;
        let head = h.ldc(bin);
        h.stc(at + HEADER_BYTES, head);
        h.set_g(bin, at);
    }
    for a in (at + 2 * VALUE_BYTES..at + len).step_by(8) {
        h.stc(a, Cap::NULL);
    }
    len
}

pub fn compact_objects(h: &mut Heap, verbose: bool) -> Result<Stats, String> {
    let lo = OBJ_BASE;
    let hi = h.g(LG_OBJ_PTR);
    let blocks = live_blocks(h)?;

    // Where everything lands: as low as it will go with its payload aligned
    // as it was, which keeps its bounds representable.
    let mut free = lo;
    let mut used = 0;
    let mut moves: Vec<Move> = Vec::with_capacity(blocks.len());
    for &(from, size, mask) in &blocks {
        let to = align_up(free + HEADER_BYTES, mask) - HEADER_BYTES;
        moves.push(Move { from, size, to });
        free = to + size;
        used += size;
    }

    // Rewrite every pointer before anything moves: after this pass the heap
    // names where everything is going, and nothing may be dereferenced until
    // it is there.
    rewrite(h, &moves, lo, hi, true)?;
    // The object-start map describes the blocks where they were: the next
    // collection builds it again.
    h.m.poke32(OBJ_STARTS_READY, 0);

    // Slide, a granule at a time with its tag. Ascending, and every block
    // moves down, so a block that overlaps its own destination copies
    // correctly and never reaches the next one.
    let mut moved = 0;
    for m in &moves {
        if m.to != m.from {
            moved += 1;
            for k in (0..m.size).step_by(8) {
                let c = h.ldc(m.from + k);
                h.stc(m.to + k, c);
            }
        }
    }

    // Whatever is not a live block is a hole, and the bins are built again
    // from them. The header on each is what lets the next collection walk
    // object space at all, and blanking the rest is what lets the image
    // writer skip a page. The tail above the last block is not a hole on a
    // bin but unclaimed ground the allocator bumps into, so it is only
    // blanked.
    for b in 0..OBJ_BIN_COUNT {
        h.set_g(OBJ_BINS + b * VALUE_BYTES, 0);
    }
    let mut freed = 0;
    let mut cursor = lo;
    for m in &moves {
        if m.to > cursor {
            freed += free_hole(h, cursor, m.to - cursor);
        }
        cursor = m.to + m.size;
    }
    for a in (free..hi).step_by(8) {
        h.stc(a, Cap::NULL);
    }
    h.set_g(LG_OBJ_PTR, free);
    h.set_g(LG_OBJFREEN, freed);

    let stats = Stats { before: hi - lo, after: free - lo, used, moved };
    if verbose {
        eprintln!(
            "compacted objects: {} KiB to {} KiB ({} KiB live), {} blocks moved",
            stats.before / 1024,
            stats.after / 1024,
            stats.used / 1024,
            stats.moved
        );
    }
    Ok(stats)
}

/// A fresh image's pool starts with the forge's scratch: the boot stack, the
/// trap stack and the trap frames, ending with the boot context at
/// `lg-trapsave`. A booting machine writes all of it before it reads any, so
/// what is left there is stale values from the machine that wrote the image,
/// and a stale capability keeps what it names alive and in the file.
fn blank_fresh_pool(h: &mut Heap) {
    let end = h.g(LG_TRAPSAVE) + CTX_BYTES;
    if end <= POOL_BASE || end > POOL_END {
        return;
    }
    for a in (POOL_BASE..end).step_by(8) {
        h.stc(a, Cap::NULL);
    }
}

/// Compact a saved image, without running it.
///
/// The same pass the build uses, on an image that came off the disk. Code is
/// in object space and slides with the rest: a jump within a function is
/// relative to itself, and everything else reaches code through a
/// capability, an entry or a return address, which the rewrite finds like
/// any other. A fresh image, which `rebuild` makes and which boots through
/// its kickstart and resumes nothing, can have its pool's scratch blanked as
/// well.
pub fn compact_image(from: &str, out: &str, verbose: bool, fresh: bool) -> i32 {
    let mut m = crate::mach::Machine::new();
    let loaded = match crate::image::load(&mut m, from) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("lm: cannot load {from}: {e}");
            return 1;
        }
    };
    let entry = loaded.entry;
    let mut h = Heap::new(&mut m);
    if fresh {
        blank_fresh_pool(&mut h);
    }
    let stats = match compact_objects(&mut h, verbose) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("lm: compacting {from}: {e}");
            return 1;
        }
    };
    let code = h.text_bytes();
    match crate::image::save(&m, out, entry) {
        Ok((pages, bytes)) => {
            println!(
                "{out}: objects {} KiB to {} KiB live, {} KiB of it code, {} pages ({} KiB)",
                stats.before / 1024,
                stats.used / 1024,
                code / 1024,
                pages,
                bytes / 1024
            );
            0
        }
        Err(e) => {
            eprintln!("lm: cannot write {out}: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Holes close, what is live slides down keeping its alignment, and
    /// every capability to a moved object, wherever it is and however it was
    /// narrowed, follows it.
    #[test]
    fn sliding_keeps_every_pointer() {
        let mut m = crate::mach::Machine::new();
        let mut h = Heap::new(&mut m);
        h.format();
        let a = h.vector(&[fix(1), fix(2), fix(3)]);
        let dead = h.bytes(&[1u8; 3000]);
        let c = h.alloc_obj(T_VECTOR, 300);
        let d = h.bytes(&[7u8; 5000]);
        h.set_slot(c, 0, d);
        h.set_slot(c, 299, a);
        h.set_slot(a, 1, c);
        let inner = d.inc(100).with_bounds(16).unwrap();
        // Narrowed to nothing at the end of its payload: its base is the next
        // block's header, and it still names `c`.
        let end = c.inc(2400).with_bounds(0).unwrap();
        let l = h.list(&[a, c, d, inner, end]);
        h.set_gv(LG_ROOTS, l);
        // What the collector does to the dead object.
        let at = dead.addr - HEADER_BYTES;
        let size = block_size(h.ld(at));
        h.hole(at, size);
        let before = h.g(LG_OBJ_PTR);

        let st = compact_objects(&mut h, false).unwrap();
        assert_eq!(st.moved, 2);
        assert!(h.g(LG_OBJ_PTR) < before);
        let items = h.list_vec(h.gv(LG_ROOTS));
        let (a, c, d, inner, end) = (items[0], items[1], items[2], items[3], items[4]);
        assert_eq!(h.slot(a, 0), fix(1));
        assert_eq!(h.slot(a, 1), c);
        assert_eq!(h.slot(c, 0), d);
        assert_eq!(h.slot(c, 299), a);
        assert_eq!(h.olen(c), 300);
        assert_eq!(h.olen(d), 5000);
        assert_eq!(d.addr & !cap::ram(5000), 0);
        assert_eq!(h.m.peek8(d.addr + 4999), 7);
        assert_eq!(inner.base(), d.addr + 100);
        assert_eq!(inner.len(), 16);
        assert_eq!(end.base(), c.addr + 2400);
        assert_eq!(end.len(), 0);
        assert!(h.blocks().is_ok());
    }
}
