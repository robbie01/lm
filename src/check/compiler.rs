//! End to end compiler tests: compile a Lisp expression to RISC-V with
//! CHERI, run it on the machine, and compare what it printed.
//!
//! This test covers the whole chain: reader, macro expander, compiler,
//! assembler, object memory and processor. The answer is printed on the
//! machine, by `write-to-string`, so the test reads back a string object
//! and nothing on this side has to know how a value is laid out.

use crate::cap::Cap;
use crate::forge::hostlisp::Lisp;
use crate::forge::{boot_host, write_layout};
use crate::heap::{NIL, PERMS_PAIR, T_TEXT};
use crate::mach::{Machine, Stop, C_ECALL, C_RANGE, C_TYPE};
use crate::map::*;
use crate::run;
use crate::rvenc::*;

/// The granule the compiled entry's closure is left in for the trampoline.
const ENTRY: u32 = 0x0000_0C00;
/// The task stack: a capability to these bytes, entered at the top.
const STACK_BASE: u32 = 0x00F0_0000;
const STACK_TOP: u32 = 0x0100_0000; // the top of the exec pool
/// Cause 28, a capability fault: mtval is (register << 5) | code.
const CAUSE_CAP: u32 = 28;

/// Assemble words at an address.
fn put(m: &mut Machine, at: u32, code: &[u32]) {
    for (i, &w) in code.iter().enumerate() {
        m.poke32(at + 4 * i as u32, w);
    }
}

/// `jcl rd, rs1`: enter the closure in rs1.
fn jcl(rd: u32, rs1: u32) -> u32 {
    (rs1 << 15) | (3 << 12) | (rd << 7) | 0x0b
}

/// `sw.ddc rs2, (rs1)`: a word stored at the integer address in rs1.
fn sw_ddc(rs2: u32, rs1: u32) -> u32 {
    (0x7c << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 7) | 0x5b
}

/// Stop the machine with an exit code: the system device's first register,
/// written by integer address through DDC.
fn halt(c: &mut Vec<u32>, code: i32) {
    li32(c, T3, MMIO_BASE);
    c.push(addi(T4, ZERO, code));
    c.push(sw_ddc(T4, T3));
    c.push(jal(ZERO, 0));
}

/// A trap handler that stops the machine with exit code 9, so a miscompiled
/// program produces a diagnosis instead of a hang. mcause, mepc and mtval
/// say what happened, and a7 is still the ecall code if it was one.
fn trap_stub(m: &mut Machine, at: u32) {
    let mut c = Vec::new();
    halt(&mut c, 9);
    put(m, at, &c);
}

/// Enter the closure in t0 with no arguments; on its return, stop with exit
/// code 0, leaving the answer in a0.
fn trampoline(m: &mut Machine, at: u32) {
    let mut c = vec![jcl(RA, T0)];
    halt(&mut c, 0);
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
        // ---- the raw vocabulary needs an unsafe form; the checked one checks ----
        // The first word of the nil cell is its car's address, which is nil's.
        Case("(unsafe (%ld-word 0))", "0"),
        Case("(%ld-word 0)", "COMPILE ERROR: unsafe"),
        Case("(define (f) peek8) (f)", "COMPILE ERROR: unsafe"),
        Case("(%root)", "COMPILE ERROR: unsafe"),
        // A wrong-type trap names the register that held the value: a0 is 10.
        Case("(vector-length 5)", "TRAP: wrong type: 0xa"),
        Case("(%symbol-value 5)", "TRAP: wrong type: 0xa"),
        Case("(without-interrupts 7)", "7"),
        // ---- fixnums are 32-bit integers ----
        Case("2147483647", "2147483647"),
        Case("-2147483648", "-2147483648"),
        Case("1073741824", "1073741824"),
        Case("(%logand 2147483647 -1)", "2147483647"),
        Case("(%+ 2147483640 7)", "2147483647"),
        Case("(%- 0 2147483647)", "-2147483647"),
        // The wrapping forms wrap at 32 bits.
        Case("(%+ 2147483647 1)", "-2147483648"),
        Case("(let ((x 2147483647) (y 1)) (%+ x y))", "-2147483648"),
        // The trapping forms trap there, with a constant operand or without;
        // the handler that widens them is not installed here.
        Case("(+ 2147483646 1)", "2147483647"),
        Case("(- -2147483647 1)", "-2147483648"),
        Case("(* 65536 32767)", "2147418112"),
        Case("(let ((x 2147483647)) (+ x 1))", "TRAP: fixnum overflow"),
        Case("(let ((x -2147483648)) (- x 1))", "TRAP: fixnum overflow"),
        Case("(let ((x 2147483647) (y 1)) (+ x y))", "TRAP: fixnum overflow"),
        Case("(* 65536 32768)", "TRAP: fixnum overflow"),
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
        // nil is not the integer 0, and eq? is exact: a character and a
        // fixnum with the same payload differ in their metadata.
        Case("(%null? 0)", "nil"),
        Case("(%eq? 65 #\\A)", "nil"),
        Case("(%eq? (%char->int #\\A) 65)", "t"),
        Case("(%eq? (%unbound) (%unbound))", "t"),
        // A capability with a permission dropped is a different value, and
        // still reads the same pair.
        Case(
            "(let ((p (%cons 1 2))) (list (%eq? p (%cap-and-perms p 511))              (%eq? p (%cap-and-perms p 383)) (%car (%cap-and-perms p 383))))",
            "(t nil 1)",
        ),
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
        Case("(%cons? (%cap-clear-tag (%cons 1 2)))", "nil"),
        Case("(%cons? (unsafe (%root)))", "nil"),
        Case("(%fixnum? #\\a)", "nil"),
        Case("(%char? 97)", "nil"),
        Case("(%char? #\\a)", "t"),
        Case("(%car nil)", "nil"),
        Case("(%cdr nil)", "nil"),
        Case("(%set-car! (%cons 1 2) 9)", "9"),
        Case("(let ((p (%cons 1 2))) (%set-cdr! p 9) (%cdr p))", "9"),
        // The kind check lives in the instruction, so these fault in the
        // processor rather than loading whatever is at address 5.
        Case("(%car 5)", "TRAP: wrong type: 0xa"),
        Case("(%cdr 5)", "TRAP: wrong type: 0xa"),
        Case("(%car #\\a)", "TRAP: wrong type: 0xa"),
        // nil reads as a pair of nils, and refuses a write: sref refuses it
        // by kind, and its capability has no store permission.
        Case("(%set-car! nil 1)", "TRAP: wrong type: 0xa"),
        Case("(set-cdr! nil 1)", "TRAP: wrong type: 0xa"),
        Case("(%cap-st! nil 0 1)", "TRAP: capability fault: reg 7"),
        // ---- a constant is read-only all the way down ----
        // SD and SC are gone from the literal and from every pair, vector,
        // string and byte object inside it; LM stays.
        Case("(%cap-perms '(1 2))", "336"),
        Case("(%set-car! '(1 2) 3)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(%set-cdr! (%cdr '(1 2 3)) 9)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(%set-car! (%car '((1) 2)) 9)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(string-set! \"abc\" 0 #\\z)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(string-set! (%car '(\"abc\")) 0 #\\z)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(vector-set! '#(1 2) 0 5)", "TRAP: capability fault: reg 10 code 0x13"),
        Case("(vector-set! (vector-ref '#(#(1)) 0) 0 5)", "TRAP: capability fault: reg 10 code 0x13"),
        // Reading one is unchanged, and a copy is the program's own.
        Case("(%car (%cdr '(1 (2 3))))", "(2 3)"),
        Case("(let ((l (append '(1 2) nil))) (%set-car! l 3) l)", "(3 2)"),
        // Symbols inside a constant are the symbols themselves, so identity
        // holds through a literal, and so does a global assigned through one.
        Case("(%eq? (%car '(a)) 'a)", "t"),
        Case("(%eq? (vector-ref '#(a) 0) 'a)", "t"),
        Case("(%cap-perms (%car '(a)))", "497"),
        Case("(begin (%set-symbol-value! (%car '(lit-sym)) 2) (%symbol-value 'lit-sym))", "2"),
        // One constant is one capability, however often its quote runs.
        Case("(define (k) '(1 2)) (%eq? (k) (k))", "t"),
        // A leaf that conses: the pair is carved from the run in four
        // instructions, with no call to make a frame for.
        Case("(define (two a b) (%cons a (%cons b nil))) (two 1 2)", "(1 2)"),
        // ---- indexed access, checked in the instruction ----
        Case("(%vector-ref (vector 5 6 7) 2)", "7"),
        Case("(%vector-length (vector 5 6 7))", "3"),
        // mtval names the register that held the index, a1 being 11, or is
        // 32 for an index written into the instruction.
        Case("(%vector-ref (vector 5 6 7) 3)", "TRAP: out of range: 0x20"),
        Case("(%vector-ref (vector 5 6 7) -1)", "TRAP: out of range: 0xb"),
        Case("(%string-ref \"abc\" 3)", "TRAP: out of range: 0xb"),
        Case("(%bytes-ref (make-bytes 2) 2)", "TRAP: out of range: 0xb"),
        // A character stored into a string is checked to be one, a2 being 12.
        Case("(string-set! (make-string 2) 0 5)", "TRAP: wrong type: 0xc"),
        // A string is an object, so the type check fires here rather than the
        // tag check.
        Case("(%vector-ref \"abc\" 0)", "TRAP: wrong type"),
        // ---- hash tables, keyed by identity ----
        Case(
            "(let ((tb (make-table))) (table-set! tb 'a 1) (table-set! tb 'b 2)              (list (table-ref tb 'a) (table-ref tb 'b) (table-ref tb 'c 'none)))",
            "(1 2 none)",
        ),
        // Mixed keys: a symbol hashes by identity, a fixnum by value, a
        // character by its code.
        Case(
            "(let ((tb (make-table))) (table-set! tb 'k 1) (table-set! tb 7 2)              (table-set! tb #\\z 3) (list (table-ref tb 'k) (table-ref tb 7)              (table-ref tb #\\z) (table-count tb)))",
            "(1 2 3 3)",
        ),
        // Replacing a key does not add one.
        Case(
            "(let ((tb (make-table))) (table-set! tb 'a 1) (table-set! tb 'a 2)              (list (table-count tb) (table-ref tb 'a)))",
            "(1 2)",
        ),
        // A deleted slot is a hole, not an empty one: the keys that probed
        // past it must still be found.
        Case(
            "(let ((tb (make-table))) (table-set! tb 'a 1) (table-set! tb 'b 2)              (table-del! tb 'a) (list (table-count tb) (table-has? tb 'a)              (table-ref tb 'b)))",
            "(1 nil 2)",
        ),
        // Growing rehashes everything and drops the holes.
        Case(
            "(let ((tb (make-table)) (i 0)) (while (< i 200) (table-set! tb i (* i i))              (set! i (+ i 1))) (list (table-count tb) (table-ref tb 199)              (table-ref tb 0) (> (table-capacity tb) 200)))",
            "(200 39601 0 t)",
        ),
        // Identities are handed out in interning order, so this checks the
        // order rather than a number that changes with the sources.
        Case("(< (symbol-index 'car) (symbol-index 'workbench))", "t"),
        Case("(eq? (symbol-package 'car) (find-package \"lm\"))", "t"),

        // ---- regions: what a window is allowed to draw on ----
        Case("(hw:rect-intersect (hw:rect 0 0 10 10) (hw:rect 5 5 10 10))", "#[rect 5 5 5 5]"),
        Case("(hw:rect-intersect (hw:rect 0 0 10 10) (hw:rect 20 0 10 10))", "nil"),
        // A hole in the middle leaves four pieces; a hole that covers leaves
        // none; a hole that misses leaves the whole thing.
        Case("(length (hw:rect-subtract (hw:rect 0 0 100 100) (hw:rect 40 40 20 20)))", "4"),
        Case("(hw:rect-subtract (hw:rect 0 0 10 10) (hw:rect 0 0 10 10))", "nil"),
        // A record inside something else prints as its type alone.
        Case("(hw:rect-subtract (hw:rect 0 0 10 10) (hw:rect 50 50 1 1))", "(#[rect ...])"),
        // Subtracting a rectangle removes exactly its overlapping area and no
        // more.
        Case(
            "(hw:region-area (hw:region-subtract (list (hw:rect 0 0 640 400))              (list (hw:rect 10 10 100 100))))",
            "246000",
        ),
        Case(
            "(hw:region-area (hw:region-subtract (list (hw:rect 0 0 640 400))              (list (hw:rect 10 10 100 100) (hw:rect 50 50 100 100))))",
            // Two holes that overlap: 10000 + 10000 - 3600 taken out of 256000.
            "239600",
        ),

        // ---- records ----
        // Two of the same shape, with the initial values the declaration gave
        // them, and no way for one to see the other's.
        Case(
            "(let ((a (eyes:make-eyes)) (b (eyes:make-eyes)))              (eyes:set-eyes-rad! a 5) (list (eyes:eyes-rad a) (eyes:eyes-rad b)))",
            "(5 20)",
        ),
        Case("(eyes:eyes? (eyes:make-eyes))", "t"),
        Case("(eyes:eyes? (vector 1 2))", "nil"),
        // An accessor checks which record type it has, not merely that it has
        // a record: a rastport passed where eyes are wanted traps.
        Case("(eyes:eyes-rad (current-stream))", "TRAP: wrong record"),
        Case("(eyes:eyes-rad 7)", "TRAP: wrong type: 0xa"),
        Case("(eyes:eyes-rad nil)", "TRAP: wrong type: 0xa"),

        // ---- functions know their own names ----
        // The name lives in the code object, which is also what every frame
        // holds in s1, so this is the same word a backtrace reads.
        Case("(begin (define (named-fn x) x) named-fn)", "#<function named-fn>"),
        Case("(lambda (x) x)", "#<function lambda in %ctest-entry>"),
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
        // Leaves: operators on the locals' own registers, a store of 0 from
        // x0, a cons built in the local it is assigned to, a loop tested at
        // the bottom through `and`, an `if` for effect, and a parallel let
        // whose operator writes the new local's register.
        Case(
            "(define (lp1 v n) (let ((i 0) (s 0)) (while (%< i n) (%vector-set! v i i) \
             (set! s (%+ s (%vector-ref v i))) (%vector-set! v i 0) (set! i (%+ i 1))) \
             (%cons s (%vector-ref v 9)))) (lp1 (make-vector 10 7) 10)",
            "(45 . 0)",
        ),
        Case(
            "(define (lp2 l) (let ((n 0)) (while (and (pair? l) (%< n 3)) \
             (set! n (%+ n 1)) (set! l (%cdr l))) n)) (list (lp2 '(1 2 3 4 5)) (lp2 '(1)) (lp2 nil))",
            "(3 1 0)",
        ),
        Case(
            "(define (lp3 n) (let ((acc nil) (i 0)) (while (%< i n) (set! acc (%cons i acc)) \
             (set! i (%+ i 1))) acc)) (lp3 4)",
            "(3 2 1 0)",
        ),
        Case(
            "(define (lp4) (let ((i 0) (k 0)) (while (%< i 6) \
             (if (%= 0 (%logand i 1)) nil (set! k (%+ k i))) (if (%< i 3) (set! k (%+ k 100))) \
             (set! i (%+ i 1))) k)) (lp4)",
            "309",
        ),
        Case(
            "(define (lp5 a) (let ((a (%+ a 1)) (b a)) (let ((c (%* a b))) (%cons a (%cons b c))))) (lp5 5)",
            "(6 5 . 30)",
        ),
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
        Case("(let ((a 1) (b 2) (c 3)) ((lambda () (list a b c))))", "(1 2 3)"),
        // A closure is sealed: it can be called, and asked its kind and its
        // header type, but not read through.
        Case("(%cap-sealed? (lambda (x) x))", "t"),
        Case("(%cap-otype (lambda (x) x))", "2"),
        Case("(%cap-sealed? car)", "t"),
        Case("(%closure? car)", "t"),
        Case("(%obj-type car)", "5"),
        Case("(%obj-type 5)", "TRAP: wrong type: 0xa"),
        Case("(%cap-ld (lambda () 1) 16)", "TRAP: capability fault: reg 10"),
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
        // ---- apply and funcall ----
        Case("(apply + '(1 2 3))", "6"),
        Case("(apply + 1 2 '(3 4))", "10"),
        Case("(apply list '())", "nil"),
        Case("(apply list 1 2 '())", "(1 2)"),
        Case("(funcall '+ 1 2)", "3"),
        Case("(apply 'list 1 '(2 3))", "(1 2 3)"),
        Case("(apply list '(1 2 3 4 5 6 7 8))", "(1 2 3 4 5 6 7 8)"),
        // Past eight, apply puts the rest on the stack the way a call would.
        Case(
            "(apply list 1 2 3 4 5 6 7 8 9 '(10 11 12))",
            "(1 2 3 4 5 6 7 8 9 10 11 12)",
        ),
        Case("(apply + '(1 2 3 4 5 6 7 8 9 10))", "55"),
        Case(
            "(define (nine a b c d e f g h i) (list i a)) (apply nine '(1 2 3 4 5 6 7 8 9))",
            "(9 1)",
        ),
        // The stack pointer has to come back exactly: the first result waits
        // on the stack while the second is worked out.
        Case(
            "(list (apply + 1 2 3 4 5 6 7 8 9 '(10)) (apply list 1 2 3 4 5 6 7 8 9 '(10 11)))",
            "(55 (1 2 3 4 5 6 7 8 9 10 11))",
        ),
        // A call through apply or funcall in tail position is a tail call: the
        // stack pointer after a thousand of them is the same capability as the
        // pointer after one.
        Case(
            "(define (down n) (if (%= n 0) (%stack-pointer) (apply down (list (%- n 1))))) (let ((sp (down 1))) (%cap=? sp (down 1000)))",
            "t",
        ),
        Case(
            "(define (down n) (if (%= n 0) (%stack-pointer) (funcall 'down (%- n 1)))) (let ((sp (down 1))) (%cap=? sp (down 1000)))",
            "t",
        ),
        // An improper list is caught rather than walked off the end.
        Case("(apply list 1 '(2 . 3))", "TRAP: wrong type"),
        // ---- strings built at run time exercise object allocation ----
        Case(
            "(let ((s (make-string 3))) (string-set! s 0 #\\a) (string-set! s 1 #\\b) (string-set! s 2 #\\c) s)",
            "\"abc\"",
        ),
        Case("(let ((v (make-vector 3 0))) (vector-set! v 1 9) v)", "#(0 9 0)"),
        // ---- capabilities ----
        // Reading one: a pair is sixteen bytes, an object its payload.
        Case("(%cap-len (%cons 1 2))", "16"),
        Case("(%cap-len \"hello\")", "5"),
        Case("(%cap-tag? 5)", "nil"),
        Case("(%cap-tag? '(1))", "t"),
        Case("(%cap-high #\\A)", "1"),
        Case("(%cap-set-high 65 1)", "#\\A"),
        Case("(%addr-of 42)", "42"),
        Case("(%addr-of #\\A)", "65"),
        Case("(%cap=? 'a 'a)", "t"),
        // Loads within one, at a written-down offset and at a computed one.
        Case("(%cap-ld '(7 8) 8)", "(8)"),
        Case("(let ((o 0)) (%cap-ld '(7 8) o))", "7"),
        Case("(%cap-ld-byte \"abc\" 1)", "98"),
        Case("(let ((s (make-bytes 4))) (%cap-st-byte! s 2 7) (%bytes-ref s 2))", "7"),
        // Narrowing one, and what the narrowed one can no longer reach.
        Case("(%cap-len (%cap-bounds (make-string 10) 4))", "4"),
        // (%cap-subset? a b) asks what `ctestsubset` asks: whether b lies
        // within a.
        Case(
            "(let ((s (make-string 8))) (list (%cap-subset? s (%cap-bounds s 4))              (%cap-subset? (%cap-bounds s 4) s)))",
            "(t nil)",
        ),
        Case(
            "(%cap-ld-byte (%cap-bounds \"abcdef\" 2) 3)",
            "TRAP: capability fault: reg 10 code 0x1",
        ),
        Case("(%rrl 100)", "100"),
    ]
}

/// Compile `src` as a zero-argument function that prints its value, and run
/// it. Returns what it printed, or a description of the fault.
pub fn run_one(l: &mut Lisp, src: &str) -> String {
    // Read the source, compile every form but the last at top level, and wrap
    // the last one in a thunk that prints it. The thunk's closure is left
    // where the trampoline picks it up.
    let script = format!(
        r#"(let* ((forms (read-forms-from-string {src:?}))
                  (n (length forms))
                  (defs (if (%> n 1) (reverse (%cdr (reverse forms))) nil))
                  (final (last forms)))
             (dolist (d defs) (compile-top d))
             (compile-top (list 'define (list '%ctest-entry)
                                (list 'write-to-string final)))
             (%st-cap! {ENTRY} (%symbol-value '%ctest-entry))
             nil)"#
    );
    if let Err(e) = l.eval_string(&script, "<ctest>") {
        return format!("COMPILE ERROR: {}", e.msg);
    }
    let closure = l.h.m.load_cap(ENTRY);
    if !closure.tag {
        return "COMPILE ERROR: no entry".into();
    }

    // Lay down the trap stub and the trampoline, give the registers what a
    // task's would hold, and run. The stack and the cons run carry the
    // permissions of a pair, as a task's do, so that every pair cut from the
    // run is one. The cons run is the rest of cons space.
    let trap = l.h.alloc_obj(T_TEXT, 64).base();
    let tramp = l.h.alloc_obj(T_TEXT, 64).base();
    let run_start = l.h.g(LG_CONS_PTR);
    let run_end = l.h.g(LG_CONS_END);
    let root = Cap::ROOT;
    let stack = root
        .with_addr(STACK_BASE)
        .with_bounds_exact(STACK_TOP - STACK_BASE)
        .expect("the test stack has exact bounds")
        .and_perms(PERMS_PAIR)
        .with_addr(STACK_TOP);
    let cons_run = root
        .with_addr(run_start)
        .with_bounds(run_end - run_start)
        .expect("the cons run can be bounded")
        .and_perms(PERMS_PAIR);
    let m: &mut Machine = l.h.m;
    trap_stub(m, trap);
    trampoline(m, tramp);
    for r in 1..32 {
        m.set_reg(r, Cap::NULL);
    }
    m.set_reg(SP, stack);
    m.set_reg(GP, cons_run);
    m.set_reg(TP, Cap::NIL);
    m.set_reg(S2, Cap::NIL);
    m.set_reg(T0, closure);
    m.set_reg(T1, Cap::int(0));
    m.mtcc = root.with_addr(trap);
    m.set_pcc(root.with_addr(tramp));
    m.halted = false;
    m.exit_code = 0;
    m.mtimecmp = u64::MAX;
    m.gfx.next_vbl = u64::MAX;
    m.mstatus = 0;
    let st = run::run(m, 400_000_000);

    if m.exit_code == 9 {
        let (cause, epc, tval) = (m.mcause, m.mepcc.addr, m.mtval);
        let a7 = m.reg(A7).addr;
        if std::env::var_os("LM_CTEST_TRACE").is_some() {
            eprintln!("trap {cause} at {epc:#x} mtval {tval:#x}: {}", crate::cpu::watch_backtrace(m));
        }
        // A wrong-type, range or capability trap is reported without the pc,
        // so a test can state the register exactly.
        if cause == C_TYPE {
            return format!("TRAP: wrong type: {tval:#x}");
        }
        if cause == C_RANGE {
            return format!("TRAP: out of range: {tval:#x}");
        }
        if cause == CAUSE_CAP {
            let (reg, code) = (tval >> 5, tval & 31);
            return format!("TRAP: capability fault: reg {reg} code {code:#x}");
        }
        use crate::mach::{E_ARITY, E_OOM, E_RECORD};
        let what = match (cause, a7) {
            (C_ECALL, E_ARITY) => "arity error".to_string(),
            (C_ECALL, E_OOM) => "out of memory".to_string(),
            (C_ECALL, E_RECORD) => "wrong record".to_string(),
            (C_ECALL, n) => format!("ecall {n}"),
            _ => format!("{} (mtval {tval:#x})", run::cause_name(cause)),
        };
        return format!("TRAP: {what} at pc {epc:#x}");
    }
    if st != Stop::Halt {
        return format!("DID NOT FINISH ({st:?}) at pc {:#x}", m.pc);
    }
    printed(m, m.reg(A0))
}

/// The text of the string the entry answered.
fn printed(m: &Machine, s: Cap) -> String {
    if !s.tag {
        return format!("NOT A STRING: {s:?}");
    }
    let base = s.base();
    (0..s.len() as u32)
        .map(|i| m.peek8(base + i) as char)
        .collect()
}

/// Compile and run one expression against a freshly built library.
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
    run_one(&mut l, "(gc:install-allocator)");
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
    // that calls into it. This is the same step the build performs.
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
        l.h.text_bytes()
    );
    // The image installs the allocator from `kickstart`, which does not run
    // here. Without this the first test to make a vector would find nothing
    // in `*object-allocator*` to call.
    let r = run_one(&mut l, "(gc:install-allocator)");
    if r != "nil" {
        println!("installing the allocator: {r}");
        return false;
    }
    // A global that compiled code calls but nothing defines is reported here
    // rather than as a wild jump at run time.
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
            let code = l.h.text_bytes();
            eprintln!("[{cons} conses, {obj} obj bytes, {code} code bytes] {src}");
        }
        let got = run_one(&mut l, src);
        // A trap whose value is a heap address cannot be spelled out, since
        // the address depends on everything compiled before it. Matching the
        // prefix checks which trap fired.
        if got == want
            || (want.starts_with("TRAP:") && got.starts_with(want))
            || (want.starts_with("COMPILE ERROR:") && got.starts_with(want))
        {
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
