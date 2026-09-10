//! Booting an image: load it, attach the peripherals, run.

use crate::dev::gfx::Present;
use crate::image;
use crate::mach::{Machine, Stop};
use crate::run;

pub struct Options {
    pub image: String,
    pub window: bool,
    pub scale: u32,
    pub script: Option<String>,
    pub interactive: bool,
    pub budget: u64,
    pub disk: Option<String>,
    pub trace_exit: bool,
    pub isaprof: bool,
    pub screenshot: Option<String>,
    pub trace_traps: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            image: "kick.img".into(),
            window: true,
            scale: 1,
            script: None,
            interactive: true,
            budget: u64::MAX,
            disk: None,
            trace_exit: false,
            isaprof: false,
            screenshot: None,
            trace_traps: false,
        }
    }
}

pub fn boot(o: &Options) -> i32 {
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

    // A script is typed at the console as if a person had typed it; the
    // machine cannot tell the difference, which is what makes it a usable
    // test harness.
    if let Some(s) = &o.script {
        m.uart.feed(s.as_bytes());
    }
    if o.interactive {
        m.uart.attach_stdin();
    }

    if o.window {
        match crate::dev::win::HostWindow::open("LM", 640, 400, o.scale) {
            Ok(w) => m.gfx.win = Some(Box::new(w) as Box<dyn Present>),
            Err(e) => eprintln!("lm: no window ({e}); running headless"),
        }
    }
    m.gfx.next_vbl = run::vbl_period();
    if o.isaprof {
        m.prof_on = true;
        m.table = &crate::cpu::PROF_TABLE;
    }
    if std::env::var("LM_WATCH_S2").is_ok() {
        m.table = &crate::cpu::WATCH_TABLE;
    }

    let t = std::time::Instant::now();
    let stop = run::run(&mut m, o.budget);
    m.uart.flush();
    let secs = t.elapsed().as_secs_f64();

    if o.trace_exit {
        eprintln!(
            "\n[{:?} after {} instructions in {:.2}s = {:.1} MIPS]",
            stop,
            m.cycles,
            secs,
            m.cycles as f64 / secs / 1e6
        );
        if m.prof_on {
            eprint!("{}", crate::prof::report(&m.prof));
            eprint!("{}", crate::prof::leaf_report(&m.prof, &m.watch));
        }
    }
    if let Some(path) = &o.screenshot {
        // Whatever the display was showing when the machine stopped, as a
        // plain PPM: enough to check that a demo drew what it meant to.
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
