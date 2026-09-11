//! The forge: everything needed to build an image, and nothing needed to run
//! one.
//!
//! It brings up a machine, loads the Lisp sources into that machine's heap
//! with the bootstrap interpreter, and then hands control to the Lisp compiler
//! - which is itself one of those sources - to compile the whole system,
//! itself included, into native RISC-V in the same heap. What falls out is the
//! kickstart image.

pub mod compact;
pub mod hostlisp;
pub mod read;

use crate::heap::*;
use crate::forge::hostlisp::{LErr, Lisp};
use crate::mach::Machine;
use crate::map::*;

/// Emit the memory map and object layout as Lisp constants, so the Rust side
/// and the Lisp side cannot drift apart: there is one definition of where
/// anything lives, and it is in Rust.
/// Build a fresh image by having a previous image do it.
///
/// The machine has a reader, a compiler and an image writer; what it does not
/// have is a filesystem. So the sources are typed at its console, exactly the
/// way a person would type them, and it compiles them and writes out what it
/// made.
///
/// Twice, the way the forge does it. The first time through, `sys:rebuild`
/// compiles them into the machine itself, so that the compiler and the macros
/// doing the work are the new ones. The second time, `sys:genesis` compiles
/// them again with those, and keeps every definition for the image instead of
/// installing it. `snap:save-fresh` then makes the machine into exactly that
/// image and writes it: what comes out holds nothing the old image had, which
/// is the difference between a fresh image and an updated one.
///
/// This is the self-hosting path. The bootstrap interpreter in Rust is only
/// needed to make the first image; after that the machine makes the next one,
/// and a change to the Lisp reader needs no Rust counterpart at all.
pub fn rebuild(from: &str, out: &str, verbose: bool, check: bool) -> i32 {
    write_layout();
    let mut sources = String::new();
    let mut bytes = 0usize;
    for f in SYSTEM {
        match std::fs::read_to_string(f) {
            Ok(t) => {
                bytes += t.len();
                sources.push_str(&t);
                sources.push('\n');
            }
            Err(e) => {
                eprintln!("lm: cannot read {f}: {e}");
                return 1;
            }
        }
    }
    let mut script = String::new();
    script.push_str("(sys:rebuild)\n");
    script.push_str(&sources);
    script.push_str("\nsys:rebuild-end\n");
    // With --verbose, the second pass names every form as it takes it: when
    // a rebuild goes wrong, that is where it went wrong.
    if verbose {
        script.push_str("(set! sys::*genesis-trace* t)\n");
    }
    script.push_str("(sys:genesis)\n");
    script.push_str(&sources);
    script.push_str("\nsys:rebuild-end\n");
    // --check stops short of writing anything: it compiles everything, both
    // times, and then collects, which is the moment a rebuilt heap has to
    // survive.
    if check {
        script.push_str("(gc)\n(+ 1 2)\n(%halt 9)\n");
    } else {
        script.push_str("(snap:save-fresh)\n");
    }
    if verbose {
        println!("rebuild: {} sources, {} bytes, on {from}", SYSTEM.len(), bytes);
    }
    // The new image is written to the disk the machine is given, so the disk
    // is the output file.
    // --check writes nothing, so it must not clear away what is there.
    if !check {
        let _ = std::fs::remove_file(out);
    }
    let o = crate::boot::Options {
        image: from.to_string(),
        window: false,
        scale: 1,
        script: Some(script),
        interactive: false,
        // Twenty times what a rebuild takes, so that one that has gone wrong
        // stops and says where rather than running for ever.
        budget: 40_000_000_000,
        disk: if check { None } else { Some(out.to_string()) },
        // LM_FNPROF=1 profiles what the machine does during a rebuild, the
        // same report `lm --fnprof` prints.
        trace_exit: verbose || std::env::var_os("LM_FNPROF").is_some(),
        isaprof: false,
        fnprof: std::env::var_os("LM_FNPROF").is_some(),
        screenshot: None,
        trace_traps: false,
    };
    let t = std::time::Instant::now();
    let code = crate::boot::boot(&o);
    // --check ends with (%halt 9) on purpose: reaching it is the pass.
    if check {
        if code == 9 {
            println!(
                "rebuild --check: {} sources compiled twice and collected cleanly",
                SYSTEM.len()
            );
            return 0;
        }
        eprintln!("lm: the check did not get to the end (exit {code})");
        return 1;
    }
    if code != 0 {
        eprintln!("lm: the rebuild did not finish cleanly (exit {code})");
        return 1;
    }
    // The machine wrote that image with a collector that cannot move an
    // object or a function, so it carries every hole it ever made. Nothing is
    // running now, and a fresh image resumes nothing, so the forge can close
    // them in both.
    if crate::forge::compact::compact_image(out, out, verbose, true) != 0 {
        return 1;
    }
    match std::fs::metadata(out) {
        Ok(m) => {
            println!(
                "{out}: {} KiB, rebuilt by {from} in {:.2}s",
                m.len() / 1024,
                t.elapsed().as_secs_f64()
            );
            0
        }
        Err(_) => {
            eprintln!("lm: the rebuild wrote no image");
            1
        }
    }
}

pub fn write_layout() {
    let mut s = String::new();
    s.push_str(";;; layout.lisp - GENERATED by `lm layout`. Do not edit.\n");
    s.push_str(";;; The single source of truth for these numbers is src/map.rs\n");
    s.push_str(";;; and src/heap.rs; this file is regenerated on every build.\n\n");
    s.push_str("(in-package lm)\n\n");

    // Fixnums are 31-bit signed, so a constant that does not fit - anything at
    // or above 2^30, such as the MMIO window - is written as the signed 32-bit
    // value instead. Addresses are signed throughout the Lisp side, and `li`
    // encodes a negative constant into exactly the same lui/addi pair.
    macro_rules! def {
        ($name:expr, $v:expr) => {{
            let v: u32 = $v;
            if v >= (1 << 30) {
                s.push_str(&format!("(define {} {})\n", $name, v as i32))
            } else {
                s.push_str(&format!("(define {} #x{:x})\n", $name, v))
            }
        }};
    }

    s.push_str(";; ---- memory map ----\n");
    def!("ram-size", RAM_SIZE);
    def!("chip-size", CHIP_SIZE);
    def!("nil-cell", NIL_CELL);
    def!("lg-base", LG_BASE);
    def!("trap-base", TRAP_BASE);
    def!("pool-base", POOL_BASE);
    def!("pool-limit", POOL_END);
    def!("code-base", CODE_BASE);
    def!("code-limit", CODE_END);
    def!("cons-base", CONS_BASE);
    def!("cons-limit", CONS_END);
    def!("obj-base", OBJ_BASE);
    def!("obj-limit", OBJ_END);
    def!("fast-base", FAST_BASE);
    def!("kick-base", KICK_BASE);

    s.push_str("\n;; ---- lisp global block ----\n");
    for (name, addr) in GLOBAL_NAMES {
        def!(format!("lg-{name}"), *addr);
    }

    s.push_str("\n;; ---- object representation ----\n");
    def!("obj-bins", OBJ_BINS);
    def!("obj-bin-count", OBJ_BIN_COUNT);
    def!("t-free", T_FREE);
    def!("t-symbol", T_SYMBOL);
    def!("t-string", T_STRING);
    def!("t-vector", T_VECTOR);
    def!("t-bytes", T_BYTES);
    def!("t-closure", T_CLOSURE);
    def!("t-record", T_RECORD);
    def!("t-float", T_FLOAT);
    def!("t-bignum", T_BIGNUM);
    def!("t-port", T_PORT);
    def!("t-code", T_CODE);
    def!("code-entry", CODE_ENTRY);
    def!("code-len", CODE_LEN);
    def!("code-name", CODE_NAME);
    def!("code-lits", CODE_LITS);
    def!("sym-slots", SYM_SLOTS);
    def!("sym-name", SYM_NAME);
    def!("sym-value", SYM_VALUE);
    def!("sym-function", SYM_FUNCTION);
    def!("sym-plist", SYM_PLIST);
    def!("sym-package", SYM_PACKAGE);
    def!("sym-macro", SYM_MACRO as u32);
    def!("sym-exported", SYM_EXPORTED as u32);
    def!("pkg-tag", PKG_TAG);
    def!("pkg-name", PKG_NAME);
    def!("pkg-use", PKG_USE);
    def!("pkg-slots", PKG_SLOTS);
    def!("sym-flags", SYM_FLAGS);
    def!("clo-entry", CLO_ENTRY);
    def!("clo-code", CLO_CODE);
    def!("clo-free", CLO_FREE);
    def!("imm-char", IMM_CHAR);
    def!("imm-unbound", IMM_UNBOUND);
    def!("imm-eof", IMM_EOF);
    def!("imm-void", IMM_VOID);

    // The trap stub saves all thirty-two registers, so a task's context and a
    // trap frame are the same block, and everything that reads one wants the
    // same names for its words rather than a number counted out by hand.
    s.push_str("\n;; ---- trap frame ----\n");
    def!("ctx-words", 32);
    def!("ctx-bytes", 32 * 4);
    for (i, name) in [
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
    ]
    .iter()
    .enumerate()
    {
        def!(format!("reg-{name}"), i as u32);
    }

    s.push_str("\n;; ---- ecall codes ----\n");
    def!("trap-arity", crate::mach::E_ARITY);
    def!("trap-type", crate::mach::E_TYPE);
    def!("trap-oom", crate::mach::E_OOM);
    def!("trap-error", crate::mach::E_ERROR);
    def!("trap-reschedule", crate::mach::E_RESCHEDULE);
    def!("trap-record", crate::mach::E_RECORD);

    s.push_str("\n;; ---- device registers ----\n");
    def!("mmio-base", MMIO_BASE);
    def!("dev-sys", DEV_SYS);
    def!("dev-uart", DEV_UART);
    def!("dev-timer", DEV_TIMER);
    def!("dev-gfx", DEV_GFX);
    def!("dev-input", DEV_INPUT);
    def!("dev-blit", DEV_BLIT);
    def!("dev-disk", DEV_DISK);
    def!("int-uart", INT_UART);
    def!("int-vblank", INT_VBLANK);
    def!("int-input", INT_INPUT);
    def!("int-blit", INT_BLIT);
    def!("int-disk", INT_DISK);
    def!("int-soft", INT_SOFT);

    // The blitter takes its whole command from a block of fourteen words, and
    // these are that block's layout - not the register map, which has a gap
    // the block does not. One store of `blt-list` runs it; nothing else in
    // the chip is worth naming on the Lisp side.
    s.push_str("\n;; ---- disk ----\n");
    {
        use crate::dev::disk::*;
        def!("disk-busy", STATUS_BUSY);
        def!("disk-cmd-read", CMD_READ);
        def!("disk-cmd-write", CMD_WRITE);
        def!("disk-cmd-flush", CMD_FLUSH);
    }
    s.push_str("\n;; ---- blitter command block ----\n");
    {
        use crate::dev::blit::*;
        def!("blit-list-reg", B_LIST);
        def!("blit-status-reg", B_STATUS);
        def!("blit-ctrl-reg", B_CTRL);
        def!("blit-list-size", LIST_WORDS * 4);
        for (i, name) in ["src", "dst", "w", "h", "smod", "dmod",
                          "val", "op", "x0", "y0", "x1", "y1",
                          "status", "next"]
            .iter()
            .enumerate()
        {
            def!(format!("bl-{name}"), (i as u32) * 4);
        }
        def!("op-copy", OP_COPY);
        def!("op-fill", OP_FILL);
        def!("op-xor", OP_XOR);
        def!("op-and", OP_AND);
        def!("op-or", OP_OR);
        def!("op-mask", OP_MASK);
        def!("op-line", OP_LINE);
        def!("op-add", OP_ADD);
    }

    let _ = std::fs::write("lisp/layout.lisp", s);
}

/// Sources are loaded in this order. Each one may only use what the ones
/// before it defined.
pub const BOOT_ORDER: &[&str] = &[
    // Everything down to read.lisp is read by the bootstrap reader in Rust,
    // which has one flat namespace. That is why these files are the prelude
    // and nothing else: their names belong in one namespace anyway.
    "boot0.lisp",
    "layout.lisp",
    "stream.lisp",
    "core.lisp",
    "macros.lisp",
    "runtime.lisp",
    "hostio.lisp",
    "read.lisp",
    // From here on the real reader is in charge, which is why the package
    // declarations can be read at all: an export list has to be read in the
    // package it is exporting from.
    "packages.lisp",
    "gc.lisp",
    "hw.lisp",
    "exec.lisp",
    "asm.lisp",
    "compile.lisp",
    "boot.lisp",
];

/// What gets compiled into the image, in order. hostio.lisp is absent on
/// purpose: it exists only so the forge can print while it works.
pub const SYSTEM: &[&str] = &[
    "lisp/packages.lisp",
    "lisp/layout.lisp",
    "lisp/runtime.lisp",
    "lisp/core.lisp",
    "lisp/macros.lisp",
    "lisp/table.lisp",
    "lisp/stream.lisp",
    "lisp/print.lisp",
    "lisp/read.lisp",
    "lisp/bignum.lisp",
    "lisp/gc.lisp",
    "lisp/hw.lisp",
    "lisp/asm.lisp",
    "lisp/compile.lisp",
    "lisp/sys.lisp",
    "lisp/exec.lisp",
    "lisp/disk.lisp",
    "lisp/input.lisp",
    "lisp/gfx.lisp",
    "lisp/console.lisp",
    "lisp/snap.lisp",
    "lisp/mono.lisp",
    "lisp/font.lisp",
    "lisp/platinum.lisp",
    "lisp/platinum.lisp",
    "lisp/wb.lisp",
    "lisp/eyes.lisp",
    "lisp/demo.lisp",
];

/// Bring the bootstrap up, and switch readers as soon as there is one.
///
/// The files before `read.lisp` are read by the reader in Rust, which knows
/// nothing about packages and puts everything in one namespace - they are the
/// shortest path to having the real reader running. Everything after it,
/// including `packages.lisp`, is read by the real reader, so the declarations
/// in it land in the packages they name.
pub fn boot_host(l: &mut Lisp) -> Result<(), LErr> {
    for f in BOOT_ORDER {
        let text = match std::fs::read_to_string(format!("lisp/{f}")) {
            Ok(t) => t,
            Err(e) => {
                return Err(crate::forge::hostlisp::LErr::new(format!(
                    "cannot read lisp/{f}: {e}"
                )))
            }
        };
        if l.have_lisp_reader() {
            l.eval_lisp(&text)?;
        } else {
            l.eval_string(&text, f)?;
        }
    }
    Ok(())
}

/// An interactive Lisp on the bootstrap interpreter. This is the build-time
/// Lisp, not the machine's own REPL - useful for poking at the compiler while
/// it is being written.
pub fn host_repl(files: &[String]) -> i32 {
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return 1;
    }
    for f in files {
        if let Err(e) = l.load(f) {
            eprint!("{e}");
            return 1;
        }
    }
    use std::io::{BufRead, Write};
    let stdin = std::io::stdin();
    let mut line = String::new();
    loop {
        print!("host> ");
        let _ = std::io::stdout().flush();
        line.clear();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        if line.trim().is_empty() {
            continue;
        }
        // The same reader the machine has, so a name here means what it
        // would mean there.
        let r = if l.have_lisp_reader() {
            l.eval_lisp(&line)
        } else {
            l.eval_string(&line, "<stdin>")
        };
        match r {
            Ok(v) => println!("{}", l.h.write(v)),
            Err(e) => eprint!("{e}"),
        }
    }
    0
}

/// Run one file and report, for scripted checks.
pub fn host_run(files: &[String]) -> i32 {
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return 1;
    }
    for f in files {
        if let Err(e) = l.load(f) {
            eprint!("{e}");
            return 1;
        }
    }
    0
}

/// Evaluate one step of the build, standing in the prelude.
///
/// Read by the Lisp reader, not the bootstrap one: `sys:kickstart` names a
/// symbol in a package, and only the real reader knows that. Each step says
/// where it is standing, because compiling a file leaves the reader in
/// whatever package that file ended in - and it stands in `lm`, which is
/// where the bootstrap reader put everything hostio.lisp defines.
fn drive(l: &mut Lisp, src: &str) -> crate::forge::hostlisp::Res {
    l.eval_lisp(&format!("(in-package lm) {src}"))
}

/// Build the kickstart image.
///
/// The shape of this is the whole bootstrap in one function: bring up the
/// interpreter, let it read the compiler, then let the compiler compile the
/// system - itself included - into the heap the interpreter has been building
/// all along. What is left in memory at the end is the image.
pub fn build(out: &str, verbose: bool) -> i32 {
    write_layout();
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    let t0 = std::time::Instant::now();
    if let Err(e) = boot_host(&mut l) {
        eprint!("bringing up the bootstrap interpreter: {e}");
        return 1;
    }
    let note = |l: &Lisp, what: &str| {
        if verbose {
            eprintln!(
                "{what}: {} pairs, {} obj bytes, {} code bytes",
                (l.h.g(LG_CONS_PTR) - CONS_BASE) / 8,
                l.h.g(LG_OBJ_PTR) - OBJ_BASE,
                l.h.g(LG_CODE_PTR) - CODE_BASE
            );
        }
    };
    note(&l, "host up");

    // Claim the reset vector before any code is generated: code space is a
    // bump allocator and the processor starts at its base.
    if let Err(e) = drive(&mut l, "(boot:reserve-reset)") {
        eprint!("{e}");
        return 1;
    }

    note(&l, "reset reserved");
    for f in SYSTEM {
        let script = if verbose {
            format!("(set! *compile-trace* t)(compile-file {f:?})")
        } else {
            format!("(compile-file {f:?})")
        };
        if let Err(e) = drive(&mut l, &script) {
            eprint!("compiling {f}: {e}");
            return 1;
        }
        note(&l, f);
    }
    // Before anything moves: the profile names functions by their heap
    // addresses, and the collection below slides them.
    l.prof_report();

    // Wire the pieces the assembly stubs reach through globals.
    for step in [
        "(%st-word! lg-toplevel (%symbol-value 'sys:kickstart))",
        "(%st-word! lg-refill (%symbol-value 'gc:refill-cons))",
        "(%st-word! lg-traphook (%symbol-value 'sys:handle-trap))",
        "(%st-word! lg-bootlist (reverse compiler:*boot-thunks*))",
    ] {
        if let Err(e) = drive(&mut l, step) {
            eprint!("wiring {step}: {e}");
            return 1;
        }
        note(&l, step);
    }
    let entry = match drive(&mut l, "(boot:build-boot-code)") {
        Ok(v) => {
            // (reset trap refill); the trap stub's address is stashed where
            // collect_before_saving can find it.
            let trap = crate::heap::unfix(l.h.cadr(v)) as u32;
            l.h.set_g(LG_SCRATCH3, trap);
            crate::heap::unfix(l.h.car(v)) as u32
        }
        Err(e) => {
            eprint!("wiring the kickstart: {e}");
            return 1;
        }
    };

    note(&l, "boot code built");
    match drive(&mut l, "(undefined-globals)") {
        Ok(v) if v != crate::heap::NIL => {
            let names = l.h.list_vec(v);
            let mut bad = Vec::new();
            for s in names {
                let n = l.h.sym_name(s);
                // *unbound* holds the unbound marker as its value on purpose.
                if n != "*unbound*" {
                    // Qualified, because the interesting question about a name
                    // nothing defines is usually which package it landed in.
                    let pkg = l.h.slot(s, crate::heap::SYM_PACKAGE);
                    if pkg == crate::heap::NIL {
                        bad.push(n);
                    } else {
                        bad.push(format!("{}:{}", l.h.package_name(pkg), n));
                    }
                }
            }
            if !bad.is_empty() {
                eprintln!("warning: compiled code calls undefined globals: {bad:?}");
            }
        }
        _ => {}
    }

    let cons_ptr = l.h.g(LG_CONS_PTR);
    l.h.set_g(LG_IMGENTRY, entry);
    l.h.set_g(LG_IMGVERSION, 1);

    // The forge declares packages for files it reads and never compiles -
    // its own I/O, the assembly stubs - and those reach the machine holding
    // nothing. Dropping them here is the last thing done to the heap, and it
    // leaves the reader standing somewhere that still exists.
    match l.eval_lisp("(in-package user) (gc:forget-unused-packages)") {
        Ok(v) if v != crate::heap::NIL => {
            let names: Vec<String> = l.h.list_vec(v).iter().map(|s| l.h.str_of(*s)).collect();
            if verbose {
                eprintln!("dropped {} empty packages: {}", names.len(), names.join(" "));
            }
        }
        Ok(_) => {}
        Err(e) => {
            eprint!("dropping the forge's own packages: {e}");
            return 1;
        }
    }

    // Run the machine's own collector, on the machine, before writing the
    // image. Everything the compiler consed while building - expanded macro
    // trees, assembler buffers, analysis lists - is garbage the moment the
    // code is placed, and there is nothing left that can see it except the
    // interpreter, which is about to be thrown away.
    collect_before_saving(&mut l, verbose);

    blank_run_scratch(&mut l);

    // Objects are never moved by the machine, for reasons `gc.lisp` explains
    // at length; nothing stops the forge doing it here, on a heap that has
    // stopped, and it is most of the file.
    match crate::forge::compact::compact_objects(&mut l.h, verbose) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("lm: compacting object space: {e}");
            return 1;
        }
    }

    // The collection above already left the allocator pointing at the one run
    // above the live data, so there is nothing to set here; overwriting it
    // would throw away what the compactor decided.
    let _ = cons_ptr;

    let stats = format!(
        "code {} KiB, objects {} KiB, live pairs {}",
        (l.h.g(LG_CODE_PTR) - CODE_BASE) / 1024,
        (l.h.g(LG_OBJ_PTR) - OBJ_BASE) / 1024,
        (l.h.g(LG_CONS_PTR) - CONS_BASE) / 8
    );
    match crate::image::save(l.h.m, out, entry) {
        Ok((pages, bytes)) => {
            println!(
                "{out}: entry {entry:#x}, {stats}, {pages} pages ({} KiB) in {:.2}s",
                bytes / 1024,
                t0.elapsed().as_secs_f64()
            );
            0
        }
        Err(e) => {
            eprintln!("writing {out}: {e}");
            1
        }
    }
}

/// Run one compiled Lisp function on the machine, from Rust.
///
/// The forge needs this exactly once, to collect before saving, but it is the
/// same trampoline the end-to-end tests use: set up a stack and the allocator
/// registers, point the trap vector somewhere, call a closure, stop.
fn call_on_machine(l: &mut Lisp, name: &str, entry_stub: u32) -> Option<u32> {
    use crate::mach::Stop;
    use crate::rvenc::*;
    let sym = l.h.intern_path(name);
    let closure = l.h.sym_value(sym);
    if closure == crate::heap::UNBOUND || closure == crate::heap::NIL {
        eprintln!("lm: {name} is not defined; skipping");
        return None;
    }
    let stack_top = l.h.g(LG_STACKTOP);
    let trap_save = l.h.g(LG_TRAPSAVE);
    let mut c: Vec<u32> = Vec::new();
    li32(&mut c, SP, stack_top);
    c.push(lw(GP, ZERO, LG_CONS_RUN as i32));
    c.push(lw(TP, ZERO, LG_CONSRUNEND as i32));
    li32(&mut c, T0, trap_save);
    c.push(csrrw(ZERO, 0x340, T0)); // mscratch
    li32(&mut c, T0, entry_stub);
    c.push(csrrw(ZERO, 0x305, T0)); // mtvec: the image's own trap stub
    // The closure is handed over through a global rather than baked into the
    // instruction stream. This trampoline is dead code once the build is over,
    // but a pointer sitting in code space is a pointer the collector cannot
    // see, and `lm inspect` checks that there are none.
    l.h.set_g(LG_SCRATCH2, closure);
    c.push(lw(T0, ZERO, LG_SCRATCH2 as i32));
    c.push(addi(T1, ZERO, 0));
    c.push(lw(T2, T0, 0));
    c.push(jalr(RA, T2, 0));
    li32(&mut c, T3, MMIO_BASE);
    c.push(sw(ZERO, T3, 0)); // halt
    c.push(jal(ZERO, 0));
    let at = l.h.alloc_code(4 * c.len() as u32 + 16);
    for (i, &w) in c.iter().enumerate() {
        l.h.m.poke32(at + 4 * i as u32, w);
    }
    l.h.m.pc = at;
    l.h.m.halted = false;
    l.h.m.mstatus = 0;
    l.h.m.mtimecmp = u64::MAX;
    l.h.m.gfx.next_vbl = u64::MAX;
    let st = crate::run::run(l.h.m, 20_000_000_000);
    if st != Stop::Halt {
        eprintln!("lm: {name} did not finish on the machine ({st:?})");
        return None;
    }
    Some(l.h.m.x[10])
}

/// The stack the machine ran the collector on, and the trap frame it would
/// have saved registers into. Both live in the Exec pool, both are scratch,
/// and both are full of whatever the collector last had in hand - Lisp values
/// that are no longer live, written into the image, and words that a
/// conservative scan would have to treat as pointers and pin. A booting image
/// sets its own stack pointer in the reset stub, so nothing here survives.
fn blank_run_scratch(l: &mut Lisp) {
    let regions = [
        (l.h.g(LG_STACKBOT), l.h.g(LG_STACKTOP)),
        (l.h.g(LG_TRAPSAVE), l.h.g(LG_TRAPSAVE) + 128),
    ];
    for (lo, hi) in regions {
        if lo == 0 || hi <= lo || hi > POOL_END {
            continue;
        }
        let mut a = lo;
        while a < hi {
            l.h.st(a, 0);
            a += 4;
        }
    }
}

fn collect_before_saving(l: &mut Lisp, verbose: bool) -> u32 {
    let trap = l.h.g(LG_SCRATCH3);
    let before = l.h.g(LG_CONS_PTR);
    // Everything up to now was allocated by the forge's own bump pointer. The
    // machine's allocator lives in a register, so hand it a run that starts
    // exactly where the forge stopped: the collector reads gp to find out how
    // much of the heap has been used.
    l.h.set_g(LG_CONS_RUN, before);
    l.h.set_g(LG_CONSRUNEND, CONS_END);
    match call_on_machine(l, "gc:gc-for-image", trap) {
        Some(v) => {
            let n = crate::heap::unfix(v) as u32;
            let _ = before;
            if verbose {
                eprintln!("collected: {n} bytes of dead object space blanked");
            }
            n
        }
        None => 0,
    }
}
