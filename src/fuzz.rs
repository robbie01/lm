//! Fuzzing the parts of the machine that take bytes from outside and handle
//! them with `unsafe`: the processor core with its custom instructions and
//! chips, the image loader, and the bootstrap reader and evaluator the forge
//! runs.
//!
//! Each target is a plain function from a byte slice, so two drivers share
//! them: `lmdev fuzz`, a seeded random generator with no coverage feedback,
//! which runs anywhere; and the cargo-fuzz targets under fuzz/, which are
//! coverage-guided. A crash found by either is replayed with
//! `lmdev fuzz --replay FILE`.
//!
//! A finding is a panic, an abort, a host memory fault, or a run that does
//! not finish. Anything the machine does inside its own memory is the
//! machine working: random code faulting is not a bug, random code reaching
//! the host is.

use crate::forge::hostlisp::Lisp;
use crate::mach::{Machine, MSTATUS_MIE, MSTATUS_MPIE};
use crate::map::*;

/// Where the fuzz code goes: the base of code space, which is also the reset
/// vector, so the trap vector can point into it as well.
const CODE_AT: u32 = CODE_BASE;
const CODE_MAX: usize = 4096;
/// Instructions a run may execute before it is stopped.
const EXEC_BUDGET: u64 = 50_000;
/// Evaluation steps a Lisp run may take before it is stopped.
const LISP_FUEL: u64 = 2_000_000;

// ---------------------------------------------------------------- targets

/// Run `data` as code with the registers it also supplies.
///
/// The first 31 words are x1..x31 and set the CSRs too; the rest is code,
/// placed at the base of code space, where the trap vector also points, so
/// traps land back in the fuzz code. The machine is fresh: what the run
/// does is a function of its input alone.
pub fn exec(data: &[u8]) {
    let mut m = Machine::new();
    let word = |i: usize| -> u32 {
        let at = i * 4;
        if at + 4 <= data.len() {
            u32::from_le_bytes(data[at..at + 4].try_into().unwrap())
        } else {
            0
        }
    };
    for i in 1..32 {
        m.x[i] = word(i - 1);
    }
    let code = data.get(31 * 4..).unwrap_or(&[]);
    let code = &code[..code.len().min(CODE_MAX)];
    let at = CODE_AT as usize;
    m.ram_mut()[at..at + code.len()].copy_from_slice(code);
    m.pc = CODE_AT;
    m.mtvec = CODE_AT | (m.x[31] & 1);
    m.mstatus = m.x[30] & (MSTATUS_MIE | MSTATUS_MPIE);
    m.mie = m.x[29] & 0x888;
    m.gcmode = m.x[28] & 1;
    m.stklim = m.x[27];
    m.mscratch = m.x[26];
    m.mtimecmp = (m.x[25] as u64) << 4;
    m.uart.mute = true;
    let _ = crate::run::run(&mut m, EXEC_BUDGET);
}

/// Load `data` as an image, and if it loads, run what came out.
pub fn image(data: &[u8]) {
    let mut m = Machine::new();
    let mut cur = std::io::Cursor::new(data);
    if let Ok(l) = crate::image::load_from(&mut m, &mut cur) {
        m.pc = l.entry;
        m.uart.mute = true;
        let _ = crate::run::run(&mut m, EXEC_BUDGET);
    }
}

/// Feed `data` to the bootstrap reader and evaluator, with the prelude
/// loaded so that the text can reach the interpreter's whole vocabulary.
///
/// One interpreter serves every run: bringing the prelude up takes seconds.
/// A run can therefore leave definitions behind for the next; a crash that
/// depends on that history is still a crash, only harder to replay.
pub fn lisp(data: &[u8]) {
    thread_local! {
        static LISP: std::cell::RefCell<Lisp<'static>> = std::cell::RefCell::new(fresh_lisp());
    }
    let text = String::from_utf8_lossy(data);
    LISP.with(|l| {
        let mut l = l.borrow_mut();
        l.fuel = LISP_FUEL;
        l.depth = 0;
        let _ = l.eval_string(&text, "<fuzz>");
    });
}

fn fresh_lisp() -> Lisp<'static> {
    let m: &'static mut Machine = Box::leak(Machine::new());
    let mut l = Lisp::new(m);
    crate::forge::write_layout();
    if let Err(e) = crate::forge::boot_host(&mut l) {
        eprintln!("fuzz: the prelude did not load: {e}");
    }
    // Nothing a run does may reach the host: no files, no exit.
    l.sandbox = true;
    l
}

// ---------------------------------------------------------------- driver
/// A small fast generator; the seed makes a session repeatable.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
    fn word(&mut self) -> u32 {
        self.next() as u32
    }
}

/// Addresses worth handing random code: each region, its edges, the chips.
const PLACES: &[u32] = &[
    0, 4, 8, LG_BASE, OBJ_BINS, TRAP_BASE, POOL_BASE, POOL_END - 4, CODE_BASE, CODE_END - 4,
    CONS_BASE, CONS_END - 4, OBJ_BASE, OBJ_END - 4, FAST_BASE, RAM_SIZE - 4, RAM_SIZE,
    MMIO_BASE, MMIO_BASE + 0x1000, MMIO_BASE + 0x2000, MMIO_BASE + 0x3000,
    MMIO_BASE + 0x4000, MMIO_BASE + 0x5000, MMIO_BASE + 0x6000, MMIO_END - 4,
    0xFFFF_FFFF, 0xFFFF_FFFC, 0x8000_0000,
];

/// Opcodes with something to check behind them: the custom spaces, loads,
/// stores, branches, jumps, system.
const OPCODES: &[u32] = &[0x0b, 0x2b, 0x5b, 0x7b, 0x03, 0x23, 0x63, 0x6f, 0x67, 0x73, 0x0f, 0x33, 0x13];

fn gen_register(r: &mut Rng) -> u32 {
    match r.below(4) {
        0 => r.below(64) as u32 * 2 + 1, // a small fixnum
        1 => PLACES[r.below(PLACES.len())].wrapping_add(r.below(16) as u32 * 4),
        2 => PLACES[r.below(PLACES.len())].wrapping_add(r.below(8) as u32) | 4,
        _ => r.word(),
    }
}

fn gen_exec(r: &mut Rng) -> Vec<u8> {
    let mut v = Vec::with_capacity(31 * 4 + 512);
    for _ in 0..31 {
        v.extend_from_slice(&gen_register(r).to_le_bytes());
    }
    let n = 1 + r.below(200);
    for _ in 0..n {
        if r.chance(60) {
            let op = OPCODES[r.below(OPCODES.len())];
            let w = (r.word() & !0x7f) | op;
            v.extend_from_slice(&w.to_le_bytes());
        } else if r.chance(50) {
            v.extend_from_slice(&r.word().to_le_bytes());
        } else {
            v.extend_from_slice(&(r.word() as u16).to_le_bytes());
        }
    }
    v
}

/// Random image files: a mutated copy of a real one when there is one, or a
/// header with random pages, or a snapshot with a random region table.
fn gen_image(r: &mut Rng, seed: &[u8]) -> Vec<u8> {
    match r.below(3) {
        0 if !seed.is_empty() => {
            let lo = r.below(seed.len());
            let hi = (lo + 1 + r.below(64 * 1024)).min(seed.len());
            let mut v = seed[lo..hi].to_vec();
            // Keep the magic most of the time so the loader gets past it.
            if r.chance(80) && v.len() >= 8 {
                v[..8].copy_from_slice(crate::image::MAGIC);
            }
            mutate(r, &mut v);
            v
        }
        1 => {
            let mut v = Vec::new();
            v.extend_from_slice(crate::image::MAGIC);
            v.extend_from_slice(&(if r.chance(90) { 1u32 } else { r.word() }).to_le_bytes());
            v.extend_from_slice(&gen_register(r).to_le_bytes());
            let n = r.below(40) as u32;
            v.extend_from_slice(&(if r.chance(90) { n } else { r.word() }).to_le_bytes());
            for _ in 0..n {
                v.extend_from_slice(&gen_register(r).to_le_bytes());
            }
            let pages = r.below(n as usize + 2);
            for _ in 0..pages {
                for _ in 0..1024 {
                    v.extend_from_slice(&gen_register(r).to_le_bytes());
                }
            }
            v.truncate(r.below(v.len() + 1).max(20));
            v
        }
        _ => {
            let mut v = vec![0u8; 512];
            v[0..4].copy_from_slice(&crate::image::SNAP_MAGIC.to_le_bytes());
            v[4..8].copy_from_slice(&gen_register(r).to_le_bytes());
            let n = if r.chance(90) { r.below(41) as u32 } else { r.word() };
            v[8..12].copy_from_slice(&n.to_le_bytes());
            for i in 0..40 {
                let base = gen_register(r);
                let len = if r.chance(50) { r.below(8192) as u32 } else { r.word() };
                let blk = r.below(64) as u32;
                v[12 + i * 12..16 + i * 12].copy_from_slice(&base.to_le_bytes());
                v[16 + i * 12..20 + i * 12].copy_from_slice(&len.to_le_bytes());
                v[20 + i * 12..24 + i * 12].copy_from_slice(&blk.to_le_bytes());
            }
            for _ in 0..r.below(16) {
                for _ in 0..128 {
                    v.extend_from_slice(&gen_register(r).to_le_bytes());
                }
            }
            v
        }
    }
}

/// Byte-level damage: flips, deletions, duplications.
fn mutate(r: &mut Rng, v: &mut Vec<u8>) {
    let k = 1 + r.below(8);
    for _ in 0..k {
        if v.is_empty() {
            return;
        }
        match r.below(4) {
            0 => {
                let i = r.below(v.len());
                v[i] = r.word() as u8;
            }
            1 => {
                let i = r.below(v.len());
                let n = r.below(64).min(v.len() - i);
                v.drain(i..i + n);
            }
            2 => {
                let i = r.below(v.len());
                let n = r.below(64).min(v.len() - i);
                let piece = v[i..i + n].to_vec();
                let at = r.below(v.len());
                v.splice(at..at, piece);
            }
            _ => {
                let i = r.below(v.len());
                v[i] ^= 1 << r.below(8);
            }
        }
    }
}

/// Pieces of Lisp that mean something to the reader and the evaluator.
const TOKENS: &[&str] = &[
    "(", ")", "(", ")", "'", "`", ",", ",@", "\"", "#\\a", "#\\newline", "#x1f", "#b101", ".", ";",
    "nil", "t", "0", "1", "-1", "1073741823", "1073741824", "99999999999999999999",
    "define", "lambda", "if", "let", "let*", "set!", "begin", "while", "quote", "defmacro",
    "&optional", "&rest", "cond", "and", "or", "case", "do", "dolist",
    "car", "cdr", "cons", "list", "append", "reverse", "length", "map", "apply", "%funcall",
    "%car", "%cdr", "%cons", "%set-car!", "%set-cdr!", "%+", "%-", "%*", "%/", "%mod",
    "%lsh", "%ash", "%logand", "%ld-word", "%st-word!", "%ld-fixnum", "%st-fixnum!",
    "%ld-byte", "%st-byte!", "%addr-of", "%from-addr", "%alloc-obj", "%slot", "%set-slot!",
    "%obj-len", "%make-string", "%string-ref", "%string-set!", "%make-vector", "%vector-ref",
    "%vector-set!", "%make-bytes", "%bytes-ref", "%bytes-set!", "%intern", "%symbol-name",
    "%symbol-value", "%set-symbol-value!", "%bit-ref", "%bit-set!", "%popcount", "%alloc-code",
    "%alloc-pool", "%record-ref", "%record-set!", "%obj-type", "%eq?", "%=", "%<",
    "string-append", "substring", "number->string", "string->number", "symbol->string",
    "make-assembler", "i-add", "i-lw", "i-sw", "place", "compile-top", "compile-file",
    "read-from-string", "write-to-string", "display", "gensym", "error", "in-package",
    "x", "y", "z", "f", "g", "lst", "n", "i",
];

/// A random Lisp text: a window out of the system's own sources, damaged,
/// or a tree of tokens.
fn gen_lisp(r: &mut Rng, corpus: &[Vec<u8>]) -> Vec<u8> {
    if !corpus.is_empty() && r.chance(50) {
        let file = &corpus[r.below(corpus.len())];
        let lo = r.below(file.len());
        let hi = (lo + 1 + r.below(3000)).min(file.len());
        let mut v = file[lo..hi].to_vec();
        if r.chance(70) {
            mutate(r, &mut v);
        }
        if r.chance(50) {
            let n = 1 + r.below(6);
            for _ in 0..n {
                let at = r.below(v.len() + 1);
                let tok = TOKENS[r.below(TOKENS.len())];
                v.splice(at..at, tok.bytes().chain(std::iter::once(b' ')));
            }
        }
        v
    } else {
        let mut s = String::new();
        let n = 1 + r.below(120);
        let mut depth = 0i32;
        for _ in 0..n {
            let tok = TOKENS[r.below(TOKENS.len())];
            if tok == "(" {
                depth += 1;
            } else if tok == ")" {
                depth -= 1;
            }
            s.push_str(tok);
            s.push(' ');
        }
        while depth > 0 && r.chance(90) {
            s.push(')');
            depth -= 1;
        }
        if r.chance(10) {
            let deep = 1 + r.below(200_000);
            for _ in 0..deep {
                s.push('(');
            }
        }
        s.into_bytes()
    }
}

/// The Lisp sources, for the reader to be given something like Lisp.
fn corpus() -> Vec<Vec<u8>> {
    let mut v = Vec::new();
    if let Ok(dir) = std::fs::read_dir("lisp") {
        for e in dir.flatten() {
            if e.path().extension().is_some_and(|x| x == "lisp") {
                if let Ok(b) = std::fs::read(e.path()) {
                    v.push(b);
                }
            }
        }
    }
    v
}

const TARGETS: &[&str] = &["exec", "image", "lisp"];

/// Run one input through one target.
pub fn run_one(target: &str, data: &[u8]) -> bool {
    match target {
        "exec" => exec(data),
        "image" => image(data),
        "lisp" => lisp(data),
        _ => {
            eprintln!("fuzz: no target {target:?}; one of exec, image, lisp, all");
            return false;
        }
    }
    true
}

/// The driver. Runs until the time is up, writing every input to
/// target/fuzz/last-TARGET.bin before running it, so that a crash leaves
/// its input behind. With `replay`, runs that one file and stops.
pub fn run(target: &str, seconds: u64, seed: u64, replay: Option<&str>) -> bool {
    if let Some(path) = replay {
        let data = match std::fs::read(path) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("fuzz: cannot read {path}: {e}");
                return false;
            }
        };
        let t = if target == "all" { target_of(path) } else { target.to_string() };
        println!("fuzz: replaying {path} ({} bytes) on {t}", data.len());
        let ok = run_one(&t, &data);
        if ok {
            println!("fuzz: the run finished");
        }
        return ok;
    }
    let targets: Vec<&str> = if target == "all" {
        TARGETS.to_vec()
    } else if TARGETS.contains(&target) {
        vec![target]
    } else {
        eprintln!("fuzz: no target {target:?}; one of exec, image, lisp, all");
        return false;
    };
    let _ = std::fs::create_dir_all("target/fuzz");
    let seed_image = std::fs::read("kick.img").unwrap_or_default();
    let corpus = if targets.contains(&"lisp") { corpus() } else { Vec::new() };
    let mut r = Rng::new(seed);
    let start = std::time::Instant::now();
    let mut runs = vec![0u64; targets.len()];
    let mut last_report = std::time::Instant::now();
    println!("fuzz: {} for {seconds}s, seed {seed}; inputs go to target/fuzz/last-*.bin", targets.join(", "));
    let mut i = 0;
    while start.elapsed().as_secs() < seconds {
        let t = targets[i % targets.len()];
        let data = match t {
            "exec" => gen_exec(&mut r),
            "image" => gen_image(&mut r, &seed_image),
            _ => gen_lisp(&mut r, &corpus),
        };
        let path = format!("target/fuzz/last-{t}.bin");
        if let Err(e) = std::fs::write(&path, &data) {
            eprintln!("fuzz: cannot write {path}: {e}");
            return false;
        }
        run_one(t, &data);
        runs[i % targets.len()] += 1;
        i += 1;
        if last_report.elapsed().as_secs() >= 5 {
            last_report = std::time::Instant::now();
            report(&targets, &runs, start.elapsed().as_secs());
        }
    }
    report(&targets, &runs, start.elapsed().as_secs());
    println!("fuzz: no crash");
    true
}

fn target_of(path: &str) -> String {
    for t in TARGETS {
        if path.contains(t) {
            return t.to_string();
        }
    }
    "exec".to_string()
}

fn report(targets: &[&str], runs: &[u64], secs: u64) {
    let parts: Vec<String> = targets.iter().zip(runs).map(|(t, n)| format!("{t} {n}")).collect();
    println!("fuzz: {secs}s: {}", parts.join(", "));
}
