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

**No memory copy or fill primitive. WONTFIX**, measured. Five
byte-at-a-time loops, not four. A byte loop moves 4,096 bytes in 98
thousand cycles, 24 a byte; the same with word loads and stores takes 31
thousand, 7.5 a byte; `list->string` of that many characters is 149
thousand. A console burst is one of those every 4 KiB of source, a shell
scroll moves 1,920 bytes and is 6% of printing a screenful. Three
milliseconds a burst is not a primitive's worth. A `bytes-copy!` in
core.lisp over word loads with byte ends is forty lines when one is.

**Exec has no timed wait. RESOLVED.** `sleep` and `wait-timeout`. Deadlines
sit on one list, soonest first, and the timer interrupt, which fires every
quantum anyway, signals whoever's has come on the fixed bit `sigf-timer`.
`wait-timeout` answers the signals that arrived and 0 if the time passed
first, and clears the timer bit around itself so an old deadline cannot
end a later wait. Resolution is a quantum, the scheduler's own. Time is the
machine's: the ticks of that interrupt, which run at the same rate in idle
jumps and under load and the same on every run; `now-ms` reads it. The
timer chip's `millis` turned out to be the host's clock, which made a first
version of this wait hundreds of machine seconds for one host second, and
is now documented as the host's, for pacing to the host only.

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

**Marking is slow per pair. WONTFIX**, measured. Marking costs 187 cycles a
pair marked, exactly the comment's figure, and sweeping 1.8 to 2.8 a pair.
The diagnosis was wrong, though: an opcode profile of a run that is 91%
marking puts 20.7% of it in frame loads and stores and 9.1% in literal
loads of the globals and constants the loop names, and the symbol read and
barrier store of `*mark-sp*` are a small part of that. Making it a machine
global was tried and is a loss, 7.7% more cycles per collection, because a
layout name compiles to the same two instructions as any global and the
tagged load comes on top; caching the frontiers in locals is a loss of 4.6%
for the same reason, a local in a non-leaf being a frame slot. The lever is
register allocation, below. Where it stands: 64% of a synthetic cons churn,
2.8% of a rebuild, and none of `(check)`, which runs no collection at all
and is not a collector benchmark. The collector's report now splits its
cycles by phase, since its "of N cycles" was elapsed time and misled.

**The workbench waits for the blitter with interrupts off. RESOLVED**, as
stale. wb.lisp has no critical section at all; the compositor copies from
front bitmaps with none. The incremental collector takes no blits. The one
blit inside a critical section is `clear-bitmap` in `collect-for-image`,
on the way into an image, when nothing else runs. The spin, when it
happens, is in `blit-wait-descriptor`, not `blit-sleep`. The measurement
predates the collector that does not stop the world.

**A run is charged to the collector when it is handed out. RESOLVED.** What
the same instrument found instead was the collector's pacing: every refill
charged a whole 256 KiB chunk of collector debt, whatever the run's size,
and to whichever task asked, so a fresh task's first cons during a cycle
ran 3.8 million cycles of marking before it continued, a task erroring
inside a critical section held interrupts off for a million instructions,
and a sweep hole of a few pairs cost as much as a chunk; a rebuild's second
cycle charged 605 refills, most of them holes, at a chunk each. A run is
now charged when it has been used up, for its own size, to the task that
was handed it: 42 thousand cycles for that first cons, and the erroring
task ends within a vertical blank instead of six.

**The scheduler gave the idle task every other quantum. RESOLVED.** Found
while measuring: `switch-tasks` took the head of the ready list without
comparing priorities, and the idle task is always on it, so a busy task at
any priority was swapped out every tick for a quantum of `wfi`. A hundred
thousand calls of an empty function cost 4.74 million cycles with 19 idle
switches; they cost 2.32 million with none now. A task that can still run
keeps the processor against anything less urgent.

**Cons space fragments between images. WONTFIX**, measured. The sweep was
instrumented to total the holes it leaves below `gap-min`: one map word of
32 pairs here and there, 0.01% of the bytes freed in a churn, 0.6 to 1% in
a rebuild. Lowering `gap-min` to 64 recovers them all and changes nothing
else. The loss that is real is inside live map words, dead pairs beside
live ones that no hole can hand out: 5 to 7% of a rebuild's freed bytes,
and 47% in a workload built to scatter survivors. Only the compactor
recovers that, and the compactor runs on the way into an image. `gap-min`
stays at 512; the instrumentation stays in the verbose report.

**Every character in a shell is a round trip. RESOLVED.** Measured first:
15,100 instructions a character, 28 million a screenful of 80 by 24, half
of it the glyph loop at 76 instructions a pixel, a third the per-cell blit,
damage under the mutex and the compositor's share, the rest scrolling.
Two changes: a shell hands over a run of cells on a row, when the row
changes, when it scrolls, or when it turns to its keyboard, instead of a
cell at a time; and a cell that lies inside the clip is drawn foreground
and background in one pass of six stores a row, with no fill blit. Eight
screenfuls: 226 million instructions before, 72 million after.

**Console output is a request per line and a check per character.
WONTFIX**, measured. `can-ask?` is 159 cycles a call, most of it the two
device-ownership lookups in `running?` and the two CSR operations of
`interrupts-on?`; the character path is 198 cycles and the check is two
thirds of it; a line's request is 13,200 cycles, not 9,700; a character
costs 375 instructions all in, a 2,000-character print 0.75 million. The
check is the correctness of the raw path, a print from a handler or a
critical section going out raw and in order, and hoisting it to once a
line, which is safe, would save a third of a line. Not worth a subtlety
at these numbers.

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

**Printing a symbol hashes its name. WONTFIX**, measured. Writing a symbol
costs 1,350 cycles, of which `find-visible` is 880, two thirds; a string
costs 550 and a fixnum 1,600, most of that `number->string`. A thousand
symbols is 67 milliseconds of the machine's clock. The fast path, an `eq?`
on the symbol's package against the current one plus a shadow check, would
take 60% off; the full question must still be asked when it fails, because
it is exactly whether the reader reads the name back as this symbol.

**The obarray does not grow. WONTFIX**, measured. 3,015 symbols in 1,021
buckets: chains average 2.95, the longest is 9, 50 buckets are empty, and
interning a new name costs 2,400 to 2,600 cycles. After 20,000 more the
chains average 22.7, the longest is 41, and a new name costs 3,100 to
5,000, a miss through every used package 20,600. A cost that grows by a
factor of two to three at that size, with no cliff, does not need growth
yet. It would be the walk snap.lisp already does to rebuild the table,
triggered on the count.

**Bignum arithmetic costs a trap per operation. WONTFIX**, as design. The
trapping `+` is what makes a fixnum add one instruction, and fixnums are
the overwhelming case. This is a warning to users and stays one.

**Compositing allocates. RESOLVED**, in the part that was a mistake. Counted
under the balls and eyes demos, the one-copy path was taken by 20% of
damage rectangles with the drawing window in front and 1% with it behind.
The cause in front: `present` damaged the window's footprint, which
includes the shadow it throws, and a footprint is by construction never
wholly inside the window, so the fast path could not apply to the very
thing it was written for. A present now damages the window itself, since
its shadow falls on what is behind and does not change with what is
inside: 94% one-copy with the window in front, and a fifth fewer
instructions for the same scene. Behind another window the long way round
is the right way, and stays; the allocation there is 111 thousand
instructions a call and not worth a scratch region.

**`asm:literal` is linear. WONTFIX**, measured. Over a whole library build
it is called 14,937 times and makes 134,236 comparisons, nine a call; the
largest function has 220 literals. Nothing to do.

**On the host. WONTFIX.** Neither the unconditional scanout nor the
`prof_on` test is measurable against dispatch, as the item says. The
scanout is capped at 83 Hz and the flag is a perfectly predicted branch.

**In the forge, the prelude files are read twice. WONTFIX**, measured.
Reading is 54% of a 3.1 second build, but not where the item put it: the
Rust reader takes two milliseconds over its 655 forms, and the rest is
`read.lisp` running interpreted, with interning and package lookup half of
that. The two readings are by different readers into different
namespaces, the Rust one knowing no packages, so the same text interns to
different symbols and a cache of forms is unsound. The lever, if a build
ever needs to be faster than three seconds, is the interpreted reader.

## Compiler

**Register allocation across calls. WONTFIX**, measured. Frame loads and
stores are 8.1% of the instructions of the suite run, not a quarter to a
third, with no spills at all; the collector's mark loop is the worst case
at 20.7%, plus 9.1% in literal loads of the names it uses. It would mean
an intermediate representation in a single-pass emitter that runs on the
machine and must stay interpretable by the forge, for a fifth of the
collector and a twelfth of everything else.

**A leaf that allocates keeps a frame. WONTFIX**, measured. Of 2,828
functions the library build compiles, 1,010 are leaves and 21 more would be
but for allocating: `reverse`, `cons`, `revappend`, `string->list`,
`make-list`, `iota`, the assembler's `label` and `literal`, and a dozen
others, none of which appears in a profile of the suite run. The fix the
item names is right and small, adding `t0` to the allocator's live mask,
but `t0` is also the closure register a leaf keeps, the refill stub is
emitted at build time only, and `check-leaf` must learn that the stub call
is not a call: three things that interact in the one piece of code that
cannot be tested incrementally, for 21 functions.

**`%ld-half` and `%st-half!` are four instructions each. WONTFIX**, with the
reason corrected. The blocker is not encoding space: custom-2 has nearly
all of its funct7 space free, and custom-1's funct3 6 and 7 are the unused
`ldxbi` and `stxbi`, exactly where a tagged half-word load and store would
go. Measured: the pair sweep, where the test lives, is 1.5% to 11% of a
collection depending on how much is dead, and a one-instruction load would
take a tenth off the sweep, 0.2% to 1.3% of a collection. Not worth an
opcode.

**Compressed branches and jumps are not emitted. WONTFIX.** A fixpoint
relaxation pass in a compiler that runs on the machine, to save 1.6% of the
image, and the compiler's condition results land in `t2`, which the
compressed branches cannot name. The weakest item in the file.

**`c.lw` and `c.sw` rarely apply. WONTFIX.** The frame layout is what the
collector's frame walker reads; laying it out upward is a handful of
constants and the worst class of bug if one of them is wrong. If ever
attempted, `rebuild --check` with `gc-verify` on is the gate.

**Records cost about nine percent of code space. WONTFIX**, measured and
confirmed: 395 accessor, predicate and allocator functions hold 50.5 KiB of
the image's 527 KiB of code, 9.4%. The definitions are load-bearing in the
forge, where they are interpreted before any inline exists, so suppressing
them needs the two-pass build to know which are only ever called. Code
space is 16 MiB and 3% used.

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
