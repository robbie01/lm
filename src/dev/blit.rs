//! Blitter. Rectangle moves, fills, raster ops, masked sprite copies and
//! lines, all on 8-bit chunky data.
//!
//! The chip is asynchronous and walks a chain of descriptors in memory. A
//! transfer takes as long as its memory traffic would on the target - see
//! `cost` - and when one finishes the chip goes on to the next descriptor by
//! itself. That keeps the deterministic timebase honest.

use crate::mach::Machine;
use crate::map::INT_BLIT;

pub const B_SRC: u32 = 0x00;
pub const B_DST: u32 = 0x04;
pub const B_W: u32 = 0x08;
pub const B_H: u32 = 0x0c;
pub const B_SMOD: u32 = 0x10; // source stride in bytes
pub const B_DMOD: u32 = 0x14; // destination stride in bytes
pub const B_VAL: u32 = 0x18; // fill value, or the transparent key
pub const B_OP: u32 = 0x1c; // write starts the operation
pub const B_STATUS: u32 = 0x20; // bit0: a transfer is running
pub const B_X0: u32 = 0x24;
pub const B_Y0: u32 = 0x28;
pub const B_X1: u32 = 0x2c;
pub const B_Y1: u32 = 0x30;
pub const B_CTRL: u32 = 0x34; // raise INT_BLIT: bit0 when the chain runs dry, bit1 after every descriptor
pub const CTRL_DRAINED: u32 = 1;
pub const CTRL_EACH: u32 = 2;
/// Write the address of a command block; the chip fetches its own parameters
/// and runs. One store, so programming the blitter is atomic without anybody
/// holding anything off - provided the block belongs to whoever filled it,
/// which is the caller's business and not the chip's.
///
///     0 src   1 dst   2 w      3 h
///     4 smod  5 dmod  6 val    7 op
///     8 x0    9 y0   10 x1    11 y1
///    12 status        13 next
///
/// `status` is written back to zero by the chip when the command finishes.
/// That is how the task that filled a block finds out its own pixels have
/// landed, by reading its own memory - rather than by waiting for the chip to
/// go idle, which means waiting behind everybody else's transfers too.
///
/// `next` links the chain: when the chip finishes a descriptor it goes on to
/// the one `next` names, and stops at zero. So a queue of blits is a list in
/// memory, and adding one is a store into the last one's link.
pub const B_LIST: u32 = 0x38;
pub const LIST_WORDS: u32 = 14;
pub const LIST_STATUS: u32 = 12;
pub const LIST_NEXT: u32 = 13;

// ---------------------------------------------------------------- cost
// What a transfer costs, in the machine's own cycles. On the target a blit is
// memory traffic and nothing else, so traffic is what is counted:
//
//  - The bus moves BUS_BYTES a cycle once a burst is going, and opening one at
//    a new address costs BURST_SETUP. Every row is a new address.
//  - A row that starts or ends part way through a bus word still moves the
//    whole word.
//  - Copies read the source and write the destination. XOR, AND, OR and ADD
//    read the destination too, before they write it, so they move it twice.
//    MASK does not: skipping the transparent bytes is what byte enables on a
//    write are for.
//  - A line is a byte at a time, each at a new address.
//  - A descriptor is fetched - fourteen words - and its status written back.
//
// The numbers assume a 32-bit path to memory at the machine's nominal clock:
// eighty megabytes a second at twenty million cycles, which is HyperRAM once
// the processor has had its share. They are guesses, to be replaced by
// measurements from the real part, and they live here so that replacing them
// is a two-line change.
pub const BUS_BYTES: u64 = 4;
pub const BURST_SETUP: u64 = 4;

pub const OP_COPY: u32 = 0;
pub const OP_FILL: u32 = 1;
pub const OP_XOR: u32 = 2;
pub const OP_AND: u32 = 3;
pub const OP_OR: u32 = 4;
pub const OP_MASK: u32 = 5; // copy, skipping bytes equal to B_VAL
pub const OP_LINE: u32 = 6;
pub const OP_ADD: u32 = 7; // saturating add

#[derive(Clone, Copy, Default)]
pub struct Regs {
    pub src: u32,
    pub dst: u32,
    pub w: u32,
    pub h: u32,
    pub smod: u32,
    pub dmod: u32,
    pub val: u32,
    pub ctrl: u32,
    pub x0: u32,
    pub y0: u32,
    pub x1: u32,
    pub y1: u32,
}

/// Two banks. Writes land in `pending`; writing the op register copies the
/// whole of it into `live` and starts the transfer.
///
/// That is not decoration. A blit takes six or seven register writes to set
/// up, and an interrupt arriving between two of them used to find the chip
/// half-programmed - a vblank server that blits inside somebody else's setup
/// drew a line across the screen once, and the fix was to wrap every blit in
/// the machine in a critical section. A shadow bank makes the command atomic
/// in the chip instead, which is how real hardware avoids the same problem,
/// and every one of those critical sections goes away.
///
/// A transfer takes time. Committing one latches it and marks the chip busy
/// until `busy_until`; the pixels move in one go when that moment arrives.
/// Until then the destination holds exactly what it held before, which is
/// what makes a missing wait visible: read too early and you see the old
/// picture. Real hardware would show a torn one. Either is wrong in a way you
/// notice, which an instantaneous chip - the previous model - never was.
pub struct Blitter {
    pub live: Regs,
    pub pending: Regs,
    pub busy: bool,
    pub busy_until: u64,
    pub op: u32,
    /// The command block the running transfer came from, for write-back, or
    /// zero if it was programmed through the registers.
    pub block: u32,
}

impl Blitter {
    pub fn new() -> Blitter {
        Blitter {
            live: Regs::default(),
            pending: Regs::default(),
            busy: false,
            busy_until: 0,
            op: 0,
            block: 0,
        }
    }

    /// Reads see what was last written, not what is running.
    pub fn read(&mut self, reg: u32) -> u32 {
        let p = &self.pending;
        match reg {
            B_SRC => p.src,
            B_DST => p.dst,
            B_W => p.w,
            B_H => p.h,
            B_SMOD => p.smod,
            B_DMOD => p.dmod,
            B_VAL => p.val,
            B_STATUS => self.busy as u32,
            B_X0 => p.x0,
            B_Y0 => p.y0,
            B_X1 => p.x1,
            B_Y1 => p.y1,
            B_CTRL => p.ctrl,
            _ => 0,
        }
    }
}

pub fn command(m: &mut Machine, reg: u32, v: u32) {
    {
        let b = &mut m.blit.pending;
        match reg {
            B_SRC => b.src = v,
            B_DST => b.dst = v,
            B_W => b.w = v,
            B_H => b.h = v,
            B_SMOD => b.smod = v,
            B_DMOD => b.dmod = v,
            B_VAL => b.val = v,
            B_X0 => b.x0 = v,
            B_Y0 => b.y0 = v,
            B_X1 => b.x1 = v,
            B_Y1 => b.y1 = v,
            B_CTRL => b.ctrl = v,
            B_OP => {}
            B_LIST => {}
            _ => return,
        }
        if reg != B_OP && reg != B_LIST {
            return;
        }
    }
    // One chain at a time. A commit that arrives while the chip is busy waits
    // for everything it has - the running transfer and whatever is linked
    // behind it - the way a store to a single-channel DMA engine stalls on the
    // bus. Software links onto the chain instead, and starts the chip only
    // when it is idle, so this does not happen; it is here so that getting
    // that wrong is slow rather than wrong. The count is for a chain that
    // links back into itself, which would otherwise stall for ever.
    let mut left = 1u32 << 20;
    while m.blit.busy && left > 0 {
        let due = m.blit.busy_until;
        if due > m.now {
            let d = due - m.now;
            m.cycles = m.cycles.wrapping_add(d);
            m.now = due;
        }
        finish(m);
        left -= 1;
    }
    m.blit.busy = false;
    let at = m.now;
    if reg == B_LIST {
        // A descriptor: the chip reads its own parameters, in one go, so
        // there is nothing for an interrupt to land in the middle of.
        start_block(m, v, at);
    } else {
        // The op write is the commit: everything programmed since the last
        // one takes effect together, or none of it does.
        m.blit.live = m.blit.pending;
        begin(m, v, 0, at);
    }
}

/// Fetch the descriptor at `block` and start it at cycle `at`. A block that
/// is not in RAM starts nothing, which ends a chain the same as a zero link.
fn start_block(m: &mut Machine, block: u32, at: u64) -> bool {
    if block == 0 || !m.in_ram(block, LIST_WORDS * 4) {
        return false;
    }
    let mut q = [0u32; LIST_WORDS as usize];
    for (i, w) in q.iter_mut().enumerate() {
        *w = m.peek32(block + (i as u32) * 4);
    }
    m.blit.live = Regs {
        src: q[0],
        dst: q[1],
        w: q[2],
        h: q[3],
        smod: q[4],
        dmod: q[5],
        val: q[6],
        ctrl: m.blit.pending.ctrl,
        x0: q[8],
        y0: q[9],
        x1: q[10],
        y1: q[11],
    };
    begin(m, q[7], block, at);
    true
}

/// `live` holds a transfer: check it if asked to, cost it, and mark the chip
/// busy until it is done. Nothing moves yet - see `finish`.
///
/// The cost is not charged to whoever committed. It used to be added to the
/// cycle counter inside the store, so a full-screen fill held every interrupt
/// off for more than two frames. Now time passes while the chip works, and
/// whoever else is ready runs in the meantime.
fn begin(m: &mut Machine, op: u32, block: u32, at: u64) {
    if guard_on() {
        guard(m, op);
    }
    m.blit.op = op;
    m.blit.block = block;
    m.blit.busy = true;
    m.blit.busy_until = at + cost(op, &m.blit.live, block != 0);
}

/// Bus words that a row of `w` bytes starting at `addr` touches.
fn row_words(addr: u32, w: u32) -> u64 {
    if w == 0 {
        return 0;
    }
    let lead = addr as u64 % BUS_BYTES;
    (lead + w as u64 + BUS_BYTES - 1) / BUS_BYTES
}

/// The cycles a transfer takes: see the constants at the top.
pub fn cost(op: u32, r: &Regs, from_block: bool) -> u64 {
    let desc = if from_block {
        2 * BURST_SETUP + LIST_WORDS as u64 + 1
    } else {
        0
    };
    let h = r.h as u64;
    let body = match op {
        OP_LINE => {
            let dx = (r.x1 as i32 - r.x0 as i32).unsigned_abs() as u64;
            let dy = (r.y1 as i32 - r.y0 as i32).unsigned_abs() as u64;
            (dx.max(dy) + 1) * (BURST_SETUP + 1)
        }
        OP_FILL => h * (BURST_SETUP + row_words(r.dst, r.w)),
        OP_COPY | OP_MASK => {
            h * (2 * BURST_SETUP + row_words(r.src, r.w) + row_words(r.dst, r.w))
        }
        _ => h * (3 * BURST_SETUP + row_words(r.src, r.w) + 2 * row_words(r.dst, r.w)),
    };
    desc + body
}

/// With LM_BLIT_GUARD set, check a transfer's extent before it starts.
fn guard(m: &Machine, v: u32) {
    let b = m.blit.live;
    let (src, dst, w, h, smod, dmod) = (b.src, b.dst, b.w, b.h, b.smod, b.dmod);
    if v == OP_LINE {
        let (x0, x1) = (b.x0.min(b.x1), b.x0.max(b.x1));
        let (y0, y1) = (b.y0.min(b.y1), b.y0.max(b.y1));
        guard_range(
            m,
            dst.wrapping_add(y0.wrapping_mul(dmod)).wrapping_add(x0),
            dst.wrapping_add(y1.wrapping_mul(dmod)).wrapping_add(x1) + 1,
            "line",
            v,
        );
    } else if h > 0 && w > 0 {
        let extent = (h - 1).wrapping_mul(dmod).wrapping_add(w);
        guard_range(m, dst, dst.wrapping_add(extent), "dst", v);
        if v == OP_COPY || v == OP_MASK {
            let sext = (h - 1).wrapping_mul(smod).wrapping_add(w);
            guard_range(m, src, src.wrapping_add(sext), "src", v);
        }
    }
}

/// The transfer that was latched into `live`, all of it, now.
fn perform(m: &mut Machine) {
    let v = m.blit.op;
    let (src, dst, w, h, smod, dmod, val) = {
        let b = &m.blit.live;
        (b.src, b.dst, b.w, b.h, b.smod, b.dmod, b.val)
    };
    if v == OP_LINE {
        let (x0, y0, x1, y1) = (m.blit.live.x0, m.blit.live.y0, m.blit.live.x1, m.blit.live.y1);
        line(m, dst, dmod, x0, y0, x1, y1, val as u8);
    } else {
        let ramlen = m.ramlen as usize;
        let ram = m.ram_mut();
        for y in 0..h {
            let so = (src as usize).wrapping_add((y as usize).wrapping_mul(smod as usize));
            let dofs = (dst as usize).wrapping_add((y as usize).wrapping_mul(dmod as usize));
            if dofs >= ramlen || dofs + w as usize > ramlen {
                break;
            }
            if v == OP_FILL {
                ram[dofs..dofs + w as usize].fill(val as u8);
                continue;
            }
            if so >= ramlen || so + w as usize > ramlen {
                break;
            }
            // Rows may overlap when scrolling in place, so go through indices
            // rather than a slice copy.
            if v == OP_COPY && (dofs + (w as usize) <= so || so + (w as usize) <= dofs) {
                ram.copy_within(so..so + w as usize, dofs);
                continue;
            }
            let back = v == OP_COPY && dofs > so;
            for i in 0..w as usize {
                let i = if back { w as usize - 1 - i } else { i };
                let s = ram[so + i];
                let d = &mut ram[dofs + i];
                *d = match v {
                    OP_COPY => s,
                    OP_XOR => *d ^ s,
                    OP_AND => *d & s,
                    OP_OR => *d | s,
                    OP_ADD => d.saturating_add(s),
                    OP_MASK => {
                        if s == val as u8 {
                            *d
                        } else {
                            s
                        }
                    }
                    _ => *d,
                };
            }
        }
    }

}

/// The running transfer's time has come: move the pixels, mark the block
/// done, and raise the interrupt if it was asked for.
///
/// The copy happens here, at the end, rather than at the commit. That is the
/// point of the whole model: between the two the destination still holds its
/// old contents, so code that reads pixels it has only just asked the chip to
/// write sees the wrong ones - loudly, and every time, rather than only on
/// hardware.
///
/// Then on down the chain. The link is read before the status is written:
/// once the status word says done, the descriptor is its owner's again - it
/// can be refilled, link and all - so a link read afterwards would sometimes
/// be the owner's next command rather than the chain's. The interrupt comes
/// when the chain runs dry, or after every descriptor, as the control
/// register asks.
fn finish(m: &mut Machine) {
    perform(m);
    m.blit.busy = false;
    let b = m.blit.block;
    let done_at = m.blit.busy_until;
    let next = if b != 0 && m.in_ram(b, LIST_WORDS * 4) {
        let n = m.peek32(b + LIST_NEXT * 4);
        m.poke32(b + LIST_STATUS * 4, 0);
        n
    } else {
        0
    };
    // The control register as it is now, not as it was when this descriptor
    // started: a task that has just asked to be woken has to be woken by the
    // transfer that was already running when it asked.
    let ctrl = m.blit.pending.ctrl;
    if ctrl & CTRL_EACH != 0 {
        m.raise(INT_BLIT);
    }
    // From the moment this one finished, not from whenever somebody looked,
    // so a chain costs the same however often it is polled.
    if start_block(m, next, done_at) {
        return;
    }
    if ctrl & CTRL_DRAINED != 0 {
        m.raise(INT_BLIT);
    }
}

/// Finish whatever is due. Called from everywhere that can observe the chip -
/// a status read, and each host slice - so completion is never early and
/// never later than the next look; and in a loop, because by the time
/// somebody looks several descriptors down a chain may be due.
pub fn poll(m: &mut Machine, now: u64) {
    while m.blit.busy && now >= m.blit.busy_until {
        finish(m);
    }
}

/// When the running transfer finishes, or never.
pub fn due(m: &Machine) -> u64 {
    if m.blit.busy {
        m.blit.busy_until
    } else {
        u64::MAX
    }
}

#[allow(clippy::too_many_arguments)]
// ---------------------------------------------------------------- guard
// A blit may only ever write to a bitmap, and every bitmap is either pool
// memory or the collector's scratch above `fast-base`. Code space, cons space
// and object space are never a legitimate destination, so a blit that names
// one is writing pixels over the machine - which is what turns up later as a
// jump into a word of colour bytes a long way from the blit that did it.
//
// Off unless LM_BLIT_GUARD is set.
fn guard_on() -> bool {
    use std::sync::OnceLock;
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("LM_BLIT_GUARD").is_ok())
}

/// Report any blit whose destination covers this address. Set LM_BLIT_WATCH to
/// a hex address - a context block, say - and the blit that scribbles it names
/// itself, with the pc that programmed it.
fn watch_addr() -> Option<u32> {
    use std::sync::OnceLock;
    static A: OnceLock<Option<u32>> = OnceLock::new();
    *A.get_or_init(|| {
        std::env::var("LM_BLIT_WATCH")
            .ok()
            .and_then(|v| u32::from_str_radix(v.trim_start_matches("0x"), 16).ok())
    })
}

/// The pool is a run of blocks, each `[size][tag-or-link][payload...]`, but it
/// starts with blocks the forge handed out before the machine ran that carry
/// no header at all. So the chain cannot be walked from `pool-base`: find
/// where it starts by trying each eight-byte offset until walking sizes from
/// there lands exactly on the bump pointer.
fn pool_chain_start(m: &Machine) -> Option<u32> {
    use crate::map::{LG_POOLPTR, POOL_BASE};
    let top = m.peek32(LG_POOLPTR);
    let mut s = POOL_BASE;
    while s < top && s < POOL_BASE + (1 << 20) {
        let mut b = s;
        let mut ok = true;
        while b < top {
            let size = m.peek32(b);
            if size < 24 || size & 7 != 0 || b.wrapping_add(size) > top {
                ok = false;
                break;
            }
            b += size;
        }
        if ok && b == top {
            return Some(s);
        }
        s += 8;
    }
    None
}

/// The block holding `addr`, as (payload start, block end).
pub fn pool_block(m: &Machine, addr: u32) -> Option<(u32, u32)> {
    use crate::map::LG_POOLPTR;
    let top = m.peek32(LG_POOLPTR);
    let mut b = pool_chain_start(m)?;
    while b < top {
        let size = m.peek32(b);
        if size < 24 {
            return None;
        }
        if addr >= b && addr < b + size {
            return Some((b + 8, b + size));
        }
        b += size;
    }
    None
}

fn guard_range(m: &Machine, lo: u32, hi: u32, what: &str, op: u32) {
    use crate::map::POOL_END;
    // Inside the pool, a blit must stay inside the one block it named.
    if lo < POOL_END {
        if let Some((start, end)) = pool_block(m, lo) {
            if hi > end {
                eprintln!(
                    "blit guard: {what} {lo:#x}..{hi:#x} leaves its block {start:#x}..{end:#x} \
                     by {} bytes (op {op}, pc {:#x})",
                    hi - end,
                    m.pc
                );
                eprintln!("  {}", crate::cpu::watch_backtrace(m));
                let b = &m.blit.live;
                eprintln!(
                    "  src {:#x} dst {:#x} w {} h {} smod {} dmod {} val {:#x}",
                    b.src, b.dst, b.w, b.h, b.smod, b.dmod, b.val
                );
            }
        }
    }
    if let Some(a) = watch_addr() {
        if a >= lo && a < hi {
            eprintln!(
                "blit watch: {what} {lo:#x}..{hi:#x} covers {a:#x} (op {op}, pc {:#x})",
                m.pc
            );
            let b = &m.blit.live;
            eprintln!(
                "  src {:#x} dst {:#x} w {} h {} smod {} dmod {} val {:#x}",
                b.src, b.dst, b.w, b.h, b.smod, b.dmod, b.val
            );
            eprintln!("  {}", crate::cpu::watch_backtrace(m));
            for i in 0..32 {
                eprint!("  x{i}={}", m.x[i] as i32);
                if i % 8 == 7 {
                    eprintln!();
                }
            }
        }
    }
    use crate::map::{CODE_BASE, FAST_BASE};
    let bad = |a: u32| a >= CODE_BASE && a < FAST_BASE;
    if bad(lo) || bad(hi.saturating_sub(1)) {
        eprintln!(
            "blit guard: {what} {lo:#x}..{hi:#x} is not a bitmap (op {op}, pc {:#x})",
            m.pc
        );
    } else if lo < POOL_END && hi > POOL_END {
        eprintln!(
            "blit guard: {what} {lo:#x}..{hi:#x} runs off the end of the pool (op {op}, pc {:#x})",
            m.pc
        );
    }
}

fn line(m: &mut Machine, base: u32, pitch: u32, x0: u32, y0: u32, x1: u32, y1: u32, c: u8) {
    let (mut x, mut y) = (x0 as i32, y0 as i32);
    let (x1, y1) = (x1 as i32, y1 as i32);
    let dx = (x1 - x).abs();
    let dy = -(y1 - y).abs();
    let sx = if x < x1 { 1 } else { -1 };
    let sy = if y < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    loop {
        if x >= 0 && y >= 0 {
            let a = (base as i64) + (y as i64) * (pitch as i64) + x as i64;
            if a >= 0 && a < m.ramlen as i64 {
                m.poke8(a as u32, c);
            }
        }
        if x == x1 && y == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            x += sx;
        }
        if e2 <= dx {
            err += dx;
            y += sy;
        }
    }
}
