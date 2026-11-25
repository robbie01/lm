//! How long a windowed machine takes to show the answer to the host's input.
//!
//! A probe stands where the window would: it hands the machine scripted
//! input at wall-clock times through the same `Present` calls the window
//! uses, wakes an idle machine for a key, a button or the wheel as the window
//! does, and notes when each frame it is handed differs from the last. The
//! machine runs through the real run loop and pacing, so the times are the
//! ones a person at the window would see, less the host's own drawing.
//!
//!     cargo run --release --example latency -- SCENARIO [GAP] [N]
//!
//! SCENARIO is `type` (keys into the shell), `explorer` (arrow keys in an
//! explorer), `wheel` (the wheel over an opened package), `shell`
//! (`(new-shell)` typed and entered, N times), `drag` (a shell by its title
//! bar), or any expression, such as `"balls 6"`, run as a demo
//! with no input. GAP is the seconds between events and N how many. Needs
//! kick.img.
//!
//! Each event's latency runs to the first changed frame after it. With
//! events closer together than a frame, several are answered by one frame;
//! then the time from the last event to the last change is the measure,
//! which is how long the machine goes on drawing after the hand has stopped.

use lm::dev::gfx::Present;
use lm::dev::input::*;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Default)]
struct Seen {
    /// Milliseconds from each answered event to the changed frame.
    latency: Vec<f64>,
    shown: u64,
    changed: u64,
    events: usize,
    last_event: Option<Instant>,
    last_change: Option<Instant>,
}

struct Probe {
    /// Wall time of the first frame, which the script counts from.
    start: Option<Instant>,
    last: Vec<u32>,
    /// (seconds after start, event, pointer)
    script: Vec<(f64, u32, (u32, u32))>,
    next: usize,
    waiting: Vec<Instant>,
    seen: Arc<Mutex<Seen>>,
}

impl Probe {
    /// Seconds until the next event that wakes an idle machine.
    fn until_wake(&self) -> Option<f64> {
        let t = self.start?.elapsed().as_secs_f64();
        self.script[self.next..]
            .iter()
            .find(|e| word_kind(e.1) != EV_MOUSEMOVE)
            .map(|e| e.0 - t)
    }
}

impl Present for Probe {
    fn show(&mut self, frame: &mut Vec<u32>, _w: usize, _h: usize) -> bool {
        let now = Instant::now();
        self.start.get_or_insert(now);
        let mut seen = self.seen.lock().unwrap();
        seen.shown += 1;
        if *frame != self.last {
            seen.changed += 1;
            if seen.last_event.is_some() {
                seen.last_change = Some(now);
            }
            for t in self.waiting.drain(..) {
                seen.latency.push(now.duration_since(t).as_secs_f64() * 1000.0);
            }
            self.last.clone_from(frame);
        }
        true
    }

    fn size(&self) -> (u32, u32) {
        (1024, 768)
    }

    fn pump(&mut self, ev: &mut Input) -> bool {
        let Some(start) = self.start else { return true };
        let t = start.elapsed().as_secs_f64();
        let mut seen = self.seen.lock().unwrap();
        while self.next < self.script.len() && self.script[self.next].0 <= t {
            let (_, w, p) = self.script[self.next];
            ev.push(w);
            (ev.mx, ev.my) = p;
            if word_kind(w) != EV_KEYUP && word_kind(w) != EV_BUTTONUP {
                self.waiting.push(Instant::now());
                seen.last_event = Some(Instant::now());
            }
            self.next += 1;
            seen.events = self.next;
        }
        true
    }

    fn wait(&mut self, d: Duration) -> bool {
        match self.until_wake() {
            Some(left) if left < d.as_secs_f64() => {
                std::thread::sleep(Duration::from_secs_f64(left.max(0.0)));
                true
            }
            _ => {
                std::thread::sleep(d);
                false
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let what = args.get(1).map(|s| s.as_str()).unwrap_or("type");
    let gap: f64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0.25);
    let n: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(20);
    // The workbench is up and idle four seconds after the first frame.
    let t0 = 4.0;
    let mut setup = "(workbench)\n".to_string();
    let mut script = Vec::new();
    let mut key = |t: f64, ascii: u32, code: u32, p: (u32, u32)| {
        script.push((t, event_word(EV_KEYDOWN, ascii, code, 0), p));
        script.push((t + 0.03, event_word(EV_KEYUP, ascii, code, 0), p));
    };
    let at = (300, 200);
    match what {
        "type" => {
            for i in 0..n {
                let c = b'a' as u32 + (i % 26) as u32;
                key(t0 + i as f64 * gap, c, c, (0, 0));
            }
        }
        "explorer" => {
            setup.push_str("(explorer)\n");
            for i in 0..n {
                // Ten down, ten up, and so on.
                key(t0 + i as f64 * gap, 0, if (i / 10) % 2 == 0 { 0x81 } else { 0x80 }, at);
            }
        }
        "wheel" => {
            setup.push_str("(explorer)\n");
            // Select the tenth package and open it, so there is something
            // to scroll.
            for j in 0..10 {
                key(t0 - 1.5 + j as f64 * 0.05, 0, 0x81, at);
            }
            key(t0 - 0.5, 0, 0x83, at);
            script.push((t0 - 0.4, pointer_word(EV_MOUSEMOVE, at.0, at.1, 0), at));
            for i in 0..n {
                let step = if (i / 10) % 2 == 0 { 0xfff } else { 1 };
                script.push((t0 + i as f64 * gap, event_word(EV_WHEEL, 0, 0, step), at));
            }
        }
        "shell" => {
            // Each round types `(new-shell)` into the front shell; the
            // window it opens is the front one for the next round.
            for i in 0..n {
                let t = t0 + i as f64 * gap;
                for (j, c) in "(new-shell)".bytes().enumerate() {
                    key(t - 0.6 + j as f64 * 0.05, c as u32, c as u32, (0, 0));
                }
                key(t, 13, 13, (0, 0));
            }
        }
        "drag" => {
            script.push((t0 - 0.2, pointer_word(EV_MOUSEMOVE, 200, 30, 0), (200, 30)));
            script.push((t0 - 0.1, pointer_word(EV_BUTTONDOWN, 200, 30, 0), (200, 30)));
            for i in 1..=n as u32 {
                let p = (200 + 3 * i, 30 + 2 * i);
                script.push((t0 + i as f64 * gap, pointer_word(EV_MOUSEMOVE, p.0, p.1, 0), p));
            }
        }
        demo => {
            setup.push_str(&format!("({demo})\n"));
            script.push((t0 + 5.0, pointer_word(EV_MOUSEMOVE, 500, 500, 0), (500, 500)));
        }
    }
    script.sort_by(|a, b| a.0.total_cmp(&b.0));
    let end = script.last().map_or(t0, |e| e.0) + 2.0;
    let total = script.len();

    let mut m = lm::mach::Machine::new();
    let loaded = match lm::image::load(&mut m, "kick.img") {
        Ok(l) => l,
        Err(e) => {
            eprintln!("latency: cannot load kick.img: {e}");
            std::process::exit(1);
        }
    };
    lm::boot::reset(&mut m, loaded.entry);
    m.uart.feed(setup.as_bytes());
    m.uart.mute = true;
    let seen = Arc::new(Mutex::new(Seen::default()));
    m.gfx.win = Some(Box::new(Probe {
        start: None,
        last: Vec::new(),
        script,
        next: 0,
        waiting: Vec::new(),
        seen: seen.clone(),
    }));
    m.gfx.next_vbl = lm::run::vbl_period();
    let wall = Instant::now();
    while wall.elapsed() < Duration::from_secs_f64(end) {
        lm::run::run(&mut m, 2_000_000);
    }

    let s = seen.lock().unwrap();
    let mut l = s.latency.clone();
    l.sort_by(f64::total_cmp);
    let mean = l.iter().sum::<f64>() / l.len().max(1) as f64;
    let median = l.get(l.len() / 2).copied().unwrap_or(0.0);
    let after = match (s.last_event, s.last_change) {
        (Some(e), Some(c)) if c > e => c.duration_since(e).as_secs_f64() * 1000.0,
        _ => 0.0,
    };
    println!("{what}: {} of {total} events given, {} answered", s.events, l.len());
    println!("  latency ms: mean {mean:.1}, median {median:.1}, max {:.1}", l.last().unwrap_or(&0.0));
    println!("  last event to last change: {after:.0} ms");
    println!("  frames handed over {}, of them changed {}", s.shown, s.changed);
    println!(
        "  {:.1} s of wall time, {:.1} asleep; {:.1} M instructions",
        wall.elapsed().as_secs_f64(),
        m.slept,
        m.executed as f64 / 1e6
    );
}
