# LM — a Lisp machine

A RISC-V computer that does not run an operating system written in C. It boots
into a Lisp image that contains its own compiler and assembler, and everything
above the emulator — the kernel, the collector, the compiler, the graphics — is
Lisp compiled to native RV32.

```
$ cargo build --release
$ ./target/release/lmforge build   # compile the Lisp sources into an image
$ ./target/release/lm              # boot it

LM 0.1 - a lisp machine
cons space 16384k pairs, object space 65536k, code 272k used
exec at 52080, 1 task
type (help) for what to try

> (define (fact n) (if (< n 2) 1 (* n (fact (- n 1)))))
fact
> (fact 12)
479001600
```

That `define` was compiled to RISC-V machine code, by a compiler that is itself
RISC-V machine code, sitting in the image you just booted.

## What is here

Three things, and they are deliberately separable — a machine, a forge that
builds images for it, and a bench that checks both. The binaries follow the
same seam, so the runtime carries neither the bootstrap interpreter nor the
tests.

| binary | |
|---|---|
| `lm` | boot an image. The runtime, and only the runtime |
| `lmforge` | compile the Lisp sources into an image |
| `lmdev` | conformance tests, benchmarks, and tools for looking inside |

| the machine | |
|---|---|
| `src/cpu.rs` | token-threaded RV32IMC core, explicit tail calls |
| `src/mach.rs` `src/run.rs` | registers, memory, CSRs, traps, the outer loop |
| `src/dev/` | uart, timer, framebuffer, blitter, input, block storage |
| `src/heap.rs` `src/image.rs` | object memory and the image format |
| `src/boot.rs` | loading an image and letting it run |

| the forge | |
|---|---|
| `src/forge/hostlisp.rs` | the bootstrap interpreter |
| `src/forge/read.rs` | the bootstrap reader: lists, and nothing else |
| `src/forge/mod.rs` | the build driver |
| `src/forge/compact.rs` | sliding object space down on the way into an image |
| `lisp/asm.lisp` | RV32 assembler, in Lisp |
| `lisp/compile.lisp` | Lisp → RISC-V compiler, in Lisp |
| `lisp/gc.lisp` | the collector |
| `lisp/exec.lisp` | Amiga Exec-style kernel |
| `lisp/packages.lisp` | every module, and the names it makes public |
| `lisp/hw.lisp` | the custom chips |
| `lisp/platinum.lisp` | the Mac OS 8/9 appearance, ported from ~/platinum |
| `lisp/font.lisp` `lisp/mono.lisp` | Charcoal for the interface, a 5x7 face for shells |
| `lisp/eyes.lisp` | xeyes, and the demonstration that an application can have more than one of itself |
| `lisp/read.lisp` | the reader, and the only one |
| `lisp/sys.lisp` | the kickstart: traps, REPL, rebuild |

| the bench | |
|---|---|
| `src/check/cpu.rs` | processor conformance |
| `src/check/asm.rs` | the Lisp assembler against an independent Rust encoder |
| `src/check/compiler.rs` | source in, machine code out, run, compare |
| `src/check/inspect.rs` | what is actually in an image |
| `src/check/reach.rs` | what each package's symbols can reach |

## The processor

`rv32imc_zba_zbb_zbs_zicond_xlm`, machine mode, with the CSRs a kernel needs.
The standard part is ordinary RISC-V; `Xlm` is the two custom opcodes below.
(`L` would have been the obvious letter and is not available: the spec reserves
it for decimal floating point, and a non-standard extension is spelled with an
`X` anyway.) Dispatch is token
threaded on the opcode itself — no predecode, no translation cache, nothing to
invalidate when the compiler writes fresh code into the heap and jumps to it:

```
16-bit forms   tok = (op[1:0] << 3) | funct3     ->  0 .. 23
32-bit forms   tok = 32 + opcode[6:2]            -> 32 .. 63
```

Every handler ends by expanding a macro that re-does the fetch, the token
computation and the indirect jump *in place*, then makes an explicit tail call
with nightly's `become`. The replication is the point: each opcode gets its own
branch site, so the predictor learns per-opcode successors instead of thrashing
on one shared dispatch. It runs at about **500 MIPS**, roughly seven host
cycles per guest instruction, in constant stack — fast enough that Conway's
life on a 640x400 board, or a Mandelbrot set in fixed point, runs at a
perfectly reasonable speed inside a Lisp inside an interpreter.

The timebase is the retired-instruction count rather than host wall time, so
the whole machine is deterministic: the same image produces the same schedule
on every run, down to which instruction a task is preempted on.

## Object memory

One 32-bit word per value:

```
w == 0          nil. Also a valid cons whose car and cdr are nil, so car and
                cdr need no null check and null? is a single beqz.
w & 1 == 1      fixnum, value = (i32)w >> 1. Order preserving, so signed
                compares work untagged and add/sub need one correction.
w & 7 == 0      cons.   car at [w], cdr at [w+4].
w & 7 == 4      object. header at [w-4], payload from [w].
w & 7 == 2      immediate: characters, the unbound marker, eof.
```

`gp` and `tp` are dedicated for the life of the machine to the cons allocator's
bump pointer and the end of its current run, so a fresh pair costs four
instructions and one well-predicted branch.

### Pairs are instructions

RISC-V reserves opcode space for whoever builds the machine, and this one knows
what a pair is, so `car`, `cdr`, `set-car!` and `set-cdr!` live in custom-0
rather than being loads and stores:

```
funct3 0   car rd, rs1        rd <- [rs1]
funct3 1   cdr rd, rs1        rd <- [rs1 + 4]
funct3 2   set-car! rs2, rs1  [rs1] <- rs2
funct3 3   set-cdr! rs2, rs1  [rs1 + 4] <- rs2
```

The check is the point, and the tag scheme is what makes it free: a pair has
its low three bits clear, so a fixnum (odd), an immediate (2 mod 8) and an
object (4 mod 8) are all caught by a mask the processor computes alongside the
address it was going to form anyway. Same one instruction, same 475 MIPS on a
list-walking loop. nil passes, because it is a legal pair; writing through it
does not, because that cell is the global vector at address 0.

A wrong type traps with cause 24 — RISC-V leaves 24 through 31 to the
implementation — and the offending value in `mtval`, which is enough for the
handler to decode the instruction that trapped, name the operation and print
the value itself:

```
> (car 5)
*** car: expected a pair, got 5, at pc 1047944
> (car "hi")
*** car: expected a pair, got "hi", at pc 104793c
> (set-car! nil 1)
*** set-car!: nil has no cell to write, at pc 10478f0
```

### Indexed access is one instruction

custom-1 does for objects what custom-0 does for pairs, and rather more, since
an indexed access has four things to establish rather than one. `funct7`
carries the type the object has to be - 0 for any object at all - and one
instruction checks the tag, checks the header, checks that the index is a
fixnum, checks it against the length in the header, then untags it, scales it
and forms the address:

```
funct3 bit 0   store rather than load
funct3 bit 1   byte rather than word
funct3 bit 2   the index is a five-bit immediate in the rs2 field
```

The address arithmetic needs the header word anyway, and the length is in the
header, so the bound costs a comparison the processor makes in parallel with
the address. Out of range traps with cause 25 and the index in `mtval`.

The immediate form is there because most indices are written down rather than
computed: every record field, every record's tag, every closure slot.
Putting the index in the `rs2` field follows `slli`, which has always kept its
shift amount there, so the encoding stays R-type and nothing that walks
instructions needs a new case.

**It is also what makes a checked call free.** A closure's entry point is slot
0 of a `t-closure`, and the call sequence used to load it with a bare `lw` that
proved nothing:

```
> (let ((f 5)) (f 1))       ; before
*** illegal instruction at pc 0, value 0
> (nosuchfunction 1)
*** illegal instruction at pc 8, value 92090
```

Calling a number jumped to whatever was in the nil cell; calling an undefined
name jumped to the sysbase pointer and executed it. `ldxi t2, t0, 0, t-closure`
is the same one instruction and says what it means:

```
> (let ((f 5)) (f 1))       ; after
*** call: expected a function, got 5, at pc 105e7d8
backtrace:
  repl-loop at 105e7d8
> (nosuchfunction 1)
*** call: undefined function, at pc 105ce44
```

### Arithmetic is checked too

The machine used to go to real trouble over `car` of a fixnum and
`vector-ref` of a string, and then let this happen:

```
> (+ "abc" 2)
(#\  . #<immediate>)
> (car (+ "abc" 2))
#\
```

`(+ "abc" 2)` returned a **cons**. A string is an object pointer with its low
three bits equal to four, adding a tagged two adds four, and four plus four is
the pair tag — so one addition fabricates a pointer into the middle of a
string, and `car` reads it. `(+ nil 1)` gave you a character. `(* (vector 1 2
3) 2)` gave you half a heap address wearing an integer's clothes.

custom-2 is the arithmetic, checked. Both operands must be fixnums, the
offending one goes in `mtval`, and the handler names the operation the source
used:

```
> (+ "abc" 2)
*** +: expected a number, got "abc", at pc 1053b20
> (+ nil 1)
*** +: expected a number, got nil, at pc 1053b90
> (/ 5 0)
*** /: division by zero, at pc 1053bc0
> (peek "abc")
*** peek: expected a number, got "abc", at pc 1053bec
```

It is cheaper as well as safer, because the tag arithmetic goes into the
instruction. `%+` was `add` and a correcting `addi`; it is one `fadd`. `%*`
was four instructions, `%/` five; they are one each. A comparison was an
unchecked `slt` and is now a checked `flt` for the same single instruction,
because 2n+1 preserves the order either way. `%eq?` is deliberately *not* one
of these: it compares identity, on values of any kind, and asking it for two
numbers would be asking it the wrong question.

custom-3 carries the same operations against a written-down constant, and the
other half of what a tag costs: memory reached through a tagged address.
`peek` was four instructions — strip the tag off the address, load, shift the
word up, put a tag back on — and the collector's inner loops are made of
little else. It is one `tlw`.

Measured over a run, instructions that exist only because values carry a tag
were 4.2% of `fib`, 9.4% of a collection-heavy workload and 7.3% of the
workbench, with roughly one tag correction for every arithmetic instruction.

**Overflow is a different question and is not switched on.** The trapping
forms exist, are tested, and nothing emits them: `string-hash` multiplies its
way past 2^30 on purpose and the fixed-point Mandelbrot relies on wrapping.
What should happen there is a decision about a numeric tower, not a change of
encoding — but an operation that cannot notice it overflowed is one bignums
could never be retrofitted onto, so the notice is built.

The one thing still unchecked is the *fused* comparison, where `(< i n)` is
the test of an `if` and compiles to a bare `blt`. Checking it would double the
instruction count in the hottest position in the machine, and its failure mode
is a branch going the wrong way rather than a forged pointer. In practice its
operands nearly always come from an operation that already checked them.

### And the things that were vectors with numbers in them

A window was eleven numbered slots, the compiler's context was thirteen with a
comment block to say which was which, the assembler was seven, and a stream was
three. They are records now, declared with `defrecord` (below), and an accessor
checks *which* record it has:

```
> (win-x "abc")
*** slot: expected a record, got "abc"
> (win-x (screen-rastport))
*** expected a window, got #[hw::rastport ...]
```

That needed a second indexed instruction. `%slot` takes any object, which is
right for the handful of places that reach into a symbol, a closure or a code
object by index and wrong everywhere else; `%record-ref` requires a record, and
everything that knows it is holding one says so. Both are the same single
`ldx` — the type it demands is a field in the instruction.

What stays raw is what has to be: the 32-word register context the trap stub
writes, the pool free list, the mark and pin bitmaps, the code area, device
registers, and object headers. Those are addresses, and pretending otherwise
would cost more than it bought.

### And a good deal of it was already standard

Before inventing an instruction it is worth checking whether the committee got
there first, and for a Lisp it repeatedly has. The core implements Zba, Zbb,
Zbs and Zicond, and the compiler emits them:

| | what wanted it |
|---|---|
| `bext`, `bset` | the collector's mark and pin maps: a bit test was a call, four run-time shifts and a mask |
| `cpop` | counting marks, which needed a 256-byte lookup table built at the first collection - and a saved-image bug of its own, since the flag saying the table existed *was* saved and the table was not |
| `czero.eqz` | turning a comparison into `t` or `nil`, at 530 sites |
| `min`, `max` | a fixnum is 2n+1, which preserves signed order, so these are right on tagged values with no untagging at all |
| `sh2add` | addressing the bit maps by word, which is what puts the bit index in the five bits `bext` looks at |

None of it is ours, and that is the point: the two custom opcodes stay small
because the standard ones did the rest. On a collection-heavy workload the lot
together is **34% fewer instructions**, and a collection itself 39% faster -
update 158M cycles to 97M, move 121M to 68M, marking 33M to 25M.

## Calling

```
a0..a7        arguments 0..7; 8 and up are pushed, so argument 8 is at 0(s0)
t0            the closure being entered
t1            how many arguments, raw
a0            the result
s1            the running function's literal vector - its own code object

s0 - 4        saved ra      raw
s0 - 8        saved s0      raw
s0 - 12       the closure
s0 - 16       saved s1
s0 - 20 - 4i  local slot i
```

Everything from `sp` up to and including the closure slot is a tagged value,
and only the two raw words sit at fixed offsets. That is not tidiness for its
own sake — it is the property the collector and the backtracer both live on.

**A function calling itself by name does not go the long way round.** The
general sequence loads the global's value cell, sets the argument count, loads
the entry address out of the closure and jumps indirectly — five instructions
and two dependent loads to reach code the compiler is *already emitting*. A
self-call instead reuses the closure it is running, from `s0-12`, and jumps
straight to a label just past its own arity check:

```
lw   t0, -12(s0)
jal  ra, self                 ; and 'j self' for a tail call
```

Two instructions rather than five, plus two more saved in the prologue for the
check it would only have been proving to itself: **six fewer instructions per
recursive call, about 12% off `fib`**. It applies only where the compiler can
see that it is safe — the operator is this function's own name, nothing local
shadows it, the argument count matches exactly, and the function is not
variadic, since the rest-list code reads that count out of `t1`.

The price is the same bargain open-coding `car` makes: redefining a function
does not reach the calls already inside it. A recursive function that redefines
itself mid-flight will finish in the version it started in.

### A function that calls nothing builds nothing

About seven functions in ten call nothing at all — accessors, predicates,
arithmetic — and they take a bit over half of every call the machine makes.
None of them needs the frame above. `ra` survives, because nothing will
overwrite it. No collection can start, because allocating is a call. And their
locals cannot be clobbered by a callee, because there is no callee.

So a leaf keeps its locals in `s3`–`s10` and its caller's literal vector in
`s11`, and its whole prologue is two instructions:

```
mv   s11, s1                  ; the caller's literals
lw   s1,  4(t0)               ; ours
                              ; ...and parameters stay in a0.. , moved to s3..
```

against ten for a frame — and its epilogue is `mv s1, s11; ret` against six.
Nothing else in the machine touches those nine registers, so there is nothing
to save and nothing to restore. Locals stop being memory entirely: no store on
entry, no reload at each mention.

The collector needs no telling. It scans from the innermost stack pointer up to
the frame it can see, and a leaf simply has no frame in between; a leaf that
pushes an argument pushes a tagged value below that pointer, which is inside
the range already. Backtraces are unaffected too, because the trap handler is
handed the saved `s1` separately from the frame chain, so the innermost
function names itself.

The catch is that leaf-ness is decided from the source, before a word is
emitted, and a source pre-pass can be wrong. So it is checked against the
result: `check-leaf` walks the bytes the function actually produced, and any
instruction that writes `ra` in something compiled as a leaf is a build
failure. On a collection-heavy workload the change is **11% fewer instructions**
and it takes frame and spill traffic from a quarter of everything the machine
runs to a sixth.

## Packages

Every name used to land in one global namespace, and the code leaned on
prefixes - `gc-`, `win-`, `tc-`, `i-` - to keep out of its own way. It now has
Common Lisp's packages, in their small form: a namespace per module, an
explicit export list, and `pkg:name` / `pkg::name` to say when you are reaching
outside your own.

They fit this machine unusually well, because a package here is a **reading**
concern and nothing else. The reader resolves a bare name in the current
package, then in whatever the packages it uses have exported, and interns one
of its own if neither has it. After that it is all symbol objects: the compiler
already resolves a global to a symbol at compile time, so **packages cost the
running machine not one instruction**.

`lisp/packages.lisp` is the whole module structure in one file, read first on
both sides of the bootstrap - which matters, because the forge and the machine
load the sources in different orders and a name has to mean the same thing in
both. It holds only the packages the *machine* has: `packages.lisp` is
compiled into the image, so a package declared there is a package the image
carries, and the forge's own namespace for the assembly stubs is declared at
the head of `boot.lisp` instead. Anything left over — a package the build made
and nothing was compiled into — is dropped before the image is collected, so
`(all-packages)` on a fresh machine lists eleven and every one of them has
code in it.

The export lists were computed from actual cross-package use rather than
guessed, which is why they are as small as they are:

```
compiler    11 public of 100 definitions
gc          23 of 105
exec        19 of 183
sys         26 of  69
wb          33 of  88
lm         541 of 474 definitions plus the primitives and special forms
```

Roughly four definitions in five are now private. The prelude is the exception
and should be: it is a library, so its interface is the library.

The current package is **per task**, swapped by the scheduler along with the
streams, so one shell can be in `wb` while another is in `user`:

```
> (current-package)
#<package user>
> (in-package wb)
> (length *windows*)
1
> wb::title-height
10
```

Two things fell out of doing this that were worth the trip on their own. The
first is that the collector was not tracing the package list, which would have
quietly collected the reader's world out from under it. The second is that the
compiler was interning `make-closure` and `t` *by name at compile time*, in
whatever package happened to be current - so compiling `wb.lisp` was quietly
creating `wb::make-closure`. Both were invisible in a flat namespace.

`lmdev readers` is what holds the rules down. There used to be two readers to
keep honest; now there is one, so what it checks is behaviour rather than
agreement — that a bare name finds what its package can see, that `pkg:name`
reaches an export and `pkg::name` reaches past the interface, that asking a
package for something it does not export is an error rather than a quietly
interned second symbol, and that the same new name read in two packages is two
symbols.

## Records

A record is an object whose slot 0 is a symbol saying what it is and whose
remaining slots are named fields. `defrecord` is where the names are written
down, and the only place they are written down:

```lisp
(defrecord (window win)
  x y w h title refresh keys task data rp bm)

;; win-slots  win-make  window?
;; win-x      set-win-x!      ... one pair per field
```

The slot numbers, the allocator, the predicate and the accessors all come out
of that one line, so adding a field in the middle is a matter of typing it
there. Before this, every one of them was a hand-kept constant beside a
hand-written pair of functions, and adding a field in the middle meant
renumbering by eye.

An **accessor is a function, and the compiler open-codes calls to it** — the
same bargain it already makes for `car`. So `(map win-x ws)` means what it
looks like, and `(win-x w)` in a body is four instructions and no call:

```
ldxi t2, a0, 0, t-record     ; the tag
lw   t3, off(s1)             ; the type this code was compiled against
beq  t2, t3, ok              ; ...and it had better be that one
ldxi a0, a0, 1, t-record     ; the field
```

Three of those four are the check, and the check is the point: a rastport
handed to `win-x` is a trap naming both ends rather than a plausible-looking
number out of the middle of somebody else. It comes out even anyway, because
what it replaces — `(win-get w win-x)` — was a function call.

Two declarations that are not just a list of fields:

```lisp
(defrecord (node open) succ pred pri name)
(defrecord (task tc) (include node) state sigalloc sigwait ...)
```

`include` puts another record's fields first, so a task **is** a node and their
slots line up — which is what Exec's lists are made of, and what lets one list
hold tasks, ports and interrupt servers at once. `open` says others are built
on this one, so a node's own accessors check that they have a record and stop
there; something has to be able to walk that list.

The shape is needed twice, the way a macro is: by the compiler running now and
by the machine's own compiler once the image boots. So `defrecord` is a macro
that expands into ordinary definitions — which is what the bootstrap
interpreter gets — and the compiler catches it before expansion, registers the
shape, and open-codes the accessors as well.

## Which task is running is a register

`s2` is dedicated for the life of the machine to the running task. Exec has no
variable for it and the scheduler does not set one: the trap stub was saving
all thirty-two registers anyway, so a task's context already carries it, and
`(this-task)` is `mv a0, s2`.

It used to hold an **instance** — a per-package record the compiler resolved
bare names into, so that `rad` inside `eyes` meant a slot rather than a global.
That read beautifully and it was a second mechanism for per-task state, with
its own register, its own trap and its own rule about what a name means inside
a package, serving one application. `eyes.lisp` passes a record now:

```lisp
(defrecord eyes window (rad 20) (pr 7) (look-x -1) (look-y -1))

(define (draw-eye e rp cx cy)
  (fill-circle rp cx cy (eyes-rad e) pt-white)
  (draw-circle rp cx cy (eyes-rad e) pt-black))
```

Nothing in `lisp/eyes.lisp` knows how many pairs of eyes there are. `(eyes)`
twice is still two windows, two tasks, two sets of pupils, one copy of the
machine code — it just says which pair it means.

## Fluid bindings

Some variables are per task in truth: where output goes, where input comes
from, the character the reader put back, which package a prompt reads in, the
block of memory this task programs the blitter through. They stay ordinary
globals, because everything reads them constantly and the common case has to
be one load. What makes them local is a **binding**:

```lisp
(fluid-let ((*out* (window-stream w)))
  (report))
```

A binding is a `(place . value)` pair on a stack the running task owns, and the
scheduler swaps that stack in and out along with the registers. The swap is
symmetrical, which is the whole trick: each entry holds the value that was
current when the binding was made, so exchanging the entry with the place
leaves the task's value in the entry and the outer value in the place — which
is exactly what "this task is not running" means. Exchanging again puts it
back, and nothing has to know which of the two states it is in.

Two consequences worth stating. A task that binds nothing shares the globals,
which is right: it has not asked for anything of its own. And a task that binds
and then *assigns* keeps the assignment, because what is exchanged is the
current value and not the one it started with.

This replaces a fixed seven-slot environment vector that the context switch
saved and loaded field by field, and whose contents were listed in three
places. A new task starts out holding whatever its creator held, which is how
a shell's children talk to the shell's window; `read.lisp` uses the same form
for the three places it used to save and restore by hand.

An error does not unwind — the stack it happened on is abandoned where it
stands — so the prompt it lands in unwinds the bindings itself, back to where
they stood when it started. Its own streams and package survive; whatever the
form that failed had bound on top of them does not.

## Symbols have identities

Interning hands every symbol a small dense integer, packed into the flags word
that was sitting empty, and the counter lives in low memory so that a symbol
made by the forge and one made by the running machine can never collide. It is
a **perfect hash**: no collisions, nothing to recompute, and nothing a
collector could invalidate by moving something.

That is what `lisp/table.lisp` is built on — open addressing over two parallel
vectors rather than buckets of pairs, because a chain costs two conses an entry
before it has stored anything. Looking up one of two hundred symbols takes 244
cycles against 9,256 for the `assq` it replaces.

The compiler was the first customer. It used to walk two lists, ninety entries
between them, at every call site it looked at; now the emitter for an
open-coded operator hangs off the symbol's function slot, which was also
sitting empty. **Compiling on the machine went from 236k cycles to 145k**, and
between that and the direct self-calls the compiler is about 40% faster than it
was.

## Finding every pointer

Compiled code contains **no heap addresses at all**. Each function reaches its
symbols and constants through a literal vector — its own code object — held in
`s1` and loaded once in the prologue. A constant is `lw a0, off(s1)`: one
instruction, where materialising an address took two. `lm inspect` checks the
invariant by decoding every `lui`/`addi` pair in code space and asserting that
none of them names anything in the heap.

That is what makes the rest possible. An object can move without a single
instruction being patched, and there are no relocation tables to maintain.

Roots are found **precisely, with no stack maps**. Every word in a Lisp frame
between its stack pointer and its closure slot is a tagged value — locals,
spilled temporaries, pushed arguments, the saved literal vector. Only the
return address and the frame link are raw, and they sit at fixed offsets. And a
callee's frame base *is* its caller's stack pointer. So the frame chain alone
describes every frame exactly, with no per-call-site metadata:

```
scan [sp, s0-8)              locals, temporaries, closure, literal vector
ra   = [s0-4]                raw
sp   = s0                    the caller's stack pointer
s0   = [s0-8]                the caller's frame
```

Allocation is the one place a live value can be in a register rather than a
frame, so a cons site tells the truth about it: the slow path writes a
live-register mask into `t5`, and the collector takes exactly those.

Exec hands over the Lisp values in its own structures — task functions, port
names, message bodies, library vectors — field by field, rather than having
the pool scanned by guesswork.

### The same chain is a backtrace

Nothing else was needed. A frame already holds its caller's frame base at
`s0-8` and its caller's literal vector — that is, its caller's *code object* —
at `s0-16`, and a code object now carries the name of the function it is. So
the walk the collector does for roots does for blame as well, with no debug
section, no unwind tables and no side map from address to function:

```
> (define (inner x) (+ 1 (car x)))
> (define (middle x) (+ 1 (inner x)))
> (define (outer) (+ 1 (middle 5)))
> (outer)
*** car: expected a pair, got 5, at pc 10484b8
backtrace:
  inner at 10484b8
  middle at 104853c
  outer at 10485b8
  repl-loop at 103d34c
  kickstart at 103d578
```

Anonymous functions are named after where they were written, so a lambda still
says something (`lambda in map`). An arity error names the function it was
about to enter and the count it was handed, because at that instant the callee
is still in `t0` and the count in `t1`. A tail call leaves no frame and so
appears in no trace — which is the honest answer, since there is no frame left
to describe.

A prompt is per task, not per machine. Everything that makes one — where its
characters come from, where they go, what it half-read, where an error puts it
back — is five globals, and the scheduler swaps them on a context switch, the
same way it swaps the registers. The common case stays one load, and two REPLs
in two windows do not interfere: an error in one prints its own backtrace and
restarts its own reader on its own stack.

The restart is a **return, not a call**. An error rewrites the interrupted
context — pc, `sp`, `t0`, `s0` — to look as though the reader had just been
entered on a clean stack, and lets the trap stub put it back. Calling the
reader from inside the handler instead would leave it running on the trap
stack, on top of the frames that had just faulted: that works exactly once, and
makes the backtrace of the second error a walk through the wreckage of the
first. Starting a task builds the same four words for the same reason.

**One thing is still guessed at.** A task preempted mid-expression has live
values in registers whose types nothing recorded. Making that precise would
mean safepoint polls in every prologue and loop back-edge, at perhaps a tenth
of the machine's speed, to remove thirty-two words of uncertainty per suspended
task. Instead those words are scanned conservatively and whatever they reach is
**pinned**. A pinned object does not move, and pushes the free pointer past
itself — which is also why the free pointer is never above the object being
considered, and why the slide can copy upwards through memory without ever
overwriting something it has not yet moved.

## The collector

Mark, then compact, in four passes: plan where everything is going, rewrite
every pointer to where its target will be, slide, and blank what is left
behind. Forwarding is not stored per object — there is nowhere to put it
without growing every pair by half. Instead each block of the heap records
where the free pointer had reached when the walk arrived at it, and a lookup
replays the few objects in between.

**Pairs are compacted. Objects and code are swept in place.** Not squeamishness
about variable sizes — it is about who is doing the collecting. This collector
is written in the language it collects: it calls functions through symbol value
cells and reaches its constants through the literal vector of its own code
object, and every one of those is an object. Move them and it loses the ability
to run, halfway through running. Pairs are safe because nothing between
updating and sliding dereferences one, and pairs are where the space is: a few
million of them against a few thousand objects.

Code space is collected but not moved, for the same reason. Liveness needs no
special rule: a closure holds its code object, a frame holds its closure, and a
running function's literal vector *is* its own code object sitting in `s1`, so
anything executing, anything on any stack and anything callable is already
reachable. The registry of code objects lives in the pool rather than the heap,
because a list in the heap would have to be a root, and a root would keep every
version of every function alive forever — the opposite of the point.

The effect on an image is the whole reason for the exercise:

| | |
|---|---|
| non-moving, no blanking | 27 MB |
| swept and blanked | 10.6 MB |
| compacted | **1.8 MB** |

That last figure is 10,340 live pairs out of the 3.4 million the compiler
allocated to build itself.

## The bootstrap, and building without it

There are two ways to make an image, and neither of them carries a second copy
of the language.

`lmforge build` is the one that needs nothing. It comes up in two stages. The
first is a reader in Rust that knows how to make a list and nothing else — no
packages, no `pkg:name`, no idea that `in-package` is anything but a call —
and a small interpreter that runs what it reads. That is enough to bring up
the prelude, and the last file in the prelude is `lisp/read.lisp`: **the
reader, written in Lisp**. From there the bootstrap reads with that, itself
included, and the compiler — one of the sources, also written in Lisp —
compiles the whole system into the same heap the interpreter has been filling
all along. What is left in memory at the end is the image.

```
boot0 layout stream core macros runtime hostio read     <- read by Rust
packages gc hw exec asm compile boot                    <- read by read.lisp
```

The split is a rule, not an accident: everything the Rust reader touches is
one namespace, which is why it is exactly the prelude. `boot0.lisp` is two
no-op macros so those files can still say which package they are in;
`read.lisp` replaces them with the real ones on its way past.

`lmforge rebuild` is the one that needs an image: it boots a previous one,
**types the sources at its console**, and lets the machine compile them and
write its successor. The machine already has a reader, a compiler and an image
writer; what it does not have is a filesystem, and a console is a perfectly
good substitute.

It goes through the sources twice, the way the forge does. The first pass,
`sys:rebuild`, compiles them into the machine itself, so that the compiler and
the macros doing the work are the new ones. The second, `sys:genesis`,
compiles them again with those, and every definition goes into a table for the
image instead of into the machine. Then `snap:save-fresh` hands over: it
warm-resets the machine through its own reset stub into the image's
`finish-fresh`, which gives every symbol what the table says and nothing else,
collects from the image's own roots, and writes the file. The forge closes the
holes on the way out, in code space as well as object space - an image that
boots through its kickstart resumes nothing, and compiled code reaches other
code only through closures, so code can move.

What comes out is **a fresh image, not an updated one**: nothing typed at a
prompt, nothing the new sources no longer define, and nothing compiled by the
old compiler. Rebuilding from a saved session gives the same image as
rebuilding from the kickstart, and each generation is the size of the last.
The machine compiles a five-line function in 148,600 cycles, 0.35 ms, so going
through the sources twice takes it about as long as the forge takes once:

```
lmforge build                       kick.img,  904 KiB, in 2.6s
lmforge rebuild --from kick.img     next.img,  868 KiB, in 2.9s, 2012 forms twice
lmforge rebuild --check             compile everything twice, collect, write nothing
lmforge compact [-f IMG] [-o OUT]   slide object space down in a saved image
                [--fresh]           and code space, for an image that does not resume
```

What both of these buy is the end of mirroring. There used to be a second
reader in `src/forge/read.rs` that knew about packages, `pkg:name`, use lists
and the symbol hash, because a symbol read at build time has to be the same
symbol read at run time — and every change to one of them had to be made
twice. What is left cannot disagree about a name, because it does not resolve
names: it interns every token into one package and stops. Layout is already
single-sourced out of `map.rs` and `heap.rs`.

One thing to know about the rebuild. In the first pass the compiler being
recompiled is the compiler doing the compiling, and calls go through symbol
value cells, so the new one takes over partway through and finishes the job;
if it is broken, the way you find out is that the build goes wrong somewhere
confusing. `lmforge rebuild --verbose` names every form of the second pass as
it goes, which narrows that down.

### Compacting on the way out

Object space is written by an allocator that never moves anything, and by the
end of a build most of it is holes: the compiler's expanded macro trees,
assembler buffers and analysis lists, allocated once and dead ever since. That
is not a fragmented heap, it is a **high water mark** — the build really did
need the memory — but an image is a file, and a file should be the size of
what is in it.

The machine cannot fix this itself, and `gc.lisp` says why: its collector is
written in the language it collects, and reaches its functions through symbol
value cells and its constants through the literal vector of its own code
object. Every one of those is an object. Move them and it loses the ability to
run, halfway through running.

The forge is under no such obligation. By the time `src/forge/compact.rs`
runs, the heap has stopped, and liveness has already been decided by the
machine's own collector — which knows about task stacks and pinned registers —
so object space is a walkable sequence of live blocks and `t-free` holes, and
all that is left is to close them. Pointers are rewritten first and everything
slides afterwards, the same order the machine uses for pairs. Words in the
Exec pool are raw, so anything there that looks like an object pointer pins
what it names rather than being rewritten; on a freshly built image nothing
does.

```
objects 4102 KiB -> 307 KiB, 13,305 blocks moved, 0 pinned
kick.img 904 KiB
```

`lmforge compact` is the same pass on an image that came off the disk. One
from `(save-image)` pins more - its tasks really are holding objects - so it
compacts less well. What `rebuild` makes is the other extreme: a fresh image
resumes nothing, so nothing in it is pinned, and its code space closes up as
well. With no stack holding a return address, the entry word of a code object
and of each closure made from it are the only words that say where code is,
and `--fresh` moves them. A rebuild's 7.9 MB of object space and 1.3 MB of
code come out as 295 KiB and 441 KiB.

The machine still cannot do this to itself. What it would take is written down
in [docs/moving-objects.md](docs/moving-objects.md), along with why it has not
mattered yet.

## Exec

An Amiga Exec, in Lisp, in one shared address space with no MMU and no
protection. Tasks with 32 signal bits and `Wait`/`Signal`; message ports on top
of signals; mutexes that belong to the task holding them; Forbid and Disable
for sections too short to sleep in; libraries reached through a jump table
below their base pointer.

`PutMsg` costs a pointer on a list. Nothing is copied, because there is nothing
to copy it between - which is the whole reason to have a shared address space.

### No ExecBase, and no raw structures

A real ExecBase exists so that any program, in any language, compiled
separately, can find the kernel with `move.l 4.w,a6` and no linker. None of
that applies to one image in one address space where every function can name a
symbol. So there isn't one: the current task, the two nesting counts, the saved
interrupt state, the counters and the four lists are ordinary variables. Two
instructions to read instead of four, inspectable by name rather than by
offset, and no longer written through a null base pointer during the allocation
that creates the base pointer, which is what `Disable` was quietly doing at
every boot.

Tasks, ports, messages, libraries and interrupt servers are records rather than
blocks of pool memory. That is not for speed, though a slot read is one checked
instruction where `peek` was four unchecked ones. It is because `rem-task` used
to hand a task's memory back to the pool, and the pool handed it out again — so
a task pointer somebody kept could come back pointing at a *different, live*
task. The old defence zeroed the node type on the way out and checked it on the
way in, and its own comment admitted the hole: *"A block reused as another task
passes this test, and then the signal goes to the wrong task rather than to
nobody."* Nothing frees a record. A kept reference is either a live task or a
dead one that says it is removed and ignores its signals:

```
> (define v (add-task "victim" 0 (lambda () nil)))
> (list (task? v) (%slot v exec::tc-state) exec::ts-removed)
(t 6 6)
> (signal v 1)
nil
```

The collector stopped needing to be told anything, too. It used to walk the
lists by hand and name each Lisp-valued field of a task in `gc-scan-task` —
add a field, forget a line, and it is silently collected out from under a
running task. Now one root reaches every task, port, message, library and
interrupt server and every value in them. What is left in `gc-extra-roots` is
the part the collector genuinely cannot reach: the raw stacks and register
blocks that suspended tasks were sitting on.

### Lists, and the trick that went

Exec's list header pretends to be a node at both ends, so insert and remove
need no test for the ends of the list — a node's predecessor is always some
node, real or sentinel. It packs both sentinels into the header's own three
words by treating it as a node at `l` and another at `l + 4`, sharing the word
that is the head's predecessor and the tail's successor, neither of which is
ever read.

The sentinels are real nodes here, and the header owns two of them. Insert and
remove are the same four unconditional writes; the walk still ends on the tail
sentinel's nil successor, exactly as it ended on Exec's zero. What went is the
packing, and only because it cannot be expressed: sharing that word means
pointing four bytes into the header, and an object reference has its low three
bits equal to four, so four bytes along reads as a cons. It saved one word per
list, on twelve lists.

The context switch comes out almost free. The trap stub already saves all 32
registers into the block `mscratch` points at and restores from there on the
way out, so switching tasks is one CSR write: point `mscratch` at a different
task's context and return. Taking a trap and switching tasks turn out to be the
same operation seen from two directions. That block stays raw pool memory —
thirty-two untagged words is not something a record can hold.

Preemption is the timer interrupt; a task that blocks asks for a reschedule
with an `ecall`, so the switch always happens inside the handler where the
registers are already saved. It is on from the moment the kickstart finishes,
which it did not used to be — you had to ask for it, so nothing was ever
tested against it.

### Being interruptible

Turning it on for good meant making everything that touches shared state safe
to be interrupted in the middle of, and the shape that took is worth
describing because it is not the obvious one.

**Interrupts are saved and restored, not turned on and off.** `%disable`
answers whether they *were* on — the instruction that clears the bit computes
that for free, and the only question was whether anyone kept the answer — and
`%restore-interrupts` puts back what it found. So there is no "enable"
operation for anything to get wrong, and no shared nesting count that everyone
has to agree to maintain: each caller keeps its own answer on its own stack.
Exec's `Disable`/`Enable` counter is gone; nothing ever read it but the pair
itself. `without-interrupts` is
the form you write, and it is a macro rather than something taking a thunk,
because a thunk that captures anything is a closure and the collector may not
allocate.

What it does not do is unwind. An error abandons the stack it happened on, so
`abort-to-repl` re-establishes the interrupt state rather than restoring it,
and zeroes Exec's nesting counts on the way past — otherwise one bad
expression inside a critical section would leave the machine deaf for as long
as it ran.

**Every task allocates out of its own run.** This is the one that had teeth.
The inline allocator is four instructions — check for room, store the car,
store the cdr, bump — and it is not atomic. `gp` and `tp` used to be machine
wide and deliberately *not* restored on a context switch, which was exactly
right when switches only happened at a `reschedule` and exactly wrong the
moment a timer could land between the store and the bump: two tasks would
write the same cell and carry on, and it would surface much later as a pair
holding somebody else's cdr. Now `refill-cons` carves a 256 KiB chunk out of
the frontier for the asking task alone, the trap stub restores `gp` and `tp`
with everything else, and the sequence is private to one task. After a
compaction every run describes the wrong heap, so each suspended task keeps
only the cell its run was about to use - moved with everything else, its `gp`
updated to match - and refills after that. The collector used to zero both
registers instead, and a task preempted between its room check and its stores
then wrote its pair into nil's cell.

**A device command is a critical section.** Setting up a blit is several
register writes and then the one that starts it; two tasks interleaved there
start each other's work. That one is visible — it draws a line across the
screen from a rectangle that was supposed to be clipped to a window.

### Locks

Ports come first: a resource one task owns cannot be raced for, which is why
every driver is a task. For data that tasks really do share there is a mutex,
and it is the Windows kind rather than a bare semaphore - it belongs to the
task holding it. Only the owner can let it go; it nests; waiters queue in
priority order and are handed it directly; a waiter lends the owner its
priority; and a task that dies holding one, or whose stack an error abandons,
has it taken away, and the next owner is told - through a repair function the
mutex can be made with. A wait that would close a circle of tasks is an error
naming the circle, not a hang.

`without-preemption` and `without-interrupts` stay, for sections a few
instructions long, and nothing may sleep inside either: `wait`, `reschedule`
and taking a mutex there are errors that say so. `(locking)` at the prompt
checks all of it. The rules, and how they came about, are under *Locking* in
[docs/open-items.md](docs/open-items.md).

### Waiting for a frame

Preemption also made it obvious that nothing was ever *waiting*. A drawing task
looped on `reschedule`, which under a cooperative scheduler was polite and
under a preemptive one is a task asking for the processor back thousands of
times a second to redraw a picture the display shows sixty times.

So the display gets an interrupt server. Exec reserves one signal bit —
`sigf-vblank`, the same bit in every task, which is what makes waking every
waiter a walk of the wait list rather than a registry somebody has to keep —
and `(wait-vblank)` blocks until the display has finished a frame. The eyes
and the workbench's input task use it, and a task blocked there is off the
ready list entirely.

Then the rest of it, because a clock is only the right thing to wait on if you
are watching the clock. A shell waiting for a key is woken by the key: the
input task signals the window's task when it delivers one. The input task
itself is woken by the input device's own interrupt rather than by asking sixty
times a second whether anything arrived — and because that device holds its
line up for as long as it has events, the server masks the line and the task
turns it back on when the queue is dry, which is what makes a level-triggered
device behave.

And an idle task, which turns out to be load-bearing rather than tidy. With
every task genuinely blocking, a machine where they all block at once has an
empty ready list, and `switch-tasks` quietly declines to switch — so the task
that just declared itself asleep carries on running, goes round `wait`'s loop
and adds itself to the wait list a second time. A doubly linked list with one
node in it twice is the end of the scheduler. Nothing noticed while every task
was a spin loop. The idle task is always ready, runs `wfi`, and costs nothing.

Four pairs of eyes open and nothing happening: three seconds of machine time
now costs three seconds of wall clock, with the emulator idling through it.
Spinning, the same three seconds had not arrived after 174. The input task went
from 125,215 context switches in that window to one; the shell from 20,893 to
one.

That stopped being true once the frame interrupt was on for good: an idle
machine skipped from one frame to the next as fast as the host could go, so a
workbench ran hundreds of machine seconds a wall-clock second, drawing and
allocating for every one of them. `run::pace` now sleeps through a windowed
machine's idle time, and it holds again - without touching the machine's own
clock, so a run is as deterministic as ever, and without slowing a busy one.

What should happen next, and why `wait-vblank` is the mechanism rather than the
interface, is in [docs/presenting.md](docs/presenting.md).

## The Workbench

A window owns the part of the bitmap it may draw on, and nothing else. Its
**region** is its own rectangle less the rectangle of every window in front of
it, recomputed whenever a window opens, closes, moves or comes forward. All
drawing goes through a **rastport** — a bitmap, an origin and a region — and
every drawing call takes one, the way `RectFill(rp, ...)` does: a rastport
belongs to a window, so anybody holding the window is clipped to it. A
**bitmap** is one value too — the memory and both its dimensions — because
three arguments that have to agree are three that can disagree, and a stride
that does not match its memory is not a drawing that looks wrong: the clipping
passes and the write lands past the end, where the stacks are.

That is the difference between an ordering and a guarantee. Before it, z-order
held only until the next repaint: a task at the back would paint over the
window in front two milliseconds later, and `xeyes` behind another window drew
its eye straight across it. Now it cannot.

It also means repainting is **only what was uncovered**. Closing a window
repaints the strip it vacated rather than the screen, and drawing order stops
mattering at all, because the regions do not overlap.

`region-subtract` is the whole of the machinery: one rectangle minus another is
at most four rectangles, and everything else is that in a loop.

`(workbench)` opens a desktop with a shell in a window, and `(new-shell)` opens
another. Each shell is a task with a prompt of its own, reading from its own
window and printing into it — the same compiler, the same collector, the same
everything, just not on the serial line.

**No window has a backing store.** There is one bitmap and every window draws
straight into it, clipped to its own region. That costs a window a few hundred
bytes instead of a quarter of a megabyte, and the price is that a window has to
be able to draw itself again on demand — a shell can, because it keeps the
characters rather than the pixels, in a grid it scrolls with the blitter.

The font is five columns by seven in an eight-pixel cell, written as eight
small numbers a glyph so the whole thing is legible in `lisp/font.lisp`, and
unpacked into a byte vector at startup. A glyph is drawn a pixel at a time,
which sounds extravagant until you count it: a full screen of text is about a
millisecond.

One task turns events into window operations — click to raise, drag the title
bar to move, the close box to close — and keys go to whichever window is in
front. Nothing else in the system knows a mouse exists.

## The chips

Every device is a 4 KiB page of naturally aligned 32-bit registers, so talking
to hardware from Lisp is peek and poke.

- **uart** — the console, and where the REPL lives
- **timer** — 64-bit compare against the instruction count
- **gfx** — chunky 8-bit or 32-bit bitmap anywhere in RAM, 256-entry palette,
  vertical blank derived from the cycle count so frames are reproducible
- **blitter** — rectangle copy, fill, raster ops, masked sprite copy, lines
- **input** — keyboard and mouse events in a fifo
- **disk** — 512-byte blocks against a host file
- **sys** — halt, interrupt request and enable, entropy

## Try it

```
(help)                what there is
(selftest)            compile a function on the machine and time it
(room)                heap and code usage
(gc)                  collect now
(tasks)               what every task is doing
(workbench)           a desktop, with a shell in a window
(new-shell)           another shell window
(eyes)                xeyes; call it more than once
(mandelbrot)          fixed point, straight to the bitmap
(life 200)            Conway, with the blitter for the copy
(balls 6)             six preemptive tasks sharing one framebuffer
(save-image)          write this machine to the disk
```

## Testing

```
lmdev all             every suite
lmdev cpu             174 processor conformance cases
lmdev asm             the Lisp assembler against an independent Rust encoder
lmdev compiler        153 end-to-end cases: source in, machine code out, compare
lmdev bench           measure the interpreter
lmdev readers         name resolution: use lists, pkg:name, pkg::name
lmforge rebuild --check   compile every source on the machine, then collect
lmdev inspect [IMG]   look inside an image without running it
lmdev reach [IMG]     what each package's symbols can reach, and what only they can
lmdev eval EXPR       compile and run one expression, for debugging the compiler
lmdev repl            a prompt on the bootstrap interpreter
```

`lmdev asm` is worth explaining: the same instruction sequence is written
twice, once in Lisp and once with Rust encoders, and the two byte streams must
match. Two independent readings of the RISC-V manual agreeing is evidence; one
encoding agreeing with itself is not.

`lmdev inspect` checks the invariant the collector depends on, by decoding
every `lui`/`addi` pair in code space and asserting that none of them names
anything in the heap.

A static count of an image says what the compiler *emitted*; it says nothing
about what runs, and the two distributions are not the same - a prologue is
emitted once per function and executed once per call. For the other half:

```
lm kick.img --isaprof --script '...'
```

which prints a sorted histogram on exit, with the custom opcodes broken down by
form, memory traffic by base register, a census of which functions never call
anything, and a count of the instructions that exist only because values carry
a tag.

Counting is a *second dispatch table* rather than a test in the threaded core's
`next!`. A branch there would cost more than everything it guarded, because
that macro is the one piece of code every instruction expands; swapping the
table costs one load of a pointer that is already hot, and measures as free.
Every entry in the counting table is the same function, because it can work out
which slot it is from the instruction word it was handed. The total it prints is smaller
than the instruction count beside it, and the difference is real - `cycles` is
the machine's timebase, and a machine parked on `wfi` has its clock moved
forward to the next interrupt without executing anything.

The histogram says which instructions run; `--fnprof` says whose:

```
lm kick.img --fnprof --script '...'
LM_FNPROF=1 lmforge rebuild
```

The outer loop hands the core slices of under a thousand instructions and
charges each one to the function the machine is standing in - the code object
every Lisp frame keeps in s1 - and once to every function on the frame chain
above it. It prints the top forty both ways on exit: where the instructions
were spent, and what they were spent on behalf of. A leaf that never builds a
frame is charged to its caller. It is how `blit-go` and `alloc-object` turned
out to be sixty percent of ten pairs of eyes following the mouse.

`lmdev reach` walks the heap once per package, from that package's own symbols,
and records for every cell the set of packages that can get to it. It answers
what a namespace actually weighs - and it is how the dead object space in a
fresh image was found: pairs were 100% live, code 99%, and objects 14%. It
now reports every space as fully live, which is the check that the compaction
above is doing what it claims.

## Known limits

- Fixnums are 31-bit. No bignums, and no floats beyond a boxed representation
  the compiler does not yet do arithmetic on.
- Compiled code open-codes `+`, `car`, `<` and friends, so redefining one does
  not affect code already compiled against it.
- No condition system: an error prints a backtrace and restarts the reader on a
  fresh stack. That is a reset, not an unwind — nothing gets a chance to clean
  up on the way past, and there is no way to catch anything. The restart puts
  the interrupt state and Exec's nesting counts back by hand, because nothing
  else would.
- The machine collects objects and code but never moves them, so object space
  can still fragment over a long session. Its free lists are exact-fit and
  segregated, which handles the usual case where sizes repeat, and the forge
  compacts object space on the way into an image — which is the only place it
  has mattered so far.
- A fault inside a task with a prompt behind it restarts that prompt; one
  without a prompt ends the task. Neither unwinds anything on the way.
- A rebuild turns preemption off and does not turn it back on. It is
  recompiling exec.lisp into the machine it is running on, and `(define
  *sysbase* nil)` is a top level form like any other — for the rest of that
  rebuild there is no ExecBase for a timer interrupt to find. The image it
  writes turns preemption on for itself when it boots.
- A task holding a partly used run keeps it until the next collection. At 256
  KiB a chunk that is the worst case, and only for tasks that allocated once
  and stopped.
- A rebuilt image carries the holes left in *code space* by the functions it
  replaced — object space is compacted, code space is not, because moving
  machine code means finding every call site. So it is bigger than a freshly
  built one and grows a little each generation. `lmforge build` renormalises.
- Thirty-two words per suspended task are scanned conservatively, and what they
  reach is pinned for that cycle. `(room)` reports how many.
- A collection walks the whole used heap, so it costs proportional to the high
  water mark rather than to the live set. Generations would fix that.
- **A collection is about 110 million cycles and every one of them has
  interrupts off** - three hundred frames at sixty hertz, five seconds at
  20 MHz, during which the machine hears nothing. It was 175 million until the
  mark bitmap stopped being cleared a word at a time over a hundred and
  ninety-two megabytes of address space that has never been touched, the
  forwarding tables stopped being filled in for a quarter of a million blocks
  nothing reads, and the compacting walk stopped asking a lookup table for an
  answer it could carry in a register. What is left is mostly the update pass
  paying Lisp call overhead per pointer. It is the largest single defect in
  the system and it wants a different shape, not another constant factor:
  interrupts have to stay off for the root scan and the pointer update,
  because those walk Exec's lists, but the marking and the sweeps touch only
  the heap and could run with them on.
- A task pointer is the only handle Exec has, and the memory it names is freed
  when the task ends. `task?` catches the usual mistake - `signal` on a task
  that has gone now reports rather than writing into whatever the pool handed
  out next - but a block reused as another task passes that test.
- More than eight arguments works, but not in tail position: the caller pushes
  the overflow and a tail call's epilogue would move the stack out from under
  it, so such a call is compiled as an ordinary one followed by a return.
  `apply` is the same: up to eight arguments it makes a tail call, and past
  eight an ordinary one.
