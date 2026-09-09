//! Conformance tests for the reader.
//!
//! There used to be two readers - one in Rust for the bootstrap, one in Lisp
//! for the machine - and this file compared them, because two implementations
//! of what a name means had to agree exactly or a symbol read at build time
//! would not be the symbol read at run time.
//!
//! There is one now. `lisp/read.lisp` reads everything, including itself, and
//! the bootstrap reader in Rust knows only how to make a list. So what is left
//! to check is not agreement but behaviour: that a bare name finds what its
//! package can see, that `pkg:name` reaches an export and `pkg::name` reaches
//! past the interface, and that asking for something a package does not export
//! is an error rather than a fresh symbol.

use crate::forge::hostlisp::Lisp;
use crate::forge::{boot_host, write_layout};
use crate::mach::Machine;

/// Read `text` while standing in `pkg`, and report where the symbol ended up.
const PROBE: &str = r#"
(define (probe-read pkg text)
  (let ((old (current-package)) (r nil))
    (set-current-package! (find-package pkg))
    (set! r (read-from-string text))
    (set-current-package! old)
    (list (package-name (symbol-package r)) (%symbol-name r))))
"#;

/// (package to read in, the text, where the symbol should end up)
const CASES: &[(&str, &str, &str)] = &[
    // The package's own names.
    ("lm", "car", "(\"lm\" \"car\")"),
    ("wb", "draw-char", "(\"wb\" \"draw-char\")"),
    // Inherited through the use list: wb has no `car`, the prelude does.
    ("wb", "car", "(\"lm\" \"car\")"),
    ("user", "workbench", "(\"wb\" \"workbench\")"),
    ("compiler", "define", "(\"lm\" \"define\")"),
    // Reaching in from outside, by the two spellings.
    ("user", "lm:car", "(\"lm\" \"car\")"),
    ("user", "wb::draw-char", "(\"wb\" \"draw-char\")"),
    ("gc", "wb::title-height", "(\"wb\" \"title-height\")"),
    // A name nobody has becomes one of the reader's own package's - and the
    // same name read in two packages is two symbols, which is the whole point
    // of having packages at all.
    ("user", "a-name-of-its-own", "(\"user\" \"a-name-of-its-own\")"),
    ("wb", "a-name-of-its-own", "(\"wb\" \"a-name-of-its-own\")"),
];

/// Text that must be refused rather than quietly interned.
const ERRORS: &[(&str, &str)] = &[
    // Private, so one colon is not enough.
    ("user", "wb:shell-putc"),
    // No such package at all.
    ("user", "nosuchpackage:thing"),
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
        .map(|f| format!("(compile-file {f:?})\n"))
        .collect();
    if let Err(e) = l.eval_string(&script, "<readers>") {
        eprint!("compiling the library: {e}");
        return false;
    }
    if let Err(e) = l.eval_lisp(PROBE) {
        eprint!("defining the probe: {e}");
        return false;
    }

    let mut pass = 0;
    let mut fail = 0;
    for (pkg, text, want) in CASES {
        let src = format!("(probe-read {pkg:?} {text:?})");
        match l.eval_lisp(&src) {
            Ok(v) => {
                let got = l.h.write(v);
                if got == *want {
                    pass += 1;
                } else {
                    fail += 1;
                    println!("FAIL reading {text} in {pkg}");
                    println!("     want {want}");
                    println!("     got  {got}");
                }
            }
            Err(e) => {
                fail += 1;
                println!("FAIL reading {text} in {pkg}: {}", e.msg);
            }
        }
    }
    for (pkg, text) in ERRORS {
        let src = format!("(probe-read {pkg:?} {text:?})");
        match l.eval_lisp(&src) {
            Err(_) => pass += 1,
            Ok(v) => {
                fail += 1;
                println!(
                    "FAIL reading {text} in {pkg} should have been refused, gave {}",
                    l.h.write(v)
                );
            }
        }
    }

    println!("readers: {pass} passed, {fail} failed");
    fail == 0
}
