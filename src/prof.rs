//! What the machine actually executed.
//!
//! A static count of an image says which instructions the compiler *emitted*;
//! it says nothing about which ones run, and the two distributions are not
//! the same - a prologue is emitted once per function and executed once per
//! call. This is the other half: one counter per dispatch slot, bumped in the
//! threaded core's `next!`, plus a handful of extra slots for the breakdowns
//! a token cannot give (which pair operation, which indexed form, which of
//! the standard bit-manipulation extensions).
//!
//! It is behind the `isaprof` feature, so an ordinary build does not carry
//! the increment at all:
//!
//!     cargo build --release --features isaprof
//!     lm kick.img --stats --script '...'
//!
//! The total here is smaller than the instruction count `--stats` prints,
//! and the difference is real rather than a miscount: `m.cycles` is the
//! machine's timebase, and a machine that parks on `wfi` has its clock moved
//! forward to the next interrupt without executing anything. This counts
//! instructions; that counts time.

pub const SLOTS: usize = 128;

// Slots past the 64 dispatch tokens.
pub const PAIR0: usize = 64; // + funct3: car, cdr, set-car!, set-cdr!
pub const INDEX0: usize = 72; // + funct3: ldx, stx, ldxb, stxb and the immediate four
pub const ZBA: usize = 80;
pub const ZBB: usize = 81;
pub const ZBS: usize = 82;
pub const ZICOND: usize = 83;
/// Where a load or a store went. The whole register-allocator question is
/// how big these are: a frame slot and a spill are a value the machine had
/// in a register and put in memory because the collector has to be able to
/// find it.
pub const LD_FRAME: usize = 84;
pub const LD_SPILL: usize = 85;
pub const LD_LIT: usize = 86;
pub const LD_OTHER: usize = 87;
pub const ST_FRAME: usize = 88;
pub const ST_SPILL: usize = 89;
pub const ST_OTHER: usize = 90;

// ---- the two questions a peephole and a leaf-frame rule turn on ----
/// A frame or spill load of a value that is already sitting in a register,
/// established in this same straight-line run of instructions.
pub const LD_REDUNDANT: usize = 91;
/// ...of which: the value was put there by the store one instruction earlier.
pub const LD_REDUNDANT_ADJ: usize = 92;
/// Activations, and the ones that returned without calling anything.
pub const CALLS: usize = 93;
pub const LEAF_CALLS: usize = 94;
pub const LEAF_INS: usize = 95;
/// A branch whose operand was put in a register by the instruction just
/// before it - which is what comparing against a written-down constant looks
/// like, since RISC-V has no compare-immediate-and-branch.
pub const LI_BRANCH: usize = 96;
pub const LI_TOTAL: usize = 97;
/// Instructions that exist only because a value carries a tag: the `addi -1`
/// that corrects a sum, the `srai 1` that strips a tag before real work, and
/// the `slli 1` / `ori 1` that put one back.
pub const TAG_FIX: usize = 98;
pub const TAG_UNTAG: usize = 99;
pub const TAG_RETAG: usize = 100;
/// Register-register arithmetic, for scale.
pub const ARITH: usize = 101;

/// The bookkeeping those four need. Not counters: the state a basic block and
/// a call stack are tracked with.
pub struct Watch {
    /// For each register, the address it currently mirrors, and the block it
    /// was established in. A register written by anything else is invalidated
    /// by setting its generation to zero, which never matches.
    pub addr: [u32; 32],
    pub gen: [u32; 32],
    pub block: u32,
    /// The pc of the last store and the address it went to, for the adjacent
    /// store-then-reload case a peephole would catch with no analysis at all.
    pub st_pc: u32,
    pub st_addr: u32,
    /// The last `li`, for the compare-against-a-constant question.
    pub li_pc: u32,
    pub li_rd: u32,
    /// The last add or sub, for spotting the tag correction after it.
    pub as_pc: u32,
    pub as_rd: u32,
    /// A shadow call stack: what was entered at this depth, and did that
    /// activation call anything?
    pub depth: usize,
    pub called: [bool; 512],
    pub entry_ins: [u64; 512],
    pub entry_pc: [u32; 512],
    /// Per entry point: how many times it was entered, and whether the
    /// *function* ever calls anything in any of its activations.
    ///
    /// The distinction matters and I got it wrong the first time. A recursive
    /// function's base case is an activation that calls nothing, but the
    /// function still needs a frame, because its other activations do. Only a
    /// function that never calls anything, in any activation, can do without
    /// one.
    pub funcs: std::collections::HashMap<u32, (u64, bool)>,
}

impl Default for Watch {
    fn default() -> Self {
        Watch {
            addr: [0; 32],
            gen: [0; 32],
            block: 1,
            st_pc: u32::MAX,
            st_addr: 0,
            li_pc: u32::MAX,
            li_rd: 32,
            as_pc: u32::MAX,
            as_rd: 32,
            depth: 0,
            called: [false; 512],
            entry_ins: [0; 512],
            entry_pc: [0; 512],
            funcs: std::collections::HashMap::new(),
        }
    }
}

impl Watch {
    /// A branch, a jump or a trap ends the straight-line run, and nothing
    /// established before it can be relied on after.
    #[inline(always)]
    pub fn new_block(&mut self) {
        self.block = self.block.wrapping_add(1);
        if self.block == 0 {
            self.block = 1;
        }
    }
}

/// The base register a load or a store used, as a slot. s0 is the frame
/// pointer, sp the spill area, s1 the running function's literal vector.
#[inline(always)]
pub fn mem_slot(rs1: u32, store: bool) -> usize {
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

/// Names for every slot, in slot order. The first 32 are the compressed
/// quadrants, which this compiler does not emit but an image may still carry.
pub const NAMES: [&str; SLOTS] = [
    // ---- quadrant 0 ----
    "c.addi4spn", "c.fld", "c.lw", "c.flw", "-", "c.fsd", "c.sw", "c.fsw",
    // ---- quadrant 1 ----
    "c.addi", "c.jal", "c.li", "c.lui", "c.alu", "c.j", "c.beqz", "c.bnez",
    // ---- quadrant 2 ----
    "c.slli", "c.fldsp", "c.lwsp", "c.flwsp", "c.jr/mv", "c.fsdsp", "c.swsp", "c.fswsp",
    // ---- unreachable ----
    "-", "-", "-", "-", "-", "-", "-", "-",
    // ---- 32-bit, by opcode[6:2] ----
    "load", "load-fp", "custom-0 pair", "fence", "op-imm", "auipc", "-", "-",
    "store", "store-fp", "custom-1 index", "amo", "op-reg", "lui", "-", "-",
    "madd", "msub", "nmsub", "nmadd", "op-fp", "-", "custom-2", "-",
    "branch", "jalr", "-", "jal", "system", "-", "custom-3", "-",
    // ---- custom-0 breakdown ----
    "  car", "  cdr", "  set-car!", "  set-cdr!", "  ?4", "  ?5", "  ?6", "  ?7",
    // ---- custom-1 breakdown ----
    "  ldx", "  stx", "  ldxb", "  stxb", "  ldxi", "  stxi", "  ldxbi", "  stxbi",
    // ---- the standard extensions, counted inside op-reg and op-imm ----
    "  Zba (sh*add)", "  Zbb", "  Zbs (b*)", "  Zicond (czero)",
    "  ld frame (s0)", "  ld spill (sp)", "  ld literal (s1)", "  ld other",
    "  st frame (s0)", "  st spill (sp)", "  st other",
    "redundant load", "  adjacent", "calls", "leaf calls", "leaf instructions",
    "li then branch", "li total",
    "tag fixup", "untag", "retag", "arithmetic",
    "-", "-",
    "-", "-", "-", "-", "-", "-", "-", "-",
    "-", "-", "-", "-", "-", "-", "-", "-",
    "-", "-", "-", "-", "-", "-", "-", "-",
];

/// How much of the machine's time goes into functions that never call
/// anything, and would therefore need no stack frame at all.
pub fn leaf_report(prof: &[u64; SLOTS], w: &Watch) -> String {
    let total: u64 = prof[..64].iter().sum();
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
    out.push_str(&format!(
        "
calls: {}, to {} distinct entry points
",
        all_entries,
        w.funcs.len()
    ));
    out.push_str(&format!(
        "  entries to functions that never call anything: {} ({:.0}% of calls, {} of {} entry points)
",
        leaf_entries,
        100.0 * leaf_entries as f64 / all_entries.max(1) as f64,
        leaf_fns,
        w.funcs.len()
    ));
    out.push_str(&format!(
        "  activations that happened not to call (base cases included): {} ({:.0}%)
",
        prof[LEAF_CALLS],
        100.0 * prof[LEAF_CALLS] as f64 / all_entries.max(1) as f64
    ));
    for (label, per) in [("12 instructions", 12u64), ("14 instructions", 14)] {
        out.push_str(&format!(
            "  at {} of frame protocol saved per call: {} ({:.1}% of all instructions)
",
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
    let total: u64 = prof[..64].iter().sum();
    let mut out = String::new();
    out.push_str(&format!("\ninstructions executed: {}\n", total));
    if total == 0 {
        return out;
    }
    let mut rows: Vec<(usize, u64)> = (0..64).filter(|&i| prof[i] > 0).map(|i| (i, prof[i])).collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    for (i, n) in rows {
        out.push_str(&format!(
            "  {:<16} {:>12}  {:>5.1}%\n",
            NAMES[i],
            n,
            100.0 * n as f64 / total as f64
        ));
        // Print a token's breakdown immediately under it.
        let sub = match i {
            34 => Some(PAIR0),
            42 => Some(INDEX0),
            _ => None,
        };
        if let Some(b) = sub {
            for k in 0..8 {
                if prof[b + k] > 0 {
                    out.push_str(&format!(
                        "  {:<16} {:>12}  {:>5.1}%\n",
                        NAMES[b + k],
                        prof[b + k],
                        100.0 * prof[b + k] as f64 / total as f64
                    ));
                }
            }
        }
    }
    // Where the memory traffic went. Frame slots and spills together are the
    // measure of what a register allocator would be worth - they are values
    // the compiler had in a register and wrote to memory anyway.
    let mem: u64 = prof[LD_FRAME..=ST_OTHER].iter().sum();
    if mem > 0 {
        out.push_str(&format!(
            "
memory traffic: {} ({:.1}%)
",
            mem,
            100.0 * mem as f64 / total as f64
        ));
        for k in LD_FRAME..=ST_OTHER {
            out.push_str(&format!(
                "  {:<16} {:>12}  {:>5.1}%
",
                NAMES[k],
                prof[k],
                100.0 * prof[k] as f64 / total as f64
            ));
        }
        let home = prof[LD_FRAME] + prof[LD_SPILL] + prof[ST_FRAME] + prof[ST_SPILL];
        out.push_str(&format!(
            "  {:<16} {:>12}  {:>5.1}%   <- what a register allocator is aimed at
",
            "frame + spill",
            home,
            100.0 * home as f64 / total as f64
        ));
    }

    let tags = prof[TAG_FIX] + prof[TAG_UNTAG] + prof[TAG_RETAG];
    out.push_str(&format!(
        "
instructions that exist only because values are tagged: {} ({:.1}%)
",
        tags,
        100.0 * tags as f64 / total.max(1) as f64
    ));
    for k in [TAG_FIX, TAG_UNTAG, TAG_RETAG, ARITH] {
        out.push_str(&format!(
            "  {:<16} {:>12}  {:>5.1}%
",
            NAMES[k],
            prof[k],
            100.0 * prof[k] as f64 / total.max(1) as f64
        ));
    }

    out.push_str(&format!(
        "
branches on a constant put in a register the instruction before: {} ({:.1}% of all instructions; {} li in total)
",
        prof[LI_BRANCH],
        100.0 * prof[LI_BRANCH] as f64 / total.max(1) as f64,
        prof[LI_TOTAL]
    ));

    // What a basic-block peephole and a leaf-frame rule are each worth.
    out.push_str(&format!(
        "
frame/spill loads of a value already in a register: {} ({:.1}% of all instructions)
",
        prof[LD_REDUNDANT],
        100.0 * prof[LD_REDUNDANT] as f64 / total as f64
    ));
    out.push_str(&format!(
        "  of those, the reload of the store one instruction earlier: {} ({:.1}%)
",
        prof[LD_REDUNDANT_ADJ],
        100.0 * prof[LD_REDUNDANT_ADJ] as f64 / total as f64
    ));

    let ext: u64 = prof[ZBA..=ZICOND].iter().sum();
    if ext > 0 {
        out.push_str(&format!(
            "\nof which the B extension and Zicond: {} ({:.1}%)\n",
            ext,
            100.0 * ext as f64 / total as f64
        ));
        for k in ZBA..=ZICOND {
            if prof[k] > 0 {
                out.push_str(&format!(
                    "  {:<16} {:>12}  {:>5.1}%\n",
                    NAMES[k],
                    prof[k],
                    100.0 * prof[k] as f64 / total as f64
                ));
            }
        }
    }
    out
}
