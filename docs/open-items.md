# Open items

What was missing, what was risky, and what is deliberately left undone.
Every item now carries a verdict. **RESOLVED** means it is done, or was
found to be already true of the tree, or the item was mistaken. **WONTFIX**
means it was weighed and decided against, and says why; where something
would reopen it, the trigger is named. Fixed problems are not kept here
beyond their verdict; the git history has them.

## API gaps

**No condition system. WONTFIX**, as design; see cleanup-targets.md. Of the
four consequences listed, three are the design working as meant: a mutex
abandoned by an error is handed on marked, and the repair a mutex can carry
is the right recovery for a half-updated invariant, better than an unwind
that restores the wrong state; a task's bindings and devices go with the
task. The fourth, a caller that cannot time out, is resolved below.

**An error inside the trap handler halts the machine. WONTFIX.** An
interrupt server that faults is a driver bug, and a halt that names it is
the honest response. Ending the server's task from inside the handler means
unwinding the outer trap frame by hand in the stub, which is assembly
emitted at build time and not testable on a running machine. Widening
faults, the common nested trap, already resume. *Trigger:* a driver that
must survive its own bugs.

**No way to interrupt a running form from the console. WONTFIX.** Without an
unwinder a break can only abandon the stack, which is what an error does
already, so this waits on the condition system it would need.

**Floats are unfinished. WONTFIX**, as leave. The item understated it: only
the forge's reader makes a float; the machine's own reader has no path for
one and reads `1.5` as a symbol. Nothing on the machine makes, prints or
adds one, and nothing needs one. `t-float` stays a reserved type, and no F
extension is added to the processor. *Trigger:* a program that needs them,
at which point software floats in Lisp, the way bignums are done, are the
shape.

**Bignums. RESOLVED** in the part that was wrong, **WONTFIX** in the rest.
`(%/ -1073741824 -1)` no longer wraps: the processor traps that one
quotient, 2^30, as an overflow and the handler widens it, so `%/` and
`quotient` agree. Bitwise operations, `gcd` and a faster division have no
user in the tree; bignum.lisp is compiled only, so any of them is a local
change when one appears.

**No memory copy or fill primitive. WONTFIX**, until measured. Five
byte-at-a-time loops, not four. Two of them are amortised or bounded; the
two that could matter are the console burst copy and the shell scroll. A
`bytes-copy!` in core.lisp over word loads with byte ends is forty lines
and needs no new syntax. *Trigger:* either of those two in a profile.

**Exec has no timed wait. RESOLVED.** `sleep` and `wait-timeout`. Deadlines
sit on one list, soonest first, and the timer interrupt, which fires every
quantum anyway, signals whoever's has come on the fixed bit `sigf-timer`.
`wait-timeout` answers the signals that arrived and 0 if the time passed
first, and clears the timer bit around itself so an old deadline cannot
end a later wait. Resolution is a quantum, the scheduler's own.

**`wait-ports` is not fair. RESOLVED** for fairness: the scan starts one
port further along on each call, so a busy port cannot starve a quiet one.
Port priority is **WONTFIX** until a driver has two classes of client.

**`%slot` takes any object. RESOLVED** in the part that was a hole. The
bound check in the processor used the header's count as a word count for
every type, and a string or byte object counts bytes, so a word access
through the "any object" form reached up to three words past the object,
reading and writing. The count is now converted to the access size. The
type looseness that remains is the point of the form: the printer and the
explorer walk objects by index, and `%slot` is the raw accessor that lets
them. It belongs in the raw vocabulary; see memory-safety.md.

**The reader has no block comments. RESOLVED.** `#| |#` nests and `#;`
comments out the datum after it, both handled where whitespace is, so a
comment before a closing parenthesis is fine. The bootstrap reader in Rust
does not know them, so a source file the forge reads cannot use them.

**No file system. WONTFIX.** The forge is the file system: sources live on
the host and `lmforge rebuild` reads them from there, which is the
self-hosting story. A file system on the machine buys editing sources on
the machine, which needs an editor first, and the image would need a home
inside it. *Trigger:* an editor.

**Window management. WONTFIX**, with two corrections and one deletion. The
collapse box was never drawn; the zoom box is drawn and starts a drag;
`drag` clamps a window wholly on screen, so a window cannot be lost off the
edge and that clause is moot. `grow-box`, drawn by nobody, is deleted.
Resize needs a size-changed event and a reallocation of both bitmaps;
menus need the toolkit. *Trigger:* an application that needs either.

**A saved image resumes with none of its tasks. WONTFIX**, as design. A
task's stack holds return addresses into code space, and the forge
compacts code space when it makes a fresh image; the two cannot both hold.
Windows are data and survive the save; only their tasks are gone. If a
resume ever wants its windows back, keeping `*windows*` and re-running each
window's refresh under a fresh task is a wb.lisp-only change.

## Performance risks

**Marking is slow per pair. WONTFIX**, until measured. The diagnosis holds:
the mark stack pointer is a Lisp global read and written through its
symbol, and its store goes through the barrier-checked path. The cheapest
route is not the one the item proposed: make `*mark-sp*` a machine global
in the low memory map and read it with `%ld-fixnum`, one instruction each
way, four edits, no restructuring. *Trigger:* marking in a profile of
something that matters.

**The workbench waits for the blitter with interrupts off. RESOLVED**, as
stale. wb.lisp has no critical section at all; the compositor copies from
front bitmaps with none. The incremental collector takes no blits. The one
blit inside a critical section is `clear-bitmap` in `collect-for-image`,
on the way into an image, when nothing else runs. The spin, when it
happens, is in `blit-wait-descriptor`, not `blit-sleep`. The measurement
predates the collector that does not stop the world.

What the same instrument finds now is the collector's pacing. A fresh
task's first cons is handed a 256 KiB run and charged the whole of it as
collector debt, so with a cycle in progress that first cons runs about 3.8
million cycles of marking before the task continues; inside a critical
section the cap of two slices is applied per allocation, not per section,
so a task that conses for an error message there holds interrupts off for
one to two million instructions. The suites were made to wait for
conditions rather than fixed times because of it. **WONTFIX** for now: the
machine is correct and the cost is bounded. *Trigger:* a task's start
being visibly slow, or the pause meter mattering.

**Cons space fragments between images. WONTFIX**, until measured. The
failure is hypothetical. Before building sliced compaction, try the
one-constant experiment: `gap-min` is 512 bytes and the run machinery has
no minimum of its own, so lowering it recovers most of the loss with no
mechanism. Note that a smaller run means more refills, and each refill is
charged a whole chunk of collector debt; the two should be changed
together.

**Every character in a shell is a round trip. WONTFIX**, until it hurts.
The batching the item asks for is already in console.lisp for the serial
stream and is the template. *Trigger:* printing a screenful in a shell
being visibly slow.

**Console output is a request per line and a check per character.
WONTFIX.** The cost is higher than stated, since `interrupts-on?` is two
CSR operations, but the check is the correctness of the raw path: a print
from a handler or a critical section must go out raw and in order. Hoisting
it to once per line is safe, since nothing in the character loop changes
the answer, and is the fix when it is measured.

**`bm-plot` and `bm-point` wait for the blitter per pixel. RESOLVED**, as
not a risk. The fast path is documented beside them: `blit-sync` once, then
store through `bm-at` or `win-row`, as the glyph drawers and life do. The
Mandelbrot demo plots a pixel at a time because it is a demo.

**`alloc-object` fills vectors and records inside the critical section.
WONTFIX.** Nothing at run time makes a large vector; the obarray is built by
the forge and shell grids are byte objects, which are filled outside.
Filling outside needs the collector to know an object is under
construction, since a slice can see it. *Trigger:* a large vector made at
run time.

**Printing a symbol hashes its name. WONTFIX**, until measured. The fast
path is an `eq?` on the symbol's package against the current one plus a
shadow check, which is the common case; the full question must still be
asked when it is not, because it is exactly whether the reader reads the
name back as this symbol.

**The obarray does not grow. WONTFIX.** 1,021 buckets against a few
thousand symbols; growth is the walk snap.lisp already does to rebuild it,
triggered on the count. *Trigger:* a session that interns tens of
thousands.

**Bignum arithmetic costs a trap per operation. WONTFIX**, as design. The
trapping `+` is what makes a fixnum add one instruction, and fixnums are
the overwhelming case. This is a warning to users and stays one.

**Compositing allocates. WONTFIX.** The common case, damage inside one
window, is one copy and no allocation, and was added deliberately. A
pool-backed scratch region for the multi-window case is a fair amount of
mechanism for the rare case. Measure how many damage rectangles fall
through before building it.

**`asm:literal` is linear. WONTFIX.** Build-time only, and quadratic only
in the few very large functions. A cap on the scan with duplicates past it
is two lines if it ever matters.

**On the host. WONTFIX.** Neither the unconditional scanout nor the
`prof_on` test is measurable against dispatch, as the item says. The
scanout is capped at 83 Hz and the flag is a perfectly predicted branch.

**In the forge, the prelude files are read twice. WONTFIX.** They are read
by two different readers into two different namespaces: the Rust reader
knows no packages, `read.lisp` does, so the same text interns to different
symbols on the two passes and the obvious cache is unsound. The large
reader cost was already removed when sources went through a byte buffer.

## Compiler

**Register allocation across calls. WONTFIX.** It means an intermediate
representation in a single-pass emitter that runs on the machine and must
stay interpretable by the forge. The leaf optimisation already takes the
easy two thirds. *Trigger:* `LM_FNPROF` showing spills where it matters.

**A leaf that allocates keeps a frame. WONTFIX**, for now. The fix the item
names is right and small, adding `t0` to the allocator's live mask, but
`t0` is also the closure register a leaf keeps, the refill stub is emitted
at build time only, and `check-leaf` must learn that the stub call is not a
call. Three small things that interact in the one piece of code that
cannot be tested incrementally. *Trigger:* a measured leaf that allocates
in a hot loop.

**`%ld-half` and `%st-half!` are four instructions each. WONTFIX**, with the
reason corrected. The blocker is not encoding space: custom-2 has nearly
all of its funct7 space free, and custom-1's funct3 6 and 7 are the unused
`ldxbi` and `stxbi`, exactly where a tagged half-word load and store would
go. *Trigger:* the collector's run-skipping test in a profile.

**Compressed branches and jumps are not emitted. WONTFIX.** A fixpoint
relaxation pass in a compiler that runs on the machine, to save 1.6% of the
image, and the compiler's condition results land in `t2`, which the
compressed branches cannot name. The weakest item in the file.

**`c.lw` and `c.sw` rarely apply. WONTFIX.** The frame layout is what the
collector's frame walker reads; laying it out upward is a handful of
constants and the worst class of bug if one of them is wrong. If ever
attempted, `rebuild --check` with `gc-verify` on is the gate.

**Records cost about nine percent of code space. WONTFIX.** Understated:
26 records, 173 fields, about four hundred emitted functions. But the
definitions are load-bearing in the forge, where they are interpreted
before any inline exists, so suppressing them needs the two-pass build to
know which are only ever called. *Trigger:* code space mattering.

## Instructions with no users

**`fltu`, `ldxbi`, `stxbi`, `fori`. RESOLVED**, as a decision to keep. `fori`
has a user, `emit-or-const`, so the item was wrong about it. The other
three are tested encodings costing nothing; `fltu` documents the intent for
address compares, and `ldxbi`/`stxbi` are the free slots the half-word item
above would spend.

## Held ISA ideas

**An allocation instruction. WONTFIX**, held. The item's own objection is
decisive: it puts an allocation policy into the instruction set, and that
policy has already changed once.

**A "what type is this" instruction. WONTFIX**, held. There is room for it,
but the 48 dispatch sites already start from one header read, so it saves
the tag extraction and not the dispatch; the win would need a jump-table
emitter.

**Compare-immediate-and-branch. WONTFIX**, held. A new branch format breaks
every tool that walks the encoding, including the compiler's own
instruction-width scanner, for 2.8%.

## Images

**Code space is never compacted. RESOLVED** for the path that ships: the
forge's `compact_code` exists and `lmforge rebuild` runs it, relocating
every closure entry, so a rebuilt image carries no holes. An image from
`(save-image)` is not compacted, and cannot be, because its stacks hold
return addresses; that is the same fact as the resume item above, and is
by design.

**The machine cannot move objects. WONTFIX.** [moving-objects.md](moving-objects.md)
has what it would take. The forge covers the case that matters, the size
of an image.

## Notes

**The desktop needs roughly four billion instructions. RESOLVED**, as a
note that stays: it is in the README, and a truncated run leaving a
half-composited screen is correct behaviour observed early.
