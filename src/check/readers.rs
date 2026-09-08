//! Differential test for the two readers.
//!
//! There are two implementations of what a name means: the forge's, in Rust,
//! and the machine's, in Lisp. They have to agree exactly, because a symbol
//! read at build time and one read by the running machine are the same symbol
//! or they are not, and nothing in between is survivable. This is the same
//! discipline `asm` applies to the two instruction encoders, for the same
//! reason: one implementation agreeing with itself is not evidence.
//!
//! The comparison is on identity, not on spelling. Each side resolves a name
//! in a package and answers the address of the symbol it got, so a hash that
//! disagreed - which would quietly intern a second symbol of the same name -
//! shows up as a different number rather than as the same text.

use crate::check::compiler::run_one;
use crate::forge::hostlisp::Lisp;
use crate::forge::{boot_host, write_layout};
use crate::heap::NIL;
use crate::mach::Machine;

/// Names worth asking about: ones a package holds itself, ones it only sees
/// because something it uses exported them, ones two packages both have, and
/// ones nobody has anywhere.
const CASES: &[(&str, &str)] = &[
    ("lm", "car"),
    ("lm", "define"),
    ("lm", "%car"),
    ("lm", "t"),
    ("user", "car"),        // inherited from the prelude
    ("user", "workbench"),  // inherited from wb
    ("user", "gc"),
    ("wb", "draw-char"),    // wb's own, and private
    ("wb", "title-height"),
    ("wb", "car"),          // inherited
    ("compiler", "compile-top"),
    ("compiler", "trap-arity"),
    ("sys", "trap-arity"),  // the same name, a different package
    ("gc", "gc-extra-roots"),
    ("exec", "gc-extra-roots"), // gc's symbol, overridden by exec
    ("asm", "i-lw"),
    ("mem", "t-vector"),
    ("hw", "plot"),
    ("snap", "save-image"),
    ("lm", "no-such-name-anywhere"),
];

pub fn run() -> bool {
    write_layout();
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return false;
    }
    let script: String = crate::forge::SYSTEM
        .iter()
        .map(|f| format!("(hostio:compile-file {f:?})\n"))
        .collect();
    if let Err(e) = l.eval_string(&script, "<readers>") {
        eprint!("compiling the library: {e}");
        return false;
    }

    let mut pass = 0;
    let mut fail = 0;
    for (pkg, name) in CASES {
        // The machine's answer, from its own reader's resolution, as the
        // address of whatever symbol it settled on.
        let src = format!(
            "(%addr-of (intern-visible (find-package {pkg:?}) {name:?}))"
        );
        let got = run_one(&mut l, &src);
        // The forge's answer, from the same three rules in Rust.
        let p = match l.h.find_package(pkg) {
            Some(p) => p,
            None => {
                println!("FAIL {pkg}:{name} - the forge has no such package");
                fail += 1;
                continue;
            }
        };
        let sym = l.h.intern_visible(p, name);
        let want = sym.to_string();
        if got == want {
            pass += 1;
        } else {
            fail += 1;
            println!("FAIL {pkg}:{name}");
            println!("     forge   {want}");
            println!("     machine {got}");
        }
    }

    // And that every symbol in the image knows which package it belongs to:
    // one without a home would print unqualified from anywhere and could not
    // be found again by name.
    let mut homeless = 0;
    let mut all = l.h.g(crate::map::LG_SYMLIST);
    let mut n = 0;
    while all != NIL {
        let s = l.h.car(all);
        if l.h.slot(s, crate::heap::SYM_PACKAGE) == NIL {
            if homeless < 5 {
                println!("FAIL homeless symbol {}", l.h.sym_name(s));
            }
            homeless += 1;
        }
        n += 1;
        all = l.h.cdr(all);
    }
    if homeless > 0 {
        println!("     {homeless} symbols of {n} have no package");
        fail += 1;
    } else {
        pass += 1;
    }

    println!("readers: {pass} passed, {fail} failed, {n} symbols checked");
    fail == 0
}
