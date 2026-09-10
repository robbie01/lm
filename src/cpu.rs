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
    if m.prof_on {
        m.watch.gen[(i & 31) as usize] = 0;
    }
}

/// orc.b: every byte that has any bit set becomes 0xff. The only Zbb
/// operation with no one-liner in Rust.
#[inline(always)]
fn orc_b(a: u32) -> u32 {
    let mut v = 0u32;
    for k in 0..4 {
        if (a >> (k * 8)) & 0xff != 0 {
            v |= 0xff << (k * 8);
        }
    }
    v
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
        become (unsafe { *m.table.get_unchecked(tok as usize) })(m, w, pc, fuel)
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
    if m.prof_on {
        m.watch.new_block();
        if rd(w) == 1 {
            prof_call(m, pc.wrapping_add(imm_j(w)));
        }
    }
    w_(m, rd(w), pc.wrapping_add(4));
    next!(m, pc.wrapping_add(imm_j(w)), fuel - 1)
}

/// A shadow call stack, to answer one question: how many activations return
/// without having called anything? Those are the ones whose frame - eight
/// instructions to build and six to take down - buys nothing, because a leaf
/// has no callee to protect anything from.
///
/// `jal`/`jalr` writing ra is a call and `jalr x0, ra` is a return, which is
/// exactly how this compiler spells them. A tail call is `jalr x0, <reg>`:
/// the caller's frame is already gone and the callee's activation is charged
/// to the same slot, so a tail-calling leaf is not counted as one. That
/// undercounts, which is the safe direction.
fn prof_call(m: &mut Machine, target: u32) {
    let d = m.watch.depth;
    // The caller is a function that calls, whatever this particular
    // activation of it happens to do.
    let here = m.watch.entry_pc[d];
    m.watch.funcs.entry(here).or_insert((0, false)).1 = true;
    m.watch.called[d] = true;
    if d < 511 {
        m.watch.depth = d + 1;
        m.watch.called[d + 1] = false;
        m.watch.entry_pc[d + 1] = target;
        m.watch.entry_ins[d + 1] = m.prof[crate::prof::TOTAL];
    }
    m.watch.funcs.entry(target).or_insert((0, false)).0 += 1;
    m.prof[crate::prof::CALLS] += 1;
}

fn prof_ret(m: &mut Machine) {
    let d = m.watch.depth;
    if d == 0 {
        return;
    }
    if !m.watch.called[d] {
        m.prof[crate::prof::LEAF_CALLS] += 1;
        let now: u64 = m.prof[crate::prof::TOTAL];
        m.prof[crate::prof::LEAF_INS] += now.saturating_sub(m.watch.entry_ins[d]);
    }
    m.watch.depth = d - 1;
}

#[inline(never)]
fn op_jalr(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if f3(w) != 0 {
        return illegal(m, w, pc, fuel);
    }
    let t = r(m, rs1(w)).wrapping_add(imm_i(w)) & !1;
    if m.prof_on {
        m.watch.new_block();
        if rd(w) == 1 {
            prof_call(m, t);
        } else if rd(w) == 0 && rs1(w) == 1 {
            prof_ret(m);
        }
    }
    w_(m, rd(w), pc.wrapping_add(4));
    next!(m, t, fuel - 1)
}

#[inline(never)]
fn op_branch(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if m.prof_on {
        if m.watch.li_pc.wrapping_add(4) == pc
            && (m.watch.li_rd == rs1(w) || m.watch.li_rd == rs2(w))
        {
            m.prof[crate::prof::LI_BRANCH] += 1;
        }
        m.watch.new_block();
    }
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
    if m.prof_on { unsafe {
        *m.prof.get_unchecked_mut(crate::prof::mem_slot(rs1(w), false)) += 1;
    }}
    let a = r(m, rs1(w)).wrapping_add(imm_i(w));
    if m.prof_on && f3(w) == 2 && (rs1(w) == 8 || rs1(w) == 2) {
        prof_load(m, a, pc, rd(w));
    }
    match do_load(m, a, f3(w), fuel) {
        Some(v) => w_(m, rd(w), v),
        None => return m.fault(C_LFAULT, a, pc, fuel),
    }
    if m.prof_on {
        let d = rd(w) as usize;
        m.watch.addr[d] = a;
        m.watch.gen[d] = m.watch.block;
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// Was this word already in a register, put there earlier in this same
/// straight-line run? That is exactly what a basic-block peephole can see,
/// and the number decides whether one is worth writing.
fn prof_load(m: &mut Machine, a: u32, pc: u32, dst: u32) {
    let gen = m.watch.block;
    let mut hit = false;
    for k in 1..32 {
        if k != dst as usize && m.watch.gen[k] == gen && m.watch.addr[k] == a {
            hit = true;
            break;
        }
    }
    if !hit {
        return;
    }
    m.prof[crate::prof::LD_REDUNDANT] += 1;
    if m.watch.st_pc.wrapping_add(4) == pc && m.watch.st_addr == a {
        m.prof[crate::prof::LD_REDUNDANT_ADJ] += 1;
    }
}

#[inline(always)]
/// TEMPORARY: report a word being stored whose top half matches LM_WATCH_HI.
/// The corruption being chased shows up as a jump to `0xf7f7xxxx`, and every
/// attempt to catch it from Lisp moves it, so the net has to be down here.
fn watch_hi() -> Option<u32> {
    use std::sync::OnceLock;
    static HI: OnceLock<Option<u32>> = OnceLock::new();
    *HI.get_or_init(|| {
        std::env::var("LM_WATCH_HI")
            .ok()
            .and_then(|s| u32::from_str_radix(s.trim_start_matches("0x"), 16).ok())
    })
}

/// The name of the function the machine is standing in, read out of the code
/// object every frame keeps in s1 - the same word a backtrace uses.
pub fn watch_backtrace(m: &Machine) -> String {
    // Every prologue saves its caller's frame base at s0-8 and its caller's
    // code object at s0-16, which is what a Lisp backtrace walks.
    let mut out = String::new();
    let mut s0 = m.x[8];
    let mut code = m.x[9];
    for _ in 0..12 {
        out.push_str(&name_of(m, code));
        out.push_str(" <- ");
        if s0 < 0x2000 || s0 >= 0x0100_0000 {
            break;
        }
        code = m.peek32(s0.wrapping_sub(16));
        s0 = m.peek32(s0.wrapping_sub(8));
    }
    out
}

fn name_of(m: &Machine, code: u32) -> String {
    if code & 7 != 4 {
        return String::from("?");
    }
    let name = m.peek32(code.wrapping_add(4 * crate::heap::CODE_NAME));
    if name & 7 != 4 {
        return String::from("?");
    }
    let mut name = name;
    let mut hdr = m.peek32(name.wrapping_sub(4));
    // A code object's name may be a symbol; follow it to the string.
    if hdr & 0xff == crate::heap::T_SYMBOL {
        name = m.peek32(name.wrapping_add(4 * crate::heap::SYM_NAME));
        if name & 7 != 4 {
            return String::from("?sym");
        }
        hdr = m.peek32(name.wrapping_sub(4));
    }
    if hdr & 0xff != crate::heap::T_STRING {
        return format!("?type{}", hdr & 0xff);
    }
    let n = (hdr >> 8).min(48);
    let mut out = String::new();
    for i in 0..n {
        out.push(m.peek32(name + i) as u8 as char);
    }
    out
}

fn watch_where(m: &Machine) -> String {
    let s1 = m.x[9];
    if s1 & 7 != 4 {
        return String::from("?");
    }
    let name = m.peek32(s1.wrapping_add(4 * crate::heap::CODE_NAME));
    if name & 7 != 4 {
        return String::from("?");
    }
    let hdr = m.peek32(name.wrapping_sub(4));
    if hdr & 0xff != crate::heap::T_STRING {
        return String::from("?");
    }
    let n = (hdr >> 8).min(64);
    let mut out = String::new();
    for i in 0..n {
        out.push(m.peek32(name + i) as u8 as char);
    }
    out
}

fn watch_range() -> Option<(u32, u32)> {
    use std::sync::OnceLock;
    static R: OnceLock<Option<(u32, u32)>> = OnceLock::new();
    *R.get_or_init(|| {
        let lo = std::env::var("LM_WATCH_ADDR").ok()?;
        let lo = u32::from_str_radix(lo.trim_start_matches("0x"), 16).ok()?;
        let len = std::env::var("LM_WATCH_LEN")
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(128);
        Some((lo, len))
    })
}

fn do_store(m: &mut Machine, a: u32, f: u32, v: u32, fuel: u32) -> bool {
    if f > 2 {
        return false;
    }
    if let Some(hi) = watch_hi() {
        if f == 2 && (v >> 16) == hi {
            eprintln!("watch: stored {v:#x} to {a:#x} from pc {:#x}", m.pc);
        }
    }
    if let Some((lo, len)) = watch_range() {
        if a >= lo && a < lo + len {
            eprintln!(
                "watch: wrote {v:#x} ({} bytes) to {a:#x} from pc {:#x} in {}",
                1 << f,
                m.pc,
                watch_where(m)
            );
        }
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
    if m.prof_on { unsafe {
        *m.prof.get_unchecked_mut(crate::prof::mem_slot(rs1(w), true)) += 1;
    }}
    let v = r(m, rs2(w));
    if !do_store(m, a, f3(w), v, fuel) {
        return m.fault(C_SFAULT, a, pc, fuel);
    }
    if m.prof_on && f3(w) == 2 && (rs1(w) == 8 || rs1(w) == 2) {
        // Whatever else claimed this address holds the old value now.
        let gen = m.watch.block;
        for k in 1..32 {
            if m.watch.gen[k] == gen && m.watch.addr[k] == a {
                m.watch.gen[k] = 0;
            }
        }
        let s = rs2(w) as usize;
        m.watch.addr[s] = a;
        m.watch.gen[s] = gen;
        m.watch.st_pc = pc;
        m.watch.st_addr = a;
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ---- integer ALU ----------------------------------------------------------
/// Which ratified extension an OP or OP-IMM encoding belongs to, for the
/// histogram. The base ISA's own funct7 values (0x00 for the arithmetic and
/// logical forms, 0x20 for sub and the arithmetic shifts, 0x01 for M) are not
/// counted; everything else here was added by Zba, Zbb, Zbs or Zicond.
fn prof_ext(m: &mut Machine, f7: u32, f3: u32) {
    let slot = match f7 {
        0x10 => crate::prof::ZBA,
        0x05 | 0x30 | 0x04 => crate::prof::ZBB,
        0x14 | 0x24 | 0x34 => crate::prof::ZBS,
        0x07 => crate::prof::ZICOND,
        // sub and sra share funct7 0x20 with andn, orn and xnor.
        0x20 if f3 == 4 || f3 == 6 || f3 == 7 => crate::prof::ZBB,
        _ => return,
    };
    unsafe {
        *m.prof.get_unchecked_mut(slot) += 1;
    }
}

#[inline(never)]
fn op_imm(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    let i = imm_i(w);
    let sh = (w >> 20) & 31;
    if m.prof_on {
        prof_ext(m, w >> 25, f3(w));
        if f3(w) == 0 && rs1(w) == 0 {
            m.prof[crate::prof::LI_TOTAL] += 1;
            m.watch.li_pc = pc;
            m.watch.li_rd = rd(w);
        }
        let f = f3(w);
        let im = imm_i(w) as i32;
        if f == 0 && (im == 1 || im == -1) && m.watch.as_pc.wrapping_add(4) == pc
            && m.watch.as_rd == rs1(w)
        {
            m.prof[crate::prof::TAG_FIX] += 1;
        } else if f == 5 && w >> 25 == 0x20 && sh == 1 {
            m.prof[crate::prof::TAG_UNTAG] += 1;
        } else if (f == 1 && w >> 25 == 0 && sh == 1) || (f == 6 && im == 1) {
            m.prof[crate::prof::TAG_RETAG] += 1;
        }
    }
    let v = match f3(w) {
        0 => a.wrapping_add(i),
        2 => ((a as i32) < (i as i32)) as u32,
        3 => (a < i) as u32,
        4 => a ^ i,
        6 => a | i,
        7 => a & i,
        // The shift-immediate slot is where the B extension hides its
        // single-source operations: funct7 tells them apart, and for the
        // Zbb unary forms the shift amount is a further selector.
        1 => match w >> 25 {
            0x00 => a << sh,
            0x14 => a | (1 << sh),  // bseti
            0x24 => a & !(1 << sh), // bclri
            0x34 => a ^ (1 << sh),  // binvi
            0x30 => match sh {
                0 => a.leading_zeros(),
                1 => a.trailing_zeros(),
                2 => a.count_ones(),
                4 => a as i8 as i32 as u32,
                5 => a as i16 as i32 as u32,
                _ => return illegal(m, w, pc, fuel),
            },
            _ => return illegal(m, w, pc, fuel),
        },
        _ => match w >> 25 {
            0x00 => a >> sh,
            0x20 => ((a as i32) >> sh) as u32,
            0x24 => (a >> sh) & 1,      // bexti
            0x30 => a.rotate_right(sh), // rori
            0x34 if sh == 0x18 => a.swap_bytes(),
            0x14 if sh == 0x07 => orc_b(a),
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
    if m.prof_on {
        prof_ext(m, w >> 25, f);
        let f7 = w >> 25;
        if (f7 == 0 && f == 0) || (f7 == 0x20 && f == 0) {
            m.watch.as_pc = pc;
            m.watch.as_rd = rd(w);
            m.prof[crate::prof::ARITH] += 1;
        } else if f7 == 1 {
            m.prof[crate::prof::ARITH] += 1;
        }
    }
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
            4 => !(a ^ b), // xnor
            5 => ((a as i32) >> (b & 31)) as u32,
            6 => a | !b, // orn
            7 => a & !b, // andn
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zba: shift-and-add, one instruction for base + index * n ----
        0x10 => match f {
            2 => (a << 1).wrapping_add(b),
            4 => (a << 2).wrapping_add(b),
            6 => (a << 3).wrapping_add(b),
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zbb: min and max. Tagged fixnums are 2n+1, which preserves
        // signed order, so these are correct on tagged values as they stand.
        0x05 => match f {
            4 => (a as i32).min(b as i32) as u32,
            5 => a.min(b),
            6 => (a as i32).max(b as i32) as u32,
            7 => a.max(b),
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zicond: conditional zero, which is how a branchless select is
        // built without a flags register.
        0x07 => match f {
            5 => {
                if b == 0 {
                    0
                } else {
                    a
                }
            } // czero.eqz
            7 => {
                if b != 0 {
                    0
                } else {
                    a
                }
            } // czero.nez
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zbb: rotate ----
        0x30 => match f {
            1 => a.rotate_left(b & 31),
            5 => a.rotate_right(b & 31),
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zbs: single-bit operations ----
        0x14 => match f {
            1 => a | (1 << (b & 31)), // bset
            _ => return illegal(m, w, pc, fuel),
        },
        0x24 => match f {
            1 => a & !(1 << (b & 31)), // bclr
            5 => (a >> (b & 31)) & 1,  // bext
            _ => return illegal(m, w, pc, fuel),
        },
        0x34 => match f {
            1 => a ^ (1 << (b & 31)), // binv
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zbb: zext.h, which on RV32 lives here rather than in OP-IMM ----
        0x04 => match f {
            4 if rs2(w) == 0 => a & 0xffff,
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

// ------------------------------------------------------------------- pairs
/// The custom-0 opcode space: a load or a store through a checked reference.
///
/// This is RV32I's LOAD and STORE with the width field spent on something
/// better. Every access here is a word, because every Lisp value is; the three
/// bits that would have said byte-or-halfword say instead what the base
/// register has to be, and the twelve-bit offset says which slot.
///
///     funct3 0   load  through a pair;   nil is a pair and reads as nils
///     funct3 1   load  through an object
///     funct3 4   store through a pair;   nil has no cell and is refused
///     funct3 5   store through an object
///
/// `car` is offset 0 and `cdr` is offset 4 of the same instruction, which is
/// how four opcodes became two. The offset is what makes it general: a
/// symbol's value cell, a closure's code object and an object's header were
/// all bare `lw`s that proved nothing, and they are checked now for the same
/// one instruction they always cost.
///
/// What this does *not* do is bound the offset. That is `ldx`'s job, and it
/// needs the length out of the header to do it. Here the offset is a constant
/// the compiler wrote, into a layout it decided; the check is that the thing
/// being reached into is the kind of thing that has such a layout at all.
#[inline(never)]
fn op_ref(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    if f & 3 > 1 {
        return illegal(m, w, pc, fuel);
    }
    let v = r(m, rs1(w));
    let store = f & 4 != 0;
    let want_object = f & 1 != 0;
    let ok = if want_object {
        v & 7 == 4
    } else {
        v & 7 == 0 && !(store && v == 0)
    };
    if !ok {
        return m.fault(C_TYPE, v, pc, fuel);
    }
    let off = if store { imm_s(w) } else { imm_i(w) };
    let a = v.wrapping_add(off);
    if !m.in_ram(a, 4) {
        return m.fault(if store { C_SFAULT } else { C_LFAULT }, a, pc, fuel);
    }
    if store {
        unsafe { m.wr32(a, r(m, rs2(w))) };
    } else {
        let d = unsafe { m.rd32(a) };
        w_(m, rd(w), d);
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The custom-1 opcode space: indexed access to an object, checked.
///
/// One instruction does what four did - untag the index, scale it, add it to
/// the base, load - and on the way it establishes everything that was being
/// taken on trust. The address arithmetic needs the header word anyway to be
/// worth anything, and the header is where the length is, so the bounds check
/// costs a comparison the processor can do in parallel with the address.
///
///     funct7   the type the object must be, or 0 for any object at all
///     funct3   bit 0 store, bit 1 byte, bit 2 the index is an immediate
///     rs1      the object, tagged
///     rs2      the index: a register holding a tagged fixnum, or - when
///              funct3 bit 2 is set - a raw five-bit index, 0 to 31
///     rd       where the result goes, or - for a store - the value to write
///
/// The immediate form exists because most indices are constants: every record
/// field, every closure slot, the instance tag and version. Putting the index
/// in the rs2 field follows `slli`, which has always kept its shift amount
/// there, so the encoding stays R-type and nothing that walks instructions
/// needs a new case. The immediate form is also what makes a checked call
/// free: loading a closure's entry point is slot 0 of a t-closure, which used
/// to be a bare `lw` that proved nothing.
///
/// Byte forms leave a raw byte in `rd` and take a raw byte from it, so the
/// tagging a character or a fixnum needs stays where it belongs, in the
/// compiler. Traps carry the offending value in `mtval`, and the handler
/// decodes the instruction to say which operand it was.
#[inline(never)]
fn op_index(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let obj = r(m, rs1(w));
    if obj & 7 != 4 {
        return m.fault(C_TYPE, obj, pc, fuel);
    }
    let hdr_at = obj.wrapping_sub(4);
    if !m.in_ram(hdr_at, 4) {
        return m.fault(C_LFAULT, hdr_at, pc, fuel);
    }
    let hdr = unsafe { m.rd32(hdr_at) };
    let want = w >> 25;
    if want != 0 && hdr & 255 != want {
        return m.fault(C_TYPE, obj, pc, fuel);
    }
    let f = f3(w);
    if m.prof_on { unsafe {
        *m.prof.get_unchecked_mut(crate::prof::INDEX0 + f as usize) += 1;
    }}
    // An immediate index is trusted to be a small non-negative number, because
    // the compiler put it there. A register index is a Lisp value and is not.
    let i = if f & 4 != 0 {
        rs2(w) as i32
    } else {
        let idx = r(m, rs2(w));
        if idx & 1 != 1 {
            return m.fault(C_TYPE, idx, pc, fuel);
        }
        (idx as i32) >> 1
    };
    if i < 0 || (i as u32) >= hdr >> 8 {
        return m.fault(C_RANGE, ((i as u32) << 1) | 1, pc, fuel);
    }
    let a = if f & 2 == 0 {
        obj.wrapping_add((i as u32) << 2)
    } else {
        obj.wrapping_add(i as u32)
    };
    let sz = if f & 2 == 0 { 4 } else { 1 };
    if !m.in_ram(a, sz) {
        return m.fault(if f & 1 == 0 { C_LFAULT } else { C_SFAULT }, a, pc, fuel);
    }
    match f & 3 {
        0 => {
            let v = unsafe { m.rd32(a) };
            w_(m, rd(w), v);
        }
        1 => unsafe { m.wr32(a, r(m, rd(w))) },
        2 => {
            let v = unsafe { m.rd8(a) } as u32;
            w_(m, rd(w), v);
        }
        _ => unsafe { m.wr8(a, r(m, rd(w)) as u8) },
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The largest and smallest a fixnum can be: thirty-one bits, tagged 2n+1.
const FIX_MAX: i64 = (1 << 30) - 1;
const FIX_MIN: i64 = -(1 << 30);

#[inline(always)]
fn tag(v: i32) -> u32 {
    ((v as u32) << 1) | 1
}

/// The custom-2 opcode space: fixnum arithmetic, checked.
///
/// This is the hole the rest of the machine did not have. `car` of a fixnum
/// traps, `vector-ref` of a string traps, calling a number traps - and until
/// this instruction existed, `(+ "abc" 2)` returned a *cons*: a string is an
/// object pointer with its low three bits equal to four, adding a tagged two
/// adds four, and four plus four is the pair tag. You could fabricate a
/// pointer to the middle of a string with one addition, and `car` would read
/// it. Both operands are checked here, and the offending one is what lands in
/// `mtval` for the handler to name.
///
///     funct7 0x00   add sub mul div rem and or xor, wrapping at 31 bits
///     funct7 0x20   the same five arithmetic forms, trapping on overflow
///     funct7 0x01   sll srl sra lt ltu eq
///
/// The comparisons leave a raw 0 or 1, the way `slt` does, because what
/// follows is either a branch or the two instructions that turn a flag into
/// `t` and `nil`.
#[inline(never)]
fn op_fixnum(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    let b = r(m, rs2(w));
    if a & 1 == 0 {
        return m.fault(C_TYPE, a, pc, fuel);
    }
    if b & 1 == 0 {
        return m.fault(C_TYPE, b, pc, fuel);
    }
    let f = f3(w);
    let f7 = w >> 25;
    if m.prof_on { unsafe {
        let base = if f7 == 1 { crate::prof::FIX1 } else { crate::prof::FIX0 };
        *m.prof.get_unchecked_mut(base + f as usize) += 1;
    }}
    let x = (a as i32) >> 1;
    let y = (b as i32) >> 1;
    let v = match f7 {
        0x01 => match f {
            0 => tag(((x as u32) << (y & 31)) as i32),
            1 => tag(((x as u32) >> (y & 31)) as i32),
            2 => tag(x >> (y & 31)),
            3 => (x < y) as u32,
            4 => ((x as u32) < (y as u32)) as u32,
            5 => (x == y) as u32,
            _ => return illegal(m, w, pc, fuel),
        },
        0x00 | 0x20 => match f {
            // and and or keep the low bit when both sides have it; xor clears
            // it and has to put it back.
            5 => a & b,
            6 => a | b,
            7 => (a ^ b) | 1,
            _ => {
                let n: i64 = match f {
                    0 => x as i64 + y as i64,
                    1 => x as i64 - y as i64,
                    2 => x as i64 * y as i64,
                    _ => {
                        if y == 0 {
                            return m.fault(C_DIVZERO, a, pc, fuel);
                        }
                        // A fixnum is never i32::MIN, so neither of these can
                        // overflow the way i32::MIN / -1 does.
                        if f == 3 {
                            (x / y) as i64
                        } else {
                            (x % y) as i64
                        }
                    }
                };
                if f7 == 0x20 && (n < FIX_MIN || n > FIX_MAX) {
                    return m.fault(C_OVER, tag(n as i32), pc, fuel);
                }
                tag(n as i32)
            }
        },
        _ => return illegal(m, w, pc, fuel),
    };
    w_(m, rd(w), v);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The custom-3 opcode space: a fixnum against a constant, and memory reached
/// through a tagged address.
///
/// The second half is the bigger one. `peek` was four instructions - strip the
/// tag off the address, load, shift the word up, put a tag on - and the
/// collector's own code is nothing but that. One instruction does it, and
/// checks that the address was a number rather than, say, a string.
///
///     funct3 0  faddi rd, rs1, imm   rd <- rs1 + 2*imm
///     funct3 1  fandi rd, rs1, imm   rd <- rs1 & (2*imm | 1)
///     funct3 2  fori  rd, rs1, imm   rd <- rs1 | (2*imm | 1)
///     funct3 3  fshi  rd, rs1, imm   imm[4:0] amount, imm[6:5] 0 sll 1 srl 2 sra
///     funct3 4  tlw   rd, imm(rs1)   rd <- tagged word at (rs1 >> 1) + imm
///     funct3 5  tlb   rd, imm(rs1)   the same for a zero-extended byte
///     funct3 6  tsw   rs2, imm(rs1)  store rs2 >> 1 there, S-type
///     funct3 7  tsb   rs2, imm(rs1)
#[inline(never)]
fn op_tagged(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    if m.prof_on { unsafe {
        *m.prof.get_unchecked_mut(crate::prof::TAGD + f as usize) += 1;
    }}
    let a = r(m, rs1(w));
    if a & 1 == 0 {
        return m.fault(C_TYPE, a, pc, fuel);
    }
    let x = (a as i32) >> 1;
    if f >= 4 {
        return op_tagged_mem(m, w, pc, fuel);
    }
    {
        let i = imm_i(w) as i32;
        let v = match f {
            0 => tag(x.wrapping_add(i)),
            1 => a & tag(i),
            2 => a | tag(i),
            _ => {
                let sh = (i as u32) & 31;
                match ((i as u32) >> 5) & 3 {
                    0 => tag(((x as u32) << sh) as i32),
                    1 => tag(((x as u32) >> sh) as i32),
                    2 => tag(x >> sh),
                    _ => return illegal(m, w, pc, fuel),
                }
            }
        };
        w_(m, rd(w), v);
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
}

/// The memory half of custom-3, split out so that the arithmetic half can end
/// in a tail call of its own rather than fall past one.
///
/// It goes through the same `do_load` and `do_store` the base ISA uses, which
/// matters more than it looks: a device register is at `mmio-base`, and
/// `mmio-base` is a *negative* fixnum. An address that is not RAM is not
/// automatically a fault.
#[inline(never)]
fn op_tagged_mem(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    let x = (r(m, rs1(w)) as i32) >> 1;
    let store = f & 2 != 0;
    let off = if store { imm_s(w) } else { imm_i(w) } as i32;
    let addr = (x as u32).wrapping_add(off as u32);
    if store {
        let val = r(m, rs2(w));
        if val & 1 == 0 {
            return m.fault(C_TYPE, val, pc, fuel);
        }
        // sw or sb, and the value goes in untagged.
        let sz = if f & 1 == 0 { 2 } else { 0 };
        if !do_store(m, addr, sz, ((val as i32) >> 1) as u32, fuel) {
            return m.fault(C_SFAULT, addr, pc, fuel);
        }
    } else {
        // lw, or lbu so that a byte arrives without a sign on it.
        let sz = if f & 1 == 0 { 2 } else { 4 };
        match do_load(m, addr, sz, fuel) {
            Some(v) => w_(m, rd(w), tag(v as i32)),
            None => return m.fault(C_LFAULT, addr, pc, fuel),
        }
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
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
            // A return, when it is the return address being jumped through.
            if m.prof_on {
                m.watch.new_block();
                if d == 1 {
                    prof_ret(m);
                }
            }
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
        if m.prof_on {
            m.watch.new_block();
            prof_call(m, t);
        }
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
/// Counting is a second dispatch table rather than a test in the dispatch
/// macro. A branch there costs more than everything it guards, because that
/// macro is the one piece of code every instruction in the machine expands;
/// swapping the table costs one load of a pointer that is already hot.
///
/// Every entry is the same function, because it can work out which slot it is
/// from the instruction word it was handed anyway.
#[inline(never)]
fn prof_hook(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let tok = if w & 3 == 3 {
        32 + ((w >> 2) & 31)
    } else {
        ((w & 3) << 3) | ((w >> 13) & 7)
    } as usize;
    unsafe {
        *m.prof.get_unchecked_mut(tok) += 1;
        *m.prof.get_unchecked_mut(crate::prof::TOTAL) += 1;
    }
    become (unsafe { *TABLE.get_unchecked(tok) })(m, w, pc, fuel)
}

pub static PROF_TABLE: [Handler; 64] = [prof_hook; 64];

/// `s2` holds the running task and nothing but `%set-this-task!` writes it, so
/// it is either nil or a record in object space - always. This checks that
/// before every instruction and reports the first one that finds it otherwise,
/// naming the instruction *before* it, which is the one that did it.
///
/// It costs no cycles and no fuel, the way the profiler's hook does not, so
/// installing it does not move a fault that depends on timing.
fn watch_hook(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if !m.watch_fired {
        // s2 holds the running task: nil, or a record in object space.
        let s2 = m.x[18];
        let s2_ok = s2 == 0
            || (s2 & 7 == 4 && s2 >= crate::map::OBJ_BASE && s2 < crate::map::OBJ_END);
        // And every indirect jump lands in code space. Catching it here rather
        // than at the fetch means the registers that chose the target are
        // still the ones this instruction is looking at.
        let jump = if w & 0x7f == 0x67 {
            let rs1 = ((w >> 15) & 31) as usize;
            let imm = ((w as i32) >> 20) as u32;
            Some((rs1, m.x[rs1].wrapping_add(imm) & !1))
        } else if w & 3 == 2 && (w >> 13) & 7 == 4 && (w >> 2) & 31 == 0 {
            let rs1 = ((w >> 7) & 31) as usize;
            Some((rs1, m.x[rs1] & !1))
        } else {
            None
        };
        // mret returns to whatever the trap stub put in mepc, which for a task
        // resuming is word 0 of its context. A wrong one is a jump with no
        // jump instruction in it.
        let mret = if w == 0x3020_0073 { Some(m.mepc) } else { None };
        let jump_bad = match jump.map(|(_, t)| t).or(mret) {
            Some(t) => t < crate::map::CODE_BASE || t >= crate::map::CODE_END,
            None => false,
        };
        if !s2_ok || jump_bad {
            m.watch_fired = true;
            if !s2_ok {
                eprintln!("s2 watch: s2 = {s2:#x} at pc {pc:#x}");
            }
            if let Some((rs1, t)) = jump {
                eprintln!("jump watch: pc {pc:#x} insn {w:#010x} through x{rs1} to {t:#x}");
            }
            if let Some(t) = mret {
                eprintln!(
                    "mret watch: pc {pc:#x} returns to {t:#x}; context at {:#x}",
                    m.mscratch
                );
            }
            eprintln!("  before: {:#010x} at pc {:#x}", m.watch_prev_w, m.watch_prev);
            for i in 0..32 {
                eprint!("  x{i}={:#x}", m.x[i]);
                if i % 4 == 3 {
                    eprintln!();
                }
            }
        }
    }
    m.watch_prev = pc;
    m.watch_prev_w = w;
    let tok = if w & 3 == 3 {
        32 + ((w >> 2) & 31)
    } else {
        ((w & 3) << 3) | ((w >> 13) & 7)
    } as usize;
    become (unsafe { *TABLE.get_unchecked(tok) })(m, w, pc, fuel)
}

pub static WATCH_TABLE: [Handler; 64] = [watch_hook; 64];

pub static TABLE: [Handler; 64] = [
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
    op_ref,    // 02 custom-0: a load or store through a checked reference
    op_fence,  // 03 MISC-MEM
    op_imm,    // 04 OP-IMM
    op_auipc,  // 05 AUIPC
    op_bad,    // 06 OP-IMM-32
    op_bad,    // 07 (48-bit)
    op_store,  // 08 STORE
    op_bad,    // 09 STORE-FP
    op_index,  // 0a custom-1: indexed access, bounds and type checked
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
    op_fixnum, // 16 custom-2: fixnum arithmetic, checked
    op_bad,    // 17 (48-bit)
    op_branch, // 18 BRANCH
    op_jalr,   // 19 JALR
    op_bad,    // 1a reserved
    op_jal,    // 1b JAL
    op_system, // 1c SYSTEM
    op_bad,    // 1d reserved
    op_tagged, // 1e custom-3: constants, and memory through a tagged address
    op_bad,    // 1f (>= 80-bit)
];
