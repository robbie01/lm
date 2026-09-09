# Open items

Things deliberately left undone, with enough detail to pick them up cold.

## Safety

**Overflow trapping is built but not switched on.**
`faddo`, `fsubo` and `fmulo` trap when a result will not fit in 31 bits. They
are tested and nothing emits them. Two things block turning them on:

- `hash-string-into` computes `(%* h 33)` where `h` is 30 bits. That overflows
  on purpose and masks afterwards.
- The fixed-point Mandelbrot in `demo.lisp` relies on multiplies wrapping.

Turning it on means deciding what a number that does not fit should become —
which is a decision about bignums, not about encoding. Until then, arithmetic
is type-checked and wraps.

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

## Instructions with no users

Emitted zero times in the image: `fltu`, `faddo`, `fsubo`, `fmulo`, `ldxbi`,
`stxbi`, and `fori` (four sites, two executions). The overflow three are
deliberate — see above. The rest exist because the encoding is orthogonal.
Decide whether orthogonality is worth the decode arms, or drop them.

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

## Loose ends

**`sysbase-ptr` (address 8) and `lg-sysbase` are dead.** Nothing writes them
since ExecBase became variables. They are still in the Rust memory map. Either
remove them or point them at something real.

**`preemption-off` silences the vblank and input interrupts and never turns
them back on.** That is correct for a rebuild, which writes an image and stops.
If a rebuild ever needs to leave the machine usable, it needs a matching
`preemption-on`.

**The profiler is behind a cargo feature.** `--features isaprof` adds a counter
per dispatch slot, a per-mnemonic breakdown of the custom opcodes, memory
traffic by base register, a leaf-function census and a count of what tagging
costs. It needs a rebuild to use. Consider a runtime flag instead.

## Note to self

The desktop needs roughly four billion instructions to finish drawing all four
demo windows. A screenshot taken with a smaller budget shows half-composited
windows that look exactly like a compositor bug. This cost real time twice in
one session. Give `--budget` enough room before believing a screenshot.
