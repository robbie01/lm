//! Blitter. Rectangle moves, fills, raster ops, masked sprite copies and
//! lines, all on 8-bit chunky data.
//!
//! The chip is asynchronous and walks a chain of descriptors in memory. A
//! transfer takes as long as its memory traffic would take on the target (see
//! `cost`). When one finishes the chip goes on to the next descriptor by
//! itself. Transfer times are part of the deterministic timebase.
//!
//! The chip is handed capabilities, not numbers. The list register takes a
//! capability to a descriptor, and a descriptor's source, destination and
//! link are capabilities. The chip refuses a transfer that its capabilities
//! do not cover, so a wrong descriptor is a reported failure, never a write
//! somewhere else.

use crate::cap::*;
use crate::dev::{load_through, refusal, REFUSE_LOAD, REFUSE_STORE};
use crate::mach::*;
use crate::map::INT_BLIT;

/// A capability register: a capability store of a descriptor's capability
/// starts the chain there. Programming the blitter is one store, so it is
/// atomic with interrupts enabled. A word store writes a number, which is no
/// capability, and is refused.
pub const B_LIST: u32 = 0x00;
/// Bit 0: a transfer is running. Bit 1: the chip has refused something since
/// the bit was last cleared; writing the bit clears it.
pub const B_STATUS: u32 = 0x08;
/// Raise INT_BLIT: bit 0 when the chain runs dry, bit 1 after every
/// descriptor.
pub const B_CTRL: u32 = 0x0c;
pub const STATUS_BUSY: u32 = 1;
pub const STATUS_REFUSED: u32 = 2;
pub const CTRL_DRAINED: u32 = 1;
pub const CTRL_EACH: u32 = 2;

/// A descriptor, `LIST_BYTES` long and 8-byte aligned, a field to each
/// granule. The three capability slots come first, each written with a
/// capability store so that it keeps its tag; the rest are words, each in
/// the low half of its granule with the high half zero, so that a run of
/// descriptors reads as value slots holding fixnums and capabilities, which
/// is what lets a ring of them be a vector.
///
/// ```text
///      0 src    8 dst   16 next
///     24 w     32 h     40 smod   48 dmod
///     56 val   64 op    72 x0     80 y0     88 x1     96 y1
///    104 status
/// ```
///
/// The chip loads each slot the way `LY` would through the descriptor's own
/// capability. `src` and `dst` carry the address of the first pixel; `smod`
/// and `dmod` are the strides in bytes.
///
/// The owner writes `status` as `DONE_PENDING` before linking the
/// descriptor; the chip writes it back when it has finished, as `DONE` or as
/// a refusal. A task polls its own descriptor to learn that its transfer is
/// done, instead of waiting for the chip to go idle behind other tasks'
/// transfers.
///
/// `next` links the chain: when the chip finishes a descriptor it goes on to
/// the one `next` names, and stops at a link that is not a capability. A
/// queue of blits is a list in memory; adding one is a store into the last
/// one's link.
pub const L_SRC: u32 = 0;
pub const L_DST: u32 = 8;
pub const L_NEXT: u32 = 16;
pub const L_W: u32 = 24;
pub const L_H: u32 = 32;
pub const L_SMOD: u32 = 40;
pub const L_DMOD: u32 = 48;
pub const L_VAL: u32 = 56;
pub const L_OP: u32 = 64;
pub const L_X0: u32 = 72;
pub const L_Y0: u32 = 80;
pub const L_X1: u32 = 88;
pub const L_Y1: u32 = 96;
pub const L_STATUS: u32 = 104;
pub const LIST_BYTES: u32 = 112;

/// The done word. A refusal is `REFUSED_SRC` or `REFUSED_DST` for the
/// capability that refused it, with the check it failed in the low byte:
/// one of the `REFUSE_*` codes in `dev`.
pub const DONE: u32 = 0;
pub const DONE_PENDING: u32 = 1;
pub const REFUSED_SRC: u32 = 0x100;
pub const REFUSED_DST: u32 = 0x200;

// ---------------------------------------------------------------- cost
// What a transfer costs, in the machine's own cycles. On the target a blit is
// memory traffic only, so memory traffic is what is counted:
//
//  - The bus moves BUS_BYTES a cycle once a burst is going, and opening a
//    burst at a new address costs BURST_SETUP. Every row is a new address.
//  - A row that starts or ends part way through a bus word still moves the
//    whole word.
//  - Copies read the source and write the destination. XOR, AND, OR and ADD
//    read the destination before they write it, so they move it twice.
//    MASK does not: transparent bytes are skipped with write byte enables.
//  - A line is a byte at a time, each at a new address.
//  - A descriptor is fetched whole, and its status and its three capability
//    slots are written back. A refused transfer costs only that.
//
// The numbers assume a 32-bit path to memory at the machine's clock. The
// blitter is a bus master on the processor's own bus, so a faster part's
// blitter is faster with it and a transfer costs the same cycles at any
// clock: at two hundred million cycles that is eight hundred megabytes a
// second, which is sixteen-bit DDR3 at 800 MT/s after the processor's share.
// They are estimates, to be replaced by measurements from the real part. They
// are kept here so that replacing them is a two-line change.
pub const BUS_BYTES: u64 = 4;
pub const BURST_SETUP: u64 = 4;
const WRITE_BACK_BYTES: u64 = 4 + 3 * 8;

pub const OP_COPY: u32 = 0;
pub const OP_FILL: u32 = 1;
pub const OP_XOR: u32 = 2;
pub const OP_AND: u32 = 3;
pub const OP_OR: u32 = 4;
pub const OP_MASK: u32 = 5; // copy, skipping bytes equal to val
pub const OP_LINE: u32 = 6;
pub const OP_ADD: u32 = 7; // saturating add

/// A descriptor's parameters, as the chip fetched them.
#[derive(Clone, Copy, Default)]
struct Regs {
    src: Cap,
    dst: Cap,
    w: u32,
    h: u32,
    smod: u32,
    dmod: u32,
    val: u32,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
}

/// A transfer takes time. Starting one latches its descriptor and marks the
/// chip busy until `busy_until`; the pixels move in one go when that moment
/// arrives. Until then the destination holds what it held before. Code that
/// reads the destination without waiting sees the old picture. Real hardware
/// would show a torn one.
pub struct Blitter {
    live: Regs,
    pub busy: bool,
    pub busy_until: u64,
    op: u32,
    /// The capability of the descriptor the running transfer came from,
    /// checked when it was fetched, for the write-back.
    block: Cap,
    /// The running transfer's done word: `DONE`, or why it was refused.
    verdict: u32,
    ctrl: u32,
    refused: bool,
}

impl Blitter {
    pub fn new() -> Blitter {
        Blitter {
            live: Regs::default(),
            busy: false,
            busy_until: 0,
            op: 0,
            block: Cap::NULL,
            verdict: DONE,
            ctrl: 0,
            refused: false,
        }
    }

    pub fn read(&self, reg: u32) -> u32 {
        match reg {
            B_STATUS => {
                (if self.busy { STATUS_BUSY } else { 0 }) | (if self.refused { STATUS_REFUSED } else { 0 })
            }
            B_CTRL => self.ctrl,
            _ => 0,
        }
    }
}

/// A word store to a register.
pub fn command(m: &mut Machine, reg: u32, v: u32) {
    match reg {
        B_LIST => start_chain(m, Cap::int(v)),
        B_STATUS => {
            if v & STATUS_REFUSED != 0 {
                m.blit.refused = false;
            }
        }
        B_CTRL => m.blit.ctrl = v,
        _ => {}
    }
}

/// Start the chain at the descriptor `d` names: a store to the list register.
pub fn start_chain(m: &mut Machine, d: Cap) {
    // One chain at a time. A commit that arrives while the chip is busy waits
    // for the running transfer and everything linked behind it, the way a
    // store to a single-channel DMA engine stalls on the bus. Software links
    // onto the chain and starts the chip only when it is idle, so this path is
    // not normally taken; a driver that commits early is slow rather than
    // wrong. The count bounds a chain that links back into itself.
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
    if !start_block(m, d, at) {
        m.blit.refused = true;
    }
}

/// What a descriptor's own capability needs: to be read, slots and all, and
/// written back.
const DESCRIPTOR: &[(u32, u32)] = &[(P_LD, REFUSE_LOAD), (P_SD, REFUSE_STORE)];
const SOURCE: &[(u32, u32)] = &[(P_LD, REFUSE_LOAD)];
const DEST: &[(u32, u32)] = &[(P_SD, REFUSE_STORE)];
const DEST_READ: &[(u32, u32)] = &[(P_LD, REFUSE_LOAD), (P_SD, REFUSE_STORE)];

/// Fetch the descriptor `d` names and start it at cycle `at`. A capability
/// that is not an aligned descriptor the chip may read and write starts
/// nothing and answers false.
fn start_block(m: &mut Machine, d: Cap, at: u64) -> bool {
    let a = d.addr;
    if a & 7 != 0 || refusal(m, d, DESCRIPTOR, a as u64, LIST_BYTES as u64).is_some() {
        return false;
    }
    let word = |k: u32| m.peek32(a + k);
    let r = Regs {
        src: load_through(m, d, a + L_SRC),
        dst: load_through(m, d, a + L_DST),
        w: word(L_W),
        h: word(L_H),
        smod: word(L_SMOD),
        dmod: word(L_DMOD),
        val: word(L_VAL),
        x0: word(L_X0),
        y0: word(L_Y0),
        x1: word(L_X1),
        y1: word(L_Y1),
    };
    let op = word(L_OP);
    let verdict = verdict(m, op, &r);
    m.blit.live = r;
    m.blit.op = op;
    m.blit.block = d;
    m.blit.verdict = verdict;
    m.blit.busy = true;
    // The cost is charged to the chip's own clock, not to the task that
    // committed the transfer. Time passes while the chip works, and other
    // tasks run in the meantime.
    m.blit.busy_until = at + cost(op, &r, verdict == DONE);
    true
}

/// The bytes a rectangle of `w` by `h` with rows `pitch` apart spans from its
/// first byte. Its 32-bit operands cannot overflow 64 bits here; the sums
/// that could saturate, and a saturated extent is refused.
fn extent(w: u32, h: u32, pitch: u32) -> u64 {
    if w == 0 || h == 0 {
        0
    } else {
        (h as u64 - 1) * pitch as u64 + w as u64
    }
}

/// The transfer's done word: `DONE` if its capabilities allow every byte it
/// touches, else the first refusal. A line touches nothing outside the box
/// its two ends make. An operation the chip does not know moves nothing.
fn verdict(m: &Machine, op: u32, r: &Regs) -> u32 {
    let dst = r.dst.addr as u64;
    let (dst_perms, off, len, reads_src) = match op {
        OP_FILL => (DEST, 0, extent(r.w, r.h, r.dmod), false),
        OP_COPY | OP_MASK => (DEST, 0, extent(r.w, r.h, r.dmod), true),
        OP_XOR | OP_AND | OP_OR | OP_ADD => (DEST_READ, 0, extent(r.w, r.h, r.dmod), true),
        OP_LINE => {
            let (x0, x1) = (r.x0.min(r.x1) as u64, r.x0.max(r.x1) as u64);
            let (y0, y1) = (r.y0.min(r.y1) as u64, r.y0.max(r.y1) as u64);
            let first = y0 * r.dmod as u64 + x0;
            (DEST, first, (y1 * r.dmod as u64 + x1).saturating_add(1) - first, false)
        }
        _ => return DONE,
    };
    if reads_src {
        if let Some(code) = refusal(m, r.src, SOURCE, r.src.addr as u64, extent(r.w, r.h, r.smod)) {
            return REFUSED_SRC | code;
        }
    }
    match refusal(m, r.dst, dst_perms, dst.saturating_add(off), len) {
        Some(code) => REFUSED_DST | code,
        None => DONE,
    }
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
fn cost(op: u32, r: &Regs, moves: bool) -> u64 {
    let desc = 2 * BURST_SETUP + (LIST_BYTES as u64 + WRITE_BACK_BYTES) / BUS_BYTES;
    if !moves {
        return desc;
    }
    let h = r.h as u64;
    let (src, dst) = (r.src.addr, r.dst.addr);
    let body = match op {
        OP_LINE => {
            let dx = (r.x1 as i32 - r.x0 as i32).unsigned_abs() as u64;
            let dy = (r.y1 as i32 - r.y0 as i32).unsigned_abs() as u64;
            (dx.max(dy) + 1) * (BURST_SETUP + 1)
        }
        OP_FILL => h * (BURST_SETUP + row_words(dst, r.w)),
        OP_COPY | OP_MASK => h * (2 * BURST_SETUP + row_words(src, r.w) + row_words(dst, r.w)),
        OP_XOR | OP_AND | OP_OR | OP_ADD => {
            h * (3 * BURST_SETUP + row_words(src, r.w) + 2 * row_words(dst, r.w))
        }
        _ => 0,
    };
    desc + body
}

/// Perform the whole transfer latched in `live`, which its capabilities have
/// been found to cover.
fn perform(m: &mut Machine) {
    let v = m.blit.op;
    let b = m.blit.live;
    let (src, dst) = (b.src.addr as usize, b.dst.addr as usize);
    let (w, h, smod, dmod, val) = (b.w as usize, b.h as usize, b.smod as usize, b.dmod as usize, b.val as u8);
    if v == OP_LINE {
        line(m, b.dst.addr, b.dmod, b.x0, b.y0, b.x1, b.y1, val);
        return;
    }
    if w == 0 {
        return;
    }
    // Every row the transfer writes is data afterwards.
    for y in 0..h {
        m.clear_tags((dst + y * dmod) as u32, w as u32);
    }
    let ram = m.ram_mut();
    // Rows run bottom-up when the destination lies above the source, so an
    // overlapping copy within one bitmap (a scroll down) never reads a row it
    // has already overwritten. The per-byte direction below does the same for
    // overlap within a row.
    let descending = v != OP_FILL && dst > src;
    for k in 0..h {
        let y = if descending { h - 1 - k } else { k };
        let so = src + y * smod;
        let dofs = dst + y * dmod;
        if v == OP_FILL {
            ram[dofs..dofs + w].fill(val);
            continue;
        }
        // Rows may overlap when scrolling in place, so go through indices
        // rather than a slice copy.
        if v == OP_COPY && (dofs + w <= so || so + w <= dofs) {
            ram.copy_within(so..so + w, dofs);
            continue;
        }
        let back = v == OP_COPY && dofs > so;
        for i in 0..w {
            let i = if back { w - 1 - i } else { i };
            let s = ram[so + i];
            let d = &mut ram[dofs + i];
            *d = match v {
                OP_COPY => s,
                OP_XOR => *d ^ s,
                OP_AND => *d & s,
                OP_OR => *d | s,
                OP_ADD => d.saturating_add(s),
                OP_MASK => {
                    if s == val {
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

/// Complete the running transfer: move the pixels unless it was refused,
/// write the done word, and raise the interrupt if it was asked for.
///
/// The copy happens here, at the end, not at the commit. Between the two the
/// destination holds its old contents, so code that reads pixels before the
/// transfer is due sees the old ones every time, not only on hardware.
///
/// Then the chip goes on down the chain. The link is read before the status
/// is written: once the status word says done, the descriptor belongs to its
/// owner again and may be refilled, link included. A link read after the
/// status write could be the owner's next command instead of the chain's.
/// The capability slots are cleared as the status is written, so a finished
/// descriptor holds no authority over anything. The interrupt is raised when
/// the chain runs dry, or after every descriptor, as the control register
/// selects.
fn finish(m: &mut Machine) {
    let verdict = m.blit.verdict;
    if verdict == DONE {
        perform(m);
    } else {
        m.blit.refused = true;
    }
    m.blit.busy = false;
    let b = m.blit.block;
    let done_at = m.blit.busy_until;
    let next = load_through(m, b, b.addr + L_NEXT);
    for slot in [L_SRC, L_DST, L_NEXT] {
        m.store_cap(b.addr + slot, Cap::NULL);
    }
    m.poke32(b.addr + L_STATUS, verdict);
    // The control register as it is now, not as it was when this descriptor
    // started: a task that enables the interrupt while a transfer is running
    // is woken by that transfer.
    let ctrl = m.blit.ctrl;
    if ctrl & CTRL_EACH != 0 {
        m.raise(INT_BLIT);
    }
    // Measured from when this descriptor finished, not from when the status
    // was read, so a chain costs the same however often it is polled. A link
    // that is a capability the chip may not follow ends the chain as refused.
    if next.tag {
        if start_block(m, next, done_at) {
            return;
        }
        m.blit.refused = true;
    }
    if ctrl & CTRL_DRAINED != 0 {
        m.raise(INT_BLIT);
    }
}

/// Finish every transfer that is due by `now`. Called from each point that
/// can observe the chip (a status read, and each host slice), so completion
/// is never early and never later than the next observation. Loops because
/// several descriptors down a chain may be due by then.
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

/// A line from `x0, y0` to `x1, y1` in the bitmap at `base` with rows `pitch`
/// apart, every byte of which lies in the box the descriptor was checked for.
#[allow(clippy::too_many_arguments)]
fn line(m: &mut Machine, base: u32, pitch: u32, x0: u32, y0: u32, x1: u32, y1: u32, c: u8) {
    let (mut x, mut y) = (x0 as i64, y0 as i64);
    let (x1, y1) = (x1 as i64, y1 as i64);
    let dx = (x1 - x).abs();
    let dy = -(y1 - y).abs();
    let sx = if x < x1 { 1 } else { -1 };
    let sy = if y < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    loop {
        m.poke8((base as i64 + y * pitch as i64 + x) as u32, c);
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
