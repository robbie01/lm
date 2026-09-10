//! Sliding object space down, on a heap that has stopped.
//!
//! Objects are never moved by the machine's own collector, and the reason is
//! in `gc.lisp`: that collector is written in the language it collects, and
//! reaches its functions through symbol value cells and its constants through
//! the literal vector of its own code object. Every one of those is an object.
//! Move them and it loses the ability to run, halfway through running.
//!
//! None of that applies here. The forge is not made of Lisp objects, and by
//! the time this runs the heap has stopped: the machine is not executing, no
//! task holds a register, and the only things that name an object are places
//! this file can enumerate. So the one thing the machine cannot do to itself,
//! the forge can do to it on the way out - which is the whole of the argument
//! for doing it here, and the reason it is worth having even though the
//! machine will one day want to do it alone.
//!
//! Liveness is not recomputed. `gc-for-image` has already run a full
//! collection with the machine's own root set, which knows about task stacks
//! and pinned registers and everything else this side would have to guess at,
//! and it leaves object space as a walkable sequence of live blocks and
//! `t-free` holes. The holes are the answer; this only closes them.

use crate::heap::*;
use crate::map::*;

pub struct Stats {
    pub before: u32,
    pub after: u32,
    /// Bytes actually occupied by live blocks. Below `after` whenever a pin
    /// holds the top of the heap up and leaves holes underneath it.
    pub used: u32,
    pub moved: u32,
    pub pinned: u32,
}

/// A live object rounds its payload up to eight; a hole records its own size
/// in granules where a live object keeps its length.
fn block_size(hdr: u32) -> u32 {
    if hdr_type(hdr) == T_FREE {
        hdr_len(hdr) * 8
    } else {
        obj_size(hdr)
    }
}

/// The global slots that hold a tagged Lisp value. Every other slot holds a
/// raw address or a count, and rewriting one would be a bug - which is why
/// this is a list and not a scan of the whole global block.
const TAGGED_GLOBALS: &[u32] = &[
    LG_SYMLIST,
    LG_OBARRAY,
    LG_PACKAGES,
    LG_PACKAGE,
    LG_BOOTLIST,
    LG_ROOTS,
    LG_TOPLEVEL,
    LG_ERRHANDLER,
    LG_TRAPHOOK,
    LG_REFILL,
    LG_STARTUP,
    LG_SCRATCH0,
];

struct Plan {
    lo: u32,
    hi: u32,
    /// New address of the block starting here, indexed by granule.
    fwd: Vec<u32>,
    live: Vec<bool>,
}

impl Plan {
    fn idx(&self, block: u32) -> usize {
        ((block - self.lo) / 8) as usize
    }
    /// Where a tagged value points after the slide. Anything that is not an
    /// object pointer into the moved range answers itself.
    fn remap(&self, v: V) -> V {
        if !is_obj(v) {
            return v;
        }
        let b = v - 4;
        if b < self.lo || b >= self.hi {
            return v;
        }
        let i = self.idx(b);
        if !self.live[i] {
            return v;
        }
        self.fwd[i] + 4
    }
}

/// The tagged slots of a live object, by the rule the collector uses.
fn tagged_slots(h: &Heap, block: u32) -> std::ops::Range<u32> {
    let hdr = h.ld(block);
    let len = hdr_len(hdr);
    match hdr_type(hdr) {
        T_SYMBOL => 0..SYM_SLOTS,
        T_STRING | T_BYTES | T_FLOAT | T_BIGNUM => 0..0,
        // Slots 0 and 1 are a raw entry address and a raw byte length.
        T_CODE => CODE_NAME..len,
        // Slot 0 is a raw entry address; following it would be a bug.
        T_CLOSURE => 1..len,
        _ => 0..len,
    }
}

pub fn compact_objects(h: &mut Heap, verbose: bool) -> Result<Stats, String> {
    let lo = OBJ_BASE;
    let hi = h.g(LG_OBJ_PTR);
    if hi <= lo {
        return Ok(Stats { before: 0, after: 0, used: 0, moved: 0, pinned: 0 });
    }
    let n = ((hi - lo) / 8) as usize;
    let mut plan = Plan { lo, hi, fwd: vec![0; n], live: vec![false; n] };

    // Where the blocks are. A zero-sized block would be a corrupt header and
    // would spin here forever, so it is an error rather than a hang.
    let mut p = lo;
    while p < hi {
        let hdr = h.ld(p);
        let sz = block_size(hdr);
        if sz == 0 || p + sz > hi {
            return Err(format!("corrupt object header at {p:#x}: {hdr:#x}"));
        }
        if hdr_type(hdr) != T_FREE {
            let i = plan.idx(p);
            plan.live[i] = true;
        }
        p += sz;
    }

    // Anything the Exec pool names must stay where it is: those words are raw,
    // so a match may be a coincidence, and a coincidence must not be rewritten.
    // The code registry is the exception - it is a real array of real object
    // pointers, and it is rewritten exactly, below.
    let reg = h.g(LG_CODEREG);
    let reg_end = if reg != 0 { reg + h.g(LG_CODEREGN) * 4 } else { 0 };
    let mut pinned = vec![false; n];
    let mut npinned = 0;
    let pool_hi = h.g(LG_POOLPTR).min(POOL_END);
    let mut a = POOL_BASE;
    while a < pool_hi {
        if reg != 0 && a >= reg && a < reg_end {
            a = reg_end;
            continue;
        }
        let w = h.ld(a);
        if is_obj(w) {
            let b = w - 4;
            if b >= lo && b < hi {
                let i = plan.idx(b);
                if plan.live[i] && !pinned[i] {
                    pinned[i] = true;
                    npinned += 1;
                    if verbose {
                        eprintln!(
                            "  pinned {b:#x} (type {}) by pool word at {a:#x}",
                            hdr_type(h.ld(b))
                        );
                    }
                }
            }
        }
        a += 4;
    }

    // Where everything lands. A pinned block stays put and pushes the free
    // pointer past itself; everything else slides down to meet it.
    let mut free = lo;
    let mut p = lo;
    let mut moved = 0;
    let mut used = 0;
    // Where every live block lands, in ascending destination order - which is
    // also ascending source order, because sliding cannot reorder anything.
    let mut placed: Vec<(u32, u32)> = Vec::new();
    while p < hi {
        let sz = block_size(h.ld(p));
        let i = plan.idx(p);
        if plan.live[i] {
            used += sz;
            if pinned[i] {
                plan.fwd[i] = p;
                if p + sz > free {
                    free = p + sz;
                }
            } else {
                plan.fwd[i] = free;
                if free != p {
                    moved += 1;
                }
                free += sz;
            }
            placed.push((plan.fwd[i], sz));
        }
        p += sz;
    }

    // Rewrite every pointer before anything moves, exactly as the machine's
    // own compactor does for pairs: after this pass the heap names where
    // everything is going, and nothing may be dereferenced until it is there.
    for g in TAGGED_GLOBALS {
        let v = h.g(*g);
        let w = plan.remap(v);
        if w != v {
            h.set_g(*g, w);
        }
    }
    let cons_hi = h.g(LG_CONS_PTR);
    let mut a = CONS_BASE;
    while a < cons_hi {
        let v = h.ld(a);
        let w = plan.remap(v);
        if w != v {
            h.st(a, w);
        }
        a += 4;
    }
    let mut p = lo;
    while p < hi {
        let sz = block_size(h.ld(p));
        if plan.live[plan.idx(p)] {
            for s in tagged_slots(h, p) {
                let at = p + 4 + s * 4;
                let v = h.ld(at);
                let w = plan.remap(v);
                if w != v {
                    h.st(at, w);
                }
            }
        }
        p += sz;
    }
    // The code registry lives in the pool and holds tagged code objects. It is
    // not a root - a code object is kept alive by the closure that names it -
    // but it is read after every collection, so a stale entry here is a wild
    // pointer at the next sweep.
    let mut a = reg;
    while a < reg_end {
        let v = h.ld(a);
        let w = plan.remap(v);
        if w != v {
            h.st(a, w);
        }
        a += 4;
    }

    // Slide. Ascending, and every block moves down, so a block that overlaps
    // its own destination copies correctly and never reaches the next one.
    let mut p = lo;
    while p < hi {
        let sz = block_size(h.ld(p));
        let i = plan.idx(p);
        if plan.live[i] && plan.fwd[i] != p {
            let to = plan.fwd[i];
            let mut k = 0;
            while k < sz {
                let w = h.ld(p + k);
                h.st(to + k, w);
                k += 4;
            }
        }
        p += sz;
    }

    // Whatever is not a live block is blanked, and the free lists are built
    // again from the holes that are left. Blanking is what lets the image
    // writer skip a page; the header on each hole is what lets the next
    // collection walk object space at all, since it reads a run of zeroes as a
    // block of size zero and stops with a corrupt heap.
    //
    // With no pins there is one hole, above everything, and it is the tail.
    // With a pin holding the top up there are holes underneath it too, and
    // they are worth blanking for exactly the same reason.
    for b in 0..OBJ_BIN_COUNT {
        h.st(OBJ_BINS + b * 4, 0);
    }
    let mut freed = 0u32;
    let mut hole = |h: &mut Heap, start: u32, len: u32| {
        if len < 8 {
            return;
        }
        let mut a = start + 8;
        while a < start + len {
            h.st(a, 0);
            a += 4;
        }
        let gran = len / 8;
        let bin = OBJ_BINS + if gran < OBJ_BIN_COUNT { gran * 4 } else { 0 };
        h.st(start, header(gran, T_FREE));
        h.st(start + 4, h.ld(bin));
        h.st(bin, start);
        freed += len;
    };
    let mut cursor = lo;
    for (dest, sz) in &placed {
        if *dest > cursor {
            hole(h, cursor, *dest - cursor);
        }
        cursor = dest + sz;
    }
    // The tail is not a hole on a list, it is unclaimed ground: the allocator
    // bumps into it, so it only has to be blank.
    let mut a = free;
    while a < hi {
        h.st(a, 0);
        a += 4;
    }
    h.set_g(LG_OBJ_PTR, free);
    h.set_g(LG_OBJ_FREE, 0);
    h.set_g(LG_OBJFREEN, freed);

    let stats = Stats { before: hi - lo, after: free - lo, used, moved, pinned: npinned };
    if verbose {
        eprintln!(
            "compacted objects: {} KiB to {} KiB ({} KiB live), {} blocks moved, {} pinned by the pool",
            stats.before / 1024,
            stats.after / 1024,
            stats.used / 1024,
            stats.moved,
            stats.pinned
        );
    }
    Ok(stats)
}

/// Compact a saved image, without running it.
///
/// The same pass the build uses, on an image that came off the disk. A live
/// image is a harder case than a freshly built one: Exec is up, tasks have
/// stacks, and the pool is full of words that might be pointers, so more of
/// object space ends up pinned. It is still correct, and it is still most of
/// the file.
pub fn compact_image(from: &str, out: &str, verbose: bool) -> i32 {
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
    let stats = match compact_objects(&mut h, verbose) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("lm: compacting {from}: {e}");
            return 1;
        }
    };
    match crate::image::save(&m, out, entry) {
        Ok((pages, bytes)) => {
            println!(
                "{out}: objects {} KiB to {} KiB live, {} pages ({} KiB)",
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
