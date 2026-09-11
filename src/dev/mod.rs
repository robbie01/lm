//! Custom chips. Every device is a 4 KiB page in the MMIO window and every
//! register is a naturally-aligned 32-bit word, so the Lisp side can talk to
//! hardware with plain `poke`/`peek` and no bit-fiddling in the compiler.

pub mod blit;
pub mod disk;
pub mod gfx;
pub mod input;
pub mod uart;
pub mod win;

use crate::mach::Machine;
use crate::map::*;

// ------------------------------------------------------------- SYS registers
pub const SYS_HALT: u32 = 0x00; // w: power down, value becomes the exit code
pub const SYS_DEBUG: u32 = 0x04; // w: byte straight to the host's stderr
pub const SYS_INTREQ: u32 = 0x08; // r: pending lines; w: write-1-to-clear
pub const SYS_INTENA: u32 = 0x0c; // rw: enabled lines
pub const SYS_INTNUM: u32 = 0x10; // r: lowest pending-and-enabled line, else -1
pub const SYS_CYCLO: u32 = 0x14;
pub const SYS_CYCHI: u32 = 0x18;
pub const SYS_RANDOM: u32 = 0x1c;
pub const SYS_RAMSIZE: u32 = 0x20;
pub const SYS_CHIPSIZE: u32 = 0x24;
pub const SYS_INTSET: u32 = 0x28; // w: raise a line from software (Cause)

// ----------------------------------------------------------- TIMER registers
pub const TMR_LO: u32 = 0x00; // r: mtime low  (== retired instructions)
pub const TMR_HI: u32 = 0x04;
pub const TMR_CMPLO: u32 = 0x08; // rw: mtimecmp
pub const TMR_CMPHI: u32 = 0x0c;
pub const TMR_FREQ: u32 = 0x10; // r: ticks per second
pub const TMR_WALL: u32 = 0x14; // r: host milliseconds since boot

/// Nominal clock. The timebase is the retired-instruction count, so this is
/// how many instructions the system calls "one second".
pub const TIMER_HZ: u32 = 20_000_000;

#[inline(never)]
pub fn read(m: &mut Machine, a: u32, f: u32) -> u32 {
    let dev = dev_of(a);
    let reg = a & 0xffc;
    let v = match dev {
        DEV_SYS => match reg {
            SYS_INTREQ => m.intreq,
            SYS_INTENA => m.intena,
            SYS_INTNUM => {
                let p = m.intreq & m.intena;
                if p == 0 {
                    u32::MAX
                } else {
                    p.trailing_zeros()
                }
            }
            SYS_CYCLO => m.now as u32,
            SYS_CYCHI => (m.now >> 32) as u32,
            SYS_RANDOM => m.next_rand(),
            SYS_RAMSIZE => RAM_SIZE,
            SYS_CHIPSIZE => CHIP_SIZE,
            _ => 0,
        },
        DEV_UART => m.uart.read(reg),
        DEV_TIMER => match reg {
            TMR_LO => m.now as u32,
            TMR_HI => (m.now >> 32) as u32,
            TMR_CMPLO => m.mtimecmp as u32,
            TMR_CMPHI => (m.mtimecmp >> 32) as u32,
            TMR_FREQ => TIMER_HZ,
            TMR_WALL => m.gfx.wall_ms(),
            _ => 0,
        },
        DEV_GFX => m.gfx.read(reg),
        DEV_INPUT => m.input.read(reg),
        DEV_BLIT => {
            // A look at the chip is a moment at which it can have finished.
            if reg == blit::B_STATUS {
                let now = m.now;
                blit::poll(m, now);
            }
            m.blit.read(reg)
        }
        DEV_DISK => {
            // The same for the disk: looking is a moment it can have finished.
            if reg == disk::D_STATUS {
                let now = m.now;
                disk::poll(m, now);
            }
            m.disk.read(reg)
        }
        _ => 0,
    };
    // Sub-word reads pick the requested lane out of the register value.
    match f {
        0 => (v >> ((a & 3) * 8)) as u8 as i8 as i32 as u32,
        4 => (v >> ((a & 3) * 8)) as u8 as u32,
        1 => (v >> ((a & 2) * 8)) as u16 as i16 as i32 as u32,
        5 => (v >> ((a & 2) * 8)) as u16 as u32,
        _ => v,
    }
}

#[inline(never)]
pub fn write(m: &mut Machine, a: u32, f: u32, v: u32) {
    let dev = dev_of(a);
    let reg = a & 0xffc;
    // Sub-word writes are only meaningful for the byte-oriented ports; for
    // everything else the low lane is what counts.
    let v = match f {
        0 => v & 0xff,
        1 => v & 0xffff,
        _ => v,
    };
    match dev {
        DEV_SYS => match reg {
            SYS_HALT => {
                m.halted = true;
                m.exit_code = v;
            }
            SYS_DEBUG => {
                use std::io::Write;
                let b = [v as u8];
                let _ = std::io::stderr().write_all(&b);
            }
            SYS_INTREQ => m.intreq &= !v,
            SYS_INTENA => m.intena = v,
            SYS_INTSET => m.intreq |= v,
            _ => {}
        },
        DEV_UART => m.uart.write(reg, v),
        DEV_TIMER => match reg {
            TMR_CMPLO => m.mtimecmp = (m.mtimecmp & !0xffff_ffff) | v as u64,
            TMR_CMPHI => m.mtimecmp = (m.mtimecmp & 0xffff_ffff) | ((v as u64) << 32),
            _ => {}
        },
        DEV_GFX => m.gfx.write(reg, v),
        DEV_INPUT => m.input.write(reg, v),
        DEV_BLIT => blit::command(m, reg, v),
        DEV_DISK => disk::command(m, reg, v),
        _ => {}
    }
}

/// Finish whatever the chips that work on their own time - the blitter and
/// the disk - have finished by `now`.
pub fn poll(m: &mut Machine, now: u64) {
    blit::poll(m, now);
    disk::poll(m, now);
}

/// The next moment one of them finishes, or never.
pub fn due(m: &Machine) -> u64 {
    blit::due(m).min(disk::due(m))
}
