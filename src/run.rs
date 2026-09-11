//! The outer loop. It hands the threaded core a quantum of fuel bounded by the
//! next thing that wants attention - a timer compare, a vertical blank, or a
//! host service interval - so interrupts land on an exact cycle and the whole
//! machine stays reproducible.

use crate::cpu;
use crate::dev::gfx::{CTRL_VBIRQ, VBL_HZ};
use crate::dev::TIMER_HZ;
use crate::mach::*;
use crate::map::*;

/// How long the core may run before the host gets a look in.
const HOST_SLICE: u64 = 200_000;

pub fn vbl_period() -> u64 {
    TIMER_HZ as u64 / VBL_HZ
}

/// Fold host-side device state into the interrupt request register.
pub fn service(m: &mut Machine) {
    m.uart.poll();
    if m.uart.rx_ready() && m.uart.ctrl & 1 != 0 {
        m.raise(INT_UART);
    } else if !m.uart.rx_ready() {
        m.lower(INT_UART);
    }
    if m.input.pending() && m.input.ctrl & 1 != 0 {
        m.raise(INT_INPUT);
    } else if !m.input.pending() {
        m.lower(INT_INPUT);
    }
}

fn vblank(m: &mut Machine) {
    m.gfx.vcount = m.gfx.vcount.wrapping_add(1);
    m.gfx.next_vbl = m.gfx.next_vbl.wrapping_add(vbl_period());
    // Catch up if the host stalled us badly.
    if m.gfx.next_vbl <= m.cycles {
        m.gfx.next_vbl = m.cycles + vbl_period();
    }
    let open = {
        // Split the borrow of gfx from the borrow of ram.
        let ramp = m.ramp;
        let len = m.ramlen as usize;
        let ram = unsafe { std::slice::from_raw_parts(ramp, len) };
        let gfx = &mut m.gfx as *mut crate::dev::gfx::Gfx;
        let input = &mut m.input as *mut crate::dev::input::Input;
        unsafe { (*gfx).present(ram, &mut *input) }
    };
    if !open {
        m.halted = true;
    }
    if m.gfx.ctrl & CTRL_VBIRQ != 0 {
        m.raise(INT_VBLANK);
    }
}

/// Nothing to run: skip forward to whatever wakes us next.
fn idle(m: &mut Machine) {
    // A running blit or disk command is an event too: an idle machine
    // fast-forwards to it rather than past it.
    let mut wake = m.gfx.next_vbl.min(m.mtimecmp).min(crate::dev::due(m));
    if m.intreq & m.intena != 0 {
        return; // an interrupt is already waiting
    }
    if wake == u64::MAX {
        // No scheduled event at all. Only the host can break the tie, so give
        // the CPU back rather than melting it.
        std::thread::sleep(std::time::Duration::from_millis(1));
        service(m);
        wake = m.cycles + 10_000;
    }
    if wake > m.cycles {
        if m.gfx.win.is_some() {
            pace(m, wake);
        }
        m.cycles = wake;
    }
}

/// Keep a machine with a window in step with the wall clock while it idles.
///
/// A machine waiting for its next frame should wait for it. Without this an
/// idle workbench ran its sixty frames a second as fast as the host could go -
/// hundreds of machine seconds a second, every animation and every allocation
/// done a hundred times over - and the window showed whichever frame it
/// happened to catch.
///
/// Only idle time is paced. A busy machine runs as fast as the host can take
/// it, and when it next idles it is lined up with the wall clock afresh rather
/// than made to wait for the time it got ahead. Nothing here touches the
/// machine's own clock, so a run is exactly as deterministic as it was: only
/// the wall clock waits.
fn pace(m: &mut Machine, wake: u64) {
    use std::time::{Duration, Instant};
    let now = Instant::now();
    let hz = TIMER_HZ as f64;
    let (mut at, mut base) = m.pace.unwrap_or((now, m.cycles));
    // Where the machine's clock stands against the wall clock. More than a
    // few frames either way - a long computation, the host looking elsewhere -
    // and the two are lined up again, not one made to catch the other up.
    let lead = (m.cycles - base) as f64 / hz - now.duration_since(at).as_secs_f64();
    if lead.abs() > 0.05 {
        at = now;
        base = m.cycles;
    }
    m.pace = Some((at, base));
    let due = at + Duration::from_secs_f64((wake - base) as f64 / hz);
    if due > now {
        let t = Instant::now();
        std::thread::sleep((due - now).min(Duration::from_millis(50)));
        m.slept += t.elapsed().as_secs_f64();
    }
}

pub fn run(m: &mut Machine, budget: u64) -> Stop {
    let mut left = budget;
    loop {
        if m.halted {
            m.uart.flush();
            return Stop::Halt;
        }
        if m.cycles >= m.gfx.next_vbl {
            vblank(m);
            continue;
        }
        service(m);
        // The blitter and the disk finish on their own schedule, and this is
        // the moment after every slice at which the machine looks.
        let now = m.cycles;
        crate::dev::poll(m, now);
        m.refresh_mip();
        if m.irq_ready() {
            m.take_interrupt();
        }

        let q = HOST_SLICE
            .min(left)
            .min(m.fuel_to_timer().max(1))
            // End the slice when a running blit or disk command is due, so
            // that it lands on time rather than whenever the next timer
            // happens to come round.
            .min(crate::dev::due(m).saturating_sub(m.cycles).max(1))
            .min(m.gfx.next_vbl.saturating_sub(m.cycles).max(1))
            .min(u32::MAX as u64) as u32;
        if q == 0 {
            return Stop::Fuel;
        }

        let pc = m.pc;
        m.fuel_left = q;
        m.fuel_start = q;
        m.now = m.cycles;
        let st = cpu::run_block(m, pc, q);
        let used = (q - m.fuel_left) as u64;
        m.cycles = m.cycles.wrapping_add(used);
        m.executed += used;
        left = left.saturating_sub(used);
        // And again as soon as the clock has moved, not only at the top of the
        // next round: a run that ends here - its budget spent, or halted -
        // would otherwise stop with a transfer that was due before now never
        // having landed. The state of the machine at the moment it stops has
        // to include everything that finished before that moment.
        let now = m.cycles;
        crate::dev::poll(m, now);

        match st {
            Stop::Fuel => {}
            Stop::Trap => {
                let (c, t, e) = m.trap;
                m.enter_trap(c, t, e);
                // Taking a trap costs a cycle. The faulting instruction
                // retired nothing, so without this a handler that faults on
                // its own first instruction makes no progress at all and the
                // outer loop spins on a budget that never goes down.
                m.cycles = m.cycles.wrapping_add(1);
                left = left.saturating_sub(1);
            }
            Stop::Wfi => idle(m),
            Stop::Halt => {
                m.uart.flush();
                return Stop::Halt;
            }
        }
        if left == 0 {
            return Stop::Fuel;
        }
    }
}

/// Human-readable trap description, for the debugger and for panics.
pub fn cause_name(c: u32) -> &'static str {
    if c & 0x8000_0000 != 0 {
        return match c & 0xff {
            IRQ_SOFT => "software interrupt",
            IRQ_TIMER => "timer interrupt",
            IRQ_EXT => "external interrupt",
            _ => "interrupt",
        };
    }
    match c {
        C_IALIGN => "misaligned fetch",
        C_IFAULT => "instruction access fault",
        C_ILLEGAL => "illegal instruction",
        C_BREAK => "breakpoint",
        C_LALIGN => "misaligned load",
        C_LFAULT => "load access fault",
        C_SALIGN => "misaligned store",
        C_SFAULT => "store access fault",
        C_ECALL => "ecall",
        C_TYPE => "wrong type",
        C_RANGE => "index out of range",
        C_OVER => "fixnum overflow",
        C_DIVZERO => "division by zero",
        C_STACK => "stack overflow",
        _ => "trap",
    }
}
