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
//! Liveness is not recomputed. `collect-for-image` has already run a full
//! collection with the machine's own root set, and it leaves object space as
//! a walkable sequence of live blocks and `t-free` holes. The holes are the
//! answer; this only closes them.

use crate::cap::{self, Cap};
use crate::heap::*;
use crate::map::*;

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
fn rewrite(h: &mut Heap, moves: &[Move], lo: u32, hi: u32) -> Result<(), String> {
    for at in h.tagged() {
        let c = h.ldc(at);
        // A headed capability's block is the one holding its header, which
        // for an object with no payload is not the block its base is in.
        let b = if c.perms() & cap::P_HD != 0 { c.base().wrapping_sub(8) } else { c.base() };
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
    rewrite(h, &moves, lo, hi)?;

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

pub struct CodeStats {
    pub before: u32,
    pub after: u32,
    pub moved: u32,
}

/// A fresh image's pool holds nothing a booting machine reads. Below the code
/// registry is the forge's scratch (trap frames, the trap stack, the boot
/// stack), which is written before it is read; and the registry is live only
/// as far as its count. What is left in them is stale values from the
/// machine that wrote the image, and a stale capability keeps what it names
/// alive and in the file.
fn blank_fresh_pool(h: &mut Heap) {
    let reg = h.g(LG_CODEREG);
    if reg < POOL_BASE + 8 || reg >= POOL_END {
        return;
    }
    let block = reg - 8;
    for a in (POOL_BASE..block).step_by(8) {
        h.stc(a, Cap::NULL);
    }
    let end = (block + h.ld(block)).min(h.g(LG_POOLPTR)).min(POOL_END);
    for a in (reg + h.g(LG_CODEREGN) * VALUE_BYTES..end).step_by(8) {
        h.stc(a, Cap::NULL);
    }
}

/// A block of code space starts with a header of two granules, its size and
/// the code object that owns it, and its code follows (see `alloc-code` in
/// gc.lisp). A free block's header is its size and the next free block.
pub const CODE_HEADER_BYTES: u32 = 16;

/// Where a code block's code is aligned: as its bounds need, and to the
/// header at least.
fn code_align(len: u32) -> u32 {
    cap::ram(len) & !(CODE_HEADER_BYTES - 1)
}

/// Slide code space down, for an image that boots through its kickstart.
///
/// That is what makes it possible. Such an image resumes nothing, so no stack
/// holds a return sentry into code; and compiled code names other code only
/// through capabilities, a code object's entry and the closures made from
/// it, while a jump within a function is relative to itself. So a code block
/// can go anywhere, and what has to change with it is every capability into
/// it, which the tags find.
///
/// An image from `(save-image)` holds code the running machine placed with
/// no code object to own it, the stub every task returns into among it, and
/// this must never be used on one.
///
/// Two things stay exactly where they are: the reset stub at the base, which
/// has no header, and the trap stub at `lg-trap-entry`, which is a block no
/// code object owns. Everything else that is not a live code object's block
/// is garbage: dead code the collector freed, and code the forge ran once.
pub fn compact_code(h: &mut Heap, verbose: bool) -> Result<CodeStats, String> {
    let lo = CODE_BASE;
    let hi = h.g(LG_CODE_PTR);
    if hi <= lo + RESET_RESERVE {
        let n = hi.saturating_sub(lo);
        return Ok(CodeStats { before: n, after: n, moved: 0 });
    }

    // Every live code object's block: where it starts, its size, and the
    // alignment its code needs.
    let mut code: Vec<(u32, u32, u32)> = Vec::new();
    for (b, _, _) in live_blocks(h)? {
        if hdr_type(h.ld(b)) != T_CODE {
            continue;
        }
        let entry = h.ldc(b + HEADER_BYTES + CODE_ENTRY * VALUE_BYTES);
        let base = entry.base();
        if !entry.tag || base < lo + RESET_RESERVE + CODE_HEADER_BYTES || base >= hi {
            continue;
        }
        let start = base - CODE_HEADER_BYTES;
        let size = h.g(start);
        let len = entry.len() as u32;
        if size < CODE_HEADER_BYTES + len || start + size > hi {
            return Err(format!("the code block at {start:#x} says it is {size} bytes"));
        }
        code.push((start, size, code_align(len)));
    }
    code.sort();
    for w in code.windows(2) {
        if w[0].0 + w[0].1 > w[1].0 {
            return Err(format!("two code objects share the bytes at {:#x}", w[1].0));
        }
    }

    let mut pins: Vec<(u32, u32)> = vec![(lo, lo + RESET_RESERVE)];
    let stub = h.g(LG_TRAPENTRY);
    if stub >= lo + RESET_RESERVE + CODE_HEADER_BYTES && stub < hi {
        let start = stub - CODE_HEADER_BYTES;
        pins.push((start, (start + h.g(start)).min(hi)));
    }
    pins.sort();

    // The only capability code space holds is a block's owner, in the
    // second granule of its header.
    for at in h.tagged().into_iter().filter(|a| (lo..hi).contains(a)) {
        if !code.iter().any(|c| c.0 + 8 == at) {
            return Err(format!("code space holds a capability that owns nothing, at {at:#x}"));
        }
    }

    // Every block, in address order, into the first room past the last one
    // placed where its code is aligned for its bounds and it does not run
    // into something pinned.
    let mut moves: Vec<Move> = Vec::with_capacity(code.len());
    let mut free = lo;
    let mut pi = 0;
    for &(from, size, mask) in &code {
        let place = |at: u32| align_up(at + CODE_HEADER_BYTES, mask) - CODE_HEADER_BYTES;
        let mut to = place(free);
        loop {
            while pi < pins.len() && pins[pi].1 <= to {
                pi += 1;
            }
            if pi < pins.len() && to + size > pins[pi].0 {
                to = place(pins[pi].1);
                continue;
            }
            break;
        }
        moves.push(Move { from, size, to });
        free = to + size;
    }
    let new_hi = pins.iter().fold(free, |m, p| m.max(p.1));

    // Capabilities into the pinned stubs stay as they are; every other one
    // into code space must be into a code object's block.
    let mut owners = moves.clone();
    owners.extend(pins.iter().map(|&(s, e)| Move { from: s, size: e - s, to: s }));
    owners.sort_by_key(|m| m.from);
    rewrite(h, &owners, lo, hi)?;

    // Take every block out, granule by granule with its tag, blank everything
    // that is not pinned, and put the blocks back where they go. Copying out
    // first is what lets a block land anywhere, without a care for what it
    // overlaps.
    let saved: Vec<Vec<Cap>> = moves
        .iter()
        .map(|m| (0..m.size / 8).map(|i| h.ldc(m.from + i * 8)).collect())
        .collect();
    let pinned = |a: u32| pins.iter().any(|p| a >= p.0 && a < p.1);
    for a in (lo..hi.max(new_hi)).step_by(8) {
        if !pinned(a) {
            h.stc(a, Cap::NULL);
        }
    }
    let mut moved = 0;
    for (m, granules) in moves.iter().zip(&saved) {
        for (k, c) in granules.iter().enumerate() {
            h.stc(m.to + 8 * k as u32, *c);
        }
        if m.to != m.from {
            moved += 1;
        }
    }

    // The free list: every gap big enough for a header, which is the same
    // rule the collector keeps to.
    let mut spans: Vec<(u32, u32)> = pins.clone();
    spans.extend(moves.iter().map(|m| (m.to, m.to + m.size)));
    spans.sort();
    let mut head = 0u32;
    let mut freen = 0u32;
    let mut at = lo;
    for &(s, e) in &spans {
        if s >= at + CODE_HEADER_BYTES {
            h.set_g(at, s - at);
            h.set_g(at + 8, head);
            head = at;
            freen += s - at;
        }
        at = at.max(e);
    }
    h.set_g(LG_CODEFREE, head);
    h.set_g(LG_CODEFREEN, freen);
    h.set_g(LG_CODE_PTR, new_hi);

    let stats = CodeStats { before: hi - lo, after: new_hi - lo, moved };
    if verbose {
        eprintln!(
            "compacted code: {} KiB to {} KiB, {} of {} code objects moved",
            stats.before / 1024,
            stats.after / 1024,
            stats.moved,
            moves.len()
        );
    }
    Ok(stats)
}

/// Compact a saved image, without running it.
///
/// The same pass the build uses, on an image that came off the disk. A fresh
/// image, which `rebuild` makes and which boots through its kickstart and
/// resumes nothing, can have more done to it: the pool's scratch is blanked,
/// and code space is slid down as well.
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
    let code = if fresh {
        match compact_code(&mut h, verbose) {
            Ok(s) => format!("code {} KiB to {} KiB, ", s.before / 1024, s.after / 1024),
            Err(e) => {
                eprintln!("lm: compacting code in {from}: {e}");
                return 1;
            }
        }
    } else {
        String::new()
    };
    match crate::image::save(&m, out, entry) {
        Ok((pages, bytes)) => {
            println!(
                "{out}: objects {} KiB to {} KiB live, {code}{} pages ({} KiB)",
                stats.before / 1024,
                stats.used / 1024,
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
        let l = h.list(&[a, c, d, inner]);
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
        let (a, c, d, inner) = (items[0], items[1], items[2], items[3]);
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
        assert!(h.blocks().is_ok());
    }
}
