//! Blitter. Rectangle moves, fills, raster ops, masked sprite copies and
//! lines, all on 8-bit chunky data.
//!
//! The transfer happens in one go when the op register is written, but it is
//! charged to the machine's cycle counter at roughly a byte per cycle, so a
//! big blit costs a plausible amount of time instead of being free. That keeps
//! the deterministic timebase honest.

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
pub const B_STATUS: u32 = 0x20;
pub const B_X0: u32 = 0x24;
pub const B_Y0: u32 = 0x28;
pub const B_X1: u32 = 0x2c;
pub const B_Y1: u32 = 0x30;
pub const B_CTRL: u32 = 0x34; // bit0: raise INT_BLIT on completion
/// Write the address of a twelve-word command block; the chip fetches its own
/// parameters and runs. One store, so programming the blitter is atomic
/// without anybody holding anything off - provided the block belongs to
/// whoever filled it, which is the caller's business and not the chip's.
///
///     0 src   1 dst   2 w      3 h
///     4 smod  5 dmod  6 val    7 op
///     8 x0    9 y0   10 x1    11 y1
pub const B_LIST: u32 = 0x38;
pub const LIST_WORDS: u32 = 12;

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
pub struct Blitter {
    pub live: Regs,
    pub pending: Regs,
}

impl Blitter {
    pub fn new() -> Blitter {
        Blitter {
            live: Regs::default(),
            pending: Regs::default(),
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
            B_STATUS => 0, // always idle: transfers are instantaneous
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
    // A command block: the chip reads its own parameters. Everything the
    // register path would have latched on the op write comes from memory
    // instead, in one go, so there is nothing for an interrupt to land in the
    // middle of.
    let v = if reg == B_LIST {
        let base = v;
        if !m.in_ram(base, LIST_WORDS * 4) {
            return;
        }
        let mut q = [0u32; LIST_WORDS as usize];
        for (i, w) in q.iter_mut().enumerate() {
            *w = unsafe { m.rd32(base + (i as u32) * 4) };
        }
        let b = &mut m.blit.pending;
        b.src = q[0];
        b.dst = q[1];
        b.w = q[2];
        b.h = q[3];
        b.smod = q[4];
        b.dmod = q[5];
        b.val = q[6];
        b.x0 = q[8];
        b.y0 = q[9];
        b.x1 = q[10];
        b.y1 = q[11];
        q[7]
    } else {
        v
    };
    // The op write is the commit: everything programmed since the last one
    // takes effect together, or none of it does.
    m.blit.live = m.blit.pending;
    let (src, dst, w, h, smod, dmod, val) = {
        let b = &m.blit.live;
        (b.src, b.dst, b.w, b.h, b.smod, b.dmod, b.val)
    };
    let cost = if v == OP_LINE {
        let dx = (m.blit.live.x1 as i32 - m.blit.live.x0 as i32).unsigned_abs();
        let dy = (m.blit.live.y1 as i32 - m.blit.live.y0 as i32).unsigned_abs();
        dx.max(dy) as u64 + 1
    } else {
        (w as u64) * (h as u64)
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

    m.cycles = m.cycles.wrapping_add(cost);
    if m.blit.live.ctrl & 1 != 0 {
        m.raise(INT_BLIT);
    }
}

#[allow(clippy::too_many_arguments)]
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
