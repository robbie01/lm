# Open items

What is missing, what is risky, and what is deliberately left undone, with
enough detail to pick each item up cold. Fixed problems are not kept here;
the git history has them.

## API gaps

**No condition system.** An error prints a report and abandons the stack it
happened on; the prompt's restart, or the end of the task, is the only
recovery. There is no `unwind-protect`, `catch`, `dynamic-wind` or
`with-handler`. Consequences, each of which is handled by hand today:

- `with-mutex` relies on the abandonment mechanism rather than on unwinding:
  a task whose stack an error abandons has its mutexes taken away and marked
  abandoned, and the next taker runs a repair function.
- `fluid-let` relies on the prompt unwinding the binding stack after an
  error; a task without a prompt keeps nothing.
- A device held by a task is released only when the task ends.
- A server's caller cannot time out or cancel a request.

**An error inside the trap handler halts the machine.** An interrupt server
that calls `error`, or faults, has no task to restart: the frame the nested
trap saved belongs to the handler. `abort-to-repl` prints the report on the
serial line and halts with exit code 1. A driver bug in a server is
therefore fatal. The alternative, ending the server's task from inside the
handler, needs the outer trap to be unwound by hand and is not built.

**No way to interrupt a running form from the console.** A prompt task
executing a long form does not read its input. There is no break key.

**Floats are unfinished.** `t-float` exists, the reader makes one from a
literal with a point, and the printer prints `#<float>`. The compiler does
no arithmetic on them, and `+` on a float is a type error.

**Bignums.** `logand`, `logior`, `logxor` and `lognot` take fixnums only.
Division is shift-and-subtract, O(bits x limbs); printing divides by ten
thousand at a time. There is no `gcd`. `(%/ -1073741824 -1)` wraps in the raw
primitive; `quotient` is checked and right.

**No memory copy or fill primitive.** Bytes are copied a byte at a time in
Lisp wherever memory moves: the assembler growing its buffer, the console
driver copying a burst out of its buffer, a shell scrolling its character
grid, `list->string`. A `bytes-copy!` and `bytes-fill!` in the core, or a
route through the blitter for large copies, would replace all of them.

**Exec has no timed wait.** There is no `sleep`, no `delay`, and no timeout
on `wait` or `request`; the only clock a task can wait on is the vertical
blank. A timer server handing out signals at a deadline is the obvious
shape and is not built.

**`wait-ports` is not fair.** It answers the first ready port in the list,
so a busy port can starve a quiet one. Ports have no priority: a
low-priority client's request sits in front of a high-priority client's
until the driver reaches it.

**`%slot` takes any object.** It is right for the places that reach into a
symbol, a closure or a code object by index, and unchecked as to which kind
it got. `%record-ref` and the record accessors are checked.

**The reader has no block comments** (`#| |#`) and no datum comment (`#;`).

**No file system.** The disk is raw blocks, used only by `save-image` and
by the `(drivers)` test.

**Window management is a shell in a window and not much more.** The zoom and
collapse boxes are drawn and do nothing; there is no resize, though
`pt-grow-box` is drawn by nobody; nothing but the pointer chooses the front
window; the front window takes every keystroke; and a window dragged to the
edge of the screen cannot be brought back from the keyboard.

**A saved image resumes with none of its tasks.** Exec is rebuilt from
nothing on resume, the drivers start again, and the workbench restarts on
the screen it had. Anything a task was doing at the save is gone.

## Performance risks

Things that are known to be expensive, in the order they are likely to hurt.

**The collector stops the world.** Interrupts are off from the root scan to
the last pointer update. A collection is about 30 million cycles on a
desktop with a few windows open and 110 million with the frontier full; the
mouse does not move for that long. The update pass pays Lisp call overhead
per pointer. The root scan and the pointer update walk Exec's lists and must
hold interrupts off; the marking and the sweeps touch only the heap and
could run with them on, which is the change that would turn the pause into
a hitch. Beyond that, the cost is proportional to the live set and only a
generational collector reduces it.

**Every character in a shell is a round trip.** `shell-putc` draws the cell,
copies it into the window's front bitmap with a blit, and adds a damage
rectangle under the damage mutex, per character. Printing a screenful into
a shell is a few thousand mutex acquisitions and blits. Batching a line, the
way the console stream does, would remove most of it.

**Console output is a request per line and a check per character.** The
serial prompt's stream asks `can-ask?` (three loads and two tests) for every
character and sends each line to `console.driver` as a request, about 9,700
cycles a line.

**`bm-plot` and `bm-point` wait for the blitter per pixel.** Each call is a
`blit-sync`, cheap when the chip is idle but a function call chain per
pixel. The Mandelbrot demo plots a pixel at a time this way. The glyph
drawers wait once per glyph and then store directly; a demo can do the same
through `win-row`, as life does.

**`alloc-object` fills vectors and records inside the critical section.** A
large `make-vector` holds interrupts off for the length of the fill. Byte
objects and strings are filled outside the section.

**Printing a symbol hashes its name.** `print-symbol` asks `find-visible`
whether the current package would read the name back as this symbol, which
is a hash and a bucket walk per symbol printed. Printing a long list of
symbols is dominated by it.

**The obarray does not grow.** The number of buckets is fixed when the image
is built, so a session that interns many symbols lengthens every chain.

**Bignum arithmetic costs a trap per operation.** A promoted `+` is about
ninety instructions of trap stub before the handler runs, and the handler
allocates. A loop that stays in bignums is a few hundred times slower than
one that stays in fixnums.

**Compositing allocates.** `composite-pieces` builds a rectangle per window
per damage rectangle that touches more than one window, and
`region-subtract` allocates its pieces. Damage inside one window is one
copy with no allocation, which is the common case.

**`asm-literal` is linear in the literals of a function**, so a function
with many distinct constants compiles in time quadratic in their number.

**On the host,** the display is scanned out into the window every host frame
whether or not anything changed, and the core tests `prof_on` on every
custom-opcode instruction. Neither is measurable against the emulator's
dispatch cost today.

**In the forge,** reading is half the build, and the prelude files are read
twice: once for the interpreter and once to compile them.

## Compiler

**Register allocation across calls.** Frame slots and spills are a quarter
to a third of every instruction the machine executes. A rule that
callee-saved registers only ever hold tagged values would keep the frame
walk correct with no extra bookkeeping, and would make `s3` to `s11`
precisely scannable instead of conservatively pinned. The cost is liveness
analysis and spilling in a compiler that has to run on the machine.

**A leaf that allocates keeps a frame.** Allocating is a call, so such a
function is not a leaf by the current test. The alternative is to add `t0`
to the live-register mask the allocator's slow path publishes.

**`%ld-half` and `%st-half!` are four instructions each**, and `%lognot` is
two: custom-3 has no funct3 left for either.

**Compressed branches and jumps are not emitted.** Their encoding depends on
a distance, which needs a relaxation pass. Worth about 1.6% of the image.

**`c.lw` and `c.sw` rarely apply**, because frame slots are at negative
offsets from `s0` and the compressed forms encode unsigned ones. Laying the
frame out upward would make roughly 30% more of the image compressible.

**Records cost about nine percent of code space.** `defrecord` emits a
getter and a setter function per field, about two hundred small functions
that are almost never called because the compiler open-codes them.

## Instructions with no users

**`fltu`.** Every `(%< p limit)` in the collector compares two addresses held
as fixnums, and an address above 2^30 would compare as negative. Nothing in
a 256 MiB machine reaches that; `fltu` is what would make it not matter.

**`ldxbi` and `stxbi`,** a byte at a constant index: string and byte access
is nearly always a computed index.

**`fori`** has four sites and is rarely executed.

## Held ISA ideas

**An allocation instruction** would make allocating a pair indivisible and
remove the per-task runs, `%sync-cons-run`, `%reload-cons-run` and the run
handling in the context switch. It would also put an allocation policy into
the instruction set.

**A "what type is this" instruction** would collapse the type predicates
and make dispatch on type cheap. There are a few dozen such sites.

**Compare-immediate-and-branch.** About 2.8% of executed instructions are a
`li` followed by a branch on it. RISC-V has no such instruction and
inventing a branch format in custom space would break every tool that
walks the encoding.

## Images

**Code space is never compacted.** A rebuilt image carries the holes its
replaced functions left; sweeping frees them but the free blocks interleave
with the live code, so blanking recovers almost no whole pages. Compacting
code means relocating every `clo-entry` and `code-entry`; intra-function
jumps are pc-relative and would survive, and calls already go through the
closure's entry word. `lmforge build` renormalises.

**The machine cannot move objects.** What it would take is in
[moving-objects.md](moving-objects.md).

## Notes

The desktop needs roughly four billion instructions to finish drawing the
demo windows. A screenshot taken with a smaller `--budget` shows
half-composited windows that look like a compositor bug.
