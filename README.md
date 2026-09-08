# LM — a Lisp machine

A RISC-V computer that does not run an operating system written in C. It boots
into a Lisp image that contains its own compiler and assembler, and everything
above the emulator — the kernel, the collector, the compiler, the graphics — is
Lisp compiled to native RV32.

```
$ cargo build --release
$ ./target/release/lm build        # forge the kickstart image
$ ./target/release/lm run          # boot it

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

| | |
|---|---|
| `src/cpu.rs` | token-threaded RV32IMC core, explicit tail calls |
| `src/mach.rs` `src/run.rs` | registers, memory, CSRs, traps, the outer loop |
| `src/dev/` | uart, timer, framebuffer, blitter, input, block storage |
| `src/hostlisp.rs` `src/read.rs` | the bootstrap interpreter, build time only |
| `src/forge.rs` `src/image.rs` | the build driver and the image format |
| `lisp/asm.lisp` | RV32 assembler, in Lisp |
| `lisp/compile.lisp` | Lisp → RISC-V compiler, in Lisp |
| `lisp/gc.lisp` | conservative mark-sweep collector |
| `lisp/exec.lisp` | Amiga Exec-style kernel |
| `lisp/hw.lisp` | the custom chips |
| `lisp/sys.lisp` | reader, printer, REPL, trap handling |

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
lm build
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
$ ./target/release/lm run snap.img
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
(mandelbrot)          fixed point, straight to the bitmap
(life 200)            Conway, with the blitter for the copy
(balls 6)             six preemptive tasks sharing one framebuffer
(save-image)          write this machine to the disk
```

## Testing

```
lm test        79 processor conformance cases
lm asmdiff     the Lisp assembler against an independent Rust encoder
lm ctest       118 end-to-end cases: source in, machine code out, run, compare
lm bench       measure the interpreter
lm inspect     look inside an image without running it
lm eval EXPR   compile and run one expression, for debugging the compiler
```

`asmdiff` is worth explaining: the same instruction sequence is written twice,
once in Lisp and once with Rust encoders, and the two byte streams must match.
Two independent readings of the RISC-V manual agreeing is evidence; one
encoding agreeing with itself is not.

## Known limits

- Fixnums are 31-bit. No bignums, and no floats beyond a boxed representation
  the compiler does not yet do arithmetic on.
- Compiled code open-codes `+`, `car`, `<` and friends, so redefining one does
  not affect code already compiled against it.
- No condition system: an error prints and restarts the REPL loop rather than
  unwinding.
- The collector is conservative, so a stack word that happens to look like a
  pointer keeps an object alive.
- Code space is never collected. Compiled code is reachable only through the
  closures that point at it, and freeing it would mean knowing that nothing has
  baked its address into an instruction — exactly what this design gives up in
  exchange for never having to move anything.
- Objects and code are collected but never moved, so object space can still
  fragment over a long session. Its free lists are exact-fit and segregated,
  which handles the usual case where sizes repeat.
- Thirty-two words per suspended task are scanned conservatively, and what they
  reach is pinned for that cycle. `(room)` reports how many.
- A collection walks the whole used heap, so it costs proportional to the high
  water mark rather than to the live set. Generations would fix that.
- More than eight arguments works, but not in tail position: the caller pushes
  the overflow and a tail call's epilogue would move the stack out from under
  it, so such a call is compiled as an ordinary one followed by a return.
