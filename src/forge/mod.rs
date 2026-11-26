//! The forge: everything needed to build an image, and nothing needed to run
//! one.
//!
//! It brings up a machine, loads the Lisp sources into that machine's heap
//! with the bootstrap interpreter, and then hands control to the Lisp
//! compiler, itself one of those sources, to compile the whole system into
//! native RISC-V in the same heap. What falls out is the kickstart image.

pub mod compact;
pub mod hostlisp;
pub mod read;

use crate::cap::Cap;
use crate::forge::hostlisp::{LErr, Lisp};
use crate::heap::*;
use crate::mach::Machine;
use crate::map::*;

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
    for f in SYSTEM {
        match std::fs::read_to_string(f) {
            Ok(t) => {
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
        script.push_str(&format!("(gc)\n(+ 1 2)\n(unsafe (%halt {}))\n", crate::mach::EXIT_CHECK_PASSED));
    } else {
        script.push_str("(unsafe (snap:save-fresh))\n");
    }
    if verbose {
        println!("rebuild: {} sources, {} bytes, on {from}", SYSTEM.len(), sources.len());
    }
    // The new image is written to the disk the machine is given, so the disk
    // is the output file. --check writes nothing, and leaves what is there.
    if !check {
        let _ = std::fs::remove_file(out);
    }
    let o = crate::boot::Options {
        image: from.to_string(),
        scale: 1,
        script: Some(script),
        interactive: false,
        // Twenty times what a rebuild takes, so that one that has gone wrong
        // stops and says where rather than running for ever.
        budget: 40_000_000_000,
        disk: if check { None } else { Some(out.to_string()) },
        // LM_FNPROF=1 profiles what the machine does during a rebuild, the
        // same report `lm --fnprof` prints, and LM_ISAPROF=1 counts what it
        // executes, as `lm --isaprof` does.
        trace_exit: verbose || std::env::var_os("LM_FNPROF").is_some() || std::env::var_os("LM_ISAPROF").is_some(),
        isaprof: std::env::var_os("LM_ISAPROF").is_some(),
        fnprof: std::env::var_os("LM_FNPROF").is_some(),
        screenshot: None,
        // LM_TRACE_TRAPS=1 reports every trap the rebuild takes, as
        // `lm --trace-traps` does.
        trace_traps: std::env::var_os("LM_TRACE_TRAPS").is_some(),
    };
    let t = std::time::Instant::now();
    let code = crate::boot::boot(&o);
    // --check ends with a halt code nothing else uses: reaching it is the pass.
    if check {
        if code == crate::mach::EXIT_CHECK_PASSED as i32 {
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
    // object, so it carries every hole it ever made. Nothing is running now,
    // and a fresh image resumes nothing, so the forge closes them and blanks
    // the stacks and frames the image will write before it reads.
    if compact::compact_image(out, out, verbose, true) != 0 {
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

/// Write lisp/layout.lisp: the memory map, the value and object layouts,
/// the permissions and otypes, the trap frame, the trap causes and the
/// chips' refusal codes, the ecall and exit codes and the device registers, as Lisp
/// constants. The Rust definitions are the only source, and the file is
/// regenerated on every build, so the two sides cannot drift apart.
pub fn write_layout() {
    use crate::cap;
    use crate::mach::*;
    let mut s = String::new();
    s.push_str(";;; layout.lisp - GENERATED by `lmforge layout`. Do not edit.\n");
    s.push_str(";;; The source of these numbers is src/map.rs, src/mach.rs, src/cap.rs,\n");
    s.push_str(";;; src/heap.rs and src/dev/*.rs; this file is regenerated on every build.\n\n");
    s.push_str("(in-package lm)\n\n");

    // Every name is a `defconstant`, so a use compiles to the number itself.
    // A fixnum is 32 bits, so a constant at or above 2^31 is written as the
    // signed value with the same bits: `li` encodes it into the same
    // lui/addi pair either way.
    macro_rules! def {
        ($name:expr, $v:expr) => {{
            let v: u32 = $v;
            if v >= (1 << 31) {
                s.push_str(&format!("(defconstant {} {})\n", $name, v as i32))
            } else {
                s.push_str(&format!("(defconstant {} #x{:x})\n", $name, v))
            }
        }};
    }

    s.push_str(";; ---- memory map ----\n");
    def!("ram-size", RAM_SIZE);
    def!("chip-size", CHIP_SIZE);
    def!("nil-cell", NIL_CELL);
    def!("low-end", LOW_END);
    def!("cons-base", CONS_BASE);
    def!("cons-limit", CONS_END);
    def!("obj-base", OBJ_BASE);
    def!("obj-limit", OBJ_END);
    def!("gc-bitmap", GC_BITMAP);
    def!("gc-bitmap-bytes", GC_BITMAP_BYTES);
    def!("obj-starts", OBJ_STARTS);
    def!("obj-starts-bytes", OBJ_STARTS_BYTES);
    def!("scratch-base", SCRATCH);
    def!("scratch-bytes", SCRATCH_BYTES);
    def!("obj-starts-magic", OBJ_STARTS_MAGIC);
    def!("reset-vector", RESET_VECTOR);
    def!("reset-reserve", RESET_RESERVE);
    def!("dev-count", DEV_COUNT);
    def!("dev-page-bytes", 1 << DEV_SHIFT);
    // The first word of an image the machine writes itself, which is how the
    // loader tells one from an image the forge built.
    def!("snap-magic", crate::image::SNAP_MAGIC);

    // The kernel block's slots, by number. One that holds a count holds it
    // as a fixnum; one that holds a value holds the value.
    s.push_str("\n;; ---- the kernel block, which mscratch names: its slots ----\n");
    def!("kb-base", KB_BASE);
    def!("kb-slots", KB_SLOTS);
    def!("kb-unscanned", KB_UNSCANNED);
    for (name, slot) in KERNEL_SLOTS {
        def!(format!("kb-{name}"), *slot);
    }

    s.push_str("\n;; ---- values ----\n");
    def!("value-bytes", VALUE_BYTES);
    def!("header-bytes", HEADER_BYTES);
    def!("pair-bytes", PAIR_BYTES);
    def!("imm-fixnum", IMM_FIXNUM);
    def!("imm-char", IMM_CHAR);
    def!("imm-unbound", IMM_UNBOUND);
    def!("imm-eof", IMM_EOF);
    def!("imm-void", IMM_VOID);
    def!("imm-default", IMM_DEFAULT);
    // What `vkind` answers: an untagged value's metadata below 16, then nil,
    // a pair and any other capability, and an object's header type above 32.
    def!("kind-fixnum", IMM_FIXNUM);
    def!("kind-char", IMM_CHAR);
    def!("kind-unbound", IMM_UNBOUND);
    def!("kind-eof", IMM_EOF);
    def!("kind-void", IMM_VOID);
    def!("kind-default", IMM_DEFAULT);
    def!("kind-nil", KIND_NIL);
    def!("kind-pair", KIND_PAIR);
    def!("kind-cap", KIND_CAP);
    def!("kind-object", KIND_OBJECT);

    // Permissions in RVY's bit field, as `YPERMR` answers them and `YPERMC`
    // takes a mask of them, and the sets the allocators hand out.
    s.push_str("\n;; ---- permissions and otypes ----\n");
    def!("perm-ld", cap::ap_of(cap::P_LD));
    def!("perm-sd", cap::ap_of(cap::P_SD));
    def!("perm-lc", cap::ap_of(cap::P_LC));
    def!("perm-sc", cap::ap_of(cap::P_SC));
    def!("perm-lm", cap::ap_of(cap::P_LM));
    def!("perm-ex", cap::ap_of(cap::P_EX));
    def!("perm-sr", cap::ap_of(cap::P_SR));
    def!("perm-se", cap::ap_of(cap::P_SE));
    def!("perm-hd", cap::ap_of(cap::P_HD));
    def!("perms-all", cap::AP_ALL);
    def!("perms-pair", cap::ap_of(PERMS_PAIR));
    def!("perms-object", cap::ap_of(PERMS_OBJECT));
    def!("perms-bytes", cap::ap_of(PERMS_BYTES));
    def!("perms-nil", cap::ap_of(PERMS_NIL));
    def!("perms-code", cap::ap_of(PERMS_CODE));
    def!("perms-space", cap::ap_of(PERMS_SPACE));
    def!("otype-unsealed", cap::OT_UNSEALED);
    def!("otype-sentry", cap::OT_SENTRY);
    def!("otype-closure", cap::OT_CLOSURE);

    s.push_str("\n;; ---- object representation ----\n");
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
    def!("t-text", T_TEXT);
    def!("t-stack", T_STACK);
    def!("t-context", T_CONTEXT);
    def!("t-kernel", T_KERNEL);
    def!("code-entry", CODE_ENTRY);
    def!("code-name", CODE_NAME);
    def!("code-lits", CODE_LITS);
    def!("clo-entry", CLO_ENTRY);
    def!("clo-code", CLO_CODE);
    def!("clo-free", CLO_FREE);
    def!("sym-slots", SYM_SLOTS);
    def!("sym-name", SYM_NAME);
    def!("sym-value", SYM_VALUE);
    def!("sym-function", SYM_FUNCTION);
    def!("sym-plist", SYM_PLIST);
    def!("sym-flags", SYM_FLAGS);
    def!("sym-package", SYM_PACKAGE);
    def!("sym-macro", SYM_MACRO as u32);
    def!("sym-exported", SYM_EXPORTED as u32);
    def!("sym-unsafe", SYM_UNSAFE as u32);
    def!("sym-constant", SYM_CONSTANT as u32);
    def!("sym-detached", SYM_DETACHED as u32);
    def!("pkg-tag", PKG_TAG);
    def!("pkg-name", PKG_NAME);
    def!("pkg-use", PKG_USE);
    def!("pkg-slots", PKG_SLOTS);

    // The trap stub saves every register into a context, so a task's
    // context and a trap frame are the same shape: 32 value slots, slot 0
    // the pc (`mepc`) and slot i register xi, and a frame for a nested trap
    // has its link after them. These name the slots.
    s.push_str("\n;; ---- contexts and trap frames ----\n");
    def!("ctx-slots", 32);
    def!("ctx-bytes", 32 * VALUE_BYTES);
    for (i, name) in [
        "pc", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
    ]
    .iter()
    .enumerate()
    {
        def!(format!("reg-{name}"), i as u32);
    }

    s.push_str("\n;; ---- ecall codes: what a7 carries when compiled code raises one ----\n");
    def!("ecall-arity", E_ARITY);
    def!("ecall-oom", E_OOM);
    def!("ecall-error", E_ERROR);
    def!("ecall-reschedule", E_RESCHEDULE);
    def!("ecall-record", E_RECORD);
    def!("ecall-unsafe", E_UNSAFE);

    s.push_str("\n;; ---- trap causes ----\n");
    def!("cause-misaligned-fetch", C_IALIGN);
    def!("cause-fetch-fault", C_IFAULT);
    def!("cause-illegal", C_ILLEGAL);
    def!("cause-breakpoint", C_BREAK);
    def!("cause-misaligned-load", C_LALIGN);
    def!("cause-load-fault", C_LFAULT);
    def!("cause-misaligned-store", C_SALIGN);
    def!("cause-store-fault", C_SFAULT);
    def!("cause-ecall", C_ECALL);
    def!("cause-wrong-type", C_TYPE);
    def!("cause-range", C_RANGE);
    def!("cause-overflow", C_OVER);
    def!("cause-divzero", C_DIVZERO);
    def!("cause-run", C_RUN);
    def!("cause-barrier", C_BARRIER);
    def!("cause-stack", C_STACK);
    def!("cause-cap-fetch", C_CAP_FETCH);
    def!("cause-cap-load", C_CAP_LOAD);
    def!("cause-cap-store", C_CAP_STORE);

    // Why a chip refused a transfer, as its status says.
    s.push_str("\n;; ---- the chips' refusals ----\n");
    def!("refuse-length", crate::dev::REFUSE_LENGTH);
    def!("refuse-tag", crate::dev::REFUSE_TAG);
    def!("refuse-seal", crate::dev::REFUSE_SEAL);
    def!("refuse-load", crate::dev::REFUSE_LOAD);
    def!("refuse-store", crate::dev::REFUSE_STORE);
    def!("refuse-object", crate::dev::REFUSE_OBJECT);

    s.push_str("\n;; ---- interrupt numbers, as mcause carries them ----\n");
    def!("irq-software", IRQ_SOFT);
    def!("irq-timer", IRQ_TIMER);
    def!("irq-external", IRQ_EXT);

    s.push_str("\n;; ---- exit codes ----\n");
    def!("exit-ok", EXIT_OK);
    def!("exit-error", EXIT_ERROR);
    def!("exit-oom", EXIT_OOM);
    def!("exit-gc-stack", EXIT_GC_STACK);
    def!("exit-gc-corrupt", EXIT_GC_CORRUPT);
    def!("exit-trap-spiral", EXIT_TRAP_SPIRAL);
    def!("exit-check-passed", EXIT_CHECK_PASSED);

    s.push_str("\n;; ---- device pages and interrupt lines ----\n");
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

    // The serial port is reached raw by the prelude, which cannot see hw.
    s.push_str("\n;; ---- the serial port ----\n");
    {
        use crate::dev::uart::*;
        def!("uart-data-reg", U_DATA);
        def!("uart-status-reg", U_STATUS);
        def!("uart-ctrl-reg", U_CTRL);
        def!("uart-count-reg", U_COUNT);
    }

    s.push_str("\n;; ---- disk ----\n");
    {
        use crate::dev::disk::*;
        def!("disk-busy", STATUS_BUSY);
        def!("disk-refused", STATUS_REFUSED);
        def!("disk-cmd-read", CMD_READ);
        def!("disk-cmd-write", CMD_WRITE);
        def!("disk-cmd-flush", CMD_FLUSH);
    }

    // The blitter takes its command from a descriptor in memory; this is the
    // descriptor's layout and its done words; its registers' accessors are
    // in devices.lisp.
    s.push_str("\n;; ---- blitter descriptor ----\n");
    {
        use crate::dev::blit::*;
        def!("blit-status-busy", STATUS_BUSY);
        def!("blit-status-refused", STATUS_REFUSED);
        def!("blit-list-size", LIST_BYTES);
        for (name, off) in [("src", L_SRC), ("dst", L_DST), ("next", L_NEXT),
                            ("w", L_W), ("h", L_H), ("smod", L_SMOD), ("dmod", L_DMOD),
                            ("val", L_VAL), ("op", L_OP), ("x0", L_X0), ("y0", L_Y0),
                            ("x1", L_X1), ("y1", L_Y1), ("status", L_STATUS)]
        {
            def!(format!("bl-{name}"), off);
        }
        def!("blit-done", DONE);
        def!("blit-pending", DONE_PENDING);
        def!("blit-refused-src", REFUSED_SRC);
        def!("blit-refused-dst", REFUSED_DST);
        def!("op-copy", OP_COPY);
        def!("op-fill", OP_FILL);
        def!("op-xor", OP_XOR);
        def!("op-and", OP_AND);
        def!("op-or", OP_OR);
        def!("op-mask", OP_MASK);
        def!("op-line", OP_LINE);
        def!("op-add", OP_ADD);
    }

    // Register offsets belong to hw, the one package that names a register.
    // An offset on its own names nothing; `hw:dev-reg` turns one into an
    // address, and only for a device the caller holds.
    s.push_str("\n;; ---- device registers, as offsets into a device's page ----\n");
    s.push_str("(in-package hw)\n\n");
    {
        use crate::dev::*;
        def!("sys-halt", SYS_HALT);
        def!("sys-debug", SYS_DEBUG);
        def!("sys-intreq", SYS_INTREQ);
        def!("sys-intena", SYS_INTENA);
        def!("sys-intnum", SYS_INTNUM);
        def!("sys-cyclo", SYS_CYCLO);
        def!("sys-cychi", SYS_CYCHI);
        def!("sys-random", SYS_RANDOM);
        def!("sys-ramsize", SYS_RAMSIZE);
        def!("sys-chipsize", SYS_CHIPSIZE);
        def!("sys-intset", SYS_INTSET);
        def!("sys-reset", SYS_RESET);
        def!("tmr-lo", TMR_LO);
        def!("tmr-hi", TMR_HI);
        def!("tmr-cmplo", TMR_CMPLO);
        def!("tmr-cmphi", TMR_CMPHI);
        def!("tmr-freq", TMR_FREQ);
        def!("tmr-wall", TMR_WALL);
    }
    {
        use crate::dev::gfx::*;
        def!("gfx-on", CTRL_ON);
        def!("gfx-vbirq", CTRL_VBIRQ);
    }
    let _ = std::fs::write("lisp/layout.lisp", s);
    write_devices();
}

/// Write lisp/devices.lisp: for each chip a driver owns and for the
/// blitter, the base of its page and an accessor for every register, from
/// the register tables in src/dev/*.rs. An accessor takes the device, a
/// page sealed with otype 5, and opens it with `device-open`, which refuses
/// a device of another class; so a safe accessor only ever touches a
/// register of the device it was written for. A register only loaded has no
/// setter, and one only stored no reader.
fn write_devices() {
    use crate::dev::Reg;
    use crate::map::*;
    let mut s = String::new();
    s.push_str(";;; devices.lisp - GENERATED by `lmforge layout` from src/dev/*.rs. Do not edit.\n");
    s.push_str(";;; A device is its page sealed with `otype-device` (see hw.lisp). Each\n");
    s.push_str(";;; accessor below opens the device it is handed for the one class it was\n");
    s.push_str(";;; written for, by the base of its page, and loads or stores one register:\n");
    s.push_str(";;; handed another device it traps, and it never touches another device's\n");
    s.push_str(";;; register. `(gfx-ctrl dev)` reads a register, `(gfx-ctrl! dev v)` writes\n");
    s.push_str(";;; it, and a capability register moves a capability. Opening the device and\n");
    s.push_str(";;; the load or store through its page are the accessor's one block.\n\n");
    s.push_str("(in-package hw)\n");
    let signed = |v: u32| v as i32;
    let mut names: Vec<String> = Vec::new();
    let chips: [(&str, &str, u32, &[Reg]); 4] = [
        ("gfx", "g", DEV_GFX, crate::dev::gfx::REGS),
        ("input", "i", DEV_INPUT, crate::dev::input::REGS),
        ("blit", "b", DEV_BLIT, crate::dev::blit::REGS),
        ("disk", "d", DEV_DISK, crate::dev::disk::REGS),
    ];
    for (dev, prefix, num, regs) in chips {
        let base = format!("{dev}-page-base");
        s.push_str(&format!("\n;; ---- {dev} ----\n"));
        s.push_str(&format!("(defconstant {base} {})\n", signed(MMIO_BASE + (num << DEV_SHIFT))));
        names.push(base.clone());
        for r in regs {
            s.push_str(&format!("(defconstant {prefix}-{} #x{:x})\n", r.name, r.off));
            names.push(format!("{prefix}-{}", r.name));
        }
        for r in regs {
            let (get, put) = if r.cap { ("%cap-ld", "%cap-st!") } else { ("%cap-ld-word", "%cap-st-word!") };
            let open = format!("(device-open dev {base})");
            let off = format!("{prefix}-{}", r.name);
            if r.read {
                s.push_str(&format!("(define ({dev}-{} dev) (unsafe ({get} {open} {off})))\n", r.name));
                names.push(format!("{dev}-{}", r.name));
            }
            if r.write {
                s.push_str(&format!("(define ({dev}-{}! dev v) (unsafe ({put} {open} {off} v)))\n", r.name));
                names.push(format!("{dev}-{}!", r.name));
            }
        }
    }
    s.push_str("\n;; The name of the device whose page `dev` is, from its base, or nil.\n");
    s.push_str("(define (device-name dev)\n  (let ((b (%cap-base dev)))\n    (cond");
    for (name, num) in [("sys", DEV_SYS), ("uart", DEV_UART), ("timer", DEV_TIMER), ("gfx", DEV_GFX),
                        ("input", DEV_INPUT), ("blit", DEV_BLIT), ("disk", DEV_DISK)] {
        s.push_str(&format!("\n     ((%= b {}) \"{name}\")", signed(MMIO_BASE + (num << DEV_SHIFT))));
    }
    s.push_str("\n     (else nil))))\n");
    names.push("device-name".into());
    s.push_str("\n(export '(");
    let mut col = 10;
    for (i, n) in names.iter().enumerate() {
        if i > 0 {
            if col + n.len() + 1 > 78 {
                s.push_str("\n  ");
                col = 2;
            } else {
                s.push(' ');
                col += 1;
            }
        }
        s.push_str(n);
        col += n.len();
    }
    s.push_str("))\n");
    let _ = std::fs::write("lisp/devices.lisp", s);
}

/// Sources are loaded in this order. Each one may only use what the ones
/// before it defined.
pub const BOOT_ORDER: &[&str] = &[
    // Everything down to read.lisp is read by the bootstrap reader in Rust,
    // which has one flat namespace. That is why these files are the prelude
    // and nothing else: their names belong in one namespace anyway.
    "boot0.lisp",
    "layout.lisp",
    "core.lisp",
    "macros.lisp",
    "runtime.lisp",
    "hostio.lisp",
    "stream.lisp",
    "read.lisp",
    // From here on the real reader is in charge, so the package declarations
    // can be read: an export list has to be read in the package it is
    // exporting from.
    "packages.lisp",
    "gc.lisp",
    "hw.lisp",
    "devices.lisp",
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
    "lisp/devices.lisp",
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
    "lisp/wb.lisp",
    "lisp/eyes.lisp",
    "lisp/ui.lisp",
    "lisp/explorer.lisp",
    "lisp/demo.lisp",
];

/// Bring the bootstrap up, and switch readers as soon as there is one.
///
/// The files before `read.lisp` are read by the reader in Rust, which knows
/// nothing about packages and puts everything in one namespace; they are the
/// shortest path to having the real reader running. Everything after it,
/// including `packages.lisp`, is read by the real reader, so the declarations
/// in it land in the packages they name.
pub fn boot_host(l: &mut Lisp) -> Result<(), LErr> {
    for f in BOOT_ORDER {
        let text = match std::fs::read_to_string(format!("lisp/{f}")) {
            Ok(t) => t,
            Err(e) => {
                return Err(LErr::new(format!(
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
/// Lisp, not the machine's own REPL, for poking at the compiler.
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

/// Evaluate one step of the build, standing in the prelude.
///
/// Read by the Lisp reader, not the bootstrap one: `sys:kickstart` names a
/// symbol in a package, and only the real reader knows that. Each step says
/// where it is standing, because compiling a file leaves the reader in
/// whatever package that file ended in. It stands in `lm`, which is where
/// the bootstrap reader put everything hostio.lisp defines.
fn drive(l: &mut Lisp, src: &str) -> hostlisp::Res {
    l.eval_lisp(&format!("(in-package lm) {src}"))
}

/// Build the kickstart image.
///
/// The whole bootstrap in one function: bring up the interpreter, let it
/// read the compiler, then let the compiler compile the system, itself
/// included, into the heap the interpreter has been building. What is left in
/// memory at the end is the image.
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
                "{what}: {} pairs, {} obj bytes",
                (l.h.g(KB_CONS_PTR) - CONS_BASE) / PAIR_BYTES,
                l.h.g(KB_OBJ_PTR) - OBJ_BASE
            );
        }
    };
    note(&l, "host up");

    // What the stubs stand on, the boot stack, the trap stack and the
    // frames, made first, before anything is compiled to run on them.
    if let Err(e) = drive(&mut l, "(boot:reserve-stub-memory)") {
        eprint!("{e}");
        return 1;
    }

    note(&l, "stub memory reserved");
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

    // Wire the pieces the assembly stubs reach through the kernel block, and
    // the boot list the kickstart runs.
    for step in [
        "(%set-slot! (%kernel) kb-toplevel (%symbol-value 'sys:kickstart))",
        "(%set-slot! (%kernel) kb-trap-hook (%symbol-value 'sys:handle-trap))",
        "(%set-symbol-value! 'sys:*boot-list* (reverse compiler:*boot-thunks*))",
    ] {
        if let Err(e) = drive(&mut l, step) {
            eprint!("wiring {step}: {e}");
            return 1;
        }
        note(&l, step);
    }
    // The trap stub goes into object space and its entry into the kernel
    // block, and the reset stub to the reset vector.
    if let Err(e) = drive(&mut l, "(boot:build-boot-code)") {
        eprint!("wiring the kickstart: {e}");
        return 1;
    }

    note(&l, "boot code built");
    match drive(&mut l, "(undefined-globals)") {
        Ok(v) if v != NIL => {
            let names = l.h.list_vec(v);
            let mut bad = Vec::new();
            for s in names {
                let n = l.h.sym_name(s);
                // *unbound* holds the unbound marker as its value by design.
                if n != "*unbound*" {
                    // Qualified, because the interesting question about a name
                    // nothing defines is usually which package it landed in.
                    let pkg = l.h.slot(s, SYM_PACKAGE);
                    if pkg == NIL {
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

    // The forge declares packages for files it reads and never compiles (its
    // own I/O, the assembly stubs), and those reach the machine holding
    // nothing. Dropping them here is the last thing done to the heap, and it
    // leaves the reader standing somewhere that still exists.
    match l.eval_lisp("(in-package user) (gc:forget-unused-packages)") {
        Ok(v) if v != NIL => {
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
    // image. Everything the compiler consed while building (expanded macro
    // trees, assembler buffers, analysis lists) is garbage once the code is
    // placed, and nothing can see it except the interpreter, which is about
    // to be thrown away.
    if !collect_before_saving(&mut l, verbose) {
        return 1;
    }

    // The collector ran on the boot stack, and its registers were saved in
    // the boot context: values no longer live, whose tags would keep what
    // they name in the image. A booting image starts on them afresh.
    l.h.blank_stub_state();

    // Objects, machine code among them, are never moved by the machine, for
    // reasons `gc.lisp` explains at length; nothing stops the forge doing it
    // here, on a heap that has stopped, and it is most of the file.
    match compact::compact_objects(&mut l.h, verbose) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("lm: compacting object space: {e}");
            return 1;
        }
    }

    let stats = format!(
        "objects {} KiB ({} KiB of it code), live pairs {}",
        (l.h.g(KB_OBJ_PTR) - OBJ_BASE) / 1024,
        l.h.text_bytes() / 1024,
        (l.h.g(KB_CONS_PTR) - CONS_BASE) / PAIR_BYTES
    );
    let entry = RESET_VECTOR;
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

/// Run one compiled Lisp function on the machine, from Rust, and answer what
/// it returned.
///
/// The machine starts as it does from an image: at the reset vector with
/// the root in PCC, and the reset stub mints the memory map, stands on the
/// boot stack and enters the kernel block's top level, which for the length
/// of the call is the function. When it returns, the stub stops the machine
/// with what it answered still in a0.
fn call_on_machine(l: &mut Lisp, name: &str) -> Option<V> {
    use crate::mach::Stop;
    use crate::rvenc::*;
    let sym = l.h.intern_path(name);
    let closure = l.h.sym_value(sym);
    if !l.h.is_type(closure, T_CLOSURE) || !closure.is_sealed() {
        eprintln!("lm: {name} is not a compiled function; skipping");
        return None;
    }
    if l.h.gv(KB_BOOTSTACK) == NIL || l.h.gv(KB_TRAPENTRY) == NIL {
        eprintln!("lm: the boot stack or the trap stub is not set up");
        return None;
    }
    let top = l.h.gv(KB_TOPLEVEL);
    l.h.set_gv(KB_TOPLEVEL, closure);
    let m = &mut *l.h.m;
    for r in 1..32 {
        m.set_reg(r, Cap::NULL);
    }
    crate::boot::reset(m, RESET_VECTOR);
    m.halted = false;
    m.mstatus = 0;
    m.mtimecmp = u64::MAX;
    m.gfx.next_vbl = u64::MAX;
    let st = crate::run::run(m, 20_000_000_000);
    let a0 = m.reg(A0);
    l.h.set_gv(KB_TOPLEVEL, top);
    if st != Stop::Halt {
        eprintln!("lm: {name} did not finish on the machine ({st:?})");
        return None;
    }
    Some(a0)
}

/// Run the machine's own collector over everything the build made. An
/// image written without it would carry everything the compiler consed.
/// The machine's allocator goes in first, as the kickstart would put it:
/// the collection makes the descriptor ring it clears the mark map through.
fn collect_before_saving(l: &mut Lisp, verbose: bool) -> bool {
    if call_on_machine(l, "gc:install-allocator").is_none() {
        eprintln!("lm: the machine's allocator did not go in; no image written");
        return false;
    }
    match call_on_machine(l, "gc:collect-for-image") {
        Some(v) => {
            if verbose {
                eprintln!("collected: {} bytes of dead object space blanked", unfix(v));
            }
            true
        }
        None => {
            eprintln!("lm: the collection before saving did not run; no image written");
            false
        }
    }
}
