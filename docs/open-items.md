# Open items

Things deliberately left undone, with enough detail to pick them up cold.

## Safety

**Overflow should make a bignum. Decided, not built.**
`faddo`, `fsubo` and `fmulo` trap when a result will not fit in 31 bits; they
are tested and nothing emits them yet. The plan:

- `+`, `-`, `*` and friends emit the trapping form and the handler promotes.
  `C_OVER` carries the wrapped result in `mtval`, which is not enough to
  reconstruct the true value for a multiply, so the handler decodes the
  instruction, reads the two operands out of the saved context, redoes the
  arithmetic in wider form and writes a bignum into `rd`. Then it steps `mepc`
  past the instruction and returns, exactly as `handle-ecall` already does.
- A bignum is an object: `t-bignum`, sign plus a vector of 30-bit limbs, with
  the invariant that anything that fits a fixnum *is* a fixnum, so `eq?` on
  small numbers keeps working and every existing type test stays right.
- The arithmetic instructions stay fixnum-only. A bignum operand is a `C_TYPE`
  trap, and the same handler catches it and dispatches to the Lisp routines.
  So one trap handler covers both promotion and mixed-mode arithmetic, and the
  fast path is untouched.
- Two explicit forms for the places that want the old behaviour. `wrap+`,
  `wrap*` and so on emit the wrapping instructions - `hash-string-into` needs
  `(wrap* h 33)`, and the fixed-point Mandelbrot needs wrapping multiplies.
  And a strict family that traps rather than promoting, for code that means
  to stay in fixnums and wants to hear about it.

The ordering matters: the wrapping forms have to exist and those two callers
have to move to them *before* the default changes, or interning breaks.

**The fused comparison is not checked.**
`(< i n)` as the test of an `if` compiles to a bare `blt`. Making it checked
would take two instructions instead of one, in the hottest position in the
machine. Its failure mode is a branch going the wrong way, not a fabricated
pointer, and its operands almost always came from an operation that already
checked them.

**`%slot` still takes any object.**
`%record-ref` demands a record and is used wherever the object is one. `%slot`
remains for the places that index a symbol, a closure, a code object or a
vector by number. Those accesses are unchecked as to which kind of object they
got.

**`%eq?` is unchecked and should stay that way.** It compares identity on
values of any kind. It is not a numeric comparison and should not become one.

## Compiler

**Register allocation across calls.**
Frame slots and spills are 25–32% of every instruction the machine executes.
The collector objection is answerable: a rule that callee-saved registers only
ever hold tagged values keeps the existing frame walk correct with no extra
bookkeeping, and makes `s2`–`s11` precisely scannable instead of conservatively
pinned. The real cost is liveness analysis and spilling in a compiler that has
to run on the machine. This is the largest remaining win and the largest
remaining job.

**A leaf that captures variables is not treated as a leaf.**
Free variables are read through the closure, which a framed function finds at
`s0-12`. A leaf would have to use `t0`, which survives because nothing in a
leaf clobbers it. Not done; top-level functions have no free variables, so this
only affects inner lambdas.

**A leaf that allocates keeps a frame.**
Allocating is a call, so such a function is not a leaf by the current test. The
alternative is to add `t0` to the live-register mask the allocator's slow path
publishes, and let leaves allocate.

**`%ld16` and `%st16!` have no tagged-address instruction.**
Still four instructions each. There was no funct3 left in custom-3 and no
measured demand.

**`%lognot` is two instructions** — `li -1` then `fxor`. An immediate xor would
make it one, but there is no funct3 left in custom-3 for it.

## Instructions with no users, and what they are for

The three overflow forms are spoken for: they are what bignums will be built
on. The others:

**`fltu` — unsigned compare.** The customer is address arithmetic. Every
`(%< p limit)` in the collector and the allocators compares two addresses held
as fixnums, and a fixnum is 31 bits, so an address above 2^30 would compare as
negative. Nothing in a 256 MiB machine reaches that today, which is why nobody
has noticed; `fltu` is what makes it not matter. It is also the right primitive
for a `bytes<?` or an unsigned `min`/`max` on raw data.

**`ldxbi` / `stxbi` — a byte at a constant index.** No customer today because
string and byte access is nearly always a computed index. The two that are not
are a string's first character - `(string-ref s 0)`, which the reader does on
every token - and fixed-layout byte records, which is what a disk block header
or a font glyph would be if either were a `t-bytes` object rather than raw
pool memory. Worth keeping until the font atlas or the file system arrives.

**`fori`** has four sites and two executions, and is simply rare rather than
useless: `(%logior x k)` with a constant is uncommon in this code.

## Held ISA ideas

**An allocation instruction.** Would make allocating a pair indivisible, which
would let the per-task allocation buffers, `%sync-cons-run`, `%reload-cons-run`
and the context-switch work around them all be deleted. Not faster — simpler.
It also puts an allocation policy into the instruction set. Revisit if the
per-task buffers cause trouble.

**A "what type is this" instruction.** Would collapse the type predicates and
make dispatch on type cheap. There are only 57 such sites today. Build it when
there is a generic dispatch layer to justify it.

**Compressed branches and jumps.** `c.j`, `c.jal`, `c.beqz` and `c.bnez` are
not emitted, because their encoding depends on a distance and shortening one
can put a target out of range — which needs a relaxation pass the assembler
does not have. Everything else that fits is compressed. Worth about another
1.6% of the image.

**Compare-immediate-and-branch.** 2.8% of executed instructions are a `li`
followed by a branch on it. There is no fix available: RISC-V has no such
instruction, `slti; bnez` is the same two instructions, and inventing a branch
format in custom space breaks every tool that walks the encoding.

**`c.lw` and `c.sw` almost never apply**, because frame slots are at negative
offsets from `s0` and the compressed forms only encode unsigned ones. Laying
the frame out upward would make roughly 30% more of the image compressible —
or the register allocator would remove those loads instead.

## The blitter

**The chip is atomic now; the software critical sections around it are not yet
gone.** Writes land in a shadow bank and the op write commits the whole of it,
so an interrupt that blits inside somebody else's setup cannot be seen by the
chip. That was the bug that once drew a line across the screen.

Taking `without-interrupts` back off `bm-fill-rect`, `bm-blit-rect` and
`draw-line` *should* now be free, and it is not: doing it makes the compositor
die with

    *** car: expected a pair, got 90, at pc 101cc9e
    backtrace:
      rect-x at 101cc9e
      wb-composite at 1048260
      wb-compositor-task at 104abb4

after two or three demo windows are open — a fixnum where a rectangle should
be. Those critical sections were incidentally keeping interrupts off for most
of the compositor's inner loop and masking a race somewhere in the damage
handling. `damage` and the steal in `wb-composite` are both already inside
`without-interrupts`, so it is not the obvious one. The unfixed version is in
`hw.lisp` at the three sites; removing them is a one-line change each once the
race is found.

**Long blits still block interrupts, and only asynchrony fixes it.** A
full-screen fill is 786,432 cycles charged inside one store instruction, and a
frame is 333,333. Nothing can preempt an instruction, so the only fix is to
make the blitter a state machine the outer loop advances — which means every
caller has to wait for completion, and a spinning waiter and the blit would
both charge the same cycles. Worth doing, but it is a change to what a blit
*means*, not a tuning.

## Images the machine writes itself

**Code space is never compacted, and that is most of why a rebuilt image is
larger than a forge-built one.** `next.img` carries 636 KiB of code region
holding 288 KiB of live code; `kick.img` carries 316 KiB holding 315 KiB.
Sweeping frees the old code but the free blocks interleave with the new, so
blanking them (which `gc-for-image` now does) frees almost no whole pages —
it saved 8 KiB. The real fix is compacting code space, which means relocating
every `clo-entry` and `code-entry`; intra-function jumps are pc-relative and
would survive the move, and calls already go through the closure's entry word.

The rest of the difference is that a rebuilt image is a *running system's*
heap - an Exec with tasks, a REPL, every symbol interned twice - where a
forge-built one is a freshly constructed one.

## Locking

Three mechanisms, and the rule for choosing between them:

- **`without-interrupts`** — for anything an interrupt server touches. It saves
  and restores the hardware state, works before Exec exists, and stops the
  clock, the keyboard and the frame for its duration. The scheduler's lists,
  the signal bits and the pool free list need this.
- **`without-tasks`** (Forbid) — for anything only tasks touch. Interrupts keep
  running; only the scheduler is held off. Costs one increment, needs nothing
  declared, and cannot deadlock. `*windows*` and `*damage*` in the workbench
  are the obvious customers and still use `without-interrupts` today.
- **A semaphore** — not built. For sections that are long, or that block, or
  that only a few tasks contend for. Forbid stops *every* task in the system,
  which is fine for a few instructions and wrong for anything that waits.

`disable`/`enable` and `forbid`/`permit` stay as raw pairs, for the sections
that are not lexical. `wait` is the one that cannot be a macro: it releases
around a `reschedule` inside a loop and takes the section again on the way
back, which no lexical form expresses.

**Semaphores are the missing piece.** An Exec semaphore is a node with a
nesting count, an owner, and a queue of waiters, with Obtain/Release/Attempt
built on Wait and Signal. Perhaps sixty lines. Nothing needs one yet because
nothing holds a lock across a block; the first customer will be a file system
or a disk queue.

## A clean self-hosted rebuild

Today a rebuilt image is a running system's heap. Two things stand between
that and a clean one, and both are listed above:

1. **Compacting code space**, so the dead code a rebuild leaves behind is not
   in the file.
2. **A purify step before saving.** Exec is rebuilt from nothing on resume, so
   at save time the old ExecBase lists, the task records, the reaper list and
   the compiler's caches are all garbage that is still rooted. Setting those
   globals to nil before the final collection, and freeing the pool blocks the
   old stacks occupy, would let the collector take them. This is the old Lisp
   machine trick and it is what `save-image` should do.

With both, `lmforge rebuild` would produce an image the size of what the new
system actually is, and the machine would be able to build a clean successor
without the forge in the loop at all.

## Loose ends

## Note to self

The desktop needs roughly four billion instructions to finish drawing all four
demo windows. A screenshot taken with a smaller budget shows half-composited
windows that look exactly like a compositor bug. This cost real time twice in
one session. Give `--budget` enough room before believing a screenshot.
