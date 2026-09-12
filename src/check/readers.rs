//! Conformance tests for the reader.
//!
//! `lisp/read.lisp` reads everything, including itself; the bootstrap reader
//! in Rust knows only how to make a list. These cases check name resolution:
//! a bare name finds what its package can see, `pkg:name` reaches an export,
//! `pkg::name` reaches past the interface, and asking for something a package
//! does not export is an error rather than a fresh symbol.

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
    ("gc", "wb::damage-max", "(\"wb\" \"damage-max\")"),
    // A name no package has is interned in the reader's current package, so
    // the same name read in two packages is two symbols.
    ("user", "a-name-of-its-own", "(\"user\" \"a-name-of-its-own\")"),
    ("wb", "a-name-of-its-own", "(\"wb\" \"a-name-of-its-own\")"),
];

/// Text that must be refused rather than interned.
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
