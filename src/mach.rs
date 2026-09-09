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
/// Wrong type handed to an instruction that checks one. RISC-V leaves causes
/// 24 through 31 to the implementation, which is where a machine that knows
/// what a pair is should put this. `mtval` carries the offending value.
pub const C_TYPE: u32 = 24;
/// An index outside the object it was applied to. `mtval` carries the index.
pub const C_RANGE: u32 = 25;

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
    /// wfi: idle until an interrupt shows up.
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
    pub mepc: u32,
    pub mcause: u32,
    pub mtval: u32,

    /// Retired instruction count. Doubles as the machine timebase, which makes
    /// the whole system deterministic: same image, same schedule, every run.
    pub cycles: u64,
    pub trap: (u32, u32, u32), // cause, tval, epc

    /// Dynamic instruction histogram. Slots 0..63 are dispatch tokens; the
    /// rest break down what a token alone cannot say. See `prof::NAMES`.
    #[cfg(feature = "isaprof")]
    pub prof: Box<[u64; crate::prof::SLOTS]>,

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
            mepc: 0,
            mcause: 0,
            mtval: 0,
            cycles: 0,
            trap: (0, 0, 0),
            #[cfg(feature = "isaprof")]
            prof: Box::new([0; crate::prof::SLOTS]),
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
        // Written as a subtraction rather than `a + sz <= ramlen`, because
        // that addition wraps for an address near the top of the space and
        // would then wave through a load at, say, 0xFFFFFFFF - which is a
        // segfault in the host, not a fault in the guest. `ramlen` is far
        // larger than any access size, so this subtraction cannot underflow.
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
            0x300 => self.mstatus = v & (MSTATUS_MIE | MSTATUS_MPIE | (3 << 11)),
            0x304 => self.mie = v & (MIE_MSIE | MIE_MTIE | MIE_MEIE),
            0x305 => self.mtvec = v,
            0x340 => self.mscratch = v,
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

    /// Number of instructions until the timer fires, saturating.
    pub fn fuel_to_timer(&self) -> u64 {
        self.mtimecmp.saturating_sub(self.cycles)
    }
}
