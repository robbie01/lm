//! The machine: register file, tagged memory, CSRs and special capability
//! registers, trap entry, and the state the outer loop hands the
//! token-threaded core.

use crate::cap::*;
use crate::dev::blit::Blitter;
use crate::dev::disk::Disk;
use crate::dev::gfx::Gfx;
use crate::dev::input::Input;
use crate::dev::uart::Uart;
use crate::map::*;

// ---------------------------------------------------------------- trap causes
pub const C_IALIGN: u32 = 0;
pub const C_IFAULT: u32 = 1;
pub const C_ILLEGAL: u32 = 2;
pub const C_BREAK: u32 = 3;
pub const C_LALIGN: u32 = 4;
pub const C_LFAULT: u32 = 5;
pub const C_SALIGN: u32 = 6;
pub const C_SFAULT: u32 = 7;
pub const C_ECALL: u32 = 11;
/// Wrong kind of operand handed to an Xlm instruction. RISC-V reserves
/// causes 24 through 31 for the implementation. `mtval` is the number of the
/// register that held the operand; the handler reads its value from the trap
/// frame.
pub const C_TYPE: u32 = 24;
/// An index at or past the length in an object's header. `mtval` is the
/// number of the index register, or 32 for an immediate index.
pub const C_RANGE: u32 = 25;
/// A fixnum result that does not fit in 32 bits. The handler decodes the
/// instruction, widens the operation to a bignum and resumes after it.
pub const C_OVER: u32 = 26;
/// Division by zero in a fixnum instruction.
pub const C_DIVZERO: u32 = 27;
/// A capability check failed. `mtval` is `(register << 5) | code`, the
/// register 32 for PCC and 33 for DDC, the code one of `CAPEX_*`.
pub const C_CAP: u32 = 28;
/// The write barrier. With bit 0 of `gcmode` set, a store of any width that
/// would overwrite a tagged granule in cons or object space whose capability
/// points at an unmarked heap object traps before writing, unless the
/// granule lies in a stack or a register context. `mtval` is the address of
/// that granule; the handler marks the object and the store re-executes.
/// This is what lets the collector mark while everything else runs: nothing
/// reachable when marking began can be lost, because the last pointer to it
/// cannot be overwritten without the collector seeing it first. A stack or a
/// context in use is a root, scanned whole when marking begins, so what it
/// held then is already marked, and a store into one loses nothing.
pub const C_BARRIER: u32 = 29;
/// A capability offset moved sp below `stklim` with interrupts on. `mtval`
/// is where it would have gone; sp is left as it was.
pub const C_STACK: u32 = 30;

// The capability fault codes, as ISAv9 numbers them: what a capability
// fault's `mtval` carries below the register.

/// An access outside the bounds, or bounds outside the authority's.
pub const CAPEX_LENGTH: u32 = 0x01;
/// An untagged capability used as one.
pub const CAPEX_TAG: u32 = 0x02;
/// A sealed capability used, or one entered other than as its seal allows.
pub const CAPEX_SEAL: u32 = 0x03;
/// The wrong otype, or for `csealclo` an object that is not a closure.
pub const CAPEX_TYPE: u32 = 0x04;
/// ISAv9's software-defined permission violation, which `cbuildcap` raises
/// for bits asking for a permission its authority lacks, or for HD at a base
/// where its authority could not have kept it.
pub const CAPEX_SOFT_PERM: u32 = 0x08;
/// `csetboundsexact` of bounds that would round.
pub const CAPEX_REPRESENTABLE: u32 = 0x0a;
/// The missing permission: EX, LD, SD, LC, SC.
pub const CAPEX_EXECUTE: u32 = 0x11;
pub const CAPEX_LOAD: u32 = 0x12;
pub const CAPEX_STORE: u32 = 0x13;
pub const CAPEX_LOAD_CAP: u32 = 0x14;
pub const CAPEX_STORE_CAP: u32 = 0x15;
/// `cseal` through an authority without SE.
pub const CAPEX_SEAL_PERM: u32 = 0x17;
/// SR, missing from PCC for a privileged act.
pub const CAPEX_SYSREG: u32 = 0x18;
/// `cunseal` through an authority without SE.
pub const CAPEX_UNSEAL: u32 = 0x1b;

/// Where the register sits in a capability fault's mtval, above the code.
pub const CAPEX_REG_SHIFT: u32 = 5;
/// The register numbers a capability fault names beyond the 32 general ones.
pub const CAPEX_REG_PCC: u32 = 32;
pub const CAPEX_REG_DDC: u32 = 33;
/// What a range fault names for an immediate index.
pub const RANGE_IMM: u32 = 32;

/// The special capability registers, as `cspecialrw` numbers them.
pub const SCR_PCC: u32 = 0;
pub const SCR_DDC: u32 = 1;
pub const SCR_MTCC: u32 = 28;
pub const SCR_MTDC: u32 = 29;
pub const SCR_MSCRATCHC: u32 = 30;
pub const SCR_MEPCC: u32 = 31;

/// The machine CSRs by number. `mtvec`, `mepc` and `mscratch` read and write
/// the addresses of MTCC, MEPCC and MScratchC.
pub const CSR_MSTATUS: u32 = 0x300;
pub const CSR_MIE: u32 = 0x304;
pub const CSR_MTVEC: u32 = 0x305;
pub const CSR_MSCRATCH: u32 = 0x340;
pub const CSR_MEPC: u32 = 0x341;
pub const CSR_MCAUSE: u32 = 0x342;
pub const CSR_MTVAL: u32 = 0x343;
pub const CSR_MIP: u32 = 0x344;
/// A custom CSR: the lowest address sp may be moved down to with interrupts
/// on. Zero means no limit.
pub const CSR_STKLIM: u32 = 0x7c0;
/// A custom CSR: bit 0 turns the write barrier on. The mark bits it consults
/// are one per eight bytes of heap, from `CONS_BASE`, at `GC_BITMAP`.
pub const CSR_GCMODE: u32 = 0x7c1;

/// A task's register save area, which is also a trap frame: 32 capability
/// slots, slot 0 the pc (MEPCC) and slot i the register x_i.
pub const CTX_SLOTS: u32 = 32;
pub const CTX_SLOT_BYTES: u32 = 8;
pub const CTX_BYTES: u32 = CTX_SLOTS * CTX_SLOT_BYTES;

/// What `vkind` answers beyond an untagged value's metadata (0 to 15): nil,
/// a pair, any other capability, and an object of header type t as
/// `KIND_OBJECT + t`.
pub const KIND_NIL: u32 = 16;
pub const KIND_PAIR: u32 = 17;
pub const KIND_CAP: u32 = 31;
pub const KIND_OBJECT: u32 = 32;

/// Stretches with interrupts off that last longer than this are counted as
/// pauses: about a millisecond of host time.
pub const PAUSE_LONG: u64 = 300_000;

/// What `a7` carries when compiled code raises an ecall. The compiler emits
/// these, `sys.lisp` reports them and the test bench names them, so they are
/// generated into `layout.lisp` rather than written three times.
pub const E_ARITY: u32 = 1;
pub const E_OOM: u32 = 3;
pub const E_ERROR: u32 = 4;
pub const E_RESCHEDULE: u32 = 5;
pub const E_RECORD: u32 = 6;

/// Exit codes the machine halts with. Shared with the Lisp side through
/// layout.lisp.
pub const EXIT_OK: u32 = 0;
pub const EXIT_ERROR: u32 = 1;
pub const EXIT_OOM: u32 = 3;
pub const EXIT_GC_STACK: u32 = 4;
pub const EXIT_GC_CORRUPT: u32 = 5;
pub const EXIT_TRAP_SPIRAL: u32 = 9;
/// What `lmforge rebuild --check` halts with when everything compiled and
/// collected. Distinct from every failure code above.
pub const EXIT_CHECK_PASSED: u32 = 42;

pub const IRQ_SOFT: u32 = 3; // machine software interrupt
pub const IRQ_TIMER: u32 = 7;
pub const IRQ_EXT: u32 = 11;

pub const MIE_MSIE: u32 = 1 << IRQ_SOFT;
pub const MIE_MTIE: u32 = 1 << IRQ_TIMER;
pub const MIE_MEIE: u32 = 1 << IRQ_EXT;

pub const MSTATUS_MIE: u32 = 1 << 3;
pub const MSTATUS_MPIE: u32 = 1 << 7;

/// Why the threaded core handed control back.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u32)]
pub enum Stop {
    /// Fuel exhausted; `m.pc` is the next instruction to run.
    Fuel = 0,
    /// A synchronous trap is pending in `m.trap`.
    Trap = 1,
    /// wfi: idle until an interrupt arrives.
    Wfi = 2,
    /// The SYS device was told to power down.
    Halt = 3,
}

/// The tag and the decoded-window flag of a register, above its metadata in
/// `Machine::xm`.
pub const XM_TAG: u64 = 1 << 32;
pub const XM_READY: u64 = 1 << 33;

/// How many windows of capabilities decoded in full are remembered.
pub const WCACHE: usize = 1024;

pub struct Machine {
    /// The register file. A register is a capability: its address in `x`,
    /// its metadata and tag in `xm` (metadata in the low 32 bits, the tag at
    /// `XM_TAG`). An integer result writes the address and zeroes `xm`, so
    /// the integer instructions touch nothing else.
    ///
    /// `wb` and `wl` cache where a tagged register reaches: the base and
    /// length of its bounds clipped to RAM. They are valid while `XM_READY`
    /// is set in `xm`, which only a tagged register has; whatever writes a
    /// capability either copies them or leaves the flag clear for the first
    /// access to fill in.
    pub x: [u32; 32],
    pub xm: [u64; 32],
    pub wb: [u32; 32],
    pub wl: [u32; 32],
    /// PCC is the address `pc` with `pcc_meta`, tagged by `pcc_tag`. Its
    /// window is the same clipped bounds as a register's, empty unless PCC
    /// may execute, so a fetch is one comparison.
    pub pc: u32,
    pub pcc_meta: u32,
    pub pcc_tag: bool,
    pub pcc_wb: u32,
    pub pcc_wl: u32,
    /// DDC, with its window and the permissions it grants (none unless it is
    /// tagged and unsealed). `set_ddc` keeps them in step, and the core
    /// refreshes them on entry, so DDC may also be assigned between runs.
    pub ddc: Cap,
    pub ddc_wb: u32,
    pub ddc_wl: u32,
    pub ddc_perms: u32,
    /// The other special capability registers.
    pub mtcc: Cap,
    pub mtdc: Cap,
    pub mscratchc: Cap,
    pub mepcc: Cap,
    /// The windows of capabilities decoded in full, keyed by the
    /// capability's bits: the entries `jcl` jumps through, and the return
    /// addresses, frames and code objects a return loads back. A window is a
    /// function of the bits alone, so nothing ever invalidates an entry.
    pub wcache: Box<[(u64, u32, u32); WCACHE]>,

    ram: Box<[u8]>,
    /// Raw view of `ram` so the hot path skips the slice length load.
    pub ramp: *mut u8,
    pub ramlen: u32,
    /// One byte per 8-byte granule of RAM, 1 where the granule holds a
    /// capability. Every data write clears the tags of the granules it
    /// touches; only a capability store sets one.
    tags: Box<[u8]>,
    tagp: *mut u8,

    // --- control and status ---
    pub mstatus: u32,
    pub mie: u32,
    pub mip: u32,
    pub stklim: u32,
    pub gcmode: u32,
    pub mcause: u32,
    pub mtval: u32,

    /// Retired instruction count, also the machine timebase. Timing is
    /// therefore deterministic: same image, same schedule, every run.
    pub cycles: u64,
    /// Instructions executed. `cycles` also counts the time an idle
    /// machine skips over and the stalls devices charge for memory traffic,
    /// so it is a clock; this is a measure of work.
    pub executed: u64,
    /// Real-time pacing, for a machine with a window: the wall time and the
    /// cycle count it was last lined up with, and how long it has slept to
    /// keep in step. See `run::pace`.
    pub pace: Option<(std::time::Instant, u64)>,
    pub slept: f64,
    pub trap: (u32, u32, u32), // cause, tval, epc

    /// The pause meter: how long the machine runs with interrupts off. The
    /// cycle the current stretch began, or `u64::MAX` while interrupts are
    /// on; the longest stretch seen; and how many exceeded `PAUSE_LONG`.
    /// Measured from the first time interrupts were enabled, so that the
    /// boot, which runs with them off, is not a pause.
    pub mie_off_at: u64,
    pub pause_max: u64,
    pub pause_long: u64,
    /// Report every stretch over `PAUSE_LONG` as it ends, with a backtrace
    /// of where the machine was. Set from the environment at boot.
    pub trace_pauses: bool,

    /// Dynamic instruction histogram. Slots 0..63 are dispatch tokens; the
    /// rest break down what a token alone cannot say. See `prof::name`.
    /// Always present, filled only by the counting dispatch table that
    /// `--isaprof` installs, so profiling needs no separate build.
    pub prof: Box<[u64; crate::prof::SLOTS]>,
    pub watch: Box<crate::prof::Watch>,
    pub prof_on: bool,
    /// Samples of which function the machine is in, taken only with
    /// `--fnprof`. See `prof::FnProf`.
    pub fnprof: Option<Box<crate::prof::FnProf>>,
    /// Which dispatch table the core is using: the plain one, the counting
    /// one, or the watching one.
    pub table: &'static [crate::cpu::Handler; 64],
    /// The pc and instruction word one instruction ago. Filled only when the
    /// watch table is installed; see `cpu::watch_hook`.
    pub watch_prev: u32,
    pub watch_prev_w: u32,
    pub watch_fired: bool,
    /// The store watches: an address range, and a word whose top half is
    /// wanted. Set from the environment at boot; see `cpu::watch_hook`.
    pub watch_addr: Option<(u32, u32)>,
    pub watch_hi: Option<u32>,

    // --- custom chips ---
    pub intreq: u32,
    pub intena: u32,
    pub uart: Uart,
    pub gfx: Gfx,
    pub input: Input,
    pub blit: Blitter,
    pub disk: Disk,
    pub mtimecmp: u64,
    pub halted: bool,
    pub exit_code: u32,
    /// Name indices for the build: `sym_name_id` maps a symbol's identity to a
    /// dense index for its name, and `name_ids` allocates those indices. Only
    /// the forge fills them; the machine never reads them. The build's global
    /// and macro tables are indexed by them. See `Heap::name_id`.
    pub sym_name_id: Vec<u32>,
    pub name_ids: std::collections::HashMap<String, u32>,

    /// Fuel left when the core handed back; the outer loop turns the
    /// difference into retired cycles.
    pub fuel_left: u32,
    /// Fuel the current quantum started with.
    pub fuel_start: u32,
    /// The retired-instruction count as of the last time something asked.
    /// `cycles` is only current between quanta; this is current whenever a
    /// CSR read or a device access has just refreshed it.
    pub now: u64,
    pub rng: u64,
    pub trace_traps: bool,
}

/// The part of a capability's bounds that lies in RAM, as a base and a
/// length; the length is 0 if none does.
#[inline]
pub fn ram_window(c: Cap, ramlen: u32) -> (u32, u32) {
    let (b, t) = c.bounds();
    let t = t.min(ramlen as u64);
    if (b as u64) < t {
        (b, (t - b as u64) as u32)
    } else {
        (0, 0)
    }
}

impl Machine {
    /// A machine at reset: PCC, DDC and MTCC the root, every general register
    /// NULL, PCC at the reset vector.
    pub fn new() -> Box<Machine> {
        let mut ram = vec![0u8; RAM_SIZE as usize].into_boxed_slice();
        let ramp = ram.as_mut_ptr();
        let mut tags = vec![0u8; (RAM_SIZE / 8) as usize].into_boxed_slice();
        let tagp = tags.as_mut_ptr();
        let mut m = Box::new(Machine {
            x: [0; 32],
            xm: [0; 32],
            wb: [0; 32],
            wl: [0; 32],
            pc: 0,
            pcc_meta: 0,
            pcc_tag: false,
            pcc_wb: 0,
            pcc_wl: 0,
            ddc: Cap::NULL,
            ddc_wb: 0,
            ddc_wl: 0,
            ddc_perms: 0,
            mtcc: Cap::ROOT,
            mtdc: Cap::NULL,
            mscratchc: Cap::NULL,
            mepcc: Cap::NULL,
            wcache: Box::new([(0, 0, 0); WCACHE]),
            ram,
            ramp,
            ramlen: RAM_SIZE,
            tags,
            tagp,
            mstatus: 0,
            mie: 0,
            mip: 0,
            stklim: 0,
            gcmode: 0,
            mcause: 0,
            mtval: 0,
            cycles: 0,
            executed: 0,
            pace: None,
            slept: 0.0,
            trap: (0, 0, 0),
            mie_off_at: u64::MAX,
            pause_max: 0,
            pause_long: 0,
            trace_pauses: false,
            prof: Box::new([0; crate::prof::SLOTS]),
            watch: Box::default(),
            prof_on: false,
            fnprof: None,
            sym_name_id: Vec::new(),
            name_ids: std::collections::HashMap::new(),
            table: &crate::cpu::TABLE,
            watch_prev: 0,
            watch_prev_w: 0,
            watch_fired: false,
            watch_addr: None,
            watch_hi: None,
            intreq: 0,
            intena: 0,
            uart: Uart::new(),
            gfx: Gfx::new(),
            input: Input::new(),
            blit: Blitter::new(),
            disk: Disk::new(),
            mtimecmp: u64::MAX,
            halted: false,
            exit_code: 0,
            fuel_left: 0,
            fuel_start: 0,
            now: 0,
            rng: 0x2545_F491_4F6C_DD1D,
            trace_traps: false,
        });
        m.set_pcc(Cap::ROOT.with_addr(RESET_VECTOR));
        m.set_ddc(Cap::ROOT);
        m
    }

    pub fn ram(&self) -> &[u8] {
        &self.ram
    }
    /// The bytes of RAM, for loading an image. Writing through this leaves
    /// the tags as they are; `tags_mut` sets them to match.
    pub fn ram_mut(&mut self) -> &mut [u8] {
        &mut self.ram
    }

    /// The tag array: byte `a / 8` is 1 if the granule at `a` holds a
    /// capability, else 0.
    pub fn tags(&self) -> &[u8] {
        &self.tags
    }
    pub fn tags_mut(&mut self) -> &mut [u8] {
        &mut self.tags
    }

    // ------------------------------------------------------------- registers
    #[inline(always)]
    pub fn reg(&self, i: u32) -> Cap {
        let i = (i & 31) as usize;
        let h = self.xm[i];
        Cap { addr: self.x[i], meta: h as u32, tag: h & XM_TAG != 0 }
    }

    /// Write a capability register. Writes to x0 are discarded.
    #[inline(always)]
    pub fn set_reg(&mut self, i: u32, c: Cap) {
        let i = (i & 31) as usize;
        self.x[i] = c.addr;
        self.xm[i] = c.meta as u64 | if c.tag { XM_TAG } else { 0 };
        self.x[0] = 0;
        self.xm[0] = 0;
    }

    /// Fill in the window of register `i` if it is tagged and has none yet.
    ///
    /// Most capabilities that get here point at the base of a small object:
    /// a pair, a symbol, a closure. Their bounds are exact (IE clear, E 0),
    /// and an address whose low ten bits are B is the base itself, which
    /// leaves the length as T - B in eight bits. Those are done in place;
    /// anything else is decoded in full.
    #[inline(always)]
    pub fn fill_window(&mut self, i: u32) {
        let i = (i & 31) as usize;
        let xm = self.xm[i];
        if xm & (XM_TAG | XM_READY) != XM_TAG {
            return;
        }
        let (a, meta) = (self.x[i], xm as u32);
        let len = (meta >> 10).wrapping_sub(meta) & 0xff;
        if meta & IE_BIT == 0 && a & 0x3ff == meta & 0x3ff && len != 0 && a as u64 + len as u64 <= self.ramlen as u64 {
            self.wb[i] = a;
            self.wl[i] = len;
            self.xm[i] = xm | XM_READY;
        } else {
            self.decode_window(i);
        }
    }

    #[inline(never)]
    fn decode_window(&mut self, i: usize) {
        let (b, l) = self.window(self.reg(i as u32));
        self.wb[i] = b;
        self.wl[i] = l;
        self.xm[i] |= XM_READY;
    }

    /// The window of a capability, from `wcache` when it was decoded before.
    #[inline(always)]
    pub fn window(&mut self, c: Cap) -> (u32, u32) {
        let bits = c.to_bits();
        let slot = ((bits ^ (bits >> 29) ^ (bits >> 41)) as usize) & (WCACHE - 1);
        let e = self.wcache[slot];
        if e.0 == bits && bits != 0 {
            (e.1, e.2)
        } else {
            let (b, l) = ram_window(c, self.ramlen);
            self.wcache[slot] = (bits, b, l);
            (b, l)
        }
    }

    pub fn pcc(&self) -> Cap {
        Cap { addr: self.pc, meta: self.pcc_meta, tag: self.pcc_tag }
    }

    /// Install a new PCC and the window fetch is checked against: its bounds
    /// clipped to RAM if it may execute, and empty if not.
    pub fn set_pcc(&mut self, c: Cap) {
        self.pc = c.addr;
        self.pcc_meta = c.meta;
        self.pcc_tag = c.tag;
        let exec = c.tag && !c.is_sealed() && c.has(P_EX);
        let (b, l) = if exec { ram_window(c, self.ramlen) } else { (0, 0) };
        self.pcc_wb = b;
        self.pcc_wl = l;
    }

    #[inline(always)]
    pub fn pcc_has(&self, p: u32) -> bool {
        self.pcc_meta & (p << PERM_SHIFT) != 0
    }

    pub fn set_ddc(&mut self, c: Cap) {
        self.ddc = c;
        let live = c.tag && !c.is_sealed();
        let (b, l) = if live { ram_window(c, self.ramlen) } else { (0, 0) };
        self.ddc_wb = b;
        self.ddc_wl = l;
        self.ddc_perms = if live { c.perms() } else { 0 };
    }

    /// Read a special capability register; None if there is no such one.
    pub fn scr_read(&self, n: u32) -> Option<Cap> {
        Some(match n {
            SCR_PCC => self.pcc(),
            SCR_DDC => self.ddc,
            SCR_MTCC => self.mtcc,
            SCR_MTDC => self.mtdc,
            SCR_MSCRATCHC => self.mscratchc,
            SCR_MEPCC => self.mepcc,
            _ => return None,
        })
    }

    /// Write one. PCC is read only here; a jump writes it.
    pub fn scr_write(&mut self, n: u32, c: Cap) {
        match n {
            SCR_DDC => self.set_ddc(c),
            SCR_MTCC => self.mtcc = c,
            SCR_MTDC => self.mtdc = c,
            SCR_MSCRATCHC => self.mscratchc = c,
            SCR_MEPCC => self.mepcc = c,
            _ => {}
        }
    }

    // -------------------------------------------------------------- raw access
    #[inline(always)]
    pub fn in_ram(&self, a: u32, sz: u32) -> bool {
        // A subtraction rather than `a + sz <= ramlen`: the addition wraps for
        // an address near the top of the space and would accept a load at
        // 0xFFFFFFFF, which is a host segfault. `ramlen` exceeds every access
        // size, so the subtraction cannot underflow.
        a <= self.ramlen - sz
    }

    #[inline(always)]
    pub unsafe fn rd8(&self, a: u32) -> u8 {
        *self.ramp.add(a as usize)
    }
    #[inline(always)]
    pub unsafe fn rd16(&self, a: u32) -> u16 {
        (self.ramp.add(a as usize) as *const u16).read_unaligned()
    }
    #[inline(always)]
    pub unsafe fn rd32(&self, a: u32) -> u32 {
        (self.ramp.add(a as usize) as *const u32).read_unaligned()
    }
    /// The data writes. Each clears the tag of every granule it touches: the
    /// first and the last, which are the same unless the write is unaligned
    /// across a granule boundary.
    #[inline(always)]
    pub unsafe fn wr8(&mut self, a: u32, v: u8) {
        *self.ramp.add(a as usize) = v;
        *self.tagp.add((a >> 3) as usize) = 0;
    }
    #[inline(always)]
    pub unsafe fn wr16(&mut self, a: u32, v: u16) {
        (self.ramp.add(a as usize) as *mut u16).write_unaligned(v);
        *self.tagp.add((a >> 3) as usize) = 0;
        *self.tagp.add(((a + 1) >> 3) as usize) = 0;
    }
    #[inline(always)]
    pub unsafe fn wr32(&mut self, a: u32, v: u32) {
        (self.ramp.add(a as usize) as *mut u32).write_unaligned(v);
        *self.tagp.add((a >> 3) as usize) = 0;
        *self.tagp.add(((a + 3) >> 3) as usize) = 0;
    }
    #[inline(always)]
    pub unsafe fn rd_tag(&self, a: u32) -> bool {
        *self.tagp.add((a >> 3) as usize) != 0
    }
    /// The capability in the granule at `a`, which is aligned and in RAM.
    #[inline(always)]
    pub unsafe fn rd_cap(&self, a: u32) -> Cap {
        let bits = (self.ramp.add(a as usize) as *const u64).read_unaligned();
        Cap::from_bits(bits, self.rd_tag(a))
    }
    #[inline(always)]
    pub unsafe fn wr_cap(&mut self, a: u32, c: Cap) {
        (self.ramp.add(a as usize) as *mut u64).write_unaligned(c.to_bits());
        *self.tagp.add((a >> 3) as usize) = c.tag as u8;
    }

    // Checked helpers for use outside the core: loaders, devices, debugger.
    pub fn peek32(&self, a: u32) -> u32 {
        if self.in_ram(a, 4) {
            unsafe { self.rd32(a) }
        } else {
            0
        }
    }
    pub fn peek16(&self, a: u32) -> u16 {
        if self.in_ram(a, 2) {
            unsafe { self.rd16(a) }
        } else {
            0
        }
    }
    pub fn peek8(&self, a: u32) -> u8 {
        if self.in_ram(a, 1) {
            unsafe { self.rd8(a) }
        } else {
            0
        }
    }
    pub fn poke32(&mut self, a: u32, v: u32) {
        if self.in_ram(a, 4) {
            unsafe { self.wr32(a, v) }
        }
    }
    pub fn poke8(&mut self, a: u32, v: u8) {
        if self.in_ram(a, 1) {
            unsafe { self.wr8(a, v) }
        }
    }
    pub fn cstr(&self, mut a: u32, max: usize) -> String {
        let mut s = String::new();
        while s.len() < max {
            let c = self.peek8(a);
            if c == 0 {
                break;
            }
            s.push(c as char);
            a = a.wrapping_add(1);
        }
        s
    }

    // ----------------------------------------------------------- tagged memory
    pub fn tag_at(&self, a: u32) -> bool {
        self.in_ram(a, 1) && unsafe { self.rd_tag(a) }
    }

    /// The capability in the granule at `a`, which is 8-byte aligned. Outside
    /// RAM, NULL.
    pub fn load_cap(&self, a: u32) -> Cap {
        if a & 7 != 0 || !self.in_ram(a, 8) {
            return Cap::NULL;
        }
        unsafe { self.rd_cap(a) }
    }

    /// Store a capability, tag and all, into the granule at `a`, which is
    /// 8-byte aligned. Outside RAM, nothing.
    pub fn store_cap(&mut self, a: u32, c: Cap) {
        if a & 7 == 0 && self.in_ram(a, 8) {
            unsafe { self.wr_cap(a, c) }
        }
    }

    /// Clear the tags of every granule `[a, a + n)` touches, within RAM.
    pub fn clear_tags(&mut self, a: u32, n: u32) {
        if n == 0 || a >= self.ramlen {
            return;
        }
        let end = (a as u64 + n as u64).min(self.ramlen as u64);
        let g0 = (a >> 3) as usize;
        let g1 = ((end + 7) >> 3) as usize;
        self.tags[g0..g1].fill(0);
    }

    #[inline(always)]
    pub fn is_mmio(a: u32) -> bool {
        a >= MMIO_BASE && a < MMIO_END
    }

    /// Record a synchronous fault for the outer loop to vector.
    #[inline(never)]
    #[cold]
    pub fn fault(&mut self, cause: u32, tval: u32, epc: u32, fuel: u32) -> Stop {
        self.trap = (cause, tval, epc);
        self.pc = epc;
        self.fuel_left = fuel;
        Stop::Trap
    }

    // ------------------------------------------------------------------ CSRs
    /// Whether code without SR may read CSR `n`: everything but the machine
    /// registers, which leaves the counters.
    pub fn csr_public(n: u32) -> bool {
        !(0x300..=0x3ff).contains(&n) && (n < 0x7c0 || (0xc00..=0xc9f).contains(&n))
    }

    pub fn csr_read(&mut self, n: u32) -> u32 {
        match n {
            CSR_MSTATUS => self.mstatus,
            CSR_MIE => self.mie,
            CSR_MTVEC => self.mtcc.addr,
            CSR_MSCRATCH => self.mscratchc.addr,
            CSR_STKLIM => self.stklim,
            CSR_GCMODE => self.gcmode,
            CSR_MEPC => self.mepcc.addr,
            CSR_MCAUSE => self.mcause,
            CSR_MTVAL => self.mtval,
            CSR_MIP => {
                self.refresh_mip();
                self.mip
            }
            0xB00 | 0xC00 | 0xB02 | 0xC02 => self.now as u32,
            0xB80 | 0xC80 | 0xB82 | 0xC82 => (self.now >> 32) as u32,
            0xF11 => 0x4C4D_0000, // mvendorid: "LM"
            0xF12 => 1,           // marchid
            0xF13 => 1,           // mimpid
            0xF14 => 0,           // mhartid
            _ => 0,
        }
    }

    pub fn csr_write(&mut self, n: u32, v: u32) {
        match n {
            CSR_MSTATUS => {
                self.mstatus = v & (MSTATUS_MIE | MSTATUS_MPIE | (3 << 11));
                let now = self.now;
                self.note_mie(now);
            }
            CSR_MIE => self.mie = v & (MIE_MSIE | MIE_MTIE | MIE_MEIE),
            CSR_MTVEC => self.mtcc = self.mtcc.with_addr(v),
            CSR_MSCRATCH => self.mscratchc = self.mscratchc.with_addr(v),
            CSR_STKLIM => self.stklim = v,
            CSR_GCMODE => self.gcmode = v & 1,
            CSR_MEPC => self.mepcc = self.mepcc.with_addr(v & !1),
            CSR_MCAUSE => self.mcause = v,
            CSR_MTVAL => self.mtval = v,
            // Only the software-interrupt bit is writable by software.
            CSR_MIP => self.mip = (self.mip & !MIE_MSIE) | (v & MIE_MSIE),
            _ => {}
        }
    }

    // ------------------------------------------------------------- interrupts
    /// Fold device state into `mip`.
    pub fn refresh_mip(&mut self) {
        if self.cycles >= self.mtimecmp {
            self.mip |= MIE_MTIE;
        } else {
            self.mip &= !MIE_MTIE;
        }
        if self.intreq & self.intena != 0 {
            self.mip |= MIE_MEIE;
        } else {
            self.mip &= !MIE_MEIE;
        }
    }

    #[inline]
    pub fn irq_ready(&self) -> bool {
        self.mstatus & MSTATUS_MIE != 0 && (self.mie & self.mip) != 0
    }

    /// Whether moving the stack pointer down to `sp` is allowed. The limit
    /// works like the ARMv8-M stack-limit register: a frame allocated below
    /// it faults rather than overwriting the memory underneath.
    ///
    /// Enforced only with interrupts on. Code running with them off (the
    /// trap handler on its own stack, the collector, the kernel's critical
    /// sections) may use the reserve below the limit. Such code can be
    /// entered with the stack nearly full and must run to completion.
    #[inline]
    pub fn stack_ok(&self, sp: u32) -> bool {
        sp >= self.stklim || self.mstatus & MSTATUS_MIE == 0
    }

    /// Take a trap: MEPCC becomes PCC at the faulting address, and PCC
    /// becomes MTCC, at an offset of four bytes per cause for an interrupt
    /// when mtvec's mode is vectored. Interrupt causes carry the top bit.
    pub fn enter_trap(&mut self, cause: u32, tval: u32, epc: u32) {
        if self.trace_traps {
            eprintln!(
                "[trap cause={cause:#x} epc={epc:#x} mtval={tval:#x} mtvec={:#x} mscratch={:#x} sp={:#x} cycles={}]",
                self.mtcc.addr, self.mscratchc.addr, self.x[2], self.cycles
            );
        }
        self.mepcc = self.pcc().with_addr(epc);
        self.mcause = cause;
        self.mtval = tval;
        let was_enabled = (self.mstatus & MSTATUS_MIE) != 0;
        self.mstatus &= !(MSTATUS_MIE | MSTATUS_MPIE);
        if was_enabled {
            self.mstatus |= MSTATUS_MPIE;
            let now = self.cycles;
            self.note_mie(now);
        }
        self.mstatus |= 3 << 11; // MPP = machine
        let tv = self.mtcc.addr;
        let base = tv & !3;
        let target = if tv & 3 == 1 && cause & 0x8000_0000 != 0 {
            base.wrapping_add(4 * (cause & 0x7fff_ffff))
        } else {
            base
        };
        let mtcc = if self.mtcc.otype() == OT_SENTRY { self.mtcc.unseal() } else { self.mtcc };
        self.set_pcc(mtcc.with_addr(target));
    }

    /// `mret`: interrupts as they were, and PCC from MEPCC.
    pub fn trap_return(&mut self) {
        let mpie = (self.mstatus & MSTATUS_MPIE) != 0;
        self.mstatus &= !MSTATUS_MIE;
        if mpie {
            self.mstatus |= MSTATUS_MIE;
        }
        self.mstatus |= MSTATUS_MPIE;
        let now = self.now;
        self.note_mie(now);
        let c = self.mepcc;
        self.set_pcc(if c.otype() == OT_SENTRY { c.unseal() } else { c });
    }

    /// Deliver the highest-priority pending interrupt, if any.
    pub fn take_interrupt(&mut self) -> bool {
        self.refresh_mip();
        if !self.irq_ready() {
            return false;
        }
        let p = self.mie & self.mip;
        // RISC-V priority order: external, then software, then timer.
        let n = if p & MIE_MEIE != 0 {
            IRQ_EXT
        } else if p & MIE_MSIE != 0 {
            IRQ_SOFT
        } else {
            IRQ_TIMER
        };
        let pc = self.pc;
        self.enter_trap(0x8000_0000 | n, 0, pc);
        true
    }

    pub fn raise(&mut self, line: u32) {
        self.intreq |= 1 << line;
    }
    pub fn lower(&mut self, line: u32) {
        self.intreq &= !(1 << line);
    }

    pub fn next_rand(&mut self) -> u32 {
        let mut x = self.rng;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.rng = x;
        (x.wrapping_mul(0x2545_F491_4F6C_DD1D) >> 32) as u32
    }

    /// Bring `now` up to date. Called from the cold paths that can observe
    /// the clock: a CSR read of the cycle counter, and any device access.
    #[inline(always)]
    pub fn tick(&mut self, fuel: u32) {
        self.now = self.cycles + (self.fuel_start - fuel) as u64;
    }

    /// The interrupt-enable bit may have changed: keep the pause meter up
    /// to date. `now` is the current cycle.
    pub fn note_mie(&mut self, now: u64) {
        if self.mstatus & MSTATUS_MIE != 0 {
            if self.mie_off_at != u64::MAX {
                let stretch = now.saturating_sub(self.mie_off_at);
                if stretch > self.pause_max {
                    self.pause_max = stretch;
                }
                if stretch > PAUSE_LONG {
                    self.pause_long += 1;
                    if self.trace_pauses {
                        eprintln!(
                            "[interrupts were off for {stretch} instructions, ending at pc {:#x} in {}]",
                            self.pc,
                            crate::cpu::watch_backtrace(self)
                        );
                    }
                }
            }
            // Off again from the next disable; and a machine that has never
            // enabled interrupts is still booting.
            self.mie_off_at = u64::MAX - 1;
        } else if self.mie_off_at == u64::MAX - 1 {
            self.mie_off_at = now;
        }
    }

    /// The write barrier's question for a store of `sz` bytes at `a` through
    /// register `who`, or DDC, asked only while it is on: the address of a
    /// granule the store touches that holds a capability to an unmarked heap
    /// object, if there is one and the store is not into a stack or a
    /// context. That is asked first, being two loads, where finding the
    /// object a capability keeps can be a walk of the object-start map.
    #[inline(never)]
    pub fn barrier_hit(&self, a: u32, sz: u32, who: u32) -> Option<u32> {
        let first = a & !7;
        let last = a.wrapping_add(sz - 1) & !7;
        for g in [first, last] {
            if g < CONS_BASE || g >= OBJ_END || !unsafe { self.rd_tag(g) } {
                continue;
            }
            if self.in_state(g, who) {
                continue;
            }
            let old = unsafe { self.rd_cap(g) };
            if let Some(obj) = self.referent(old) {
                let bit = (obj - CONS_BASE) >> 3;
                let word = unsafe { self.rd32(GC_BITMAP + ((bit >> 5) << 2)) };
                if word & (1 << (bit & 31)) == 0 {
                    return Some(g);
                }
            }
        }
        None
    }

    /// Whether a store through register `who` into the granule at `g` is a
    /// store into a stack or a register context: whether the authority is
    /// based at the payload of one, as every stack pointer, frame pointer
    /// and context capability is, and the granule lies in that payload. The
    /// granule below the base must be an object start, a header the
    /// allocator wrote, and not a slot that happens to hold its number.
    fn in_state(&self, g: u32, who: u32) -> bool {
        let base = if who == CAPEX_REG_DDC {
            self.ddc.base()
        } else if self.xm[who as usize] & XM_READY != 0 {
            self.wb[who as usize]
        } else {
            self.reg(who).base()
        };
        if base <= OBJ_BASE || base > OBJ_END {
            return false;
        }
        let h = base - 8;
        let i = (h - OBJ_BASE) >> 3;
        let starts = unsafe { self.rd32(OBJ_STARTS + ((i >> 5) << 2)) };
        let hdr = unsafe { self.rd32(h) };
        starts & (1 << (i & 31)) != 0
            && crate::heap::is_state_type(crate::heap::hdr_type(hdr))
            && g < base + crate::heap::bounds_bytes(hdr)
    }

    /// The heap block a tagged capability keeps alive, as the address its
    /// mark bit belongs to: the block its base lies in. One without HD based
    /// in cons space keeps the pair at its base rounded down to sixteen,
    /// whatever its length. One based in object space, headed or not, keeps
    /// the block whose header is the nearest object start at or below the
    /// granule before its base: for an object's own capability that is its
    /// header, and a capability narrowed into a payload, or to nothing at its
    /// end, keeps the object it was cut from.
    pub fn referent(&self, c: Cap) -> Option<u32> {
        if !c.tag {
            return None;
        }
        let b = c.base();
        if (CONS_BASE..CONS_END).contains(&b) {
            (!c.has(P_HD)).then_some(b & !15)
        } else if b > OBJ_BASE && b <= OBJ_END {
            self.object_start(b - 8)
        } else {
            None
        }
    }

    /// The nearest object start at or below `a`, in object space.
    pub fn object_start(&self, a: u32) -> Option<u32> {
        let i = (a - OBJ_BASE) >> 3;
        let mut w = i >> 5;
        let mut bits = unsafe { self.rd32(OBJ_STARTS + (w << 2)) };
        let k = i & 31;
        if k < 31 {
            bits &= (2u32 << k) - 1;
        }
        loop {
            if bits != 0 {
                return Some(OBJ_BASE + (((w << 5) + 31 - bits.leading_zeros()) << 3));
            }
            if w == 0 {
                return None;
            }
            w -= 1;
            bits = unsafe { self.rd32(OBJ_STARTS + (w << 2)) };
        }
    }

    /// Number of instructions until the timer fires, saturating.
    pub fn fuel_to_timer(&self) -> u64 {
        self.mtimecmp.saturating_sub(self.cycles)
    }
}

/// The heap object a pair or headed capability refers to, as the address its
/// mark bit belongs to: a pair's base, or an object's header. None for
/// anything else, a run, a code entry, a stack, a device. What the barrier
/// asks is wider: see `Machine::referent`.
pub fn heap_object(c: Cap) -> Option<u32> {
    if !c.tag {
        return None;
    }
    let (b, t) = c.bounds();
    if c.has(P_HD) {
        let h = b.wrapping_sub(8);
        (b >= 8 && (OBJ_BASE..OBJ_END).contains(&h)).then_some(h)
    } else {
        ((CONS_BASE..CONS_END).contains(&b) && t == b as u64 + 16).then_some(b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The window made in place for a small exact capability is the one the
    /// full decode gives, whatever the capability and wherever its address.
    #[test]
    fn windows_made_in_place_match_the_decode() {
        let mut m = Machine::new();
        let mut x = 0x2545_f491_4f6c_dd1du64;
        let mut next = move || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 16) as u32
        };
        for _ in 0..200_000 {
            let base = next() & (RAM_SIZE - 1) & !7;
            let len = next() % 600;
            let Some(c) = Cap::ROOT.with_addr(base).with_bounds(len) else { continue };
            let c = c.with_addr(c.base().wrapping_add(next() % (len + 16)).wrapping_sub(8));
            m.set_reg(10, c);
            m.fill_window(10);
            let want = ram_window(c, m.ramlen);
            let got = (m.wb[10], m.wl[10]);
            assert!(got == want || (got.1 == 0 && want.1 == 0), "{c:x?}: {got:x?} against {want:x?}");
        }
    }
}
