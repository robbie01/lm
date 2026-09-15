//! Booting an image: load it, attach the peripherals, run.

use crate::dev::win::Host;
use crate::image;
use crate::mach::{Machine, Stop};
use crate::run;

pub struct Options {
    pub image: String,
    /// The window's size, in multiples of the display's; see `boot_in_window`.
    pub scale: u32,
    pub script: Option<String>,
    pub interactive: bool,
    pub budget: u64,
    pub disk: Option<String>,
    pub trace_exit: bool,
    pub isaprof: bool,
    pub fnprof: bool,
    pub screenshot: Option<String>,
    pub trace_traps: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            image: "kick.img".into(),
            scale: 1,
            script: None,
            interactive: true,
            budget: u64::MAX,
            disk: None,
            trace_exit: false,
            isaprof: false,
            fnprof: false,
            screenshot: None,
            trace_traps: false,
        }
    }
}

/// Boot and run headless.
pub fn boot(o: &Options) -> i32 {
    run_machine(o, None)
}

/// Boot and run with a window onto the display, or headless where there can
/// be no window, saying why. The window's event loop keeps this thread and
/// the machine gets one of its own.
///
/// Only `lm` opens a window, so only `lm` carries the window's code.
pub fn boot_in_window(o: &Options) -> i32 {
    crate::dev::win::run(|host| run_machine(o, Some(host)))
}

/// Boot and run, on whichever thread this is. `host`, when there is one, is
/// where the window comes from.
fn run_machine(o: &Options, host: Option<Host>) -> i32 {
    let mut m = Machine::new();
    let loaded = match image::load(&mut m, &o.image) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("lm: cannot load {}: {e}", o.image);
            return 1;
        }
    };
    m.pc = loaded.entry;
    m.trace_traps = o.trace_traps;

    if let Some(path) = &o.disk {
        if let Err(e) = m.disk.attach(path) {
            eprintln!("lm: cannot attach {path}: {e}");
            return 1;
        }
    }

    // A script is fed to the console as typed input; the machine cannot
    // distinguish it from a person typing.
    if let Some(s) = &o.script {
        m.uart.feed(s.as_bytes());
    }
    if o.interactive {
        m.uart.attach_stdin();
    }

    if let Some(host) = host {
        match host.open("LM", m.gfx.width, m.gfx.height, o.scale) {
            Ok(w) => m.gfx.win = Some(Box::new(w)),
            Err(e) => eprintln!("lm: no window ({e}); running headless"),
        }
    }
    m.gfx.next_vbl = run::vbl_period();
    if o.isaprof {
        m.prof_on = true;
        m.table = &crate::cpu::PROF_TABLE;
    }
    if o.fnprof {
        m.fnprof = Some(Box::default());
    }
    // The debugging watches, enabled only from the environment.
    let hex = |k: &str| {
        std::env::var(k).ok().and_then(|s| u32::from_str_radix(s.trim_start_matches("0x"), 16).ok())
    };
    m.watch_hi = hex("LM_WATCH_HI");
    m.watch_addr = hex("LM_WATCH_ADDR").map(|lo| {
        let len = std::env::var("LM_WATCH_LEN").ok().and_then(|s| s.parse().ok()).unwrap_or(128);
        (lo, len)
    });
    m.trace_pauses = std::env::var_os("LM_TRACE_PAUSES").is_some();
    if std::env::var_os("LM_WATCH_S2").is_some() || m.watch_hi.is_some() || m.watch_addr.is_some() {
        m.table = &crate::cpu::WATCH_TABLE;
    }

    let t = std::time::Instant::now();
    let stop = run::run(&mut m, o.budget);
    m.uart.flush();
    crate::dev::disk::settle(&mut m);
    let secs = t.elapsed().as_secs_f64();

    if o.trace_exit {
        // `cycles` is the machine's clock: instructions run, plus the time an
        // idle machine skips over and the cycles devices charge. `executed`
        // is the work. The MIPS rate is `executed` over the time the emulator
        // ran, excluding time spent asleep pacing an idle windowed machine.
        let clock = m.cycles as f64 / crate::dev::TIMER_HZ as f64;
        let waiting = m.cycles.saturating_sub(m.executed);
        let running = (secs - m.slept).max(1e-6);
        let asleep = if m.slept > 0.005 {
            format!(", {:.2}s of it asleep", m.slept)
        } else {
            String::new()
        };
        eprintln!(
            "\n[{:?} after {} instructions in {:.2}s{} = {:.1} MIPS; the machine's clock ran {:.2}s, {:.0}% of it waiting]",
            stop,
            m.executed,
            secs,
            asleep,
            m.executed as f64 / running / 1e6,
            clock,
            100.0 * waiting as f64 / m.cycles.max(1) as f64
        );
        // How long the machine ever ran with interrupts off: the pause a
        // collection, a critical section or a trap handler imposes on
        // everything else.
        eprintln!(
            "[longest stretch with interrupts off: {} instructions ({:.1} ms of the machine's clock); {} stretches over {}]",
            m.pause_max,
            m.pause_max as f64 * 1000.0 / crate::dev::TIMER_HZ as f64,
            m.pause_long,
            crate::mach::PAUSE_LONG
        );
        if m.prof_on {
            eprint!("{}", crate::prof::report(&m.prof));
            eprint!("{}", crate::prof::leaf_report(&m.prof, &m.watch));
        }
        if let Some(p) = &m.fnprof {
            eprint!("{}", p.report());
        }
    }
    if let Some(path) = &o.screenshot {
        // The display contents when the machine stopped, written as a binary
        // PPM.
        let (w, h) = (m.gfx.width as usize, m.gfx.height as usize);
        let ramp = m.ramp;
        let len = m.ramlen as usize;
        let ram = unsafe { std::slice::from_raw_parts(ramp, len) };
        let gfx = &mut m.gfx as *mut crate::dev::gfx::Gfx;
        unsafe { (*gfx).scanout(ram) };
        let mut out = format!("P6
{w} {h}
255
").into_bytes();
        for p in m.gfx.scan.iter().take(w * h) {
            out.push((p >> 16) as u8);
            out.push((p >> 8) as u8);
            out.push(*p as u8);
        }
        match std::fs::write(path, &out) {
            Ok(()) => eprintln!("[wrote {path}, {w}x{h}]"),
            Err(e) => eprintln!("lm: cannot write {path}: {e}"),
        }
    }
    match stop {
        Stop::Halt => m.exit_code as i32,
        _ => 0,
    }
}
