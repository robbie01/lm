//! Dynamic instruction counts: what the machine executed.
//!
//! A static count of an image says which instructions the compiler emitted,
//! not which ones run; a prologue is emitted once per function and executed
//! once per call. This module keeps one counter per dispatch slot, plus
//! slots for breakdowns a token alone cannot give: which Xlm form, which
//! CHERI instruction, which standard bit-manipulation extension, where the
//! memory traffic went, and how many activations called nothing.
//!
//! Counting is enabled at run time by `--isaprof`, which installs the
//! counting dispatch table (`cpu::PROF_TABLE`). Its one entry calls `count`
//! on every instruction before dispatching it, so the handlers carry no
//! profiling at all and an ordinary run pays nothing.
//!
//! The total here is smaller than `m.cycles`. `m.cycles` is the timebase, and
//! a machine parked on `wfi` has its clock moved forward to the next interrupt
//! without executing anything. This counts instructions; that counts time.

use crate::mach::Machine;

// Slots past the 64 dispatch tokens.
/// custom-0 by funct3: lref vkind lvar jcl sref lhdr beqx bnex.
pub const REF0: usize = 64;
/// custom-1 by funct3: ldx stx ldxb stxb and the immediate four.
pub const INDEX0: usize = 72;
/// custom-3 by funct3: faddi faddio fandi fori fshi fop - retag.
pub const FIX0: usize = 80;
/// fop by operation, in `FOPS` order.
pub const FOP0: usize = 88;
const FOPS: [u32; 17] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15];
/// The CHERI instructions with two operands or an immediate, in `CHERIS`
/// order, and the one-operand ones by their rs2 selector.
pub const CH0: usize = 105;
const CHERIS: [u32; 15] = [0x01, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x10, 0x11, 0x14, 0x16, 0x1d, 0x20, 0x21, 0x7c, 0x7d];
pub const CH_INCI: usize = CH0 + 15;
pub const CH_BOUNDSI: usize = CH0 + 16;
pub const CH1: usize = 122;
pub const ZBA: usize = 154;
pub const ZBB: usize = 155;
pub const ZBS: usize = 156;
pub const ZICOND: usize = 157;
/// Where a load or a store went. Frame slots and spills hold values the
/// machine had in a register and wrote to memory so the collector can find
/// them; their count measures what a register allocator would save.
pub const LD_FRAME: usize = 158;
pub const LD_SPILL: usize = 159;
pub const LD_LIT: usize = 160;
pub const LD_OTHER: usize = 161;
pub const ST_FRAME: usize = 162;
pub const ST_SPILL: usize = 163;
pub const ST_OTHER: usize = 164;
/// Activations, and the ones that returned without calling anything.
pub const CALLS: usize = 165;
pub const LEAF_CALLS: usize = 166;
pub const LEAF_INS: usize = 167;
/// A running count of everything, kept so that charging instructions to an
/// activation does not have to add up sixty-four slots per call.
pub const TOTAL: usize = 168;
pub const SLOTS: usize = 169;

/// A shadow call stack, for the leaf count.
pub struct Watch {
    /// What was entered at this depth, and did that activation call
    /// anything?
    pub depth: usize,
    pub called: [bool; 512],
    pub entry_ins: [u64; 512],
    pub entry_pc: [u32; 512],
    /// Per entry point: how many times it was entered, and whether the
    /// function ever calls anything in any of its activations.
    ///
    /// A recursive function's base case is an activation that calls nothing,
    /// but the function still needs a frame, because its other activations
    /// do. Only a function that never calls anything can omit its frame.
    pub funcs: std::collections::HashMap<u32, (u64, bool)>,
}

impl Default for Watch {
    fn default() -> Self {
        Watch {
            depth: 0,
            called: [false; 512],
            entry_ins: [0; 512],
            entry_pc: [0; 512],
            funcs: std::collections::HashMap::new(),
        }
    }
}

/// The base register a load or a store used, as a slot. s0 is the frame
/// pointer, sp the spill area, s1 the running function's code object.
fn mem_slot(rs1: u32, store: bool) -> usize {
    match (rs1, store) {
        (8, false) => LD_FRAME,
        (2, false) => LD_SPILL,
        (9, false) => LD_LIT,
        (_, false) => LD_OTHER,
        (8, true) => ST_FRAME,
        (2, true) => ST_SPILL,
        (_, true) => ST_OTHER,
    }
}

/// Which ratified extension an OP or OP-IMM encoding belongs to. The base
/// ISA's own funct7 values (0x00 for the arithmetic and logical forms, 0x20
/// for sub and the arithmetic shifts, 0x01 for M) are not counted; every
/// other value belongs to Zba, Zbb, Zbs or Zicond.
fn ext_slot(f7: u32, f3: u32) -> Option<usize> {
    Some(match f7 {
        0x10 => ZBA,
        0x05 | 0x30 | 0x04 => ZBB,
        0x14 | 0x24 | 0x34 => ZBS,
        0x07 => ZICOND,
        // sub and sra share funct7 0x20 with andn, orn and xnor.
        0x20 if f3 == 4 || f3 == 6 || f3 == 7 => ZBB,
        _ => return None,
    })
}

/// Count one instruction, before it runs.
pub fn count(m: &mut Machine, w: u32, pc: u32) {
    let tok = crate::cpu::token(w) as usize;
    m.prof[tok] += 1;
    m.prof[TOTAL] += 1;
    let rd = (w >> 7) & 31;
    let rs1 = (w >> 15) & 31;
    let rs2 = (w >> 20) & 31;
    let f3 = ((w >> 12) & 7) as usize;
    let f7 = w >> 25;
    let mut slot = None;
    if w & 3 == 3 {
        match w & 0x7f {
            0x0b => {
                slot = Some(REF0 + f3);
                if f3 == 3 && rd == 1 {
                    let entry = m.load_cap(m.x[rs1 as usize]).addr;
                    call(m, entry);
                }
            }
            0x2b => slot = Some(INDEX0 + f3),
            0x7b => {
                slot = Some(FIX0 + f3);
                if f3 == 5 {
                    if let Some(i) = FOPS.iter().position(|&o| o == f7) {
                        m.prof[FOP0 + i] += 1;
                    }
                }
            }
            0x5b => {
                slot = match f3 {
                    1 => Some(CH_INCI),
                    2 => Some(CH_BOUNDSI),
                    _ if f7 == 0x7f => Some(CH1 + rs2 as usize),
                    _ => CHERIS.iter().position(|&o| o == f7).map(|i| CH0 + i),
                }
            }
            0x03 => slot = Some(mem_slot(rs1, false)),
            0x23 => slot = Some(mem_slot(rs1, true)),
            0x13 if f3 == 1 || f3 == 5 => slot = ext_slot(f7, f3 as u32),
            0x33 => slot = ext_slot(f7, f3 as u32),
            0x6f if rd == 1 => call(m, pc.wrapping_add(crate::cpu::imm_j(w))),
            0x67 if rd == 1 => call(m, m.x[rs1 as usize].wrapping_add(((w as i32) >> 20) as u32)),
            0x67 if rd == 0 && rs1 == 1 => ret(m),
            _ => {}
        }
    } else {
        match (w & 3, f3) {
            (0, 2) | (0, 3) => slot = Some(mem_slot(((w >> 7) & 7) + 8, false)),
            (0, 6) | (0, 7) => slot = Some(mem_slot(((w >> 7) & 7) + 8, true)),
            (2, 2) | (2, 3) => slot = Some(LD_SPILL),
            (2, 6) | (2, 7) => slot = Some(ST_SPILL),
            (1, 1) => call(m, pc.wrapping_add(crate::cpu::cj_imm(w))),
            (2, 4) if (w >> 2) & 31 == 0 && rd != 0 => {
                if w & 0x1000 != 0 {
                    call(m, m.x[rd as usize])
                } else if rd == 1 {
                    ret(m)
                }
            }
            _ => {}
        }
    }
    if let Some(s) = slot {
        m.prof[s] += 1;
    }
}

/// A call: the shadow stack goes one deeper, and the target identifies the
/// function.
///
/// A tail call is a jump with no link; the caller's activation is charged
/// with the callee, so a tail-calling leaf is not counted, and the result
/// is an undercount.
fn call(m: &mut Machine, target: u32) {
    let w = &mut m.watch;
    let d = w.depth;
    let here = w.entry_pc[d];
    w.funcs.entry(here).or_insert((0, false)).1 = true;
    w.called[d] = true;
    if d < 511 {
        w.depth = d + 1;
        w.called[d + 1] = false;
        w.entry_pc[d + 1] = target;
        w.entry_ins[d + 1] = m.prof[TOTAL];
    }
    w.funcs.entry(target).or_insert((0, false)).0 += 1;
    m.prof[CALLS] += 1;
}

fn ret(m: &mut Machine) {
    let d = m.watch.depth;
    if d == 0 {
        return;
    }
    if !m.watch.called[d] {
        m.prof[LEAF_CALLS] += 1;
        m.prof[LEAF_INS] += m.prof[TOTAL].saturating_sub(m.watch.entry_ins[d]);
    }
    m.watch.depth = d - 1;
}

const TOKENS: [&str; 64] = [
    // ---- quadrant 0 ----
    "c.addi4spn", "c.fld", "c.lw", "c.lc", "-", "c.fsd", "c.sw", "c.sc",
    // ---- quadrant 1 ----
    "c.addi", "c.jal", "c.li", "c.lui", "c.alu", "c.j", "c.beqz", "c.bnez",
    // ---- quadrant 2 ----
    "c.slli", "c.fldsp", "c.lwsp", "c.lcsp", "c.jr/mv", "c.fsdsp", "c.swsp", "c.scsp",
    // ---- unreachable ----
    "-", "-", "-", "-", "-", "-", "-", "-",
    // ---- 32-bit, by opcode[6:2] ----
    "load", "load-fp", "xlm ref", "fence", "op-imm", "auipcc", "-", "-",
    "store", "store-fp", "xlm index", "amo", "op-reg", "lui", "-", "-",
    "madd", "msub", "nmsub", "nmadd", "op-fp", "-", "cheri", "-",
    "branch", "jalr", "-", "jal", "system", "-", "xlm fixnum", "-",
];
const REFS: [&str; 8] = ["lref", "vkind", "lvar", "jcl", "sref", "lhdr", "beqx", "bnex"];
const INDEXES: [&str; 8] = ["ldx", "stx", "ldxb", "stxb", "ldxi", "stxi", "ldxbi", "stxbi"];
const FIXES: [&str; 8] = ["faddi", "faddio", "fandi", "fori", "fshi", "fop", "?6", "retag"];
const FOP_NAMES: [&str; 17] = [
    "add", "sub", "mul", "div", "rem", "and", "or", "xor", "addo", "subo", "mulo", "sll", "srl", "sra", "lt",
    "ltu", "eq",
];
const CHERI_NAMES: [&str; 17] = [
    "cspecialrw", "csetbounds", "csetboundsexact", "cseal", "cunseal", "candperm", "csetaddr", "cincoffset",
    "csub", "csethigh", "cbuildcap", "ctestsubset", "cseqx", "store.ddc", "load.ddc", "cincoffsetimm",
    "csetboundsimm",
];
const ONE_NAMES: [&str; 32] = [
    "cgetperm", "cgettype", "cgetbase", "cgetlen", "cgettag", "cgetsealed", "cgetoffset", "?07", "crrl",
    "cram", "cmove", "ccleartag", "cjalr", "?0d", "?0e", "cgetaddr", "?10", "csealentry", "?12", "?13", "?14",
    "?15", "?16", "cgethigh", "cgettop", "?19", "?1a", "?1b", "csealclo", "?1d", "?1e", "?1f",
];

/// The name of a slot.
pub fn name(slot: usize) -> &'static str {
    match slot {
        0..=63 => TOKENS[slot],
        REF0..=71 => REFS[slot - REF0],
        INDEX0..=79 => INDEXES[slot - INDEX0],
        FIX0..=87 => FIXES[slot - FIX0],
        FOP0..=104 => FOP_NAMES[slot - FOP0],
        CH0..=121 => CHERI_NAMES[slot - CH0],
        CH1..=153 => ONE_NAMES[slot - CH1],
        ZBA => "Zba (sh*add)",
        ZBB => "Zbb",
        ZBS => "Zbs (b*)",
        ZICOND => "Zicond (czero)",
        LD_FRAME => "ld frame (s0)",
        LD_SPILL => "ld spill (sp)",
        LD_LIT => "ld code object (s1)",
        LD_OTHER => "ld other",
        ST_FRAME => "st frame (s0)",
        ST_SPILL => "st spill (sp)",
        ST_OTHER => "st other",
        CALLS => "calls",
        LEAF_CALLS => "leaf calls",
        LEAF_INS => "leaf instructions",
        _ => "total",
    }
}

/// How much of the machine's time goes into functions that never call
/// anything, and would therefore need no stack frame at all.
pub fn leaf_report(prof: &[u64; SLOTS], w: &Watch) -> String {
    let total: u64 = prof[TOTAL];
    let mut leaf_entries = 0u64;
    let mut leaf_fns = 0usize;
    let mut all_entries = 0u64;
    for (_, (n, calls)) in w.funcs.iter() {
        all_entries += n;
        if !calls {
            leaf_entries += n;
            leaf_fns += 1;
        }
    }
    let mut out = String::new();
    out.push_str(&format!("\ncalls: {}, to {} distinct entry points\n", all_entries, w.funcs.len()));
    out.push_str(&format!(
        "  entries to functions that never call anything: {} ({:.0}% of calls, {} of {} entry points)\n",
        leaf_entries,
        100.0 * leaf_entries as f64 / all_entries.max(1) as f64,
        leaf_fns,
        w.funcs.len()
    ));
    out.push_str(&format!(
        "  activations that happened not to call (base cases included): {} ({:.0}%)\n",
        prof[LEAF_CALLS],
        100.0 * prof[LEAF_CALLS] as f64 / all_entries.max(1) as f64
    ));
    for (label, per) in [("12 instructions", 12u64), ("14 instructions", 14)] {
        out.push_str(&format!(
            "  at {} of frame protocol saved per call: {} ({:.1}% of all instructions)\n",
            label,
            leaf_entries * per,
            100.0 * (leaf_entries * per) as f64 / total.max(1) as f64
        ));
    }
    out
}

/// A sorted table, and the share of the whole each line is.
pub fn report(prof: &[u64; SLOTS]) -> String {
    // The 64 dispatch tokens are the whole of what ran; the breakdown slots
    // are subsets of them and must not be added in again.
    let total: u64 = prof[TOTAL];
    let mut out = String::new();
    out.push_str(&format!("\ninstructions executed: {}\n", total));
    if total == 0 {
        return out;
    }
    let line = |out: &mut String, indent: &str, k: usize| {
        out.push_str(&format!(
            "  {indent}{:<18} {:>12}  {:>5.1}%\n",
            name(k),
            prof[k],
            100.0 * prof[k] as f64 / total as f64
        ))
    };
    let mut rows: Vec<usize> = (0..64).filter(|&i| prof[i] > 0).collect();
    rows.sort_by(|a, b| prof[*b].cmp(&prof[*a]));
    for i in rows {
        line(&mut out, "", i);
        // A token's breakdown immediately under it.
        let subs: &[std::ops::Range<usize>] = match i {
            34 => &[REF0..REF0 + 8],
            42 => &[INDEX0..INDEX0 + 8],
            62 => &[FIX0..FIX0 + 8, FOP0..FOP0 + 17],
            54 => &[CH0..CH0 + 17, CH1..CH1 + 32],
            _ => &[],
        };
        for range in subs {
            for k in range.clone().filter(|&k| prof[k] > 0) {
                line(&mut out, "  ", k);
            }
        }
    }
    // Where the memory traffic went. Frame slots and spills together measure
    // what a register allocator would save: values the compiler had in a
    // register and wrote to memory.
    let mem: u64 = prof[LD_FRAME..=ST_OTHER].iter().sum();
    if mem > 0 {
        out.push_str(&format!("\nmemory traffic: {} ({:.1}%)\n", mem, 100.0 * mem as f64 / total as f64));
        for k in LD_FRAME..=ST_OTHER {
            line(&mut out, "", k);
        }
        let home = prof[LD_FRAME] + prof[LD_SPILL] + prof[ST_FRAME] + prof[ST_SPILL];
        out.push_str(&format!(
            "  {:<18} {:>12}  {:>5.1}%   <- what a register allocator is aimed at\n",
            "frame + spill",
            home,
            100.0 * home as f64 / total as f64
        ));
    }
    let ext: u64 = prof[ZBA..=ZICOND].iter().sum();
    if ext > 0 {
        out.push_str(&format!(
            "\nof which the B extension and Zicond: {} ({:.1}%)\n",
            ext,
            100.0 * ext as f64 / total as f64
        ));
        for k in (ZBA..=ZICOND).filter(|&k| prof[k] > 0) {
            line(&mut out, "", k);
        }
    }
    out
}

/// Where the time goes, by function.
///
/// With `--fnprof` the outer loop hands the core slices of under a thousand
/// instructions. Each slice is charged to the function the machine is in
/// (the code object every Lisp frame keeps in s1) and once to every function
/// on the frame chain above it. The first is own time; the second is
/// inclusive time.
///
/// A leaf that sets up no frame of its own is charged to its caller, as a
/// backtrace would name it. Names are read the first time a code object is
/// seen, so one freed and reused during the run keeps its first name.
#[derive(Default)]
pub struct FnProf {
    own: std::collections::HashMap<u32, u64>,
    total: std::collections::HashMap<u32, u64>,
    names: std::collections::HashMap<u32, String>,
    all: u64,
    chain: Vec<u32>,
}

/// Small enough that a slice is mostly one function, and not a round number,
/// so that it does not fall into step with a loop.
pub const FNPROF_SLICE: u64 = 997;

impl FnProf {
    pub fn sample(&mut self, m: &Machine, used: u64) {
        self.all += used;
        let mut code = m.reg(9);
        let mut s0 = m.x[8];
        *self.own.entry(code.addr).or_insert(0) += used;
        // The same walk as `cpu::watch_backtrace`: every prologue leaves its
        // caller's frame at s0-16 and its caller's code object at s0-32. A
        // function recursing on the chain is charged once.
        self.chain.clear();
        for _ in 0..64 {
            if !self.chain.contains(&code.addr) {
                self.chain.push(code.addr);
                *self.total.entry(code.addr).or_insert(0) += used;
                if !self.names.contains_key(&code.addr) {
                    self.names.insert(code.addr, crate::cpu::name_of(m, code));
                }
            }
            if s0 < crate::map::OBJ_BASE + 32 || s0 >= crate::map::OBJ_END {
                break;
            }
            code = m.load_cap(s0.wrapping_sub(32));
            s0 = m.load_cap(s0.wrapping_sub(16)).addr;
        }
    }

    pub fn report(&self) -> String {
        let all = self.all.max(1) as f64;
        let name = |code: &u32| self.names.get(code).map(|s| s.as_str()).unwrap_or("?");
        let mut own: Vec<(&u32, &u64)> = self.own.iter().collect();
        own.sort_by(|a, b| b.1.cmp(a.1));
        let mut out = format!(
            "\nwhere {} instructions went, by the function they ran in:\n    own%  total%  function\n",
            self.all
        );
        for (code, n) in own.iter().take(40) {
            let t = self.total.get(*code).copied().unwrap_or(0);
            out.push_str(&format!(
                "  {:>6.1}  {:>6.1}  {}\n",
                100.0 * **n as f64 / all,
                100.0 * t as f64 / all,
                name(code)
            ));
        }
        let mut total: Vec<(&u32, &u64)> = self.total.iter().collect();
        total.sort_by(|a, b| b.1.cmp(a.1));
        out.push_str("\nand by the function they ran on behalf of:\n  total%  function\n");
        for (code, n) in total.iter().take(40) {
            out.push_str(&format!("  {:>6.1}  {}\n", 100.0 * **n as f64 / all, name(code)));
        }
        out
    }
}
