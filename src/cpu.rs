//! Token-threaded RV32IMC core.
//!
//! The "token" is the opcode itself: no predecode pass, no translation cache,
//! nothing to invalidate when the Lisp compiler writes fresh code into the
//! heap and jumps to it. A 64-entry table is indexed straight off the encoded
//! instruction:
//!
//!     16-bit forms   tok = (op[1:0] << 3) | funct3       ->  0 .. 23
//!     32-bit forms   tok = 32 + opcode[6:2]              -> 32 .. 63
//!
//! Every handler ends by expanding `next!`, which re-does the fetch, the
//! token computation and the indirect jump *in place* before an explicit tail
//! call. That replication is the whole point: each opcode gets its own branch
//! site, so the predictor learns per-opcode successor patterns instead of
//! thrashing on one shared dispatch. `become` guarantees the jump is a real
//! `jmp`, so a program can run forever in constant stack.

use crate::dev;
use crate::mach::*;

pub type Handler = fn(&mut Machine, u32, u32, u32) -> Stop;

// ---------------------------------------------------------------- field picks
#[inline(always)]
fn rd(w: u32) -> u32 {
    (w >> 7) & 31
}
#[inline(always)]
fn rs1(w: u32) -> u32 {
    (w >> 15) & 31
}
#[inline(always)]
fn rs2(w: u32) -> u32 {
    (w >> 20) & 31
}
#[inline(always)]
fn f3(w: u32) -> u32 {
    (w >> 12) & 7
}

#[inline(always)]
fn r(m: &Machine, i: u32) -> u32 {
    unsafe { *m.x.get_unchecked((i & 31) as usize) }
}

/// Write a register and re-zero x0. Unconditional, so no branch on `rd != 0`;
/// x0 shares a cache line with the hottest registers so the extra store is
/// cheaper than the misprediction it replaces.
#[inline(always)]
fn w_(m: &mut Machine, i: u32, v: u32) {
    unsafe {
        *m.x.get_unchecked_mut((i & 31) as usize) = v;
        *m.x.get_unchecked_mut(0) = 0;
    }
}

// ------------------------------------------------------------- 32-bit immediates
#[inline(always)]
fn imm_i(w: u32) -> u32 {
    ((w as i32) >> 20) as u32
}
#[inline(always)]
fn imm_s(w: u32) -> u32 {
    ((((w & 0xfe00_0000) as i32) >> 20) as u32) | ((w >> 7) & 0x1f)
}
#[inline(always)]
fn imm_b(w: u32) -> u32 {
    ((((w & 0x8000_0000) as i32) >> 19) as u32)
        | ((w & 0x80) << 4)
        | ((w >> 20) & 0x7e0)
        | ((w >> 7) & 0x1e)
}
#[inline(always)]
fn imm_j(w: u32) -> u32 {
    ((((w & 0x8000_0000) as i32) >> 11) as u32)
        | (w & 0xff000)
        | ((w >> 9) & 0x800)
        | ((w >> 20) & 0x7fe)
}

// ------------------------------------------------------------- RVC immediates
#[inline(always)]
fn bit(w: u32, n: u32) -> u32 {
    (w >> n) & 1
}
/// rd'/rs1'/rs2' -> x8..x15
#[inline(always)]
fn rcs(w: u32, sh: u32) -> u32 {
    ((w >> sh) & 7) + 8
}
/// CIW: c.addi4spn, zero-extended, scaled by 4.
#[inline(always)]
fn ciw_imm(w: u32) -> u32 {
    ((w >> 1) & 0x3c0) | ((w >> 7) & 0x30) | (bit(w, 6) << 2) | (bit(w, 5) << 3)
}
/// CL/CS word offset: uimm[5:3]=w[12:10], uimm[2]=w[6], uimm[6]=w[5]
#[inline(always)]
fn clw_imm(w: u32) -> u32 {
    ((w >> 7) & 0x38) | (bit(w, 6) << 2) | (bit(w, 5) << 6)
}
/// CI signed 6-bit: {w[12], w[6:2]}
#[inline(always)]
fn ci_imm(w: u32) -> u32 {
    ((((w << 19) & 0x8000_0000) as i32) >> 26) as u32 | ((w >> 2) & 0x1f)
}
/// CJ 11-bit signed jump offset.
#[inline(always)]
fn cj_imm(w: u32) -> u32 {
    ((((w << 19) & 0x8000_0000) as i32) >> 20) as u32
        | (bit(w, 11) << 4)
        | ((w >> 1) & 0x300)
        | (bit(w, 8) << 10)
        | (bit(w, 7) << 6)
        | (bit(w, 6) << 7)
        | ((w >> 2) & 0xe)
        | (bit(w, 2) << 5)
}
/// CB 8-bit signed branch offset.
#[inline(always)]
fn cb_imm(w: u32) -> u32 {
    ((((w << 19) & 0x8000_0000) as i32) >> 23) as u32
        | ((w >> 7) & 0x18)
        | ((w << 1) & 0xc0)
        | ((w >> 2) & 0x6)
        | (bit(w, 2) << 5)
}

// ------------------------------------------------------------------- dispatch
/// Fetch, tokenise, jump. Expanded at the tail of every handler.
macro_rules! next {
    ($m:expr, $pc:expr, $fuel:expr) => {{
        let m: &mut Machine = $m;
        let pc: u32 = $pc;
        let fuel: u32 = $fuel;
        if fuel == 0 {
            m.pc = pc;
            m.fuel_left = 0;
            return Stop::Fuel;
        }
        if !m.in_ram(pc, 4) {
            return fetch_slow(m, pc, fuel);
        }
        let w = unsafe { m.rd32(pc) };
        let tok = if w & 3 == 3 {
            32 + ((w >> 2) & 31)
        } else {
            ((w & 3) << 3) | ((w >> 13) & 7)
        };
        become (unsafe { *TABLE.get_unchecked(tok as usize) })(m, w, pc, fuel)
    }};
}

/// Entry into the threaded core. `become` demands that caller and callee
/// share a signature, so the entry stub wears the handler shape too and
/// ignores the instruction word it is handed.
fn enter(m: &mut Machine, _w: u32, pc: u32, fuel: u32) -> Stop {
    next!(m, pc, fuel)
}

pub fn run_block(m: &mut Machine, pc: u32, fuel: u32) -> Stop {
    enter(m, 0, pc, fuel)
}

/// Instruction fetch that fell outside RAM. A 16-bit instruction in the last
/// two bytes of RAM is legal, so retry narrowly before faulting.
#[cold]
#[inline(never)]
fn fetch_slow(m: &mut Machine, pc: u32, fuel: u32) -> Stop {
    if m.in_ram(pc, 2) {
        let h = unsafe { m.rd16(pc) } as u32;
        if h & 3 != 3 {
            let tok = ((h & 3) << 3) | ((h >> 13) & 7);
            return (unsafe { *TABLE.get_unchecked(tok as usize) })(m, h, pc, fuel);
        }
    }
    m.fault(C_IFAULT, pc, pc, fuel)
}

#[cold]
#[inline(never)]
fn illegal(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    m.fault(C_ILLEGAL, w, pc, fuel)
}

// ============================================================== 32-bit opcodes

// ---- LUI / AUIPC ----------------------------------------------------------
#[inline(never)]
fn op_lui(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), w & 0xffff_f000);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

#[inline(never)]
fn op_auipc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), pc.wrapping_add(w & 0xffff_f000));
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ---- jumps ----------------------------------------------------------------
#[inline(never)]
fn op_jal(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), pc.wrapping_add(4));
    next!(m, pc.wrapping_add(imm_j(w)), fuel - 1)
}

#[inline(never)]
fn op_jalr(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if f3(w) != 0 {
        return illegal(m, w, pc, fuel);
    }
    let t = r(m, rs1(w)).wrapping_add(imm_i(w)) & !1;
    w_(m, rd(w), pc.wrapping_add(4));
    next!(m, t, fuel - 1)
}

#[inline(never)]
fn op_branch(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    let b = r(m, rs2(w));
    let taken = match f3(w) {
        0 => a == b,
        1 => a != b,
        4 => (a as i32) < (b as i32),
        5 => (a as i32) >= (b as i32),
        6 => a < b,
        7 => a >= b,
        _ => return illegal(m, w, pc, fuel),
    };
    let npc = if taken {
        pc.wrapping_add(imm_b(w))
    } else {
        pc.wrapping_add(4)
    };
    next!(m, npc, fuel - 1)
}

// ---- memory ---------------------------------------------------------------
/// Unaligned accesses are serviced rather than trapped: the object memory
/// leans on that for byte vectors and packed image data.
#[inline(always)]
fn do_load(m: &mut Machine, a: u32, f: u32, fuel: u32) -> Option<u32> {
    let sz = 1u32 << (f & 3);
    if m.in_ram(a, sz) {
        unsafe {
            Some(match f {
                0 => m.rd8(a) as i8 as i32 as u32,
                1 => m.rd16(a) as i16 as i32 as u32,
                2 => m.rd32(a),
                4 => m.rd8(a) as u32,
                5 => m.rd16(a) as u32,
                _ => return None,
            })
        }
    } else if Machine::is_mmio(a) && f <= 5 && f != 3 {
        m.tick(fuel);
        Some(dev::read(m, a, f))
    } else {
        None
    }
}

#[inline(never)]
fn op_load(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w)).wrapping_add(imm_i(w));
    match do_load(m, a, f3(w), fuel) {
        Some(v) => w_(m, rd(w), v),
        None => return m.fault(C_LFAULT, a, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

#[inline(always)]
fn do_store(m: &mut Machine, a: u32, f: u32, v: u32, fuel: u32) -> bool {
    if f > 2 {
        return false;
    }
    let sz = 1u32 << f;
    if m.in_ram(a, sz) {
        unsafe {
            match f {
                0 => m.wr8(a, v as u8),
                1 => m.wr16(a, v as u16),
                _ => m.wr32(a, v),
            }
        }
        true
    } else if Machine::is_mmio(a) {
        m.tick(fuel);
        dev::write(m, a, f, v);
        true
    } else {
        false
    }
}

#[inline(never)]
fn op_store(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w)).wrapping_add(imm_s(w));
    let v = r(m, rs2(w));
    if !do_store(m, a, f3(w), v, fuel) {
        return m.fault(C_SFAULT, a, pc, fuel);
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ---- integer ALU ----------------------------------------------------------
#[inline(never)]
fn op_imm(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    let i = imm_i(w);
    let sh = (w >> 20) & 31;
    let v = match f3(w) {
        0 => a.wrapping_add(i),
        2 => ((a as i32) < (i as i32)) as u32,
        3 => (a < i) as u32,
        4 => a ^ i,
        6 => a | i,
        7 => a & i,
        1 => {
            if w >> 25 != 0 {
                return illegal(m, w, pc, fuel);
            }
            a << sh
        }
        _ => match w >> 25 {
            0 => a >> sh,
            0x20 => ((a as i32) >> sh) as u32,
            _ => return illegal(m, w, pc, fuel),
        },
    };
    w_(m, rd(w), v);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

#[inline(never)]
fn op_reg(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    let b = r(m, rs2(w));
    let f = f3(w);
    let v = match w >> 25 {
        0 => match f {
            0 => a.wrapping_add(b),
            1 => a << (b & 31),
            2 => ((a as i32) < (b as i32)) as u32,
            3 => (a < b) as u32,
            4 => a ^ b,
            5 => a >> (b & 31),
            6 => a | b,
            _ => a & b,
        },
        0x20 => match f {
            0 => a.wrapping_sub(b),
            5 => ((a as i32) >> (b & 31)) as u32,
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- M extension ----
        1 => match f {
            0 => a.wrapping_mul(b),
            1 => (((a as i32 as i64) * (b as i32 as i64)) >> 32) as u32,
            2 => (((a as i32 as i64) * (b as u64 as i64)) >> 32) as u32,
            3 => (((a as u64) * (b as u64)) >> 32) as u32,
            4 => {
                if b == 0 {
                    u32::MAX
                } else {
                    (a as i32).wrapping_div(b as i32) as u32
                }
            }
            5 => {
                if b == 0 {
                    u32::MAX
                } else {
                    a / b
                }
            }
            6 => {
                if b == 0 {
                    a
                } else {
                    (a as i32).wrapping_rem(b as i32) as u32
                }
            }
            _ => {
                if b == 0 {
                    a
                } else {
                    a % b
                }
            }
        },
        _ => return illegal(m, w, pc, fuel),
    };
    w_(m, rd(w), v);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ---- fence / system -------------------------------------------------------
#[inline(never)]
fn op_fence(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    // Nothing is reordered and there is no icache, so fence and fence.i are
    // both nops. Self-modifying code just works, which the compiler relies on.
    let _ = w;
    next!(m, pc.wrapping_add(4), fuel - 1)
}

#[inline(never)]
fn op_system(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    if f == 0 {
        return match w {
            0x0000_0073 => m.fault(C_ECALL, 0, pc, fuel),
            0x0010_0073 => m.fault(C_BREAK, pc, pc, fuel),
            0x3020_0073 => {
                // mret
                let mpie = (m.mstatus & MSTATUS_MPIE) != 0;
                m.mstatus &= !MSTATUS_MIE;
                if mpie {
                    m.mstatus |= MSTATUS_MIE;
                }
                m.mstatus |= MSTATUS_MPIE;
                let t = m.mepc;
                m.fuel_left = fuel - 1;
                m.pc = t;
                // Re-enabling interrupts can make one immediately deliverable,
                // so hand back to the outer loop rather than run blind.
                Stop::Fuel
            }
            0x1050_0073 => {
                m.pc = pc.wrapping_add(4);
                m.fuel_left = fuel - 1;
                Stop::Wfi
            }
            _ => illegal(m, w, pc, fuel),
        };
    }
    // ---- Zicsr ----
    m.tick(fuel);
    let csr = w >> 20;
    let src = if f & 4 != 0 { rs1(w) } else { r(m, rs1(w)) };
    let d = rd(w);
    // A csr*i/csr*(x0) read-modify-write with no write side must not write.
    let writes = if f & 3 == 1 { true } else { rs1(w) != 0 };
    let old = if d != 0 || writes { m.csr_read(csr) } else { 0 };
    if writes {
        let v = match f & 3 {
            1 => src,
            2 => old | src,
            _ => old & !src,
        };
        m.csr_write(csr, v);
    }
    w_(m, d, old);
    // mstatus/mie writes can arm an interrupt; resynchronise outside.
    if writes && (csr == 0x300 || csr == 0x304 || csr == 0x344) {
        m.pc = pc.wrapping_add(4);
        m.fuel_left = fuel - 1;
        return Stop::Fuel;
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

#[inline(never)]
fn op_bad(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    illegal(m, w, pc, fuel)
}

// =========================================================== compressed, Q0

#[inline(never)]
fn c_addi4spn(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let i = ciw_imm(w);
    if i == 0 {
        return illegal(m, w, pc, fuel); // all-zero halfword
    }
    let v = r(m, 2).wrapping_add(i);
    w_(m, rcs(w, 2), v);
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_lw(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rcs(w, 7)).wrapping_add(clw_imm(w));
    match do_load(m, a, 2, fuel) {
        Some(v) => w_(m, rcs(w, 2), v),
        None => return m.fault(C_LFAULT, a, pc, fuel),
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_sw(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rcs(w, 7)).wrapping_add(clw_imm(w));
    let v = r(m, rcs(w, 2));
    if !do_store(m, a, 2, v, fuel) {
        return m.fault(C_SFAULT, a, pc, fuel);
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

// =========================================================== compressed, Q1

#[inline(never)]
fn c_addi(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let v = r(m, d).wrapping_add(ci_imm(w));
    w_(m, d, v);
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_jal(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, 1, pc.wrapping_add(2));
    next!(m, pc.wrapping_add(cj_imm(w)), fuel - 1)
}

#[inline(never)]
fn c_li(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), ci_imm(w));
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_lui(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    if d == 2 {
        // c.addi16sp
        let i = ((((w << 19) & 0x8000_0000) as i32) >> 22) as u32
            | (bit(w, 6) << 4)
            | (bit(w, 5) << 6)
            | ((w << 4) & 0x180)
            | (bit(w, 2) << 5);
        if i == 0 {
            return illegal(m, w, pc, fuel);
        }
        let v = r(m, 2).wrapping_add(i);
        w_(m, 2, v);
    } else {
        let i = (ci_imm(w) << 12) as u32;
        if i == 0 || d == 0 {
            return illegal(m, w, pc, fuel);
        }
        w_(m, d, i);
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_alu(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rcs(w, 7);
    let a = r(m, d);
    let v = match (w >> 10) & 3 {
        0 => a >> (((w >> 2) & 31) | (bit(w, 12) << 5)) & 31,
        1 => ((a as i32) >> ((((w >> 2) & 31) | (bit(w, 12) << 5)) & 31)) as u32,
        2 => a & ci_imm(w),
        _ => {
            if bit(w, 12) != 0 {
                return illegal(m, w, pc, fuel); // RV64-only subw/addw
            }
            let b = r(m, rcs(w, 2));
            match (w >> 5) & 3 {
                0 => a.wrapping_sub(b),
                1 => a ^ b,
                2 => a | b,
                _ => a & b,
            }
        }
    };
    w_(m, d, v);
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_j(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    next!(m, pc.wrapping_add(cj_imm(w)), fuel - 1)
}

#[inline(never)]
fn c_beqz(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let npc = if r(m, rcs(w, 7)) == 0 {
        pc.wrapping_add(cb_imm(w))
    } else {
        pc.wrapping_add(2)
    };
    next!(m, npc, fuel - 1)
}

#[inline(never)]
fn c_bnez(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let npc = if r(m, rcs(w, 7)) != 0 {
        pc.wrapping_add(cb_imm(w))
    } else {
        pc.wrapping_add(2)
    };
    next!(m, npc, fuel - 1)
}

// =========================================================== compressed, Q2

#[inline(never)]
fn c_slli(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let sh = (((w >> 2) & 31) | (bit(w, 12) << 5)) & 31;
    let v = r(m, d) << sh;
    w_(m, d, v);
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_lwsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    if d == 0 {
        return illegal(m, w, pc, fuel);
    }
    let off = (bit(w, 12) << 5) | ((w >> 2) & 0x1c) | ((w << 4) & 0xc0);
    let a = r(m, 2).wrapping_add(off);
    match do_load(m, a, 2, fuel) {
        Some(v) => w_(m, d, v),
        None => return m.fault(C_LFAULT, a, pc, fuel),
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_swsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let off = ((w >> 7) & 0x3c) | ((w >> 1) & 0xc0);
    let a = r(m, 2).wrapping_add(off);
    let v = r(m, (w >> 2) & 31);
    if !do_store(m, a, 2, v, fuel) {
        return m.fault(C_SFAULT, a, pc, fuel);
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_jalr_mv(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let s = (w >> 2) & 31;
    if bit(w, 12) == 0 {
        if s == 0 {
            // c.jr
            if d == 0 {
                return illegal(m, w, pc, fuel);
            }
            let t = r(m, d) & !1;
            next!(m, t, fuel - 1)
        } else {
            // c.mv
            let v = r(m, s);
            w_(m, d, v);
            next!(m, pc.wrapping_add(2), fuel - 1)
        }
    } else if s == 0 {
        if d == 0 {
            // c.ebreak
            return m.fault(C_BREAK, pc, pc, fuel);
        }
        // c.jalr
        let t = r(m, d) & !1;
        w_(m, 1, pc.wrapping_add(2));
        next!(m, t, fuel - 1)
    } else {
        // c.add
        let v = r(m, d).wrapping_add(r(m, s));
        w_(m, d, v);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
}

// ===================================================================== table

static TABLE: [Handler; 64] = [
    // ---- quadrant 0 (tok 0..7) ----
    c_addi4spn, // 000 c.addi4spn
    op_bad,     // 001 c.fld
    c_lw,       // 010 c.lw
    op_bad,     // 011 c.flw
    op_bad,     // 100 reserved
    op_bad,     // 101 c.fsd
    c_sw,       // 110 c.sw
    op_bad,     // 111 c.fsw
    // ---- quadrant 1 (tok 8..15) ----
    c_addi, // 000 c.nop / c.addi
    c_jal,  // 001 c.jal
    c_li,   // 010 c.li
    c_lui,  // 011 c.lui / c.addi16sp
    c_alu,  // 100 misc-alu
    c_j,    // 101 c.j
    c_beqz, // 110 c.beqz
    c_bnez, // 111 c.bnez
    // ---- quadrant 2 (tok 16..23) ----
    c_slli,    // 000 c.slli
    op_bad,    // 001 c.fldsp
    c_lwsp,    // 010 c.lwsp
    op_bad,    // 011 c.flwsp
    c_jalr_mv, // 100 c.jr/c.mv/c.ebreak/c.jalr/c.add
    op_bad,    // 101 c.fsdsp
    c_swsp,    // 110 c.swsp
    op_bad,    // 111 c.fswsp
    // ---- tok 24..31: unreachable, op[1:0]==3 means 32-bit ----
    op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad,
    // ---- 32-bit, indexed by opcode[6:2] (tok 32..63) ----
    op_load,   // 00 LOAD
    op_bad,    // 01 LOAD-FP
    op_bad,    // 02 custom-0
    op_fence,  // 03 MISC-MEM
    op_imm,    // 04 OP-IMM
    op_auipc,  // 05 AUIPC
    op_bad,    // 06 OP-IMM-32
    op_bad,    // 07 (48-bit)
    op_store,  // 08 STORE
    op_bad,    // 09 STORE-FP
    op_bad,    // 0a custom-1
    op_bad,    // 0b AMO
    op_reg,    // 0c OP
    op_lui,    // 0d LUI
    op_bad,    // 0e OP-32
    op_bad,    // 0f (64-bit)
    op_bad,    // 10 MADD
    op_bad,    // 11 MSUB
    op_bad,    // 12 NMSUB
    op_bad,    // 13 NMADD
    op_bad,    // 14 OP-FP
    op_bad,    // 15 reserved
    op_bad,    // 16 custom-2
    op_bad,    // 17 (48-bit)
    op_branch, // 18 BRANCH
    op_jalr,   // 19 JALR
    op_bad,    // 1a reserved
    op_jal,    // 1b JAL
    op_system, // 1c SYSTEM
    op_bad,    // 1d reserved
    op_bad,    // 1e custom-3
    op_bad,    // 1f (>= 80-bit)
];
