//! Token-threaded RV32IMC core in CHERI capability mode, with Xlm.
//!
//! The token is the opcode itself. There is no predecode pass and no
//! translation cache, so nothing needs invalidating when the Lisp compiler
//! writes fresh code into the heap and jumps to it. A 64-entry table is
//! indexed directly off the encoded instruction:
//!
//! ```text
//!     16-bit forms   tok = (op[1:0] << 3) | funct3       ->  0 .. 23
//!     32-bit forms   tok = 32 + opcode[6:2]              -> 32 .. 63
//! ```
//!
//! Every handler ends by expanding `next!`, which repeats the fetch, the
//! token computation and the indirect jump in place before an explicit tail
//! call. Each opcode therefore has its own branch site, and the predictor
//! learns per-opcode successor patterns rather than one shared dispatch.
//! `become` guarantees a real `jmp`, so a program runs in constant stack.
//!
//! Every register is a capability (see `Machine::x`). The integer
//! instructions read addresses and write untagged results, two stores. An
//! access through a capability is checked against a window cached with the
//! register: its bounds clipped to RAM, filled in the first time the
//! register is used as an authority. So the common load or store is one
//! mask test and one range comparison, and an access that passes them is in
//! RAM. Everything else, the first use of a fresh capability, a device, a
//! fault, goes to one slow path per kind of instruction that decodes the
//! instruction again and checks it in full. Fetch is checked the same way
//! against PCC's window.

use crate::cap::*;
use crate::dev;
use crate::heap::{T_BYTES, T_CLOSURE, T_STRING, T_SYMBOL};
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

// ------------------------------------------------------------ register file
/// The metadata bits the fast paths test, in `Machine::xm` positions.
const TAG: u64 = XM_TAG;
const READY: u64 = XM_READY;
const fn pm(p: u32) -> u64 {
    (p as u64) << PERM_SHIFT
}
const M_LD: u64 = pm(P_LD);
const M_SD: u64 = pm(P_SD);
const M_LC: u64 = pm(P_LC);
const M_SC: u64 = pm(P_SC);
const M_LM: u64 = pm(P_LM);
const M_EX: u64 = pm(P_EX);
const M_HD: u64 = pm(P_HD);
const M_OT: u64 = OTYPE_MASK as u64;
/// Every otype but unsealed and the sentry: what a jump refuses.
const M_OT_HI: u64 = (OTYPE_MASK & !(1 << OTYPE_SHIFT)) as u64;
const M_SENTRY: u64 = (OT_SENTRY << OTYPE_SHIFT) as u64;
const M_CLOSURE: u64 = (OT_CLOSURE << OTYPE_SHIFT) as u64;
/// What a load through a capability strips when its authority lacks LM.
const M_MUTABLE: u64 = M_SD | M_SC | M_LM;

#[inline(always)]
fn r(m: &Machine, i: u32) -> u32 {
    unsafe { *m.x.get_unchecked((i & 31) as usize) }
}
#[inline(always)]
fn h(m: &Machine, i: u32) -> u64 {
    unsafe { *m.xm.get_unchecked((i & 31) as usize) }
}

/// Write an integer result: the address, and no metadata or tag. x0 is
/// re-zeroed unconditionally rather than branched around; it shares a cache
/// line with the hottest registers, so the extra store is cheaper than the
/// misprediction it replaces.
#[inline(always)]
fn w_(m: &mut Machine, i: u32, v: u32) {
    unsafe {
        *m.x.get_unchecked_mut((i & 31) as usize) = v;
        *m.xm.get_unchecked_mut((i & 31) as usize) = 0;
        *m.x.get_unchecked_mut(0) = 0;
    }
}

/// Write a capability whose window is not yet known.
#[inline(always)]
fn wc(m: &mut Machine, i: u32, addr: u32, xm: u64) {
    unsafe {
        *m.x.get_unchecked_mut((i & 31) as usize) = addr;
        *m.xm.get_unchecked_mut((i & 31) as usize) = xm & !READY;
        *m.x.get_unchecked_mut(0) = 0;
        *m.xm.get_unchecked_mut(0) = 0;
    }
}

#[inline(always)]
fn wcap(m: &mut Machine, i: u32, c: Cap) {
    wc(m, i, c.addr, c.meta as u64 | if c.tag { TAG } else { 0 })
}

/// Write a tagged capability with its window.
#[inline(always)]
fn wcw(m: &mut Machine, i: u32, addr: u32, xm: u64, wb: u32, wl: u32) {
    let k = (i & 31) as usize;
    unsafe {
        *m.x.get_unchecked_mut(k) = addr;
        *m.xm.get_unchecked_mut(k) = xm | READY;
        *m.wb.get_unchecked_mut(k) = wb;
        *m.wl.get_unchecked_mut(k) = wl;
        *m.x.get_unchecked_mut(0) = 0;
        *m.xm.get_unchecked_mut(0) = 0;
    }
}

/// Copy a register whole, window and all: `cmove`.
#[inline(always)]
fn mv(m: &mut Machine, d: u32, s: u32) {
    let (d, s) = ((d & 31) as usize, (s & 31) as usize);
    unsafe {
        *m.x.get_unchecked_mut(d) = *m.x.get_unchecked(s);
        *m.xm.get_unchecked_mut(d) = *m.xm.get_unchecked(s);
        *m.wb.get_unchecked_mut(d) = *m.wb.get_unchecked(s);
        *m.wl.get_unchecked_mut(d) = *m.wl.get_unchecked(s);
        *m.x.get_unchecked_mut(0) = 0;
        *m.xm.get_unchecked_mut(0) = 0;
    }
}

#[inline(always)]
fn in_win(a: u32, b: u32, l: u32, sz: u32) -> bool {
    a.wrapping_sub(b) as u64 + sz as u64 <= l as u64
}

/// Register `s`'s metadata, with its window made first if it is tagged and
/// has none yet. A capability loaded from memory has no window until it is
/// used, and most are used at once: a pointer is loaded to be followed.
#[inline(always)]
fn hw(m: &mut Machine, s: u32) -> u64 {
    let hh = h(m, s);
    if hh & (READY | TAG) == TAG {
        m.fill_window(s);
        h(m, s)
    } else {
        hh
    }
}

/// The fast authority test: register `s` is tagged and unsealed, holds the
/// permissions `need`, and `[a, a + sz)` is inside its window, so inside its
/// bounds and inside RAM.
#[inline(always)]
fn auth(m: &mut Machine, s: u32, need: u64, a: u32, sz: u32) -> bool {
    let k = (s & 31) as usize;
    let hh = hw(m, s);
    hh & (READY | TAG | M_OT | need) == READY | TAG | need
        && in_win(a, unsafe { *m.wb.get_unchecked(k) }, unsafe { *m.wl.get_unchecked(k) }, sz)
}

/// The same through DDC, for integer addressing: PCC must have SR.
#[inline(always)]
fn ddc_auth(m: &Machine, need: u32, a: u32, sz: u32) -> bool {
    m.pcc_has(P_SR) && m.ddc_perms & need == need && in_win(a, m.ddc_wb, m.ddc_wl, sz)
}

/// The sentry a jump leaves in its link register: PCC sealed for entry, at
/// the next instruction, with PCC's window.
#[inline(always)]
fn link(m: &mut Machine, d: u32, ret: u32) {
    if d != 0 {
        let xm = (m.pcc_meta as u64 & !M_OT) | M_SENTRY | if m.pcc_tag { TAG } else { 0 };
        let (b, l) = (m.pcc_wb, m.pcc_wl);
        wcw(m, d, ret, xm, b, l);
    }
}

/// PCC at `pc`. Inside the core the pc travels in the handlers' arguments
/// and `Machine::pc` is stale until the core stops.
#[inline(always)]
fn pcc_at(m: &Machine, pc: u32) -> Cap {
    Cap { addr: pc, meta: m.pcc_meta, tag: m.pcc_tag }
}

#[inline(always)]
fn capfault(m: &mut Machine, reg: u32, code: u32, pc: u32, fuel: u32) -> Stop {
    m.fault(C_CAP, (reg << CAPEX_REG_SHIFT) | code, pc, fuel)
}

/// orc.b: every byte that has any bit set becomes 0xff.
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
pub(crate) fn imm_j(w: u32) -> u32 {
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
/// CL/CS capability offset, as RV64C's c.ld: uimm[5:3]=w[12:10], uimm[7:6]=w[6:5]
#[inline(always)]
fn clc_imm(w: u32) -> u32 {
    ((w >> 7) & 0x38) | ((w << 1) & 0xc0)
}
/// c.lwsp: uimm[5]=w[12], uimm[4:2]=w[6:4], uimm[7:6]=w[3:2]
#[inline(always)]
fn lwsp_imm(w: u32) -> u32 {
    (bit(w, 12) << 5) | ((w >> 2) & 0x1c) | ((w << 4) & 0xc0)
}
/// c.lcsp, as c.ldsp: uimm[5]=w[12], uimm[4:3]=w[6:5], uimm[8:6]=w[4:2]
#[inline(always)]
fn lcsp_imm(w: u32) -> u32 {
    (bit(w, 12) << 5) | ((w >> 2) & 0x18) | ((w << 4) & 0x1c0)
}
/// c.swsp: uimm[5:2]=w[12:9], uimm[7:6]=w[8:7]
#[inline(always)]
fn swsp_imm(w: u32) -> u32 {
    ((w >> 7) & 0x3c) | ((w >> 1) & 0xc0)
}
/// c.scsp, as c.sdsp: uimm[5:3]=w[12:10], uimm[8:6]=w[9:7]
#[inline(always)]
fn scsp_imm(w: u32) -> u32 {
    ((w >> 7) & 0x38) | ((w >> 1) & 0x1c0)
}
/// CI signed 6-bit: {w[12], w[6:2]}
#[inline(always)]
fn ci_imm(w: u32) -> u32 {
    ((((w << 19) & 0x8000_0000) as i32) >> 26) as u32 | ((w >> 2) & 0x1f)
}
/// c.addi16sp: a signed multiple of 16.
#[inline(always)]
fn addi16sp_imm(w: u32) -> u32 {
    ((((w << 19) & 0x8000_0000) as i32) >> 22) as u32
        | (bit(w, 6) << 4)
        | (bit(w, 5) << 6)
        | ((w << 4) & 0x180)
        | (bit(w, 2) << 5)
}
/// CJ 11-bit signed jump offset.
#[inline(always)]
pub(crate) fn cj_imm(w: u32) -> u32 {
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
#[inline(always)]
fn token(w: u32) -> u32 {
    if w & 3 == 3 {
        32 + ((w >> 2) & 31)
    } else {
        ((w & 3) << 3) | ((w >> 13) & 7)
    }
}

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
        if !in_win(pc, m.pcc_wb, m.pcc_wl, 4) {
            return fetch_slow(m, pc, fuel);
        }
        let w = unsafe { m.rd32(pc) };
        become (unsafe { *m.table.get_unchecked(token(w) as usize) })(m, w, pc, fuel)
    }};
}

/// Entry into the threaded core. `become` requires caller and callee to
/// share a signature, so the entry stub has the handler signature and
/// ignores the instruction word.
fn enter(m: &mut Machine, _w: u32, pc: u32, fuel: u32) -> Stop {
    next!(m, pc, fuel)
}

pub fn run_block(m: &mut Machine, pc: u32, fuel: u32) -> Stop {
    let ddc = m.ddc;
    m.set_ddc(ddc);
    enter(m, 0, pc, fuel)
}

/// A fetch that is not four bytes inside PCC's window. A 16-bit instruction
/// in the window's last two bytes is legal; anything else is a fault, a
/// capability fault naming PCC if PCC forbids it and an access fault if PCC
/// allows it and there is no RAM there.
#[cold]
#[inline(never)]
fn fetch_slow(m: &mut Machine, pc: u32, fuel: u32) -> Stop {
    if in_win(pc, m.pcc_wb, m.pcc_wl, 2) {
        let w = unsafe { m.rd16(pc) } as u32;
        if w & 3 != 3 {
            return (unsafe { *m.table.get_unchecked(token(w) as usize) })(m, w, pc, fuel);
        }
    }
    let c = pcc_at(m, pc);
    let code = if !c.tag {
        CAPEX_TAG
    } else if c.is_sealed() {
        CAPEX_SEAL
    } else if !c.has(P_EX) {
        CAPEX_EXECUTE
    } else if !c.covers(pc, 2) {
        CAPEX_LENGTH
    } else {
        return m.fault(C_IFAULT, pc, pc, fuel);
    };
    capfault(m, CAPEX_REG_PCC, code, pc, fuel)
}

#[cold]
#[inline(never)]
fn illegal(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    m.fault(C_ILLEGAL, w, pc, fuel)
}

#[inline(never)]
fn op_bad(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    illegal(m, w, pc, fuel)
}

/// The length of an instruction, from its low bits.
#[inline(always)]
fn ilen(w: u32) -> u32 {
    if w & 3 == 3 {
        4
    } else {
        2
    }
}

// ============================================================== 32-bit opcodes

// ---- LUI / AUIPCC ---------------------------------------------------------
#[inline(never)]
fn op_lui(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), w & 0xffff_f000);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// `auipcc`: PCC with its address moved. Inside PCC's window the move is
/// representable and the window is PCC's.
#[inline(never)]
fn op_auipc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = pc.wrapping_add(w & 0xffff_f000);
    if in_win(a, m.pcc_wb, m.pcc_wl, 0) {
        let xm = m.pcc_meta as u64 | TAG;
        let (b, l) = (m.pcc_wb, m.pcc_wl);
        wcw(m, rd(w), a, xm, b, l);
    } else {
        let c = pcc_at(m, pc).with_addr(a);
        wcap(m, rd(w), c);
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ---- jumps ----------------------------------------------------------------
/// A jump within PCC. The target must be inside PCC's window, or the jump
/// faults where it stands.
#[inline(never)]
fn op_jal(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let t = pc.wrapping_add(imm_j(w));
    if !in_win(t, m.pcc_wb, m.pcc_wl, 2) {
        return jump_out(m, t, pc, fuel);
    }
    link(m, rd(w), pc.wrapping_add(4));
    next!(m, t, fuel - 1)
}

/// A jump within PCC to `t` outside its window: past its bounds, or to no
/// RAM.
#[cold]
#[inline(never)]
fn jump_out(m: &mut Machine, t: u32, pc: u32, fuel: u32) -> Stop {
    if pcc_at(m, pc).covers(t, 2) {
        m.fault(C_IFAULT, t, pc, fuel)
    } else {
        capfault(m, CAPEX_REG_PCC, CAPEX_LENGTH, pc, fuel)
    }
}

/// A jump through a capability: `jalr`, `c.jr`, `c.jalr` and `cjalr`. The
/// target is `cs1` plus the offset, and `cs1` must be tagged and
/// executable, unsealed or a sentry, which is unsealed by the jump and may
/// only be entered at its own address. PCC becomes `cs1` at the target; the
/// link is a sentry for the next instruction. A macro, so that its `next!`
/// tail-calls from the handler it is expanded in.
macro_rules! jump {
    ($m:expr, $w:expr, $pc:expr, $fuel:expr, $s:expr, $off:expr, $d:expr) => {{
        let (m, w, pc, fuel): (&mut Machine, u32, u32, u32) = ($m, $w, $pc, $fuel);
        let (s, off, d): (u32, u32, u32) = ($s, $off, $d);
        let k = (s & 31) as usize;
        let hh = hw(m, s);
        let t = r(m, s).wrapping_add(off) & !1;
        let (b, l) = (m.wb[k], m.wl[k]);
        if hh & (READY | TAG | M_EX | M_OT_HI) != READY | TAG | M_EX
            || (hh & M_SENTRY != 0 && off != 0)
            || !in_win(t, b, l, 2)
        {
            return jump_slow(m, w, pc, fuel);
        }
        link(m, d, pc.wrapping_add(ilen(w)));
        m.pcc_meta = (hh as u32) & !OTYPE_MASK;
        m.pcc_tag = true;
        m.pcc_wb = b;
        m.pcc_wl = l;
        next!(m, t, fuel - 1)
    }};
}

/// What a jump through a capability decodes to: the register, the offset
/// and the link register.
fn jump_form(w: u32) -> (u32, u32, u32) {
    if w & 3 != 3 {
        // c.jr and c.jalr
        (rd(w), 0, bit(w, 12))
    } else if w & 0x7f == 0x67 {
        (rs1(w), imm_i(w), rd(w))
    } else {
        // cjalr
        (rs1(w), 0, rd(w))
    }
}

#[cold]
#[inline(never)]
fn jump_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (s, off, d) = jump_form(w);
    let c = m.reg(s);
    let t = c.addr.wrapping_add(off) & !1;
    let code = if !c.tag {
        CAPEX_TAG
    } else if c.otype() > OT_SENTRY || (c.otype() == OT_SENTRY && off != 0) {
        CAPEX_SEAL
    } else if !c.has(P_EX) {
        CAPEX_EXECUTE
    } else if !c.covers(t, 2) {
        CAPEX_LENGTH
    } else {
        m.fill_window(s);
        if !in_win(t, m.wb[s as usize], m.wl[s as usize], 2) {
            return m.fault(C_IFAULT, t, pc, fuel);
        }
        jump!(m, w, pc, fuel, s, off, d)
    };
    capfault(m, s, code, pc, fuel)
}

#[inline(never)]
fn op_jalr(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if f3(w) != 0 {
        return illegal(m, w, pc, fuel);
    }
    jump!(m, w, pc, fuel, rs1(w), imm_i(w), rd(w))
}

/// Integer branches compare addresses.
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
/// A data load from RAM. Unaligned accesses are serviced rather than
/// trapped; byte objects and packed image data rely on this.
#[inline(always)]
unsafe fn ld_data(m: &Machine, a: u32, f: u32) -> u32 {
    match f {
        0 => m.rd8(a) as i8 as i32 as u32,
        1 => m.rd16(a) as i16 as i32 as u32,
        2 => m.rd32(a),
        4 => m.rd8(a) as u32,
        _ => m.rd16(a) as u32,
    }
}

/// A data store into RAM, which clears the tags it touches.
#[inline(always)]
unsafe fn st_data(m: &mut Machine, a: u32, f: u32, v: u32) {
    match f {
        0 => m.wr8(a, v as u8),
        1 => m.wr16(a, v as u16),
        _ => m.wr32(a, v),
    }
}

/// The write barrier, asked before every store into RAM.
#[inline(always)]
fn barrier(m: &Machine, a: u32, sz: u32) -> Option<u32> {
    if m.gcmode & 1 == 0 {
        None
    } else {
        m.barrier_hit(a, sz)
    }
}

/// Load a capability from RAM at `a` into `d` through an authority whose
/// metadata is `auth`. Without LC the tag is dropped; without LM a tagged,
/// unsealed capability loses SD, SC and LM.
#[inline(always)]
fn ld_cap(m: &mut Machine, d: u32, a: u32, auth: u64) {
    let c = unsafe { m.rd_cap(a) };
    let tag = c.tag && auth & M_LC != 0;
    let mut xm = c.meta as u64;
    if tag && auth & M_LM == 0 && xm & M_OT == 0 {
        xm &= !M_MUTABLE;
    }
    wc(m, d, c.addr, xm | if tag { TAG } else { 0 });
}

#[inline(always)]
unsafe fn st_cap(m: &mut Machine, a: u32, s: u32) {
    let c = m.reg(s);
    m.wr_cap(a, c);
}

const SIZE: [u32; 8] = [1, 2, 4, 8, 1, 2, 0, 0];

/// LOAD: `lb lh lw lbu lhu` and `lc`, through `cs1`, or through DDC when
/// the base register is x0.
#[inline(never)]
fn op_load(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let a = r(m, s).wrapping_add(imm_i(w));
    let f = f3(w);
    if f == 3 {
        if a & 7 == 0 && auth(m, s, M_LD, a, 8) {
            let au = h(m, s);
            ld_cap(m, rd(w), a, au);
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
        return mem_slow(m, w, pc, fuel);
    }
    let sz = SIZE[f as usize];
    if f < 6 && (auth(m, s, M_LD, a, sz) || (s == 0 && ddc_auth(m, P_LD, a, sz))) {
        let v = unsafe { ld_data(m, a, f) };
        w_(m, rd(w), v);
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// STORE: `sb sh sw` and `sc`.
#[inline(never)]
fn op_store(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let a = r(m, s).wrapping_add(imm_s(w));
    let f = f3(w);
    if f == 3 {
        let need = if h(m, rs2(w)) & TAG != 0 { M_SD | M_SC } else { M_SD };
        if a & 7 == 0 && auth(m, s, need, a, 8) && barrier(m, a, 8).is_none() {
            unsafe { st_cap(m, a, rs2(w)) };
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
        return mem_slow(m, w, pc, fuel);
    }
    let sz = SIZE[f as usize];
    if f < 3 && (auth(m, s, M_SD, a, sz) || (s == 0 && ddc_auth(m, P_SD, a, sz))) && barrier(m, a, sz).is_none() {
        let v = r(m, rs2(w));
        unsafe { st_data(m, a, f, v) };
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// Whose authority a load or store goes through.
#[derive(Clone, Copy)]
enum Via {
    Reg(u32),
    Ddc,
}

/// A load or store decoded, whatever its encoding: the width as LOAD's
/// funct3 numbers it (3 a capability), the authority, the address, the
/// register loaded or stored, and the instruction's length.
struct Mem {
    store: bool,
    f: u32,
    via: Via,
    a: u32,
    data: u32,
    len: u32,
}

fn decode_mem(m: &Machine, w: u32) -> Option<Mem> {
    let base = |s: u32| if s == 0 { Via::Ddc } else { Via::Reg(s) };
    let at = |s: u32, off: u32| r(m, s).wrapping_add(off);
    Some(if w & 3 == 3 {
        match w & 0x7f {
            0x03 if f3(w) < 6 => {
                Mem { store: false, f: f3(w), via: base(rs1(w)), a: at(rs1(w), imm_i(w)), data: rd(w), len: 4 }
            }
            0x23 if f3(w) < 4 => {
                Mem { store: true, f: f3(w), via: base(rs1(w)), a: at(rs1(w), imm_s(w)), data: rs2(w), len: 4 }
            }
            0x5b if w >> 25 == 0x7d && rs2(w) < 6 => {
                Mem { store: false, f: rs2(w), via: Via::Ddc, a: r(m, rs1(w)), data: rd(w), len: 4 }
            }
            0x5b if w >> 25 == 0x7c && rd(w) < 4 => {
                Mem { store: true, f: rd(w), via: Via::Ddc, a: r(m, rs1(w)), data: rs2(w), len: 4 }
            }
            _ => return None,
        }
    } else {
        let (q, f) = (w & 3, (w >> 13) & 7);
        match (q, f) {
            (0, 2) => Mem { store: false, f: 2, via: Via::Reg(rcs(w, 7)), a: at(rcs(w, 7), clw_imm(w)), data: rcs(w, 2), len: 2 },
            (0, 3) => Mem { store: false, f: 3, via: Via::Reg(rcs(w, 7)), a: at(rcs(w, 7), clc_imm(w)), data: rcs(w, 2), len: 2 },
            (0, 6) => Mem { store: true, f: 2, via: Via::Reg(rcs(w, 7)), a: at(rcs(w, 7), clw_imm(w)), data: rcs(w, 2), len: 2 },
            (0, 7) => Mem { store: true, f: 3, via: Via::Reg(rcs(w, 7)), a: at(rcs(w, 7), clc_imm(w)), data: rcs(w, 2), len: 2 },
            (2, 2) if rd(w) != 0 => Mem { store: false, f: 2, via: Via::Reg(2), a: at(2, lwsp_imm(w)), data: rd(w), len: 2 },
            (2, 3) if rd(w) != 0 => Mem { store: false, f: 3, via: Via::Reg(2), a: at(2, lcsp_imm(w)), data: rd(w), len: 2 },
            (2, 6) => Mem { store: true, f: 2, via: Via::Reg(2), a: at(2, swsp_imm(w)), data: (w >> 2) & 31, len: 2 },
            (2, 7) => Mem { store: true, f: 3, via: Via::Reg(2), a: at(2, scsp_imm(w)), data: (w >> 2) & 31, len: 2 },
            _ => return None,
        }
    })
}

/// Check an access of `sz` bytes at `a` through `c`, which register `who`
/// names in a fault, needing the permissions `perms` (the first one missing
/// is reported as `codes` says). Answers whether the access is to RAM (else
/// to a device), or the fault.
fn check(m: &Machine, c: Cap, who: u32, perms: &[(u32, u32)], a: u32, sz: u32, store: bool) -> Result<bool, (u32, u32)> {
    let cf = |code: u32| Err((C_CAP, (who << CAPEX_REG_SHIFT) | code));
    if !c.tag {
        return cf(CAPEX_TAG);
    }
    if c.is_sealed() {
        return cf(CAPEX_SEAL);
    }
    for &(p, code) in perms {
        if !c.has(p) {
            return cf(code);
        }
    }
    if !c.covers(a, sz) {
        return cf(CAPEX_LENGTH);
    }
    if m.in_ram(a, sz) {
        Ok(true)
    } else if Machine::is_mmio(a) && Machine::is_mmio(a.wrapping_add(sz - 1)) {
        Ok(false)
    } else {
        Err((if store { C_SFAULT } else { C_LFAULT }, a))
    }
}

/// Every load and store the fast paths did not finish: the first use of a
/// fresh authority, integer addressing, a device, the write barrier, and
/// every fault.
#[cold]
#[inline(never)]
fn mem_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let Some(d) = decode_mem(m, w) else {
        return illegal(m, w, pc, fuel);
    };
    let (c, who) = match d.via {
        Via::Reg(s) => (m.reg(s), s),
        Via::Ddc => {
            if !m.pcc_has(P_SR) {
                return capfault(m, CAPEX_REG_PCC, CAPEX_SYSREG, pc, fuel);
            }
            (m.ddc, CAPEX_REG_DDC)
        }
    };
    let sz = SIZE[d.f as usize];
    if d.f == 3 && d.a & 7 != 0 {
        return m.fault(if d.store { C_SALIGN } else { C_LALIGN }, d.a, pc, fuel);
    }
    let perms: &[(u32, u32)] = match (d.store, d.f == 3 && m.reg(d.data).tag) {
        (false, _) => &[(P_LD, CAPEX_LOAD)],
        (true, false) => &[(P_SD, CAPEX_STORE)],
        (true, true) => &[(P_SD, CAPEX_STORE), (P_SC, CAPEX_STORE_CAP)],
    };
    let ram = match check(m, c, who, perms, d.a, sz, d.store) {
        Ok(ram) => ram,
        Err((cause, tval)) => return m.fault(cause, tval, pc, fuel),
    };
    // A device hands out no capabilities, and only a capability register
    // takes one.
    if !ram && d.f == 3 && !(d.store && dev::takes_cap(d.a)) {
        return m.fault(if d.store { C_SFAULT } else { C_LFAULT }, d.a, pc, fuel);
    }
    if let Via::Reg(s) = d.via {
        m.fill_window(s);
    }
    let auth_meta = c.meta as u64;
    if !ram {
        m.tick(fuel);
        if d.f == 3 {
            let v = m.reg(d.data);
            dev::write_cap(m, d.a, v);
        } else if d.store {
            let v = r(m, d.data);
            dev::write(m, d.a, d.f, v);
            // A store that powers the machine down is the last instruction.
            if m.halted {
                m.pc = pc.wrapping_add(d.len);
                m.fuel_left = fuel - 1;
                return Stop::Halt;
            }
        } else {
            let v = dev::read(m, d.a, d.f);
            w_(m, d.data, v);
        }
    } else if d.store {
        if let Some(g) = barrier(m, d.a, sz) {
            return m.fault(C_BARRIER, g, pc, fuel);
        }
        if d.f == 3 {
            unsafe { st_cap(m, d.a, d.data) };
        } else {
            let v = r(m, d.data);
            unsafe { st_data(m, d.a, d.f, v) };
        }
    } else if d.f == 3 {
        ld_cap(m, d.data, d.a, auth_meta);
    } else {
        let v = unsafe { ld_data(m, d.a, d.f) };
        w_(m, d.data, v);
    }
    next!(m, pc.wrapping_add(d.len), fuel - 1)
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
        // The B extension encodes its single-source operations in the
        // shift-immediate slot: funct7 selects the operation, and for the
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
        // ---- Zbb: min and max ----
        0x05 => match f {
            4 => (a as i32).min(b as i32) as u32,
            5 => a.min(b),
            6 => (a as i32).max(b as i32) as u32,
            7 => a.max(b),
            _ => return illegal(m, w, pc, fuel),
        },
        // ---- Zicond: conditional zero, the basis of a branchless select
        // without a flags register.
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
        // ---- Zbb: zext.h, which on RV32 is encoded in OP rather than OP-IMM ----
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
    // both nops. Self-modifying code needs no flush; the compiler relies on this.
    let _ = w;
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// SYSTEM: `ecall`, `ebreak`, `mret`, `wfi` and Zicsr. Writing a CSR,
/// reading a machine-level one, `mret` and `wfi` need SR in PCC.
#[inline(never)]
fn op_system(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    let sr = m.pcc_has(P_SR);
    if f == 0 {
        return match w {
            0x0000_0073 => m.fault(C_ECALL, 0, pc, fuel),
            0x0010_0073 => m.fault(C_BREAK, pc, pc, fuel),
            0x3020_0073 | 0x1050_0073 if !sr => capfault(m, CAPEX_REG_PCC, CAPEX_SYSREG, pc, fuel),
            0x3020_0073 => {
                m.tick(fuel);
                m.trap_return();
                m.fuel_left = fuel - 1;
                // Re-enabling interrupts can make one deliverable at once, so
                // control returns to the outer loop.
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
    if f == 4 {
        return illegal(m, w, pc, fuel);
    }
    // ---- Zicsr ----
    m.tick(fuel);
    let csr = w >> 20;
    let src = if f & 4 != 0 { rs1(w) } else { r(m, rs1(w)) };
    let d = rd(w);
    // A csrrs/csrrc with x0 or a zero immediate only reads.
    let writes = if f & 3 == 1 { true } else { rs1(w) != 0 };
    if !sr && (writes || !Machine::csr_public(csr)) {
        return capfault(m, CAPEX_REG_PCC, CAPEX_SYSREG, pc, fuel);
    }
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
    if writes && (csr == CSR_MSTATUS || csr == CSR_MIE || csr == CSR_MIP) {
        m.pc = pc.wrapping_add(4);
        m.fuel_left = fuel - 1;
        return Stop::Fuel;
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ======================================================= CHERI, opcode 0x5b

/// Move a capability's address by `d`, keeping its window when the new
/// address is still inside it, which makes the move representable. A move
/// of sp down is checked against the stack limit.
#[inline(always)]
fn inc_cap(m: &mut Machine, pc: u32, fuel: u32, d: u32, s: u32, off: u32) -> Result<(), Stop> {
    let k = (s & 31) as usize;
    let hh = h(m, s);
    let a = r(m, s).wrapping_add(off);
    if d == 2 && s == 2 && (off as i32) < 0 && !m.stack_ok(a) {
        return Err(m.fault(C_STACK, a, pc, fuel));
    }
    if hh & (READY | M_OT) == READY && in_win(a, m.wb[k], m.wl[k], 0) {
        let (b, l) = (m.wb[k], m.wl[k]);
        wcw(m, d, a, hh, b, l);
    } else {
        let c = m.reg(s).with_addr(a);
        wcap(m, d, c);
    }
    Ok(())
}

/// Bounds from `cs1`'s address for `len` bytes. A request inside the window
/// below 256 bytes is exact and its own window.
#[inline(always)]
fn set_bounds(m: &mut Machine, d: u32, s: u32, len: u32, exact: bool, pc: u32, fuel: u32) -> Result<(), Stop> {
    let k = (s & 31) as usize;
    let hh = h(m, s);
    let a = r(m, s);
    if hh & (READY | TAG | M_OT) == READY | TAG && len < 256 && in_win(a, m.wb[k], m.wl[k], len) {
        let t = a.wrapping_add(len);
        let meta = (hh as u32 & !BOUNDS_MASK) | ((t & 0xff) << 10) | (a & 0x3ff);
        wcw(m, d, a, meta as u64 | TAG, a, len);
        return Ok(());
    }
    let c = m.reg(s);
    let code = if !c.tag {
        CAPEX_TAG
    } else if c.is_sealed() {
        CAPEX_SEAL
    } else {
        match c.with_bounds(len) {
            None => CAPEX_LENGTH,
            Some(n) => {
                if exact && c.with_bounds_exact(len).is_none() {
                    CAPEX_REPRESENTABLE
                } else {
                    wcap(m, d, n);
                    return Ok(());
                }
            }
        }
    };
    Err(capfault(m, s, code, pc, fuel))
}

/// The CHERI instructions. funct3 1 and 2 are the immediate forms of
/// `cincoffset` and `csetbounds`; funct3 0 is R-type, funct7 choosing.
#[inline(never)]
fn op_cheri(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, s, t) = (rd(w), rs1(w), rs2(w));
    match f3(w) {
        1 => {
            if let Err(st) = inc_cap(m, pc, fuel, d, s, imm_i(w)) {
                return st;
            }
        }
        2 => {
            if let Err(st) = set_bounds(m, d, s, w >> 20, false, pc, fuel) {
                return st;
            }
        }
        0 => match w >> 25 {
            0x11 => {
                let off = r(m, t);
                if let Err(st) = inc_cap(m, pc, fuel, d, s, off) {
                    return st;
                }
            }
            0x7f if t == 0x0a => mv(m, d, s),
            0x7f => return op_cheri_one(m, w, pc, fuel),
            0x7c | 0x7d => {
                let store = w >> 25 == 0x7c;
                let f = if store { d } else { t };
                let a = r(m, s);
                let sz = SIZE[f as usize & 7];
                if store {
                    if f < 3 && ddc_auth(m, P_SD, a, sz) && barrier(m, a, sz).is_none() {
                        let v = r(m, t);
                        unsafe { st_data(m, a, f, v) };
                        next!(m, pc.wrapping_add(4), fuel - 1)
                    }
                } else if f < 6 && f != 3 && ddc_auth(m, P_LD, a, sz) {
                    let v = unsafe { ld_data(m, a, f) };
                    w_(m, d, v);
                    next!(m, pc.wrapping_add(4), fuel - 1)
                }
                return mem_slow(m, w, pc, fuel);
            }
            0x08 | 0x09 => {
                let len = r(m, t);
                if let Err(st) = set_bounds(m, d, s, len, w >> 25 == 0x09, pc, fuel) {
                    return st;
                }
            }
            _ => return op_cheri_two(m, w, pc, fuel),
        },
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The two-operand CHERI instructions other than the hot ones.
#[cold]
#[inline(never)]
fn op_cheri_two(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, s, t) = (rd(w), rs1(w), rs2(w));
    let a = m.reg(s);
    let b = m.reg(t);
    match w >> 25 {
        0x01 => {
            // cspecialrw: cs1 = c0 only reads.
            if !m.pcc_has(P_SR) {
                return capfault(m, CAPEX_REG_PCC, CAPEX_SYSREG, pc, fuel);
            }
            // PCC's address is the pc this instruction is at.
            let old = if t == SCR_PCC { Some(pcc_at(m, pc)) } else { m.scr_read(t) };
            let Some(old) = old else {
                return illegal(m, w, pc, fuel);
            };
            if s != 0 {
                m.scr_write(t, a);
            }
            wcap(m, d, old);
        }
        0x0b => {
            // cseal: cs2 an SE authority whose address, in its bounds, is
            // the otype, any from 1 to 15.
            if let Err((reg, code)) = seal_check(a, s, b, t) {
                return capfault(m, reg, code, pc, fuel);
            }
            if b.addr == 0 || b.addr > 15 {
                return capfault(m, t, CAPEX_TYPE, pc, fuel);
            }
            wcap(m, d, a.seal(b.addr));
        }
        0x0c => {
            // cunseal: any sealed capability, by an SE authority whose address
            // is its otype. This is how the explorer looks inside a closure.
            if !a.tag {
                return capfault(m, s, CAPEX_TAG, pc, fuel);
            }
            if !a.is_sealed() {
                return capfault(m, s, CAPEX_SEAL, pc, fuel);
            }
            if !b.tag {
                return capfault(m, t, CAPEX_TAG, pc, fuel);
            }
            if b.is_sealed() {
                return capfault(m, t, CAPEX_SEAL, pc, fuel);
            }
            if !b.has(P_SE) {
                return capfault(m, t, CAPEX_UNSEAL, pc, fuel);
            }
            if !b.covers(b.addr, 1) {
                return capfault(m, t, CAPEX_LENGTH, pc, fuel);
            }
            if b.addr != a.otype() {
                return capfault(m, t, CAPEX_TYPE, pc, fuel);
            }
            wcap(m, d, a.unseal());
        }
        0x0d => wcap(m, d, a.and_perms(b.addr)),
        0x10 => wcap(m, d, a.with_addr(b.addr)),
        0x14 => w_(m, d, a.addr.wrapping_sub(b.addr)),
        0x16 => wcap(m, d, Cap { addr: a.addr, meta: b.addr, tag: false }),
        0x1d => {
            // cbuildcap: cs2's bits, tagged again if cs1 could have made
            // them.
            if !a.tag {
                return capfault(m, s, CAPEX_TAG, pc, fuel);
            }
            if a.is_sealed() {
                return capfault(m, s, CAPEX_SEAL, pc, fuel);
            }
            let (bb, bt) = b.bounds();
            let (ab, at) = a.bounds();
            if bt < bb as u64 || bb < ab || bt > at {
                return capfault(m, s, CAPEX_LENGTH, pc, fuel);
            }
            if b.perms() & !a.perms() != 0 {
                return capfault(m, s, CAPEX_PERM, pc, fuel);
            }
            if b.otype() > OT_SENTRY {
                return capfault(m, t, CAPEX_TYPE, pc, fuel);
            }
            wcap(m, d, Cap { tag: true, ..b });
        }
        0x20 => w_(m, d, b.is_subset_of(&a) as u32),
        0x21 => w_(m, d, (a == b) as u32),
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// What sealing `a` (register `s`) with the authority `b` (register `t`)
/// needs: both tagged and unsealed, and `b` an SE capability whose address
/// is inside it.
fn seal_check(a: Cap, s: u32, b: Cap, t: u32) -> Result<(), (u32, u32)> {
    if !a.tag {
        return Err((s, CAPEX_TAG));
    }
    if a.is_sealed() {
        return Err((s, CAPEX_SEAL));
    }
    if !b.tag {
        return Err((t, CAPEX_TAG));
    }
    if b.is_sealed() {
        return Err((t, CAPEX_SEAL));
    }
    if !b.has(P_SE) {
        return Err((t, CAPEX_SEAL_PERM));
    }
    if !b.covers(b.addr, 1) {
        return Err((t, CAPEX_LENGTH));
    }
    Ok(())
}

/// The header word of the object `c` names, if `c` is headed and the header
/// is in RAM.
fn header(m: &Machine, c: Cap) -> Option<u32> {
    let b = c.base();
    if !c.tag || !c.has(P_HD) || b < 8 || !m.in_ram(b - 8, 8) {
        return None;
    }
    Some(unsafe { m.rd32(b - 8) })
}

/// The one-operand CHERI instructions, the rs2 field choosing.
#[inline(never)]
fn op_cheri_one(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, s) = (rd(w), rs1(w));
    let c = m.reg(s);
    let sat = |v: u64| v.min(u32::MAX as u64) as u32;
    match rs2(w) {
        0x00 => w_(m, d, c.perms()),
        0x01 => w_(m, d, c.otype()),
        0x02 => w_(m, d, c.base()),
        0x03 => w_(m, d, sat(c.len())),
        0x04 => w_(m, d, c.tag as u32),
        0x05 => w_(m, d, c.is_sealed() as u32),
        0x06 => w_(m, d, c.addr.wrapping_sub(c.base())),
        0x08 => w_(m, d, rrl(c.addr)),
        0x09 => w_(m, d, ram(c.addr)),
        0x0b => wcap(m, d, c.without_tag()),
        0x0c => jump!(m, w, pc, fuel, s, 0, d),
        0x0f => w_(m, d, c.addr),
        0x11 => {
            let code = if !c.tag {
                CAPEX_TAG
            } else if c.is_sealed() {
                CAPEX_SEAL
            } else if !c.has(P_EX) {
                CAPEX_EXECUTE
            } else {
                wcap(m, d, c.seal(OT_SENTRY));
                next!(m, pc.wrapping_add(4), fuel - 1)
            };
            return capfault(m, s, code, pc, fuel);
        }
        0x17 => w_(m, d, c.meta),
        0x18 => w_(m, d, sat(c.top())),
        0x1c => {
            // csealclo: anyone may seal their own closure object.
            let code = if !c.tag {
                CAPEX_TAG
            } else if c.is_sealed() {
                CAPEX_SEAL
            } else if header(m, c).map(|hd| hd & 0xff) != Some(T_CLOSURE) {
                CAPEX_TYPE
            } else {
                wcap(m, d, c.seal(OT_CLOSURE));
                next!(m, pc.wrapping_add(4), fuel - 1)
            };
            return capfault(m, s, code, pc, fuel);
        }
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ===================================================== Xlm custom-0: references

/// A pair in the processor's sense: tagged, unsealed, not headed. nil is
/// one. The bounds check of the access does the rest.
const PAIR_MASK: u64 = TAG | M_OT | M_HD;

/// The custom-0 opcode space: references.
///
/// ```text
///     f3 0  lref  rd, imm(rs1)   the capability at imm in a pair
///     f3 1  vkind rd, rs1        the kind of a value
///     f3 2  lvar  rd, imm(rs1)   a symbol's slot, refusing the unbound marker
///     f3 3  jcl   rd, rs1        call a closure
///     f3 4  sref  rs2, imm(rs1)  store into a pair; nil is refused
///     f3 5  lhdr  rd, rs1, type  an object's length, checking its type
///     f3 6  beqx  rs1, rs2, off  branch if identical
///     f3 7  bnex  rs1, rs2, off  branch if not
/// ```
///
/// `car` and `cdr` are offsets 0 and 8 of `lref`. The fast paths are the
/// common case, a reference through a capability that is what it should be
/// to a slot inside its bounds; everything else is decided in `ref_slow`.
#[inline(never)]
fn op_ref(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    match f3(w) {
        0 => {
            let hh = hw(m, s);
            let a = r(m, s).wrapping_add(imm_i(w));
            if hh & (READY | PAIR_MASK | M_LD | M_LC) == READY | TAG | M_LD | M_LC
                && a & 7 == 0
                && in_win(a, m.wb[k], m.wl[k], 8)
            {
                ld_cap(m, rd(w), a, hh);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        4 => {
            let hh = hw(m, s);
            let a = r(m, s).wrapping_add(imm_s(w));
            if hh & (READY | PAIR_MASK | M_SD | M_SC) == READY | TAG | M_SD | M_SC
                && a & 7 == 0
                && in_win(a, m.wb[k], m.wl[k], 8)
                && barrier(m, a, 8).is_none()
            {
                unsafe { st_cap(m, a, rs2(w)) };
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        2 => {
            // lvar: a symbol is a headed object whose header, in the granule
            // below its window, says so. The unbound marker is the trap's to
            // report.
            let hh = hw(m, s);
            let a = r(m, s).wrapping_add(imm_i(w));
            let (b, l) = (m.wb[k], m.wl[k]);
            if hh & (READY | TAG | M_OT | M_HD | M_LD | M_LC) == READY | TAG | M_HD | M_LD | M_LC
                && a & 7 == 0
                && in_win(a, b, l, 8)
                && b >= 8
                && unsafe { m.rd32(b - 8) } & 0xff == T_SYMBOL
            {
                let v = unsafe { m.rd_cap(a) };
                if v.tag || v.meta != IMM_UNBOUND {
                    ld_cap(m, rd(w), a, hh);
                    next!(m, pc.wrapping_add(4), fuel - 1)
                }
            }
        }
        6 | 7 => {
            let (a, b) = (rs1(w), rs2(w));
            let same = r(m, a) == r(m, b) && (h(m, a) ^ h(m, b)) & !READY == 0;
            let npc = if same == (f3(w) == 6) {
                pc.wrapping_add(imm_b(w))
            } else {
                pc.wrapping_add(4)
            };
            next!(m, npc, fuel - 1)
        }
        3 => return op_jcl(m, w, pc, fuel),
        _ => {}
    }
    ref_slow(m, w, pc, fuel)
}

#[cold]
#[inline(never)]
fn ref_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let c = m.reg(s);
    let pair = c.tag && !c.is_sealed() && !c.has(P_HD);
    match f3(w) {
        0 | 4 => {
            let store = f3(w) == 4;
            if !pair || (store && c == Cap::NIL) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let a = c.addr.wrapping_add(if store { imm_s(w) } else { imm_i(w) });
            if a & 7 != 0 {
                return m.fault(if store { C_SALIGN } else { C_LALIGN }, a, pc, fuel);
            }
            let perms: &[(u32, u32)] = if store {
                &[(P_SD, CAPEX_STORE), (P_SC, CAPEX_STORE_CAP)]
            } else {
                &[(P_LD, CAPEX_LOAD), (P_LC, CAPEX_LOAD_CAP)]
            };
            match check(m, c, s, perms, a, 8, store) {
                Ok(true) => {}
                Ok(false) => return m.fault(if store { C_SFAULT } else { C_LFAULT }, a, pc, fuel),
                Err((cause, tval)) => return m.fault(cause, tval, pc, fuel),
            }
            m.fill_window(s);
            if store {
                if let Some(g) = barrier(m, a, 8) {
                    return m.fault(C_BARRIER, g, pc, fuel);
                }
                unsafe { st_cap(m, a, rs2(w)) };
            } else {
                ld_cap(m, rd(w), a, c.meta as u64);
            }
        }
        1 => {
            if imm_i(w) != 0 {
                return illegal(m, w, pc, fuel);
            }
            let k = kind(m, c);
            w_(m, rd(w), k);
        }
        2 => {
            // lvar: a symbol's slot.
            if !(c.tag && !c.is_sealed() && header(m, c).map(|hd| hd & 0xff) == Some(T_SYMBOL)) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let a = c.addr.wrapping_add(imm_i(w));
            if a & 7 != 0 {
                return m.fault(C_LALIGN, a, pc, fuel);
            }
            match check(m, c, s, &[(P_LD, CAPEX_LOAD), (P_LC, CAPEX_LOAD_CAP)], a, 8, false) {
                Ok(true) => {}
                Ok(false) => return m.fault(C_LFAULT, a, pc, fuel),
                Err((cause, tval)) => return m.fault(cause, tval, pc, fuel),
            }
            let v = unsafe { m.rd_cap(a) };
            if !v.tag && v.meta == IMM_UNBOUND {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            ld_cap(m, rd(w), a, c.meta as u64);
        }
        5 => {
            // lhdr: an object, a closure included, of the type asked for.
            let want = imm_i(w) & 0xfff;
            let ok = c.tag && (c.otype() == OT_UNSEALED || c.otype() == OT_CLOSURE);
            match header(m, c) {
                Some(hd) if ok && (want == 0 || hd & 0xff == want) => w_(m, rd(w), hd >> 8),
                _ => return m.fault(C_TYPE, s, pc, fuel),
            }
        }
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// What `vkind` answers for a value.
pub fn kind(m: &Machine, c: Cap) -> u32 {
    if !c.tag {
        return c.meta.min(15);
    }
    if c == Cap::NIL {
        return KIND_NIL;
    }
    if c.has(P_HD) {
        // An object is a headed capability whose header is in object space;
        // the root, and anything else that merely has HD, is a capability.
        let open = c.otype() == OT_UNSEALED || c.otype() == OT_CLOSURE;
        return match heap_object(c) {
            Some(hd) if open => KIND_OBJECT + (m.peek32(hd) & 0xff),
            _ => KIND_CAP,
        };
    }
    if !c.is_sealed() && c.len() == 16 {
        KIND_PAIR
    } else {
        KIND_CAP
    }
}

/// `jcl rd, rs1`: call a closure. rs1 must be sealed as a closure; it is
/// left unsealed for the callee, rd gets a sentry for the next instruction,
/// and PCC becomes the entry capability in the closure's slot 0, which must
/// be tagged and executable. The entry's window comes from the window cache
/// when the same entry was called before.
#[inline(never)]
fn op_jcl(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    let hh = h(m, s);
    if hh & (TAG | M_OT) != TAG | M_CLOSURE {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    if hh & READY == 0 {
        m.fill_window(s);
    }
    let a = r(m, s);
    if a & 7 != 0 || !in_win(a, m.wb[k], m.wl[k], 8) {
        return capfault(m, s, CAPEX_LENGTH, pc, fuel);
    }
    let e = unsafe { m.rd_cap(a) };
    if !e.tag || e.otype() > OT_SENTRY || !e.has(P_EX) {
        return capfault(m, s, if e.tag { CAPEX_EXECUTE } else { CAPEX_TAG }, pc, fuel);
    }
    let (b, l) = m.window(e);
    let t = e.addr & !1;
    if !in_win(t, b, l, 2) {
        return if e.covers(t, 2) {
            m.fault(C_IFAULT, t, pc, fuel)
        } else {
            capfault(m, s, CAPEX_LENGTH, pc, fuel)
        };
    }
    m.xm[k] &= !M_OT;
    link(m, rd(w), pc.wrapping_add(4));
    m.pcc_meta = e.meta & !OTYPE_MASK;
    m.pcc_tag = true;
    m.pcc_wb = b;
    m.pcc_wl = l;
    next!(m, t, fuel - 1)
}

// ================================================ Xlm custom-1: indexed access

/// The custom-1 opcode space: indexed access to an object, checked.
///
/// ```text
///     funct7   the type the object must be, or 0 for any object
///     funct3   bit 0 store, bit 1 byte, bit 2 the index is an immediate
///     rs1      the object: headed and unsealed
///     rs2      the index, a fixnum, or with funct3 bit 2 the five-bit
///              immediate in its place
///     rd       where the result goes, or, for a store, the value to write
/// ```
///
/// The value forms move 8-byte capabilities and refuse a string or byte
/// object; the byte forms move one byte, zero-extended, and refuse anything
/// else. The index must be below the length in the header, which counts
/// elements of the object's own size. The address needs the header, and
/// the header holds the length, so the bounds check is one comparison
/// alongside the address arithmetic; the capability's bounds are checked as
/// well, so a header that lied could not reach past the object.
#[inline(never)]
fn op_index(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    let f = f3(w);
    let hh = h(m, s);
    if hh & (TAG | M_OT | M_HD) != TAG | M_HD {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    if hh & READY == 0 {
        m.fill_window(s);
    }
    let (base, wl) = (m.wb[k], m.wl[k]);
    // A headed capability in RAM has its base in the window and its header
    // just below; one with no header there, the root, is not an object.
    if base < 8 || wl == 0 || !m.in_ram(base - 8, 8) {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let hdr = unsafe { m.rd32(base - 8) };
    let ty = hdr & 0xff;
    let want = w >> 25;
    let bytes = ty == T_STRING || ty == T_BYTES;
    if (want != 0 && ty != want) || bytes != (f & 2 != 0) {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let (i, ireg) = if f & 4 != 0 {
        (rs2(w), RANGE_IMM)
    } else {
        if h(m, rs2(w)) != 0 {
            return m.fault(C_TYPE, rs2(w), pc, fuel);
        }
        (r(m, rs2(w)), rs2(w))
    };
    if i >= hdr >> 8 {
        return m.fault(C_RANGE, ireg, pc, fuel);
    }
    let (a, sz) = if bytes { (base.wrapping_add(i), 1) } else { (base.wrapping_add(i << 3), 8) };
    if !in_win(a, base, wl, sz) {
        return capfault(m, s, CAPEX_LENGTH, pc, fuel);
    }
    let v = rd(w);
    let perm = match (f & 1 != 0, bytes) {
        (false, false) => M_LD,
        (false, true) => M_LD,
        (true, false) if h(m, v) & TAG != 0 => M_SD | M_SC,
        (true, _) => M_SD,
    };
    if hh & perm != perm {
        let code = match perm {
            M_LD => CAPEX_LOAD,
            M_SD => CAPEX_STORE,
            _ if hh & M_SD == 0 => CAPEX_STORE,
            _ => CAPEX_STORE_CAP,
        };
        return capfault(m, s, code, pc, fuel);
    }
    if f & 1 != 0 {
        if let Some(g) = barrier(m, a, sz) {
            return m.fault(C_BARRIER, g, pc, fuel);
        }
        if bytes {
            let b = r(m, v) as u8;
            unsafe { m.wr8(a, b) };
        } else {
            unsafe { st_cap(m, a, v) };
        }
    } else if bytes {
        let b = unsafe { m.rd8(a) } as u32;
        w_(m, v, b);
    } else {
        ld_cap(m, v, a, hh);
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// ========================================================= Xlm custom-3: fixnums

/// The custom-3 opcode space: fixnums. Every operand must be untagged with
/// metadata 0, which is one comparison of `xm` against zero; the register
/// that is not lands in `mtval`.
///
/// ```text
///     f3 0  faddi  rd, rs1, imm   wrapping
///     f3 1  faddio rd, rs1, imm   overflow traps
///     f3 2  fandi  rd, rs1, imm
///     f3 3  fori   rd, rs1, imm
///     f3 4  fshi   rd, rs1, imm   imm[4:0] the amount, imm[6:5] 0 sll 1 srl 2 sra
///     f3 5  fop    rd, rs1, rs2   R-type, funct7 the operation
///     f3 7  retag  rd, rs1, imm   rs1 untagged of kind imm[11:6] (63 any);
///                                 rd its address with metadata imm[5:0]
/// ```
///
/// Overflow is cause 26 and the handler widens the result into a bignum;
/// division by zero is cause 27.
#[inline(never)]
fn op_fix(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let f = f3(w);
    if f == 7 {
        let k = (w >> 26) & 63;
        let hh = h(m, s);
        if hh & TAG != 0 || (k != 63 && hh as u32 != k) {
            return m.fault(C_TYPE, s, pc, fuel);
        }
        let a = r(m, s);
        wc(m, rd(w), a, ((w >> 20) & 63) as u64);
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
    if h(m, s) != 0 {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let x = r(m, s) as i32;
    let i = imm_i(w) as i32;
    let v = match f {
        0 => x.wrapping_add(i),
        1 => match x.checked_add(i) {
            Some(v) => v,
            None => return m.fault(C_OVER, 0, pc, fuel),
        },
        2 => x & i,
        3 => x | i,
        4 => {
            let sh = (i as u32) & 31;
            match ((i as u32) >> 5) & 3 {
                0 => ((x as u32) << sh) as i32,
                1 => ((x as u32) >> sh) as i32,
                2 => x >> sh,
                _ => return illegal(m, w, pc, fuel),
            }
        }
        5 => return op_fop(m, w, pc, fuel),
        _ => return illegal(m, w, pc, fuel),
    };
    w_(m, rd(w), v as u32);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// `fop`: two fixnums.
#[inline(never)]
fn op_fop(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (s, t) = (rs1(w), rs2(w));
    if h(m, s) != 0 {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    if h(m, t) != 0 {
        return m.fault(C_TYPE, t, pc, fuel);
    }
    let x = r(m, s) as i32;
    let y = r(m, t) as i32;
    let over = |v: Option<i32>| v.ok_or(C_OVER);
    let v: Result<i32, u32> = match w >> 25 {
        0x00 => Ok(x.wrapping_add(y)),
        0x01 => Ok(x.wrapping_sub(y)),
        0x02 => Ok(x.wrapping_mul(y)),
        0x03 => {
            if y == 0 {
                Err(C_DIVZERO)
            } else {
                over(x.checked_div(y))
            }
        }
        0x04 => {
            if y == 0 {
                Err(C_DIVZERO)
            } else {
                Ok(x.wrapping_rem(y))
            }
        }
        0x05 => Ok(x & y),
        0x06 => Ok(x | y),
        0x07 => Ok(x ^ y),
        0x08 => over(x.checked_add(y)),
        0x09 => over(x.checked_sub(y)),
        0x0a => over(x.checked_mul(y)),
        0x10 => Ok(((x as u32) << (y & 31)) as i32),
        0x11 => Ok(((x as u32) >> (y & 31)) as i32),
        0x12 => Ok(x >> (y & 31)),
        0x13 => Ok((x < y) as i32),
        0x14 => Ok(((x as u32) < (y as u32)) as i32),
        0x15 => Ok((x == y) as i32),
        _ => return illegal(m, w, pc, fuel),
    };
    match v {
        Ok(v) => w_(m, rd(w), v as u32),
        Err(cause) => return m.fault(cause, 0, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

// =========================================================== compressed, Q0

/// `c.addi4spn`: `cincoffset rd', csp, imm`.
#[inline(never)]
fn c_addi4spn(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let i = ciw_imm(w);
    if i == 0 {
        return illegal(m, w, pc, fuel); // all-zero halfword
    }
    if let Err(st) = inc_cap(m, pc, fuel, rcs(w, 2), 2, i) {
        return st;
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_lw(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rcs(w, 7);
    let a = r(m, s).wrapping_add(clw_imm(w));
    if auth(m, s, M_LD, a, 4) {
        let v = unsafe { m.rd32(a) };
        w_(m, rcs(w, 2), v);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_lc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rcs(w, 7);
    let a = r(m, s).wrapping_add(clc_imm(w));
    if a & 7 == 0 && auth(m, s, M_LD, a, 8) {
        let au = h(m, s);
        ld_cap(m, rcs(w, 2), a, au);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_sw(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rcs(w, 7);
    let a = r(m, s).wrapping_add(clw_imm(w));
    if auth(m, s, M_SD, a, 4) && barrier(m, a, 4).is_none() {
        let v = r(m, rcs(w, 2));
        unsafe { m.wr32(a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_sc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rcs(w, 7);
    let a = r(m, s).wrapping_add(clc_imm(w));
    let v = rcs(w, 2);
    let need = if h(m, v) & TAG != 0 { M_SD | M_SC } else { M_SD };
    if a & 7 == 0 && auth(m, s, need, a, 8) && barrier(m, a, 8).is_none() {
        unsafe { st_cap(m, a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
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
    let t = pc.wrapping_add(cj_imm(w));
    if !in_win(t, m.pcc_wb, m.pcc_wl, 2) {
        return jump_out(m, t, pc, fuel);
    }
    link(m, 1, pc.wrapping_add(2));
    next!(m, t, fuel - 1)
}

#[inline(never)]
fn c_li(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), ci_imm(w));
    next!(m, pc.wrapping_add(2), fuel - 1)
}

/// `c.lui`, and `c.addi16sp`, which is `cincoffset csp, csp, imm`.
#[inline(never)]
fn c_lui(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    if d == 2 {
        let i = addi16sp_imm(w);
        if i == 0 {
            return illegal(m, w, pc, fuel);
        }
        if let Err(st) = inc_cap(m, pc, fuel, 2, 2, i) {
            return st;
        }
    } else {
        let i = ci_imm(w) << 12;
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
        0 => a >> ((((w >> 2) & 31) | (bit(w, 12) << 5)) & 31),
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
    let t = pc.wrapping_add(cj_imm(w));
    if !in_win(t, m.pcc_wb, m.pcc_wl, 2) {
        return jump_out(m, t, pc, fuel);
    }
    next!(m, t, fuel - 1)
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
    let a = r(m, 2).wrapping_add(lwsp_imm(w));
    if d != 0 && auth(m, 2, M_LD, a, 4) {
        let v = unsafe { m.rd32(a) };
        w_(m, d, v);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_lcsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let a = r(m, 2).wrapping_add(lcsp_imm(w));
    if d != 0 && a & 7 == 0 && auth(m, 2, M_LD, a, 8) {
        let au = h(m, 2);
        ld_cap(m, d, a, au);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_swsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, 2).wrapping_add(swsp_imm(w));
    if auth(m, 2, M_SD, a, 4) && barrier(m, a, 4).is_none() {
        let v = r(m, (w >> 2) & 31);
        unsafe { m.wr32(a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

#[inline(never)]
fn c_scsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, 2).wrapping_add(scsp_imm(w));
    let v = (w >> 2) & 31;
    let need = if h(m, v) & TAG != 0 { M_SD | M_SC } else { M_SD };
    if a & 7 == 0 && auth(m, 2, need, a, 8) && barrier(m, a, 8).is_none() {
        unsafe { st_cap(m, a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// `c.jr`, `c.mv` (`cmove`), `c.ebreak`, `c.jalr` and `c.add`.
#[inline(never)]
fn c_jalr_mv(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let s = (w >> 2) & 31;
    if bit(w, 12) == 0 {
        if s == 0 {
            if d == 0 {
                return illegal(m, w, pc, fuel);
            }
            jump!(m, w, pc, fuel, d, 0, 0)
        } else {
            mv(m, d, s);
            next!(m, pc.wrapping_add(2), fuel - 1)
        }
    } else if s == 0 {
        if d == 0 {
            return m.fault(C_BREAK, pc, pc, fuel);
        }
        jump!(m, w, pc, fuel, d, 0, 1)
    } else {
        let v = r(m, d).wrapping_add(r(m, s));
        w_(m, d, v);
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
}

// ================================================================ debugging

/// The function the machine is in and the ones that called it, by name,
/// from the frame chain: every prologue saves its caller's frame at s0-16
/// and its caller's code object at s0-32.
pub fn watch_backtrace(m: &Machine) -> String {
    let mut out = String::new();
    let mut s0 = m.x[8];
    let mut code = code_containing(m, m.mepcc.addr).unwrap_or(m.reg(9));
    for _ in 0..12 {
        out.push_str(&name_of(m, code));
        out.push_str(" <- ");
        if s0 < crate::map::POOL_BASE + 32 || s0 >= crate::map::POOL_END {
            break;
        }
        code = m.load_cap(s0.wrapping_sub(32));
        s0 = m.load_cap(s0.wrapping_sub(16)).addr;
    }
    out
}

/// The code object whose machine code holds `pc`, found by walking object
/// space: a code object's entry capability is bounded to its code. The
/// answer is the object's own capability, headed and bounded to its payload.
pub fn code_containing(m: &Machine, pc: u32) -> Option<Cap> {
    use crate::heap::{block_size, bounds_bytes, cap_to, CODE_ENTRY, PERMS_OBJECT, T_CODE};
    let end = m.peek32(crate::map::LG_OBJ_PTR);
    let mut p = crate::map::OBJ_BASE;
    while p < end {
        let hdr = m.peek32(p);
        if hdr & 0xff == T_CODE {
            let entry = m.load_cap(p + 8 + 8 * CODE_ENTRY);
            if entry.tag && pc >= entry.base() && (pc as u64) < entry.top() {
                return Some(cap_to(p + 8, bounds_bytes(hdr), PERMS_OBJECT));
            }
        }
        let size = block_size(hdr);
        if size == 0 {
            return None;
        }
        p += size;
    }
    None
}

/// The name of a code object, read through its name slot: a string, a
/// symbol whose name is one, or for a lambda the pair `(lambda . home)`,
/// which reads as the printer writes it, "lambda in home".
pub fn name_of(m: &Machine, code: Cap) -> String {
    let slot = |c: Cap, i: u32| m.load_cap(c.base().wrapping_add(8 * i));
    let string = |c: Cap| -> Option<String> {
        let hd = header(m, c)?;
        if hd & 0xff != T_STRING {
            return None;
        }
        let b = c.base();
        Some((0..(hd >> 8).min(48)).map(|i| m.peek8(b + i) as char).collect())
    };
    let atom = |c: Cap| -> Option<String> {
        if header(m, c).map(|hd| hd & 0xff) == Some(T_SYMBOL) {
            string(slot(c, crate::heap::SYM_NAME))
        } else {
            string(c)
        }
    };
    if header(m, code).map(|hd| hd & 0xff) != Some(crate::heap::T_CODE) {
        return String::from("?");
    }
    let name = slot(code, crate::heap::CODE_NAME);
    if crate::heap::is_cons(name) {
        return match atom(slot(name, 1)) {
            Some(home) => format!("lambda in {home}"),
            None => String::from("lambda"),
        };
    }
    atom(name).unwrap_or_else(|| String::from("?"))
}

// ===================================================================== table
/// Counting uses a second dispatch table rather than a test in `next!`.
/// A branch in that macro is paid by every instruction; swapping the table
/// costs one load of a pointer that is already hot. Every entry is the same
/// function, which counts the instruction and dispatches it.
#[inline(never)]
fn prof_hook(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    crate::prof::count(m, w, pc);
    become (unsafe { *TABLE.get_unchecked(token(w) as usize) })(m, w, pc, fuel)
}

pub static PROF_TABLE: [Handler; 64] = [prof_hook; 64];

/// What a store instruction is about to write: the address, the width in
/// bytes and the value's address field. Used by the store watch below.
fn store_target(m: &Machine, w: u32) -> Option<(u32, u32, u32)> {
    if let Some(d) = decode_mem(m, w) {
        return d.store.then(|| (d.a, SIZE[d.f as usize], r(m, d.data)));
    }
    if w & 3 != 3 {
        return None;
    }
    let f = f3(w);
    match w & 0x7f {
        // sref
        0x0b if f == 4 => Some((r(m, rs1(w)).wrapping_add(imm_s(w)), 8, r(m, rs2(w)))),
        // an indexed store, the value in rd
        0x2b if f & 1 != 0 => {
            let base = m.reg(rs1(w)).base();
            let i = if f & 4 != 0 { rs2(w) } else { r(m, rs2(w)) };
            if f & 2 == 0 {
                Some((base.wrapping_add(i << 3), 8, r(m, rd(w))))
            } else {
                Some((base.wrapping_add(i), 1, r(m, rd(w))))
            }
        }
        _ => None,
    }
}

/// The debugging watches, installed as the dispatch table when any of
/// `LM_WATCH_S2`, `LM_WATCH_ADDR` or `LM_WATCH_HI` is set. They cost no
/// cycles and no fuel, so installing them does not move a timing-dependent
/// fault.
///
/// `s2` holds the running task and only `%set-this-task!` writes it, so it
/// is either nil or a record in object space. Every jump through a register
/// lands in code space. The first instruction that violates either rule is
/// reported together with the instruction before it. A store into the
/// watched range, or of a word whose top half is the watched value, is
/// reported with the function it came from.
fn watch_hook(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if m.watch_hi.is_some() || m.watch_addr.is_some() {
        if let Some((a, sz, v)) = store_target(m, w) {
            if let Some(hi) = m.watch_hi {
                if sz >= 4 && (v >> 16) == hi {
                    eprintln!("watch: stored {v:#x} to {a:#x} from pc {pc:#x} in {}", name_of(m, m.reg(9)));
                }
            }
            if let Some((lo, len)) = m.watch_addr {
                if a >= lo && a < lo.wrapping_add(len) {
                    eprintln!(
                        "watch: wrote {v:#x} ({sz} bytes) to {a:#x} from pc {pc:#x} in {}",
                        name_of(m, m.reg(9))
                    );
                }
            }
        }
    }
    if !m.watch_fired {
        let s2 = m.reg(18);
        let s2_ok = s2 == Cap::NIL
            || (s2.has(P_HD) && (crate::map::OBJ_BASE..crate::map::OBJ_END).contains(&s2.base()));
        let jump = if w & 0x7f == 0x67 || (w & 3 == 2 && (w >> 13) & 7 == 4 && (w >> 2) & 31 == 0 && rd(w) != 0) {
            let (s, off, _) = jump_form(w);
            Some((s, r(m, s).wrapping_add(off) & !1))
        } else {
            None
        };
        // mret returns to whatever the trap stub put in MEPCC; for a
        // resuming task that is slot 0 of its context. A wrong value is a
        // jump without a jump instruction, so it is checked too.
        let mret = if w == 0x3020_0073 { Some(m.mepcc.addr) } else { None };
        let jump_bad = match jump.map(|(_, t)| t).or(mret) {
            Some(t) => t < crate::map::CODE_BASE || t >= crate::map::CODE_END,
            None => false,
        };
        if !s2_ok || jump_bad {
            m.watch_fired = true;
            if !s2_ok {
                eprintln!("s2 watch: s2 = {s2:x?} at pc {pc:#x}");
            }
            if let Some((s, t)) = jump {
                eprintln!("jump watch: pc {pc:#x} insn {w:#010x} through x{s} to {t:#x}");
            }
            if let Some(t) = mret {
                eprintln!("mret watch: pc {pc:#x} returns to {t:#x}; context at {:#x}", m.mscratchc.addr);
            }
            eprintln!("  before: {:#010x} at pc {:#x}", m.watch_prev_w, m.watch_prev);
            for i in 0..32 {
                let c = m.reg(i);
                eprint!("  x{i}={:#x}{}", c.addr, if c.tag { "*" } else { "" });
                if i % 4 == 3 {
                    eprintln!();
                }
            }
        }
    }
    m.watch_prev = pc;
    m.watch_prev_w = w;
    become (unsafe { *TABLE.get_unchecked(token(w) as usize) })(m, w, pc, fuel)
}

pub static WATCH_TABLE: [Handler; 64] = [watch_hook; 64];

pub static TABLE: [Handler; 64] = [
    // ---- quadrant 0 (tok 0..7) ----
    c_addi4spn, // 000 c.addi4spn
    op_bad,     // 001 c.fld
    c_lw,       // 010 c.lw
    c_lc,       // 011 c.lc (c.flw)
    op_bad,     // 100 reserved
    op_bad,     // 101 c.fsd
    c_sw,       // 110 c.sw
    c_sc,       // 111 c.sc (c.fsw)
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
    c_lcsp,    // 011 c.lcsp (c.flwsp)
    c_jalr_mv, // 100 c.jr/c.mv/c.ebreak/c.jalr/c.add
    op_bad,    // 101 c.fsdsp
    c_swsp,    // 110 c.swsp
    c_scsp,    // 111 c.scsp (c.fswsp)
    // ---- tok 24..31: unreachable, op[1:0]==3 means 32-bit ----
    op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad,
    // ---- 32-bit, indexed by opcode[6:2] (tok 32..63) ----
    op_load,   // 00 LOAD, and lc
    op_bad,    // 01 LOAD-FP
    op_ref,    // 02 custom-0: references
    op_fence,  // 03 MISC-MEM
    op_imm,    // 04 OP-IMM
    op_auipc,  // 05 AUIPCC
    op_bad,    // 06 OP-IMM-32
    op_bad,    // 07 (48-bit)
    op_store,  // 08 STORE, and sc
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
    op_cheri,  // 16 custom-2: CHERI
    op_bad,    // 17 (48-bit)
    op_branch, // 18 BRANCH
    op_jalr,   // 19 JALR
    op_bad,    // 1a reserved
    op_jal,    // 1b JAL
    op_system, // 1c SYSTEM
    op_bad,    // 1d reserved
    op_fix,    // 1e custom-3: fixnums
    op_bad,    // 1f (>= 80-bit)
];
