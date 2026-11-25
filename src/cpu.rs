//! Token-threaded RV32IMC core: RVY in capability mode, with Xlm.
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
//! RAM. Everything else, a device, the write barrier, a fault, goes to one
//! slow path per kind of instruction that decodes the instruction again and
//! checks it in full. Fetch is checked the same way against PCC's window.

use crate::cap::*;
use crate::dev;
use crate::heap::{T_BYTES, T_CLOSURE, T_STRING, T_SYMBOL};
use crate::mach::*;
use crate::map::{OBJ_BASE, OBJ_END};

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

/// Copy a register whole, window and all: `YMV`.
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
fn ddc_auth(m: &Machine, need: u64, a: u32, sz: u32) -> bool {
    m.pcc_has(P_SR) && pm(m.ddc_perms) & need == need && in_win(a, m.ddc_wb, m.ddc_wl, sz)
}

/// The fast test for a load or store with base register `s`: through `s`,
/// or through DDC when `s` is x0. Answers the authority's metadata, in
/// `xm` positions, which a capability load reads LC and LM from.
#[inline(always)]
fn authority(m: &mut Machine, s: u32, need: u64, a: u32, sz: u32) -> Option<u64> {
    if auth(m, s, need, a, sz) {
        Some(h(m, s))
    } else if s == 0 && ddc_auth(m, need, a, sz) {
        Some(m.ddc.meta as u64)
    } else {
        None
    }
}

/// The sentry a jump leaves in its link register: PCC sealed for entry, at
/// the next instruction, with PCC's window. PCC is tagged, or nothing would
/// be running.
#[inline(always)]
fn link(m: &mut Machine, d: u32, ret: u32) {
    if d != 0 {
        let xm = (m.pcc_meta as u64 & !M_OT) | M_SENTRY | TAG;
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
/// c.lysp, as c.ldsp: uimm[5]=w[12], uimm[4:3]=w[6:5], uimm[8:6]=w[4:2]
#[inline(always)]
fn lcsp_imm(w: u32) -> u32 {
    (bit(w, 12) << 5) | ((w >> 2) & 0x18) | ((w << 4) & 0x1c0)
}
/// c.swsp: uimm[5:2]=w[12:9], uimm[7:6]=w[8:7]
#[inline(always)]
fn swsp_imm(w: u32) -> u32 {
    ((w >> 7) & 0x3c) | ((w >> 1) & 0xc0)
}
/// c.sysp, as c.sdsp: uimm[5:3]=w[12:10], uimm[8:6]=w[9:7]
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
pub(crate) fn token(w: u32) -> u32 {
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
/// capability fault on PCC if PCC forbids it and an access fault if PCC
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
    let cause = if c.tag && !c.is_sealed() && c.has(P_EX) && c.covers(pc, 2) { C_IFAULT } else { C_CAP_FETCH };
    m.fault(cause, pc, pc, fuel)
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

// ---- LUI / AUIPC ----------------------------------------------------------
#[inline(never)]
fn op_lui(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    w_(m, rd(w), w & 0xffff_f000);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// `auipc`: PCC with its address moved, as RVY has it. Inside PCC's window
/// the move is representable and the window is PCC's.
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
/// Continue at `t`, the target of a taken branch. A target outside PCC's
/// window faults at the branch, as a jump's does.
macro_rules! branch_to {
    ($m:expr, $t:expr, $pc:expr, $fuel:expr) => {{
        let (m, t, pc, fuel): (&mut Machine, u32, u32, u32) = ($m, $t, $pc, $fuel);
        if !in_win(t, m.pcc_wb, m.pcc_wl, 2) {
            return jump_out(m, t, pc, fuel);
        }
        next!(m, t, fuel - 1)
    }};
}

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

/// A jump or branch within PCC to `t` outside its window: past its bounds,
/// which is a capability fault on PCC with the target's address, raised at
/// the jump as RVY envisages an extension may, or to no RAM.
#[cold]
#[inline(never)]
fn jump_out(m: &mut Machine, t: u32, pc: u32, fuel: u32) -> Stop {
    let cause = if pcc_at(m, pc).covers(t, 2) { C_IFAULT } else { C_CAP_FETCH };
    m.fault(cause, t, pc, fuel)
}

/// A jump through a capability: `jalr`, `c.jr` and `c.jalr`. The target is
/// `cs1` plus the offset, and `cs1` must be tagged and executable, unsealed
/// or a sentry, which is unsealed by the jump and may only be entered at its
/// own address: with no offset, and at an even address, since a jump clears
/// bit 0 of its target. PCC becomes `cs1` at the target; the link is a
/// sentry for the next instruction. A jump that would leave PCC unable to
/// fetch faults where it stands, with the target's address. A macro, so
/// that its `next!` tail-calls from the handler it is expanded in.
macro_rules! jump {
    ($m:expr, $w:expr, $pc:expr, $fuel:expr, $s:expr, $off:expr, $d:expr) => {{
        let (m, w, pc, fuel): (&mut Machine, u32, u32, u32) = ($m, $w, $pc, $fuel);
        let (s, off, d): (u32, u32, u32) = ($s, $off, $d);
        let k = (s & 31) as usize;
        let hh = hw(m, s);
        let t = r(m, s).wrapping_add(off) & !1;
        let (b, l) = (m.wb[k], m.wl[k]);
        if hh & (READY | TAG | M_EX | M_OT_HI) != READY | TAG | M_EX
            || (hh & M_SENTRY != 0 && (off | r(m, s) & 1) != 0)
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

/// What a jump through a capability decodes to: the register and the
/// offset.
fn jump_form(w: u32) -> (u32, u32) {
    if w & 3 != 3 {
        // c.jr and c.jalr
        (rd(w), 0)
    } else {
        (rs1(w), imm_i(w))
    }
}

/// A jump the fast test refused: a capability fault on the target, or,
/// when the capability allows the jump, an access fault for a target
/// outside RAM.
#[cold]
#[inline(never)]
fn jump_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (s, off) = jump_form(w);
    let c = m.reg(s);
    let t = c.addr.wrapping_add(off) & !1;
    let ok = c.tag && c.enterable(off) && c.has(P_EX) && c.covers(t, 2);
    m.fault(if ok { C_IFAULT } else { C_CAP_FETCH }, t, pc, fuel)
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
    if taken {
        branch_to!(m, pc.wrapping_add(imm_b(w)), pc, fuel)
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
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

/// The write barrier, asked before every store into RAM, with the register
/// the store goes through, or `WHO_DDC`.
#[inline(always)]
fn barrier(m: &Machine, a: u32, sz: u32, who: u32) -> Option<u32> {
    if m.gcmode & 1 == 0 {
        None
    } else {
        m.barrier_hit(a, sz, who)
    }
}

/// Load a capability from RAM at `a` into `d` through an authority whose
/// metadata is `auth`. Without LC the tag is dropped; without LM a tagged,
/// unsealed capability loses SD, SC and LM, as RVY's `LY` drops W and LM.
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

/// Store register `s` into the granule at `a` through an authority whose
/// metadata is `auth`: its tag goes with it only if the authority has SC,
/// as RVY's `SY` stores the tag only through C.
#[inline(always)]
unsafe fn st_cap(m: &mut Machine, a: u32, s: u32, auth: u64) {
    let c = m.reg(s);
    m.wr_cap(a, Cap { tag: c.tag && auth & M_SC != 0, ..c });
}

/// The bytes an access moves, by its width as LOAD's funct3 numbers it,
/// with 3 for a capability.
const SIZE: [u32; 8] = [1, 2, 4, 8, 1, 2, 0, 0];

/// A checked load into `d` from RAM at `a`, at width `f`, through an
/// authority whose metadata is `au`.
#[inline(always)]
fn load(m: &mut Machine, d: u32, a: u32, f: u32, au: u64) {
    if f == 3 {
        ld_cap(m, d, a, au);
    } else {
        let v = unsafe { ld_data(m, a, f) };
        w_(m, d, v);
    }
}

/// A checked store of register `v` into RAM at `a`, at width `f`, through
/// an authority whose metadata is `au`.
#[inline(always)]
fn store(m: &mut Machine, a: u32, f: u32, v: u32, au: u64) {
    if f == 3 {
        unsafe { st_cap(m, a, v, au) };
    } else {
        let x = r(m, v);
        unsafe { st_data(m, a, f, x) };
    }
}

/// LOAD: `lb lh lw lbu lhu`, through `cs1`, or through DDC when the base
/// register is x0. funct3 3 is RV64's `ld` and Zilsd's, neither of which
/// the machine has.
#[inline(never)]
fn op_load(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let a = r(m, s).wrapping_add(imm_i(w));
    let f = f3(w);
    if f < 6 && f != 3 {
        if let Some(au) = authority(m, s, M_LD, a, SIZE[f as usize]) {
            load(m, rd(w), a, f, au);
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
    }
    mem_slow(m, w, pc, fuel)
}

/// STORE: `sb sh sw`, likewise.
#[inline(never)]
fn op_store(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let a = r(m, s).wrapping_add(imm_s(w));
    let (f, v) = (f3(w), rs2(w));
    if f < 3 {
        let sz = SIZE[f as usize];
        if let Some(au) = authority(m, s, M_SD, a, sz) {
            if barrier(m, a, sz, s).is_none() {
                store(m, a, f, v, au);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
    }
    mem_slow(m, w, pc, fuel)
}

/// Xlm's loads and stores through DDC, `lb.ddc` to `ly.ddc` and `sb.ddc`
/// to `sy.ddc`: `rs1` the integer address, the width in `rd` for a store
/// and in `rs2` for a load.
#[inline(never)]
fn op_ddc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, rs1(w));
    if w >> 25 == 0x7c {
        let (f, v) = (rd(w), rs2(w));
        if f < 4 && (f != 3 || a & 7 == 0) {
            let sz = SIZE[f as usize];
            if ddc_auth(m, M_SD, a, sz) && barrier(m, a, sz, WHO_DDC).is_none() {
                let au = m.ddc.meta as u64;
                store(m, a, f, v, au);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
    } else {
        let f = rs2(w);
        if f < 6 && (f != 3 || a & 7 == 0) && ddc_auth(m, M_LD, a, SIZE[f as usize]) {
            let au = m.ddc.meta as u64;
            load(m, rd(w), a, f, au);
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
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
        let (f, s) = (f3(w), rs1(w));
        match w & 0x7f {
            0x03 if f < 6 && f != 3 => Mem { store: false, f, via: base(s), a: at(s, imm_i(w)), data: rd(w), len: 4 },
            0x23 if f < 3 => Mem { store: true, f, via: base(s), a: at(s, imm_s(w)), data: rs2(w), len: 4 },
            0x7b if f == 1 => Mem { store: false, f: 3, via: base(s), a: at(s, imm_i(w)), data: rd(w), len: 4 },
            0x7b if f == 2 => Mem { store: true, f: 3, via: base(s), a: at(s, imm_s(w)), data: rs2(w), len: 4 },
            0x0b if f == 6 && w >> 25 == 0x7d && rs2(w) < 6 => {
                Mem { store: false, f: rs2(w), via: Via::Ddc, a: r(m, s), data: rd(w), len: 4 }
            }
            0x0b if f == 6 && w >> 25 == 0x7c && rd(w) < 4 => {
                Mem { store: true, f: rd(w), via: Via::Ddc, a: r(m, s), data: rs2(w), len: 4 }
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

/// Check an access of `sz` bytes at `a` through `c` needing the permission
/// `perm`, as RVY checks one: tag, seal, permission and bounds, any of
/// which refused is a capability fault on the access, cause 33 for a load
/// and 34 for a store, with the address. Answers whether the access is to
/// RAM (else to a device), or the fault as a cause and `mtval`.
fn check(m: &Machine, c: Cap, perm: u32, a: u32, sz: u32, store: bool) -> Result<bool, (u32, u32)> {
    if !c.tag || c.is_sealed() || !c.has(perm) || !c.covers(a, sz) {
        return Err((if store { C_CAP_STORE } else { C_CAP_LOAD }, a));
    }
    if m.in_ram(a, sz) {
        Ok(true)
    } else if Machine::is_mmio(a) && Machine::is_mmio(a.wrapping_add(sz - 1)) {
        Ok(false)
    } else {
        Err((if store { C_SFAULT } else { C_LFAULT }, a))
    }
}

/// Every load and store the fast paths did not finish: a device, the write
/// barrier, and every fault.
#[cold]
#[inline(never)]
fn mem_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let Some(d) = decode_mem(m, w) else {
        return illegal(m, w, pc, fuel);
    };
    // Integer addressing is Xlm's, in the encodings RVY reserves, and
    // without SR they are the reserved encodings they would otherwise be.
    let (c, who) = match d.via {
        Via::Reg(s) => (m.reg(s), s),
        Via::Ddc if !m.pcc_has(P_SR) => return illegal(m, w, pc, fuel),
        Via::Ddc => (m.ddc, WHO_DDC),
    };
    let sz = SIZE[d.f as usize];
    let ram = match check(m, c, if d.store { P_SD } else { P_LD }, d.a, sz, d.store) {
        Ok(ram) => ram,
        Err((cause, tval)) => return m.fault(cause, tval, pc, fuel),
    };
    // A tag belongs to an aligned granule, so a misaligned capability
    // access cannot be emulated: it is an access fault, as RVY has it.
    if d.f == 3 && d.a & 7 != 0 {
        return m.fault(if d.store { C_SFAULT } else { C_LFAULT }, d.a, pc, fuel);
    }
    // A device hands out no capabilities, and only a capability register
    // takes one.
    if !ram && d.f == 3 && !(d.store && dev::takes_cap(d.a)) {
        return m.fault(if d.store { C_SFAULT } else { C_LFAULT }, d.a, pc, fuel);
    }
    if !ram {
        m.tick(fuel);
        if d.f == 3 {
            let v = m.reg(d.data);
            let v = if c.has(P_SC) { v } else { v.without_tag() };
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
        if let Some(g) = barrier(m, d.a, sz, who) {
            return m.fault(C_BARRIER, g, pc, fuel);
        }
        store(m, d.a, d.f, d.data, c.meta as u64);
    } else {
        load(m, d.data, d.a, d.f, c.meta as u64);
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

/// SYSTEM: `ecall`, `ebreak`, `mret`, `wfi` and Zicsr. `mret`, every CSR
/// write and every read of a privileged CSR need SR in PCC, as RVY's ASR
/// gates them, and without it are illegal instructions. A capability-wide
/// CSR reads as a capability; `csrrw` writes one whole, and the other forms
/// write its address.
#[inline(never)]
fn op_system(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    let sr = m.pcc_has(P_SR);
    if f == 0 {
        return match w {
            0x0000_0073 => m.fault(C_ECALL, 0, pc, fuel),
            0x0010_0073 => m.fault(C_BREAK, pc, pc, fuel),
            0x3020_0073 if !sr => illegal(m, w, pc, fuel),
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
    let (s, d) = (rs1(w), rd(w));
    let src = if f & 4 != 0 { s } else { r(m, s) };
    // A csrrs/csrrc with x0 or a zero immediate only reads.
    let writes = f & 3 == 1 || s != 0;
    if (writes && Machine::csr_read_only(csr)) || (!sr && (writes || !Machine::csr_public(csr))) {
        return illegal(m, w, pc, fuel);
    }
    if let Some(old) = m.csr_cap(csr) {
        if writes {
            match f {
                1 => {
                    let c = m.reg(s);
                    m.csr_cap_write(csr, c, true);
                }
                5 => m.csr_cap_write(csr, Cap::int(src), false),
                _ => {
                    let a = if f & 3 == 2 { old.addr | src } else { old.addr & !src };
                    m.csr_cap_write(csr, Cap::int(a), false);
                }
            }
        }
        wcap(m, d, old);
        next!(m, pc.wrapping_add(4), fuel - 1)
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

// ============================================================ RVY-A, opcode 0x7b

/// Move a capability's address by `d`, keeping its window when the new
/// address is still inside it, which makes the move representable. A move
/// of sp down is checked against the stack limit, which is Xlm's.
#[inline(always)]
fn inc_cap(m: &mut Machine, pc: u32, fuel: u32, d: u32, s: u32, off: u32) -> Result<(), Stop> {
    let k = (s & 31) as usize;
    let hh = hw(m, s);
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

/// `YBNDSW` and `YBNDSRW`: bounds from `cs1`'s address for `len` bytes,
/// exact or rounded outward, untagged where RVY says. A request inside the
/// window below 256 bytes is exact and its own window, unless `cs1` is
/// headed: whether the result keeps HD is `Cap::bounded`'s to say.
#[inline(always)]
fn bounds(m: &mut Machine, d: u32, s: u32, len: u32, exact: bool) {
    let k = (s & 31) as usize;
    let hh = hw(m, s);
    let a = r(m, s);
    if hh & (READY | TAG | M_OT) == READY | TAG
        && (hh as u32) & (P_HD << PERM_SHIFT) == 0
        && len < 256
        && in_win(a, m.wb[k], m.wl[k], len)
    {
        let t = a.wrapping_add(len);
        let meta = (hh as u32 & !BOUNDS_MASK) | ((t & 0xff) << 10) | (a & 0x3ff);
        wcw(m, d, a, meta as u64 | TAG, a, len);
        return;
    }
    let c = m.reg(s).bounded(len, exact);
    wcap(m, d, c);
}

/// The length `YBNDSWI`'s nine-bit immediate encodes: 1 to 255 bytes, 256
/// to 504 by eight, 512 to 4080 by sixteen, and 0 for 4096.
pub fn ybndswi_len(imm: u32) -> u32 {
    if imm == 0 {
        4096
    } else if imm & 0x100 == 0 {
        imm & 0xff
    } else if (imm >> 5) & 7 == 0 {
        0x100 | ((imm & 0xf) << 4) | (((imm >> 4) & 1) << 3)
    } else {
        (imm & 0xff) << 4
    }
}

/// RVY-A: the capability instructions RVY defines. funct3 1 is `LY` and 2
/// `SY`, the commonest instructions there are, tested first and alone; 0 is
/// R-type, funct7 choosing, 4 `YADDI` and 5 `YBNDSWI`.
#[inline(never)]
fn op_rvy(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let f = f3(w);
    let s = rs1(w);
    if f == 1 {
        let a = r(m, s).wrapping_add(imm_i(w));
        if a & 7 == 0 {
            if let Some(au) = authority(m, s, M_LD, a, 8) {
                ld_cap(m, rd(w), a, au);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        return mem_slow(m, w, pc, fuel);
    }
    if f == 2 {
        let a = r(m, s).wrapping_add(imm_s(w));
        if a & 7 == 0 {
            if let Some(au) = authority(m, s, M_SD, a, 8) {
                if barrier(m, a, 8, s).is_none() {
                    unsafe { st_cap(m, a, rs2(w), au) };
                    next!(m, pc.wrapping_add(4), fuel - 1)
                }
            }
        }
        return mem_slow(m, w, pc, fuel);
    }
    op_rvy_more(m, w, pc, fuel)
}

/// The rest of RVY-A.
#[inline(never)]
fn op_rvy_more(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, s, t) = (rd(w), rs1(w), rs2(w));
    match f3(w) {
        4 => {
            if let Err(st) = inc_cap(m, pc, fuel, d, s, imm_i(w)) {
                return st;
            }
        }
        5 if w >> 29 == 7 => bounds(m, d, s, ybndswi_len((w >> 20) & 0x1ff), true),
        0 => match w >> 25 {
            // `YADD` by x0 is `YMV`: the whole capability, sealed or not.
            0x03 if t == 0 => mv(m, d, s),
            0x03 => {
                let off = r(m, t);
                if let Err(st) = inc_cap(m, pc, fuel, d, s, off) {
                    return st;
                }
            }
            0x1b | 0x23 => {
                let len = r(m, t);
                bounds(m, d, s, len, w >> 25 == 0x1b);
            }
            _ => return op_rvy_r(m, w, pc, fuel),
        },
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The R-type capability instructions other than the hot ones.
#[cold]
#[inline(never)]
fn op_rvy_r(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, s, t) = (rd(w), rs1(w), rs2(w));
    let a = m.reg(s);
    let b = m.reg(t);
    let sat = |v: u64| v.min(u32::MAX as u64) as u32;
    match w >> 25 {
        0x01 => wcap(m, d, Cap { addr: a.addr, meta: b.addr, tag: false }),
        // YSH1ADD, YSH2ADD, YSH3ADD: cs2 moved by rs1 shifted.
        0x05 | 0x0d | 0x15 => wcap(m, d, b.inc(a.addr << (((w >> 28) & 3) + 1))),
        0x06 => w_(m, d, (a == b) as u32),
        0x07 => wcap(m, d, b.unsealed_within(&a)),
        0x0b => wcap(m, d, a.with_addr(b.addr)),
        0x0e => w_(m, d, b.is_subset_of(&a) as u32),
        0x0f => wcap(m, d, b.built_by(&a)),
        0x13 => wcap(m, d, a.clear_perms(b.addr)),
        0x17 if s == 0 => wcap(m, d, b.sealed_entry()),
        0x17 => wcap(m, d, b.sealed_by(&a)),
        0x1f => wcap(m, d, b.unsealed_by(&a)),
        0x78 if t == 0 => w_(m, d, ram(a.addr)),
        0x7a => match t {
            0 => w_(m, d, a.base()),
            1 => w_(m, d, a.perm_bits()),
            2 => w_(m, d, sat(a.top())),
            3 => w_(m, d, sat(a.len())),
            4 => w_(m, d, a.tag as u32),
            5 => w_(m, d, a.otype()),
            7 => w_(m, d, a.meta),
            _ => return illegal(m, w, pc, fuel),
        },
        _ => return illegal(m, w, pc, fuel),
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
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

// ================================================================ Xlm, custom-0

/// A pair in the processor's sense: tagged, unsealed, not headed. nil is
/// one. The bounds check of the access does the rest.
const PAIR_MASK: u64 = TAG | M_OT | M_HD;

/// custom-0: the Lisp instructions, every one a CHERI operation and a Lisp
/// type check.
///
/// ```text
///     f3 0  lref  rd, imm(rs1)   the capability at imm in a pair
///     f3 1  sref  rs2, imm(rs1)  store into a pair; nil is refused
///     f3 2  lvar  rd, imm(rs1)   a symbol's slot, refusing the unbound marker
///     f3 3  beqx  rs1, rs2, off  branch if identical
///     f3 4  bnex  rs1, rs2, off  branch if not
///     f3 5  fixnum immediates    imm[11:10] the operation, imm[9:0] signed
///     f3 6  R-type, funct7 the operation: fixnums, calls, kinds, DDC
///     f3 7  indexed access       funct7 = the form << 4 | the type
/// ```
///
/// `car` and `cdr` are offsets 0 and 8 of `lref`. The fast paths are the
/// common case, a reference through a capability that is what it should be
/// to a slot inside its bounds; everything else is decided in `xlm_slow`.
#[inline(never)]
fn op_xlm(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    become (unsafe { *XLM.get_unchecked(f3(w) as usize) })(m, w, pc, fuel)
}

/// custom-0 by funct3, each its own handler, so that each has its own
/// branch sites as each opcode does.
static XLM: [Handler; 8] = [op_lref, op_sref, op_lvar, op_beqx, op_beqx, op_fixi, op_xlm_r, op_index];

#[inline(never)]
fn op_lref(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    let hh = hw(m, s);
    let a = r(m, s).wrapping_add(imm_i(w));
    if hh & (READY | PAIR_MASK | M_LD | M_LC) == READY | TAG | M_LD | M_LC
        && a & 7 == 0
        && in_win(a, m.wb[k], m.wl[k], 8)
    {
        ld_cap(m, rd(w), a, hh);
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
    xlm_slow(m, w, pc, fuel)
}

#[inline(never)]
fn op_sref(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    let hh = hw(m, s);
    let a = r(m, s).wrapping_add(imm_s(w));
    if hh & (READY | PAIR_MASK | M_SD) == READY | TAG | M_SD
        && a & 7 == 0
        && in_win(a, m.wb[k], m.wl[k], 8)
        && barrier(m, a, 8, s).is_none()
    {
        unsafe { st_cap(m, a, rs2(w), hh) };
        next!(m, pc.wrapping_add(4), fuel - 1)
    }
    xlm_slow(m, w, pc, fuel)
}

/// lvar: a symbol is a headed object whose header, in the granule below its
/// window, says so. The unbound marker is the trap's to report.
#[inline(never)]
fn op_lvar(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
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
    xlm_slow(m, w, pc, fuel)
}

/// beqx and bnex: whether two registers are identical, tag, metadata and
/// address.
#[inline(never)]
fn op_beqx(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (a, b) = (rs1(w), rs2(w));
    let same = r(m, a) == r(m, b) && (h(m, a) ^ h(m, b)) & !READY == 0;
    if same == (f3(w) == 3) {
        branch_to!(m, pc.wrapping_add(imm_b(w)), pc, fuel)
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// custom-0's R-type instructions, by funct7:
///
/// ```text
///     0x00..0x15  fop   rd, rs1, rs2   two fixnums (see `op_fop`)
///     0x18..0x1a  fshi  rd, rs1, n     a fixnum shifted by the rs2 field:
///                                      sll, srl, sra
///     0x20  jcl    rd, rs1             call a closure
///     0x21  vkind  rd, rs1             the kind of a value
///     0x22  lhdr   rd, rs1, type       an object's length, its type checked
///                                      against the rs2 field (0 any)
///     0x23  sealcl cd, cs1             seal a closure object as a closure
///     0x24  npair  cd, cs1             the next pair of a cons run
///     0x40 | from  retag rd, rs1, to   rs1 untagged of kind `from` (31 any);
///                                      rd its address with metadata `to`
///     0x7c  sb.ddc .. sy.ddc           stores through DDC, rd the width
///     0x7d  lb.ddc .. lhu.ddc          loads through DDC, rs2 the width
/// ```
#[inline(never)]
fn op_xlm_r(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    if w >> 25 <= 0x15 {
        return op_fop(m, w, pc, fuel);
    }
    match w >> 25 {
        0x20 => return op_jcl(m, w, pc, fuel),
        0x21 => {
            // vkind, of everything the window settles: an untagged value,
            // nil, a pair, an object. The rest is `kind`'s to decide.
            let hh = hw(m, s);
            let (b, l) = (m.wb[k], m.wl[k]);
            let v = if hh & TAG == 0 {
                Some((hh as u32).min(15))
            } else if r(m, s) == Cap::NIL.addr && hh as u32 == Cap::NIL.meta {
                Some(KIND_NIL)
            } else if hh & (M_HD | M_OT) == 0 {
                (l == 16 && b < m.ramlen - 16).then_some(KIND_PAIR)
            } else {
                headed(m, k, hh)
                    .filter(|_| (OBJ_BASE + 8..OBJ_END + 8).contains(&b))
                    .map(|hd| KIND_OBJECT + (hd & 0xff))
            };
            if let Some(v) = v.filter(|_| rs2(w) == 0) {
                w_(m, rd(w), v);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        0x22 => {
            let hh = hw(m, s);
            let want = rs2(w);
            if let Some(hd) = headed(m, k, hh).filter(|hd| want == 0 || hd & 0xff == want) {
                w_(m, rd(w), hd >> 8);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        0x24 => {
            // npair: the run's next sixteen bytes, as YBNDSWI would bound
            // them; a pair is short enough to be its own window.
            let hh = hw(m, s);
            let a = r(m, s);
            if hh & (READY | TAG | M_OT | M_HD) == READY | TAG && in_win(a, m.wb[k], m.wl[k], 16) {
                let meta = (hh as u32 & !BOUNDS_MASK) | ((a.wrapping_add(16) & 0xff) << 10) | (a & 0x3ff);
                wcw(m, rd(w), a, meta as u64 | TAG, a, 16);
                next!(m, pc.wrapping_add(4), fuel - 1)
            }
        }
        0x7c | 0x7d => return op_ddc(m, w, pc, fuel),
        0x40..=0x5f => {
            let from = (w >> 25) & 31;
            let hh = h(m, s);
            if hh & TAG != 0 || (from != 31 && hh as u32 != from) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let a = r(m, s);
            wc(m, rd(w), a, rs2(w) as u64);
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
        0x18..=0x1a => {
            if h(m, s) != 0 {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let (x, sh) = (r(m, s), rs2(w));
            let v = match w >> 25 {
                0x18 => x << sh,
                0x19 => x >> sh,
                _ => ((x as i32) >> sh) as u32,
            };
            w_(m, rd(w), v);
            next!(m, pc.wrapping_add(4), fuel - 1)
        }
        0x23 => {}
        _ => return illegal(m, w, pc, fuel),
    }
    xlm_slow(m, w, pc, fuel)
}

/// The header word of the object register `k` holds, read through its
/// window: a headed capability, unsealed or a closure, whose bounds start
/// in RAM, so that the header is the word below its window.
#[inline(always)]
fn headed(m: &Machine, k: usize, hh: u64) -> Option<u32> {
    let (b, l) = (m.wb[k], m.wl[k]);
    let ot = hh & M_OT;
    let ok = hh & (READY | TAG | M_HD) == READY | TAG | M_HD && (ot == 0 || ot == M_CLOSURE) && b >= 8 && l != 0;
    ok.then(|| unsafe { m.rd32(b - 8) })
}

/// What an Xlm load or store of the granule at `a` through `c`, register
/// `s`, does after its type check: the checks and the faults of `LY` or
/// `SY`, with the barrier before a store.
fn xlm_access(m: &mut Machine, c: Cap, s: u32, a: u32, store: bool, v: u32, pc: u32, fuel: u32) -> Option<Stop> {
    match check(m, c, if store { P_SD } else { P_LD }, a, 8, store) {
        Ok(true) if a & 7 == 0 => {}
        Ok(_) => return Some(m.fault(if store { C_SFAULT } else { C_LFAULT }, a, pc, fuel)),
        Err((cause, tval)) => return Some(m.fault(cause, tval, pc, fuel)),
    }
    if store {
        if let Some(g) = barrier(m, a, 8, s) {
            return Some(m.fault(C_BARRIER, g, pc, fuel));
        }
        unsafe { st_cap(m, a, v, c.meta as u64) };
    } else {
        ld_cap(m, v, a, c.meta as u64);
    }
    None
}

#[cold]
#[inline(never)]
fn xlm_slow(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let c = m.reg(s);
    let pair = c.tag && !c.is_sealed() && !c.has(P_HD);
    match (f3(w), w >> 25) {
        (0, _) | (1, _) => {
            let store = f3(w) == 1;
            if !pair || (store && c == Cap::NIL) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let a = c.addr.wrapping_add(if store { imm_s(w) } else { imm_i(w) });
            let v = if store { rs2(w) } else { rd(w) };
            if let Some(st) = xlm_access(m, c, s, a, store, v, pc, fuel) {
                return st;
            }
        }
        (2, _) => {
            // lvar: a symbol's slot.
            if !(c.tag && !c.is_sealed() && header(m, c).map(|hd| hd & 0xff) == Some(T_SYMBOL)) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            let a = c.addr.wrapping_add(imm_i(w));
            if a & 7 == 0 && m.in_ram(a, 8) && c.covers(a, 8) {
                let v = unsafe { m.rd_cap(a) };
                if !v.tag && v.meta == IMM_UNBOUND {
                    return m.fault(C_TYPE, s, pc, fuel);
                }
            }
            if let Some(st) = xlm_access(m, c, s, a, false, rd(w), pc, fuel) {
                return st;
            }
        }
        (_, 0x21) => {
            if rs2(w) != 0 {
                return illegal(m, w, pc, fuel);
            }
            let k = kind(m, c);
            w_(m, rd(w), k);
        }
        (_, 0x22) => {
            // lhdr: an object, a closure included, of the type asked for.
            let want = rs2(w);
            let ok = c.tag && (c.otype() == OT_UNSEALED || c.otype() == OT_CLOSURE);
            match header(m, c) {
                Some(hd) if ok && (want == 0 || hd & 0xff == want) => w_(m, rd(w), hd >> 8),
                _ => return m.fault(C_TYPE, s, pc, fuel),
            }
        }
        (_, 0x23) => {
            // sealcl: anyone may seal their own closure object.
            if !(c.tag && !c.is_sealed() && header(m, c).map(|hd| hd & 0xff) == Some(T_CLOSURE)) {
                return m.fault(C_TYPE, s, pc, fuel);
            }
            wcap(m, rd(w), c.seal(OT_CLOSURE));
        }
        (_, 0x24) => {
            // npair: a run with no pair left, or no run.
            if !(pair && c.covers(c.addr, 16)) {
                return m.fault(C_RUN, s, pc, fuel);
            }
            wcap(m, rd(w), c.bounded(16, true));
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

/// `jcl rd, rs1`: call a closure. rs1 must be sealed as a closure; the
/// entry is loaded through it, as `LY` would load it, so a closure without
/// LD or LC, or one whose slot 0 is outside its bounds, is a load fault on
/// that slot. rs1 is left unsealed for the callee, rd gets a sentry for the
/// next instruction, and PCC becomes the entry, which must be tagged,
/// enterable and executable with its first instruction inside its bounds,
/// or the call faults where it stands, as RVY envisages a jump may, with
/// the entry's address. The entry's window comes from the window cache
/// when the same entry was called before.
#[inline(never)]
fn op_jcl(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    let k = (s & 31) as usize;
    let hh = hw(m, s);
    if hh & (TAG | M_OT) != TAG | M_CLOSURE {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let a = r(m, s);
    if hh & (M_LD | M_LC) != M_LD | M_LC || !in_win(a, m.wb[k], m.wl[k], 8) {
        return if hh & (M_LD | M_LC) == M_LD | M_LC && m.reg(s).covers(a, 8) {
            m.fault(C_LFAULT, a, pc, fuel)
        } else {
            m.fault(C_CAP_LOAD, a, pc, fuel)
        };
    }
    if a & 7 != 0 {
        return m.fault(C_LFAULT, a, pc, fuel);
    }
    let e = unsafe { m.rd_cap(a) };
    let t = e.addr & !1;
    if !e.tag || !e.enterable(0) || !e.has(P_EX) {
        return m.fault(C_CAP_FETCH, t, pc, fuel);
    }
    let (b, l) = m.window(e);
    if !in_win(t, b, l, 2) {
        return m.fault(if e.covers(t, 2) { C_IFAULT } else { C_CAP_FETCH }, t, pc, fuel);
    }
    m.xm[k] &= !M_OT;
    link(m, rd(w), pc.wrapping_add(4));
    m.pcc_meta = e.meta & !OTYPE_MASK;
    m.pcc_tag = true;
    m.pcc_wb = b;
    m.pcc_wl = l;
    next!(m, t, fuel - 1)
}

/// Indexed access to an object, checked: funct3 7 of custom-0.
///
/// ```text
///     funct7   the form << 4 | the type the object must be, or 0 for any
///     form     bit 0 store, bit 1 byte, bit 2 the index is an immediate
///     rs1      the object: headed and unsealed
///     rs2      the index, a fixnum, or with form bit 2 the five-bit
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
    let f = w >> 29;
    let hh = hw(m, s);
    if hh & (TAG | M_OT | M_HD) != TAG | M_HD {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let (base, wl) = (m.wb[k], m.wl[k]);
    // A headed capability whose bounds start in RAM has its base in the
    // window and its header just below; one with no header there, the root,
    // is not an object.
    if base < 8 || wl == 0 {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let hdr = unsafe { m.rd32(base - 8) };
    let ty = hdr & 0xff;
    let want = (w >> 25) & 15;
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
    let store = f & 1 != 0;
    let perm = if store { M_SD } else { M_LD };
    if !in_win(a, base, wl, sz) || hh & perm != perm {
        return m.fault(if store { C_CAP_STORE } else { C_CAP_LOAD }, a, pc, fuel);
    }
    let v = rd(w);
    if store {
        if let Some(g) = barrier(m, a, sz, s) {
            return m.fault(C_BARRIER, g, pc, fuel);
        }
        if bytes {
            let b = r(m, v) as u8;
            unsafe { m.wr8(a, b) };
        } else {
            unsafe { st_cap(m, a, v, hh) };
        }
    } else if bytes {
        let b = unsafe { m.rd8(a) } as u32;
        w_(m, v, b);
    } else {
        ld_cap(m, v, a, hh);
    }
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// The fixnum immediates, funct3 5 of custom-0. The operand must be a
/// fixnum (untagged, metadata 0), which is one comparison of `xm` against
/// zero; the result is one.
///
/// ```text
///     imm[11:10] 0  faddi   rd, rs1, imm   wrapping
///                1  faddio  rd, rs1, imm   cause 26 on overflow
///                2  fandi   rd, rs1, imm
///                3  fori    rd, rs1, imm
/// ```
///
/// The immediate is imm[9:0], sign-extended: -512 to 511.
#[inline(never)]
fn op_fixi(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rs1(w);
    if h(m, s) != 0 {
        return m.fault(C_TYPE, s, pc, fuel);
    }
    let x = r(m, s) as i32;
    let i = ((w << 2) as i32) >> 22;
    let v = match w >> 30 {
        0 => x.wrapping_add(i),
        1 => match x.checked_add(i) {
            Some(v) => v,
            None => return m.fault(C_OVER, 0, pc, fuel),
        },
        2 => x & i,
        _ => x | i,
    };
    w_(m, rd(w), v as u32);
    next!(m, pc.wrapping_add(4), fuel - 1)
}

/// `fop`: two fixnums, funct7 the operation.
///
/// ```text
///     0x00 add 0x01 sub 0x02 mul 0x03 div 0x04 rem 0x05 and 0x06 or 0x07 xor
///     0x08 addo 0x09 subo 0x0a mulo          cause 26 on overflow
///     0x10 sll 0x11 srl 0x12 sra             amount taken mod 32
///     0x13 lt 0x14 ltu 0x15 eq               the fixnum 0 or 1
/// ```
///
/// Overflow is cause 26 and the handler widens the result into a bignum;
/// division by zero is cause 27.
#[inline(always)]
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

/// `c.addi4spn`: `YADDI rd', csp, imm`.
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

/// `c.ly`, in `c.flw`'s slot.
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
    if auth(m, s, M_SD, a, 4) && barrier(m, a, 4, s).is_none() {
        let v = r(m, rcs(w, 2));
        unsafe { m.wr32(a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// `c.sy`, in `c.fsw`'s slot.
#[inline(never)]
fn c_sc(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let s = rcs(w, 7);
    let a = r(m, s).wrapping_add(clc_imm(w));
    if a & 7 == 0 && auth(m, s, M_SD, a, 8) && barrier(m, a, 8, s).is_none() {
        let au = h(m, s);
        unsafe { st_cap(m, a, rcs(w, 2), au) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

// =========================================================== compressed, Q1
// Every Zca HINT is a nop, as RVY has them: `c.addi` and the shifts by
// nothing leave their register as it was, tag and all, rather than making
// it an integer.

#[inline(never)]
fn c_addi(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let (d, i) = (rd(w), ci_imm(w));
    if i != 0 {
        let v = r(m, d).wrapping_add(i);
        w_(m, d, v);
    }
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

/// `c.lui`, and `c.addi16sp`, which is `YADDI csp, csp, imm`.
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
        if i == 0 {
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
    let sh = (((w >> 2) & 31) | (bit(w, 12) << 5)) & 31;
    if (w >> 10) & 3 < 2 && sh == 0 {
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    let v = match (w >> 10) & 3 {
        0 => a >> sh,
        1 => ((a as i32) >> sh) as u32,
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
    if r(m, rcs(w, 7)) == 0 {
        branch_to!(m, pc.wrapping_add(cb_imm(w)), pc, fuel)
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

#[inline(never)]
fn c_bnez(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    if r(m, rcs(w, 7)) != 0 {
        branch_to!(m, pc.wrapping_add(cb_imm(w)), pc, fuel)
    }
    next!(m, pc.wrapping_add(2), fuel - 1)
}

// =========================================================== compressed, Q2

#[inline(never)]
fn c_slli(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let d = rd(w);
    let sh = (((w >> 2) & 31) | (bit(w, 12) << 5)) & 31;
    if sh != 0 {
        let v = r(m, d) << sh;
        w_(m, d, v);
    }
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

/// `c.lysp`, in `c.flwsp`'s slot.
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
    if auth(m, 2, M_SD, a, 4) && barrier(m, a, 4, 2).is_none() {
        let v = r(m, (w >> 2) & 31);
        unsafe { m.wr32(a, v) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// `c.sysp`, in `c.fswsp`'s slot.
#[inline(never)]
fn c_scsp(m: &mut Machine, w: u32, pc: u32, fuel: u32) -> Stop {
    let a = r(m, 2).wrapping_add(scsp_imm(w));
    if a & 7 == 0 && auth(m, 2, M_SD, a, 8) && barrier(m, a, 8, 2).is_none() {
        let au = h(m, 2);
        unsafe { st_cap(m, a, (w >> 2) & 31, au) };
        next!(m, pc.wrapping_add(2), fuel - 1)
    }
    mem_slow(m, w, pc, fuel)
}

/// `c.jr`, `c.mv` (`C.YMV`), `c.ebreak`, `c.jalr` and `c.add`.
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
    let mut code = code_containing(m, m.mepc.addr).unwrap_or(m.reg(9));
    for _ in 0..12 {
        out.push_str(&name_of(m, code));
        out.push_str(" <- ");
        if s0 < crate::map::OBJ_BASE + 32 || s0 >= crate::map::OBJ_END {
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
    let (f, form) = (f3(w), w >> 29);
    match w & 0x7f {
        // sref
        0x0b if f == 1 => Some((r(m, rs1(w)).wrapping_add(imm_s(w)), 8, r(m, rs2(w)))),
        // an indexed store, the value in rd
        0x0b if f == 7 && form & 1 != 0 => {
            let base = m.reg(rs1(w)).base();
            let i = if form & 4 != 0 { rs2(w) } else { r(m, rs2(w)) };
            if form & 2 == 0 {
                Some((base.wrapping_add(i << 3), 8, r(m, rd(w))))
            } else {
                Some((base.wrapping_add(i), 1, r(m, rd(w))))
            }
        }
        _ => None,
    }
}

/// Where code can be: object space, where every function's text is, and the
/// reset stub.
fn in_code(a: u32) -> bool {
    use crate::map::*;
    (OBJ_BASE..OBJ_END).contains(&a) || (RESET_VECTOR..RESET_VECTOR + RESET_RESERVE).contains(&a)
}

/// The debugging watches, installed as the dispatch table when any of
/// `LM_WATCH_S2`, `LM_WATCH_ADDR` or `LM_WATCH_HI` is set. They cost no
/// cycles and no fuel, so installing them does not move a timing-dependent
/// fault.
///
/// `s2` holds the running task and only `%set-this-task!` writes it, so it
/// is either nil or a record in object space. Every jump through a register
/// lands in code. The first instruction that violates either rule is
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
            let (s, off) = jump_form(w);
            Some((s, r(m, s).wrapping_add(off) & !1))
        } else {
            None
        };
        // mret returns to whatever the trap stub put in `mepc`; for a
        // resuming task that is slot 0 of its context. A wrong value is a
        // jump without a jump instruction, so it is checked too.
        let mret = if w == 0x3020_0073 { Some(m.mepc.addr) } else { None };
        let jump_bad = match jump.map(|(_, t)| t).or(mret) {
            Some(t) => !in_code(t),
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
                eprintln!("mret watch: pc {pc:#x} returns to {t:#x}; context at {:#x}", m.mscratch.addr);
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
    c_lc,       // 011 c.ly (c.flw)
    op_bad,     // 100 reserved
    op_bad,     // 101 c.fsd
    c_sw,       // 110 c.sw
    c_sc,       // 111 c.sy (c.fsw)
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
    c_lcsp,    // 011 c.lysp (c.flwsp)
    c_jalr_mv, // 100 c.jr/c.mv/c.ebreak/c.jalr/c.add
    op_bad,    // 101 c.fsdsp
    c_swsp,    // 110 c.swsp
    c_scsp,    // 111 c.sysp (c.fswsp)
    // ---- tok 24..31: unreachable, op[1:0]==3 means 32-bit ----
    op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad, op_bad,
    // ---- 32-bit, indexed by opcode[6:2] (tok 32..63) ----
    op_load,   // 00 LOAD
    op_bad,    // 01 LOAD-FP
    op_xlm,    // 02 custom-0: Xlm
    op_fence,  // 03 MISC-MEM
    op_imm,    // 04 OP-IMM
    op_auipc,  // 05 AUIPC
    op_bad,    // 06 OP-IMM-32
    op_bad,    // 07 (48-bit)
    op_store,  // 08 STORE
    op_bad,    // 09 STORE-FP
    op_bad,    // 0a RVY-C, reserved
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
    op_bad,    // 16 RVY-B, reserved
    op_bad,    // 17 (48-bit)
    op_branch, // 18 BRANCH
    op_jalr,   // 19 JALR
    op_bad,    // 1a reserved
    op_jal,    // 1b JAL
    op_system, // 1c SYSTEM
    op_bad,    // 1d reserved
    op_rvy,    // 1e RVY-A
    op_bad,    // 1f (>= 80-bit)
];
