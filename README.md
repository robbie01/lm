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
| `src/forge/hostlisp.rs` `src/forge/read.rs` | the bootstrap interpreter |
| `src/forge/mod.rs` | the build driver |
| `lisp/asm.lisp` | RV32 assembler, in Lisp |
| `lisp/compile.lisp` | Lisp → RISC-V compiler, in Lisp |
| `lisp/gc.lisp` | the collector |
| `lisp/exec.lisp` | Amiga Exec-style kernel |
| `lisp/hw.lisp` | the custom chips |
| `lisp/sys.lisp` | reader, printer, REPL, trap handling |

| the bench | |
|---|---|
| `src/check/cpu.rs` | processor conformance |
| `src/check/asm.rs` | the Lisp assembler against an independent Rust encoder |
| `src/check/compiler.rs` | source in, machine code out, run, compare |
| `src/check/inspect.rs` | what is actually in an image |

## The processor

RV32IMC, machine mode, with the CSRs a kernel needs. Dispatch is token
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

## The bootstrap

There is one compiler, written once, in Lisp.

At build time a small interpreter in Rust runs it. That interpreter evaluates
over the *target* representation — its conses are real conses at real target
addresses in the machine's RAM — so what the compiler builds while being
interpreted is already exactly what the machine will run. The compiler compiles
the whole system, itself included, into that same heap. What is left in memory
at the end is the image.

```
lmforge build
  bring up the interpreter, load lisp/*.lisp
  claim the reset vector
  compile layout, runtime, core, macros, print, gc, hw, asm, compile, sys,
          exec, snap, demo
  wire the kickstart, assemble the three stubs that have to be assembly
  write out the non-empty pages
```

A handful of names mean different things on either side of that line — reading
a file, expanding a macro, evaluating a constant — so each is a one-line
function defined twice: once in `hostio.lisp` for the forge, once in `sys.lisp`
for the machine. Everything else is shared, and the build fails loudly if
compiled code refers to a global that nothing defines.

Once booted, the image can save itself:

```
> (define (greet who) (string-append "hello, " who))
> (save-image)
saved 4270 blocks
$ ./target/release/lm snap.img
LM resumed, 284k of code
> (greet "again")
"hello, again"
```

## Exec

An Amiga Exec, in Lisp, in one shared address space with no MMU and no
protection. Doubly linked lists with a virtual head and tail node so removal
needs no special cases; tasks with 32 signal bits and `Wait`/`Signal`; message
ports on top of signals; `Forbid`/`Permit` for cooperative critical sections and
`Disable`/`Enable` for real ones; libraries reached through a jump table below
their base pointer. `AbsSysBase` is at address 8 rather than 4, because address
4 is nil's cdr.

`PutMsg` costs a pointer on a list. Nothing is copied, because there is nothing
to copy it between — which is the whole reason to have a shared address space.

The context switch comes out almost free. The trap stub already saves all 32
registers into the block `mscratch` points at and restores from there on the
way out, so switching tasks is one CSR write: point `mscratch` at a different
task's context and return. Taking a trap and switching tasks turn out to be the
same operation seen from two directions.

Preemption is the timer interrupt; a task that blocks asks for a reschedule
with an `ecall`, so the switch always happens inside the handler where the
registers are already saved.

## The Workbench

`(workbench)` opens a desktop with a shell in a window, and `(new-shell)` opens
another. Each shell is a task with a prompt of its own, reading from its own
window and printing into it — the same compiler, the same collector, the same
everything, just not on the serial line.

**No window has a backing store.** There is one bitmap, every window draws
straight into it, and repainting is back to front over the window list. That
is the entire occlusion model: no clip rectangles, no damage regions, an order
and the willingness to redraw. It costs a window a few hundred bytes instead of
a quarter of a megabyte, and it costs a drag one full repaint, which at blitter
speed lands well inside a frame. The price is that a window has to be able to
draw itself again on demand — a shell can, because it keeps the characters
rather than the pixels, in a grid it scrolls with the blitter.

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
(mandelbrot)          fixed point, straight to the bitmap
(life 200)            Conway, with the blitter for the copy
(balls 6)             six preemptive tasks sharing one framebuffer
(save-image)          write this machine to the disk
```

## Testing

```
lmdev all             every suite
lmdev cpu             96 processor conformance cases
lmdev asm             the Lisp assembler against an independent Rust encoder
lmdev compiler        139 end-to-end cases: source in, machine code out, compare
lmdev bench           measure the interpreter
lmdev inspect [IMG]   look inside an image without running it
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

## Known limits

- Fixnums are 31-bit. No bignums, and no floats beyond a boxed representation
  the compiler does not yet do arithmetic on.
- Compiled code open-codes `+`, `car`, `<` and friends, so redefining one does
  not affect code already compiled against it.
- No condition system: an error prints a backtrace and restarts the reader on a
  fresh stack. That is a reset, not an unwind — nothing gets a chance to clean
  up on the way past, and there is no way to catch anything.
- Objects and code are collected but never moved, so object space can still
  fragment over a long session. Its free lists are exact-fit and segregated,
  which handles the usual case where sizes repeat.
- A fault inside a task with a prompt behind it restarts that prompt; one
  without a prompt ends the task. Neither unwinds anything on the way.
- Window contents are not clipped against each other: a window draws its whole
  interior and the ones in front are drawn after it. Correct, and more work
  than a clip rectangle would be.
- Thirty-two words per suspended task are scanned conservatively, and what they
  reach is pinned for that cycle. `(room)` reports how many.
- A collection walks the whole used heap, so it costs proportional to the high
  water mark rather than to the live set. Generations would fix that.
- More than eight arguments works, but not in tail position: the caller pushes
  the overflow and a tail call's epilogue would move the stack out from under
  it, so such a call is compiled as an ordinary one followed by a return.
