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

pub const SLOTS: usize = 96;

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
    "-", "-", "-", "-", "-",
];

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
