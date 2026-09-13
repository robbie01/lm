//! The machine: register file, physical memory, CSRs, trap entry, and the
//! outer scheduling loop that hands fuel to the token-threaded core.

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
/// Wrong type handed to an instruction that checks one. RISC-V reserves
/// causes 24 through 31 for the implementation. `mtval` carries the
/// offending value.
pub const C_TYPE: u32 = 24;
/// An index outside the object it was applied to. `mtval` carries the index.
pub const C_RANGE: u32 = 25;
/// A fixnum result that does not fit in thirty-one bits. `+`, `-` and `*` emit
/// the trapping forms; the handler widens the operation to a bignum and
/// resumes after the instruction.
pub const C_OVER: u32 = 26;
/// Division by zero in a checked fixnum instruction. The base ISA's own
/// division returns -1; the fixnum forms trap instead.
pub const C_DIVZERO: u32 = 27;
/// The stack pointer was moved below `stklim`. mtval holds where it would have
/// gone; sp itself is left as it was.
pub const C_STACK: u32 = 28;
/// The write barrier. With bit 0 of `gcmode` set, a checked store (`sref`,
/// `sobj`, `stx`, `stxi`) that would overwrite a heap pointer whose mark bit
/// is clear traps before writing. `mtval` carries the pointer being
/// overwritten; the handler marks it and the store re-executes. This is what
/// lets the collector mark while everything else runs: nothing reachable
/// when marking began can be lost, because the last pointer to it cannot
/// be overwritten without the collector seeing it first.
pub const C_BARRIER: u32 = 29;
/// A custom CSR: the lowest address the stack pointer may be moved down to.
/// Zero means no limit.
pub const CSR_STKLIM: u32 = 0x7c0;
/// A custom CSR: bit 0 turns the write barrier on. The mark bits it consults
/// are one per eight bytes of heap, from `CONS_BASE`, at `GC_BITMAP`.
pub const CSR_GCMODE: u32 = 0x7c1;
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

pub struct Machine {
    pub x: [u32; 32],
    pub pc: u32,
    ram: Box<[u8]>,
    /// Raw view of `ram` so the hot path skips the slice length load.
    pub ramp: *mut u8,
    pub ramlen: u32,

    // --- control and status ---
    pub mstatus: u32,
    pub mie: u32,
    pub mip: u32,
    pub mtvec: u32,
    pub mscratch: u32,
    pub stklim: u32,
    pub gcmode: u32,
    pub mepc: u32,
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
    /// rest break down what a token alone cannot say. See `prof::NAMES`.
    /// Always present, filled only when `prof_on` is set by `--isaprof`, so
    /// profiling needs no separate build.
    pub prof: Box<[u64; crate::prof::SLOTS]>,
    pub watch: Box<crate::prof::Watch>,
    pub prof_on: bool,
    /// Samples of which function the machine is in, taken only with
    /// `--fnprof`. See `prof::FnProf`.
    pub fnprof: Option<Box<crate::prof::FnProf>>,
    /// Which dispatch table the core is using: the plain one, or the
    /// counting one.
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

impl Machine {
    pub fn new() -> Box<Machine> {
        let mut ram = vec![0u8; RAM_SIZE as usize].into_boxed_slice();
        let ramp = ram.as_mut_ptr();
        Box::new(Machine {
            x: [0; 32],
            pc: KICK_BASE,
            ram,
            ramp,
            ramlen: RAM_SIZE,
            mstatus: 0,
            mie: 0,
            mip: 0,
            mtvec: 0,
            mscratch: 0,
            stklim: 0,
            gcmode: 0,
            mepc: 0,
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
        })
    }

    pub fn ram(&self) -> &[u8] {
        &self.ram
    }
    pub fn ram_mut(&mut self) -> &mut [u8] {
        &mut self.ram
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
    #[inline(always)]
    pub unsafe fn wr8(&mut self, a: u32, v: u8) {
        *self.ramp.add(a as usize) = v;
    }
    #[inline(always)]
    pub unsafe fn wr16(&mut self, a: u32, v: u16) {
        (self.ramp.add(a as usize) as *mut u16).write_unaligned(v);
    }
    #[inline(always)]
    pub unsafe fn wr32(&mut self, a: u32, v: u32) {
        (self.ramp.add(a as usize) as *mut u32).write_unaligned(v);
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

    #[inline(always)]
    pub fn is_mmio(a: u32) -> bool {
        a >= MMIO_BASE && a < MMIO_END
    }

    /// Record a synchronous fault for the outer loop to vector.
    #[inline(never)]
    #[cold]
    pub fn fault(&mut self, cause: u32, tval: u32, epc: u32, fuel: u32) -> Stop {
        if self.prof_on {
            self.watch.new_block();
        }
        self.trap = (cause, tval, epc);
        self.pc = epc;
        self.fuel_left = fuel;
        Stop::Trap
    }

    // ------------------------------------------------------------------ CSRs
    pub fn csr_read(&mut self, n: u32) -> u32 {
        match n {
            0x300 => self.mstatus,
            0x304 => self.mie,
            0x305 => self.mtvec,
            0x340 => self.mscratch,
            CSR_STKLIM => self.stklim,
            CSR_GCMODE => self.gcmode,
            0x341 => self.mepc,
            0x342 => self.mcause,
            0x343 => self.mtval,
            0x344 => {
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
            0x300 => {
                self.mstatus = v & (MSTATUS_MIE | MSTATUS_MPIE | (3 << 11));
                let now = self.now;
                self.note_mie(now);
            }
            0x304 => self.mie = v & (MIE_MSIE | MIE_MTIE | MIE_MEIE),
            0x305 => self.mtvec = v,
            0x340 => self.mscratch = v,
            CSR_STKLIM => self.stklim = v,
            CSR_GCMODE => self.gcmode = v & 1,
            0x341 => self.mepc = v & !1,
            0x342 => self.mcause = v,
            0x343 => self.mtval = v,
            // Only the software-interrupt bit is writable by software.
            0x344 => self.mip = (self.mip & !MIE_MSIE) | (v & MIE_MSIE),
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

    /// Vector to `mtvec`. Interrupt causes carry the top bit.
    pub fn enter_trap(&mut self, cause: u32, tval: u32, epc: u32) {
        if self.trace_traps {
            eprintln!(
                "[trap cause={cause:#x} epc={epc:#x} mtval={tval:#x} mtvec={:#x}                  mscratch={:#x} sp={:#x} cycles={}]",
                self.mtvec, self.mscratch, self.x[2], self.cycles
            );
        }
        self.mepc = epc;
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
        let base = self.mtvec & !3;
        self.pc = if self.mtvec & 3 == 1 && cause & 0x8000_0000 != 0 {
            base.wrapping_add(4 * (cause & 0x7fff_ffff))
        } else {
            base
        };
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

    /// Whether a checked store at `a` must trap first: the barrier is on and
    /// the word there is an unmarked heap pointer. Answers the pointer.
    #[inline(always)]
    pub fn barrier_hit(&self, a: u32) -> Option<u32> {
        if self.gcmode & 1 == 0 {
            return None;
        }
        let old = unsafe { self.rd32(a) };
        // A pair (tag 0, not nil) or an object (tag 4), inside the heap.
        let tag = old & 7;
        if (tag != 0 && tag != 4) || old < CONS_BASE || old >= OBJ_END {
            return None;
        }
        // An object's bit is at its header, four bytes below the pointer;
        // the shift lands on the same bit either way.
        let bit = (old - CONS_BASE) >> 3;
        let word = unsafe { self.rd32(GC_BITMAP + ((bit >> 5) << 2)) };
        if word & (1 << (bit & 31)) == 0 {
            Some(old)
        } else {
            None
        }
    }

    /// Number of instructions until the timer fires, saturating.
    pub fn fuel_to_timer(&self) -> u64 {
        self.mtimecmp.saturating_sub(self.cycles)
    }
}
