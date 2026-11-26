//! Custom chips. Every device is a 4 KiB page in the MMIO window and every
//! register is a naturally-aligned 32-bit word, but for the three capability
//! registers: the blitter's list register, the disk's buffer register and
//! the display's scan-out register, each 8 bytes at the start of its page,
//! written with a capability store. A chip that reaches memory is handed
//! capabilities, never numbers, and refuses what its capability does not
//! cover.

pub mod blit;
pub mod boxfilter;
pub mod disk;
pub mod gfx;
pub mod input;
pub mod uart;
pub mod win;

use crate::cap::*;
use crate::mach::*;
use crate::map::*;

/// A register as the Lisp side names it, from which `lmforge layout`
/// generates its accessors (lisp/devices.lisp): its name, its offset, whether
/// a load reads it and a store writes it, and whether it holds a capability,
/// which is moved with a capability load or store.
pub struct Reg {
    pub name: &'static str,
    pub off: u32,
    pub read: bool,
    pub write: bool,
    pub cap: bool,
}

/// A word register that loads and stores, one that only loads, and one that
/// only stores.
pub const fn rw(name: &'static str, off: u32) -> Reg {
    Reg { name, off, read: true, write: true, cap: false }
}
pub const fn ro(name: &'static str, off: u32) -> Reg {
    Reg { name, off, read: true, write: false, cap: false }
}
pub const fn wo(name: &'static str, off: u32) -> Reg {
    Reg { name, off, read: false, write: true, cap: false }
}

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
/// w: the processor starts again at the reset vector with the root in PCC,
/// as from power-on, with memory and the chips as they are.
pub const SYS_RESET: u32 = 0x2c;

// ----------------------------------------------------------- TIMER registers
pub const TMR_LO: u32 = 0x00; // r: mtime low  (== retired instructions)
pub const TMR_HI: u32 = 0x04;
pub const TMR_CMPLO: u32 = 0x08; // rw: mtimecmp
pub const TMR_CMPHI: u32 = 0x0c;
pub const TMR_FREQ: u32 = 0x10; // r: ticks per second
pub const TMR_WALL: u32 = 0x14; // r: host milliseconds since boot

/// The machine's clock: a 200 MHz part. The timebase is the retired
/// instruction count, so this is how many instructions the system calls one
/// second, and the vertical blank, the timer and the chips' costs are all
/// counted against it.
pub const TIMER_HZ: u32 = 200_000_000;

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
            // A status read is a point at which the transfer can have finished.
            if reg == blit::B_STATUS {
                let now = m.now;
                blit::poll(m, now);
            }
            m.blit.read(reg)
        }
        DEV_DISK => {
            // A status read is a point at which the command can have finished.
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
    // Sub-word writes are only meaningful for the byte-oriented ports; every
    // other register takes the low lane.
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
                if !m.uart.mute {
                    let _ = std::io::stderr().write_all(&b);
                }
            }
            SYS_INTREQ => m.intreq &= !v,
            SYS_INTENA => m.intena = v,
            SYS_INTSET => m.intreq |= v,
            SYS_RESET => m.reset_asked = true,
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

/// Whether the register at `a` is a capability register. A capability store
/// to any other faults.
pub fn takes_cap(a: u32) -> bool {
    let reg = a & 0xfff;
    match dev_of(a) {
        DEV_BLIT => reg == blit::B_LIST,
        DEV_DISK => reg == disk::D_BUF,
        DEV_GFX => reg == gfx::G_BASE,
        _ => false,
    }
}

/// Whether the register at `a` hands back the capability it holds to a
/// capability load, so that the collector can keep alive what a chip is
/// still using: the display's scan-out register, which holds its bitmap for
/// as long as it shows it, and the blitter's list register, which holds the
/// descriptor the chip is working on, and through it its ring and the
/// chain linked after it. A ring is anybody's to let go of while its blits
/// are in flight. The disk holds its buffer only for a command, whose
/// caller is blocked holding it, and hands nothing back.
pub fn gives_cap(a: u32) -> bool {
    let reg = a & 0xfff;
    match dev_of(a) {
        DEV_GFX => reg == gfx::G_BASE,
        DEV_BLIT => reg == blit::B_LIST,
        _ => false,
    }
}

/// A capability load from a register `gives_cap` allows, through `auth`,
/// the page's capability, as `LY` loads one.
pub fn read_cap(m: &Machine, a: u32, auth: Cap) -> Cap {
    let held = match dev_of(a) {
        DEV_GFX => m.gfx.base,
        DEV_BLIT if m.blit.busy => m.blit.block,
        _ => Cap::NULL,
    };
    loaded_through(held, auth)
}

/// A capability store to a capability register.
pub fn write_cap(m: &mut Machine, a: u32, c: Cap) {
    match dev_of(a) {
        DEV_BLIT => blit::start_chain(m, c),
        DEV_DISK => m.disk.buf = c,
        DEV_GFX => m.gfx.write_cap(c),
        _ => {}
    }
}

/// The capability in the granule at `a` as a chip loads it through `auth`,
/// the way `LY` does: without LC in `auth` the tag is dropped, and without
/// LM a tagged, unsealed capability loses SD, SC and LM.
pub fn load_through(m: &Machine, auth: Cap, a: u32) -> Cap {
    loaded_through(m.load_cap(a), auth)
}

/// `c` as a load through `auth` leaves it, by `LY`'s rule.
pub fn loaded_through(c: Cap, auth: Cap) -> Cap {
    if !c.tag {
        c
    } else if !auth.has(P_LC) {
        c.without_tag()
    } else if !auth.has(P_LM) && !c.is_sealed() {
        c.strip(P_SD | P_SC | P_LM)
    } else {
        c
    }
}

/// Why a chip refused a transfer: the check a capability failed, numbered
/// as ISAv9 numbers its capability faults. A chip says which in its status.
pub const REFUSE_LENGTH: u32 = 0x01;
pub const REFUSE_TAG: u32 = 0x02;
pub const REFUSE_SEAL: u32 = 0x03;
pub const REFUSE_LOAD: u32 = 0x12;
pub const REFUSE_STORE: u32 = 0x13;

/// Why a chip may not move the `len` bytes from `at` through `c`, as a
/// `REFUSE_*` code: `c` must be tagged, unsealed and hold every permission
/// in `perms` (each with the code its absence is reported as), and the
/// bytes must lie inside its bounds and in RAM. None if `c` allows it.
pub fn refusal(m: &Machine, c: Cap, perms: &[(u32, u32)], at: u64, len: u64) -> Option<u32> {
    if !c.tag {
        return Some(REFUSE_TAG);
    }
    if c.is_sealed() {
        return Some(REFUSE_SEAL);
    }
    if let Some(&(_, code)) = perms.iter().find(|&&(p, _)| !c.has(p)) {
        return Some(code);
    }
    let (base, top) = c.bounds();
    let end = at.saturating_add(len);
    if at < base as u64 || end > top || end > m.ramlen as u64 {
        return Some(REFUSE_LENGTH);
    }
    None
}

/// Finish whatever the asynchronous chips (the blitter and the disk) have
/// finished by `now`.
pub fn poll(m: &mut Machine, now: u64) {
    blit::poll(m, now);
    disk::poll(m, now);
}

/// The next moment either chip finishes, or never.
pub fn due(m: &Machine) -> u64 {
    blit::due(m).min(disk::due(m))
}
