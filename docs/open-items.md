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

**`%ld-half` and `%st-half!` have no tagged-address instruction.**
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

**Done: the chip takes its whole command from a block in memory.** One store of
an address to `blt-list`, twelve words read by the chip, no lock. Programming
it is atomic because the store is, and the *fill* is safe because the block
belongs to whoever is filling it: every task has one, handed round by the
scheduler with `*out*` and the current package, and interrupt servers have one
more - which `blit-block` chooses by asking, not by the handler assigning. It
was assignment once, and *Fixed: two tasks could share one blitter command
block* below is what that cost.

A shadow bank alone was not enough and it is worth writing down why, because it
looks like it should be. It makes the chip never *run* a half-programmed
command — but `pending` is still one bank, so a server that blits inside a
task's setup overwrites the half already written and the task then commits a
coherent command made of both. The list fixes that by giving each context its
own memory; a shared block would have had exactly the same race.

**Still open: long blits block interrupts.** A full-screen fill is 786,432
cycles charged inside one store, and a frame is 333,333. Nothing preempts an
instruction, so the only fix is a state machine the outer loop advances — which
means every caller waits for completion, and a spinning waiter and the blit
would charge the same cycles. A change to what a blit *means*, not a tuning.

## Records cost about nine percent of code space

`defrecord` emits a getter and a setter function per field, so that an accessor
is a value as well as something the compiler open-codes. That is roughly two
hundred small functions almost nobody calls: code went from 314 to 341 KiB over
the two passes that introduced them. Emitting them only for records that are
asked for by name would get most of it back, and would cost a declaration
nobody wants to write. Worth revisiting when code space starts to matter, which
is the same day compacting it does.

## Fixed: two tasks could share one blitter command block

Kept because it took three sessions to find and the shape of it is worth
remembering.

**The symptom** was a machine that died a few seconds after four or five
windows were open, in a different place every time: a jump to `0xf7f7f7f6`,
`switch-tasks` reading a slot of a fixnum, `car: expected a pair, got 271` on
a damage rectangle. All of them were a word of *colour bytes* where a pointer
should be. It moved whenever anything else moved: one extra call in
`fill-rect` was enough to bring it on or make it go away, so every instrument
written in Lisp made it vanish.

**The fault.** The blitter takes its whole command from a block of memory, and
that is only safe because the block belongs to whoever is filling it - every
task has one. An interrupt server needs one too, and the trap handler gave it
one by *assignment*:

    (set! *in-interrupt* t)
    (let ((saved *blit-list*))
      (set! *blit-list* *int-blit-list*)
      (handle-interrupt-1 n ctx)      ; <- calls switch-tasks
      (set! *blit-list* saved))

`*blit-list*` is per task, and the scheduler swaps it with the rest of a
task's state - from inside that handler. So: task A is interrupted, the
variable becomes the interrupt's block, `switch-tasks` swaps A's state out
*and records the interrupt's block as A's*, swaps B's in, and then the handler
puts A's block back - into B's live value. B then programs the blitter through
A's block, and what the chip runs is half of each. In the case that finally
named itself: a destination address from one window with the row stride of
another, writing 131 rows of pixels across whatever followed the bitmap it
thought it had - a task's context block, so the next `mret` returned into a
word of colour.

It predates fluid bindings. The per-task environment vector they replaced did
exactly the same thing in `save-task-env`.

**The fix** is that choosing a block is a question rather than an assignment.
`blit-block` asks `*in-interrupt*` which block this context should fill;
nothing writes a per-task variable inside the handler, so there is nothing for
a task switch to capture. `*in-interrupt*` is safe to set the same way only
because it is cleared before the handler returns, and no other task runs until
it does.

**What it also fixed:** window chrome appearing on the bare desktop - the same
wild blits, landing on the screen bitmap rather than on a stack - and the
compositor losing a damage rectangle, which was this all along rather than the
cons-run refill race it was blamed on two sessions ago. That race was real and
is also fixed; it was not this.

**What found it,** after three sessions of not: `LM_BLIT_GUARD=1`, which walks
the pool's block chain and checks that every blit stays inside the block it
named. The Lisp-side version of that check could never have worked, because
adding it moved the fault.

## Window management is a farce

There is more of it than it looks - `wb-button-down` raises the window under
the pointer, closes it if the click was in the close box, and starts a drag if
it was anywhere else in the title bar, and `wb-event` wires all of that to the
mouse. What there is not:

- **The zoom box is drawn and does nothing.** `pt-title-box` draws it with a
  bar in it and `in-close-box?` has no counterpart for it. Neither has the
  collapse box, which is not drawn at all.
- **No resize.** `pt-grow-box` exists, is exported, and is drawn by nobody;
  windows are the size they were created.
- **Nothing but the pointer chooses the front window.** No keyboard way round
  the stack, no window menu, no list of open windows anywhere.
- **The front window takes every keystroke**, so activation and focus are the
  same thing and neither can be changed without the mouse.
- **A window cannot be moved off the top of the screen** but can be dragged
  until only a sliver of its title bar shows, and there is nothing to bring it
  back.

Worth doing as one pass rather than piecemeal: the boxes, a resize corner, and
some way to cycle the front window from the keyboard.

## Closing a window frees a bitmap the compositor may still be reading

`window-close` takes the window off `*windows*` under Forbid, then frees its
bitmap. The compositor reads `*windows*` outside any section, so it can be
holding the old list - the one that still has this window on it - and blit from
pool memory that has just gone back. Nothing has hit it, because nothing in the
demos closes a window while the compositor is running.

The Amiga answer is a deferred free: put the block on a list and let the
compositor release it after a pass in which the window was already gone. A
Forbid around the compositor's walk would also do it, but the walk is the
expensive part of the frame and that is exactly the lock that was just taken
off.

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
  the signal bits, the pool free list and object allocation need this.
- **`without-preemption`** (Forbid) — for anything only tasks touch. Interrupts
  keep running; only the scheduler is held off. It costs one increment, needs
  nothing declared, and cannot deadlock. `*windows*` and `*damage*` in the
  workbench are what it is for, and what it holds.
- **A semaphore** — not built. For sections that are long, or that block, or
  that only a few tasks contend for. Forbid stops *every* task in the system,
  which is fine for a few instructions and wrong for anything that waits.

Both are lexical. `Disable`/`Enable` and `Forbid`/`Permit` are no longer public
at all; the one section in the machine that cannot be lexical is in `wait`,
which releases the interrupt state around a `reschedule` inside a loop and
takes it again on the way back, and that one works the state by hand.

**Fixed: two tasks could be handed the same run of cons space.** Worth keeping
on the record, because it wore a disguise for a long time. Cons allocation is
four inline instructions bumping a pointer in `gp` against a limit in `tp`, and
what makes that safe without a lock is that the run those two registers describe
belongs to one task. When a run was used up the stub called `refill-cons`, which
carved a new one under `without-interrupts` and left it in two globals - and
then the stub picked it up from those globals *after* interrupts were back on.
A task preempted in that window came back to whatever the task that ran in the
gap had left there, and the two of them bumped the same run: the same cell handed
out twice, one owner's list node overwritten by the other's data. It surfaced as
`car: expected a pair, got 271` in the compositor, which allocates a rectangle
per window per frame and so lost the coin toss most often. `refill-cons` now
takes the run into `gp` and `tp` itself, before it lets interrupts back in, and
the stub does not touch the globals at all.

That is what the critical section around `composite` was covering for. It is
gone.

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
