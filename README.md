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

**Nothing ever moves.** Compiled code embeds the addresses of symbols and
quoted constants directly in the instruction stream; the kernel holds raw
pointers to tasks and messages; the display reads the framebuffer where it
lies. A copying collector would have to cooperate with all of that. A
non-moving one cooperates with none of it — and in exchange it can be
conservative about stacks, which is what lets compiled code keep live values in
registers and spill them anywhere, with no stack maps at all.

The collector sweeps cons space into a chain of contiguous *runs* rather than a
free list of cells, which is what keeps allocation at a bump. Its roots are the
symbol table, a handful of globals, and one conservative scan of the Exec pool
— which covers every task's stack, every saved register context and every Exec
structure holding a Lisp value, in a single range.

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
saved 54497 blocks
$ ./target/release/lm run snap.img
LM resumed, 272k of code
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
- The collector does not compact, so an image carries the shape of its
  allocation history: live pairs are scattered through the range the compiler
  touched, and a page with one live pair in it still has to be stored. The
  build runs the collector on the machine and blanks what it reclaims, which
  takes the kickstart from 27 MB to about 10 MB, but the rest is the price of
  never moving anything.
- More than eight arguments works, but not in tail position: the caller pushes
  the overflow and a tail call's epilogue would move the stack out from under
  it, so such a call is compiled as an ordinary one followed by a return.
