//! End to end compiler tests: compile a Lisp expression to RISC-V, run it on
//! the machine, print what came back.
//!
//! This is the only test that proves the whole chain - reader, macro expander,
//! compiler, assembler, object memory, processor - agrees with itself.

use crate::forge::{boot_host, write_layout};
use crate::heap::*;
use crate::forge::hostlisp::Lisp;
use crate::mach::{Machine, Stop, C_TYPE};
use crate::map::*;
use crate::run;
use crate::rvenc::*;

/// Somewhere harmless to leave the answer and the fault report.
const RESULT: u32 = 0x0000_0C00;
const FAULT: u32 = 0x0000_0C10;
const STACK_TOP: u32 = 0x0100_0000; // top of the exec pool, below code space

/// Assemble words at an address.
fn put(m: &mut Machine, at: u32, code: &[u32]) {
    for (i, &w) in code.iter().enumerate() {
        m.poke32(at + 4 * i as u32, w);
    }
}

/// A trap handler that records what went wrong and stops the machine, so a
/// miscompiled program produces a diagnosis instead of a hang.
fn trap_stub(m: &mut Machine, at: u32) {
    let mut c = Vec::new();
    li32(&mut c, T0, FAULT);
    c.push(csrrs(T1, 0x342, ZERO)); // mcause
    c.push(sw(T1, T0, 0));
    c.push(csrrs(T1, 0x341, ZERO)); // mepc
    c.push(sw(T1, T0, 4));
    c.push(csrrs(T1, 0x343, ZERO)); // mtval
    c.push(sw(T1, T0, 8));
    c.push(sw(A7, T0, 12)); // the ecall code, if this was an ecall
    li32(&mut c, T0, MMIO_BASE);
    c.push(addi(T1, ZERO, 9));
    c.push(sw(T1, T0, 0)); // halt
    c.push(jal(ZERO, 0));
    put(m, at, &c);
}

/// The stub the inline cons allocator calls when it runs out of room. Nothing
/// collects yet, so it reports and stops; the collector replaces this later.
fn cons_stub(m: &mut Machine, at: u32) {
    let mut c = Vec::new();
    c.push(addi(A7, ZERO, 3)); // trap-oom
    c.push(ecall());
    c.push(jalr(ZERO, RA, 0));
    put(m, at, &c);
}

/// Call a closure with no arguments, stash a0, halt.
fn trampoline(m: &mut Machine, at: u32, closure: u32, trap: u32) {
    let mut c = Vec::new();
    li32(&mut c, SP, STACK_TOP);
    li32(&mut c, T0, LG_CONS_PTR);
    c.push(lw(GP, T0, 0));
    li32(&mut c, T0, LG_CONS_END);
    c.push(lw(TP, T0, 0));
    li32(&mut c, T0, trap);
    c.push(csrrw(ZERO, 0x305, T0)); // mtvec
    li32(&mut c, T0, closure);
    c.push(addi(T1, ZERO, 0)); // zero arguments
    c.push(lw(T2, T0, 0)); // entry address
    c.push(jalr(RA, T2, 0));
    li32(&mut c, T3, RESULT);
    c.push(sw(A0, T3, 0));
    li32(&mut c, T3, MMIO_BASE);
    c.push(sw(ZERO, T3, 0)); // halt, exit code 0
    c.push(jal(ZERO, 0));
    put(m, at, &c);
}

struct Case(&'static str, &'static str);

fn cases() -> Vec<Case> {
    vec![
        // ---- constants and arithmetic ----
        Case("42", "42"),
        Case("-7", "-7"),
        Case("(%+ 2 3)", "5"),
        Case("(%- 2 3)", "-1"),
        Case("(%* 6 7)", "42"),
        Case("(%* -6 7)", "-42"),
        Case("(%/ 17 5)", "3"),
        Case("(%/ -17 5)", "-3"),
        Case("(%rem 17 5)", "2"),
        Case("(%mod -1 5)", "4"),
        Case("(%mod 7 5)", "2"),
        Case("(%logand 12 10)", "8"),
        Case("(%logior 12 10)", "14"),
        Case("(%logxor 12 10)", "6"),
        Case("(%lognot 0)", "-1"),
        Case("(%ash 1 10)", "1024"),
        Case("(%ash -16 -2)", "-4"),
        Case("(%lsh 256 -4)", "16"),
        // Constants at the edge of the fixnum range: the tagged form of these
        // does not fit in a fixnum, so the assembler has to build it without
        // ever forming it.
        Case("1073741823", "1073741823"),
        Case("-1073741824", "-1073741824"),
        Case("536870912", "536870912"),
        Case("(%logand 1073741823 1073741823)", "1073741823"),
        Case("(%+ 1073741820 3)", "1073741823"),
        Case("(%- 0 1073741823)", "-1073741823"),
        Case("(%logand 1000000000 1073741823)", "1000000000"),
        Case("(string-hash \"list\")", "1016731233"),
        Case("(string-hash \"\")", "5381"),
        // ---- comparison, as a value ----
        Case("(%< 1 2)", "t"),
        Case("(%< 2 1)", "nil"),
        Case("(%>= 2 2)", "t"),
        Case("(%eq? 3 3)", "t"),
        Case("(%eq? 3 4)", "nil"),
        Case("(%null? nil)", "t"),
        Case("(%null? 1)", "nil"),
        // ---- comparison, fused into a branch ----
        Case("(if (%< 1 2) 10 20)", "10"),
        Case("(if (%< 2 1) 10 20)", "20"),
        Case("(if (%null? nil) 10 20)", "10"),
        Case("(if nil 10 20)", "20"),
        Case("(if 0 10 20)", "10"),
        // ---- pairs ----
        Case("(%car (%cons 1 2))", "1"),
        Case("(%cdr (%cons 1 2))", "2"),
        Case("(%cons 1 (%cons 2 nil))", "(1 2)"),
        Case("(%cons? (%cons 1 2))", "t"),
        Case("(%cons? 5)", "nil"),
        Case("(%cons? nil)", "nil"),
        Case("(%car nil)", "nil"),
        Case("(%cdr nil)", "nil"),
        Case("(%set-car! (%cons 1 2) 9)", "9"),
        Case("(let ((p (%cons 1 2))) (%set-cdr! p 9) (%cdr p))", "9"),
        // The tag check lives in the instruction, so these fault in the
        // processor rather than loading whatever is at address 11.
        Case("(%car 5)", "TRAP: not a pair: 0xb"),
        Case("(%cdr 5)", "TRAP: not a pair: 0xb"),
        Case("(%car #\\a)", "TRAP: not a pair: 0x6102"),
        // nil reads as a pair of nils, but writing through it would land on
        // the globals at address zero.
        Case("(%set-car! nil 1)", "TRAP: not a pair: 0x0"),
        // ---- functions know their own names ----
        // The name lives in the code object, which is also what every frame
        // holds in s1, so this is the same word a backtrace reads.
        Case("(begin (define (named-fn x) x) named-fn)", "#<function named-fn>"),
        Case("(lambda (x) x)", "#<function (lambda . %ctest-entry)>"),
        // ---- quoted structure ----
        Case("'(a b c)", "(a b c)"),
        Case("'foo", "foo"),
        Case("\"hello\"", "\"hello\""),
        Case("(%car '(1 . 2))", "1"),
        // ---- let, set!, while ----
        Case("(let ((x 1) (y 2)) (%+ x y))", "3"),
        Case("(let ((x 1)) (set! x 9) x)", "9"),
        Case("(let ((x 0)) (while (%< x 5) (set! x (%+ x 1))) x)", "5"),
        Case("(let ((a 1)) (let ((a 2)) a))", "2"),
        Case("(let ((a 1)) (let ((b 2)) (%+ a b)))", "3"),
        // ---- macros all the way down ----
        Case("(cond ((%< 2 1) 'a) ((%< 1 2) 'b) (else 'c))", "b"),
        Case("(and 1 2 3)", "3"),
        Case("(and 1 nil 3)", "nil"),
        Case("(or nil nil 7)", "7"),
        Case("(when (%< 1 2) 'yes)", "yes"),
        Case("(unless (%< 1 2) 'yes)", "nil"),
        Case("(let ((n 0)) (dotimes (i 5) (set! n (%+ n i))) n)", "10"),
        Case("(let ((n 0)) (dolist (x '(1 2 3)) (set! n (%+ n x))) n)", "6"),
        Case("(case 2 ((1) 'one) ((2) 'two) (else 'many))", "two"),
        Case("`(1 ,(%+ 1 1) 3)", "(1 2 3)"),
        // ---- library functions, now running compiled ----
        Case("(length '(1 2 3 4))", "4"),
        Case("(reverse '(1 2 3))", "(3 2 1)"),
        Case("(append2 '(1 2) '(3 4))", "(1 2 3 4)"),
        Case("(list 1 2 3)", "(1 2 3)"),
        Case("(nth 2 '(a b c d))", "c"),
        Case("(memq 'c '(a b c d))", "(c d)"),
        Case("(assq 'b '((a 1) (b 2)))", "(b 2)"),
        Case("(equal? '(1 (2 3)) '(1 (2 3)))", "t"),
        Case("(equal? '(1 (2 3)) '(1 (2 4)))", "nil"),
        Case("(+ 1 2 3 4)", "10"),
        Case("(- 10 1 2)", "7"),
        Case("(* 2 3 4)", "24"),
        Case("(< 1 2 3)", "t"),
        Case("(< 1 3 2)", "nil"),
        Case("(max 3 9 2)", "9"),
        Case("(abs -5)", "5"),
        Case("(number->string 12345)", "\"12345\""),
        Case("(number->string -42)", "\"-42\""),
        Case("(string->number \"907\")", "907"),
        Case("(string-append \"ab\" \"cd\")", "\"abcd\""),
        Case("(string-length \"hello\")", "5"),
        Case("(string-ref \"hello\" 1)", "#\\e"),
        Case("(list->string (list #\\h #\\i))", "\"hi\""),
        Case("(symbol->string 'abc)", "\"abc\""),
        Case("(string->symbol \"xyz\")", "xyz"),
        Case("(vector-ref (list->vector '(1 2 3)) 1)", "2"),
        Case("(vector->list (vector 1 2 3))", "(1 2 3)"),
        Case("(sort '(5 2 9 1 7) <)", "(1 2 5 7 9)"),
        Case("(filter odd? '(1 2 3 4 5))", "(1 3 5)"),
        Case("(fold + 0 '(1 2 3 4))", "10"),
        Case("(char-upcase #\\a)", "#\\A"),
        Case("(char->integer #\\A)", "65"),
        // ---- closures ----
        Case("(let ((f (lambda (x) (%* x x)))) (f 7))", "49"),
        Case("(let ((n 10)) (let ((f (lambda (x) (%+ x n)))) (f 5)))", "15"),
        Case("(map (lambda (x) (%* x 2)) '(1 2 3))", "(2 4 6)"),
        Case(
            "(let ((mk (lambda (n) (lambda (x) (%+ x n))))) ((mk 100) 5))",
            "105",
        ),
        // a captured variable that is also assigned has to be boxed
        Case(
            "(let ((n 0)) (let ((bump (lambda () (set! n (%+ n 1))))) (bump) (bump) n))",
            "2",
        ),
        Case(
            "(let ((acc nil)) (dolist (x '(1 2 3)) (set! acc (%cons x acc))) acc)",
            "(3 2 1)",
        ),
        // ---- recursion, including deep tail recursion ----
        Case("(define (fact n) (if (%< n 2) 1 (%* n (fact (%- n 1))))) (fact 10)", "3628800"),
        // Deep tail recursion must run in constant stack.
        Case(
            "(define (countdown n acc) (if (%= n 0) acc (countdown (%- n 1) (%+ acc 1)))) (countdown 200000 0)",
            "200000",
        ),
        Case(
            "(define (fib n) (if (%< n 2) n (%+ (fib (%- n 1)) (fib (%- n 2))))) (fib 20)",
            "6765",
        ),
        // ---- variadic ----
        Case("(define (f . xs) xs) (f 1 2 3)", "(1 2 3)"),
        Case("(define (f a . xs) (%cons a xs)) (f 1 2 3)", "(1 2 3)"),
        Case("(define (f a . xs) (length xs)) (f 1)", "0"),
        Case("(list 1 2 3 4 5 6 7)", "(1 2 3 4 5 6 7)"),
        // Past the eighth argument the caller starts using the stack.
        Case("(list 1 2 3 4 5 6 7 8)", "(1 2 3 4 5 6 7 8)"),
        Case("(list 1 2 3 4 5 6 7 8 9)", "(1 2 3 4 5 6 7 8 9)"),
        Case("(list 1 2 3 4 5 6 7 8 9 10 11 12)", "(1 2 3 4 5 6 7 8 9 10 11 12)"),
        Case("(+ 1 2 3 4 5 6 7 8 9 10)", "55"),
        Case(
            "(define (nine a b c d e f g h i) (list i a)) (nine 1 2 3 4 5 6 7 8 9)",
            "(9 1)",
        ),
        // ---- strings built at run time exercise object allocation ----
        Case(
            "(let ((s (make-string 3))) (string-set! s 0 #\\a) (string-set! s 1 #\\b) (string-set! s 2 #\\c) s)",
            "\"abc\"",
        ),
        Case("(let ((v (make-vector 3 0))) (vector-set! v 1 9) v)", "#(0 9 0)"),
    ]
}

/// Compile `src` as a zero-argument function and run it. Returns the printed
/// result, or a description of the fault.
pub fn run_one(l: &mut Lisp, src: &str) -> String {
    // Read the source, compile every form but the last as a definition, and
    // wrap the last one in a thunk we can call.
    let script = format!(
        r#"(let* ((forms (%read-from-string {src:?}))
                  (n (length forms))
                  (defs (if (%> n 1) (reverse (%cdr (reverse forms))) nil))
                  (final (last forms)))
             (dolist (d defs) (compile-top d))
             (compile-top (list 'define (list '%ctest-entry) final))
             nil)"#
    );
    if let Err(e) = l.eval_string(&script, "<ctest>") {
        return format!("COMPILE ERROR: {}", e.msg);
    }
    let entry_sym = l.h.intern("%ctest-entry");
    let closure = l.h.sym_value(entry_sym);
    if closure == UNBOUND || closure == NIL {
        return "COMPILE ERROR: no entry".into();
    }

    // Lay down the support stubs and the trampoline, then let it rip.
    let trap = l.h.alloc_code(96);
    let cons = l.h.alloc_code(32);
    let tramp = l.h.alloc_code(128);
    trap_stub(l.h.m, trap);
    cons_stub(l.h.m, cons);
    l.h.set_g(LG_GCHOOK, cons);
    trampoline(l.h.m, tramp, closure, trap);

    l.h.m.poke32(RESULT, 0xDEAD_BEEF);
    l.h.m.poke32(FAULT, 0);
    l.h.m.pc = tramp;
    l.h.m.halted = false;
    l.h.m.mtimecmp = u64::MAX;
    l.h.m.gfx.next_vbl = u64::MAX;
    l.h.m.mstatus = 0;
    let st = run::run(l.h.m, 400_000_000);

    let fault = l.h.m.peek32(FAULT);
    if l.h.m.exit_code == 9 {
        let cause = fault;
        let epc = l.h.m.peek32(FAULT + 4);
        let tval = l.h.m.peek32(FAULT + 8);
        let a7 = l.h.m.peek32(FAULT + 12);
        // A wrong-type trap is reported without the pc: the value is the
        // whole diagnosis, and leaving the address out is what lets a test
        // say exactly what it expects.
        if cause == C_TYPE {
            return format!("TRAP: not a pair: {tval:#x}");
        }
        let what = match (cause, a7 >> 1) {
            (11, 1) => "arity error".to_string(),
            (11, 3) => "out of memory".to_string(),
            (11, n) => format!("ecall {n}"),
            _ => format!("{} (mtval {tval:#x})", run::cause_name(cause)),
        };
        return format!("TRAP: {what} at pc {epc:#x}");
    }
    if st != Stop::Halt {
        return format!("DID NOT FINISH ({st:?}) at pc {:#x}", l.h.m.pc);
    }
    let v = l.h.m.peek32(RESULT);
    l.h.write(v)
}

/// Compile and run one expression against a freshly built library. This is
/// the quickest way to ask the compiler what it actually does with a form.
pub fn eval_one(exprs: &[String]) -> i32 {
    write_layout();
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return 1;
    }
    let script: String = crate::forge::SYSTEM
        .iter()
        .map(|f| format!("(compile-file {f:?})
"))
        .collect();
    if let Err(e) = l.eval_string(&script, "<eval>") {
        eprint!("{e}");
        return 1;
    }
    for e in exprs {
        println!("{}", run_one(&mut l, e));
    }
    0
}

pub fn run_all(verbose: bool) -> bool {
    write_layout();
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return false;
    }
    // Compile the standard library to native code before testing anything
    // that calls into it. This is the same step the real build performs, and
    // it is itself the first serious exercise of the compiler.
    let t = std::time::Instant::now();
    let script: String = crate::forge::SYSTEM
        .iter()
        .map(|f| format!("(compile-file {f:?})
"))
        .collect();
    if let Err(e) = l.eval_string(&script, "<ctest-library>") {
        eprint!("compiling the library: {e}");
        return false;
    }
    println!(
        "library compiled in {:.2}s, {} bytes of code",
        t.elapsed().as_secs_f64(),
        l.h.g(LG_CODE_PTR) - CODE_BASE
    );
    // Anything compiled code will call that nothing ever defined shows up
    // here rather than as a wild jump at run time.
    if let Ok(v) = l.eval_string("(undefined-globals)", "<ctest>") {
        if v != NIL {
            println!("undefined globals: {}", l.h.write(v));
        }
    }
    let mut pass = 0;
    let mut fail = 0;
    for Case(src, want) in cases() {
        if verbose {
            let cons = (l.h.g(LG_CONS_PTR) - CONS_BASE) / 8;
            let obj = l.h.g(LG_OBJ_PTR) - OBJ_BASE;
            let code = l.h.g(LG_CODE_PTR) - CODE_BASE;
            eprintln!("[{cons} conses, {obj} obj bytes, {code} code bytes] {src}");
        }
        let got = run_one(&mut l, src);
        if got == want {
            pass += 1;
        } else {
            fail += 1;
            println!("FAIL {src}");
            println!("     want {want}");
            println!("     got  {got}");
        }
    }
    println!("compiler: {pass} passed, {fail} failed");
    fail == 0
}
