# Open items

Things deliberately left undone, with enough detail to pick them up cold.

## Safety

**Overflow makes a bignum. Built.**
`+`, `-` and `*` are mixed fixnum and bignum arithmetic: a result that outgrows
thirty-one bits promotes, one that fits again demotes, and no program has to
ask which kind it is holding. `(fact 50)` is exact; `(ash 1 100)` is 2^100.

The fast path is unchanged and still one instruction. `+` emits `faddo` rather
than `fadd` - the trapping form, which had been sitting in the instruction set
unused since it was built - and `try-widen` in sys.lisp catches the trap,
redoes that one instruction in whatever width the answer needs, writes the
result into the saved context and steps the saved pc past it. Every fixnum
instruction already refused an operand that was not a fixnum, so mixed-mode
arithmetic arrives at the same place by the same route: a wrong-type trap on a
bignum operand is not an error, it is the same operation asked in a wider
form. Comparisons come through too, and `flt` and `feq` leave a raw flag
behind, so the handler writes a raw flag and lets the instructions after it
build the `t` or `nil`.

**Representation.** `t-bignum` is sign-magnitude: slot 0 is the sign, and the
slots after it are the magnitude as raw 32-bit limbs, least significant first.
That is the machine's own word, so a one-limb bignum is a machine word with a
sign on it. The collector does not trace the slots - a limb is very often a
word that would look like a pointer.

*The arithmetic works sixteen bits at a time, and that is the part worth
knowing.* A fixnum has thirty-one bits and a limb has thirty-two, so no Lisp
variable can hold a limb: the moment one is loaded into a value it has to be
narrower than the storage it came from. Sixteen is the width that works. A sum
of two halves and a carry is eighteen bits; a product of two halves is
thirty-two, one bit too wide, so it is taken in two pieces - `%mulhi16` for the
top half and a wrapping `%*` for the bottom. `%mulhi16` is not a new
instruction; it is the base `mul`, which the machine has always had and which
nothing else emits, because every other multiply in the system is a fixnum one.

**Should the one-limb case be special?** No, and the reason is that the cost is
not where it looks. A promoted operation costs a trap - ninety-odd instructions
of stub, sixty-two of them memory, before the handler runs - against forty to
sixty for the allocation inside it. Special-casing the allocation would save
perhaps a tenth of the operation, and it would cost a second numeric type in
every dispatch in the arithmetic, which is the code that most has to stay
simple to stay right. If promoted arithmetic ever needs to be faster, the thing
to attack is the trap, not the allocation.

**Three explicit families**, for code with a reason not to promote:

    wrap+   wrap-   wrap*     modulo 2^31, silently
    strict+ strict- strict*   an error if the answer is not a fixnum
    sat+    sat-    sat*      clamped to the ends of the fixnum range

The ordering worry in the old version of this item turned out not to exist:
`hash-string-into` was already written with `%*`, the raw wrapping primitive,
so interning never depended on `*`.

**What is not done:**

- **Bitwise operations on bignums.** `logand`, `logior`, `logxor` and `lognot`
  take fixnums only; a bignum gets a clear error rather than a wrong answer.
  Doing them properly means treating a bignum as an infinite two's complement
  string, which is a real piece of design and not an afternoon.
- **Division is a bit at a time.** Long division by shift-and-subtract, because
  the estimate step of a digit-at-a-time method needs to divide a thirty-two
  bit value by a sixteen bit one, and thirty-two bits is exactly the width this
  machine cannot hold in a value. Correct, and O(bits x limbs). Printing does
  not go that way - it divides by ten thousand at a time, which is the largest
  round number small enough to keep `r * 2^16 + half` inside a fixnum.
- **Floats and bignums do not mix.** They did not before either.
- **No `expt`, `gcd` or `isqrt`.**
- **`(%/ -1073741824 -1)` still wraps**, in the raw primitive. The answer is
  2^30, which is not a fixnum, and the wrapping form does not check. `quotient`
  goes through the checking instruction and is right.

**A machine word is not a fixnum, and `peek` now says which number it means.**
Thirty-two bits into thirty-one does not go, so reading a location has to pick
a reading. Three names, three answers:

    peek / poke               the word as an unsigned integer, 0 .. 2^32-1
    peek-signed               the same word as -2^31 .. 2^31-1
    %ld-fixnum / %st-fixnum!  the raw instruction: the low thirty-one bits,
                              sign extended, in one instruction

`poke` takes anything from -2^31 to 2^32-1 and stores the low thirty-two bits,
so a word read either way goes back unchanged. The raw pair is still the right
thing for an address or a count - neither can have the top bit set on a machine
with 256 MiB of RAM - and it is what the collector and the device registers
use.

Unsigned is the default because a location is a bit pattern and the neutral
reading of one is the number it spells. It costs something, and it is worth
being clear about what: a word with its *top* bit set becomes a bignum where
the signed reading would have kept it a fixnum. That is the only case where the
two differ. A word with bit 30 set and not bit 31 is 2^30, one past the largest
fixnum, and promotes under either reading - so the choice is not between "some
words allocate" and "none do", it is only about the top quarter.

`peek` and `poke` used to *be* `%ld-fixnum` and `%st-fixnum!`, and a tagged
load tags: `(peek a)` of a word holding 0x80000000 answered 0 and said nothing
about it. That is the fault that cost a session of chasing heap corruption in
the collector.

**The location is read once.** Taking a word apart with two half-word loads
reads it twice, which is fine for memory and wrong for a device register: the
timer's counter moves between the two reads, the random register rolls again,
and a half-word *write* to a device only writes the low lane. So the word is
moved whole and taken apart in a scratch cell (`lg-scratch3`, chosen because
the collector scans `lg-scratch0` as a root and what sits here is a raw word).

`(words)` at the prompt checks all of it.

## Fixed: traps nest now

The trap stub used to swap `mscratch` into a register and save the whole
register file into the one block it named. There was one block per task and no
notion of depth, so a trap taken *inside* the handler overwrote the registers
of the trap already in progress, and the `mret` at the end returned into
whatever was left - a fault that surfaces somewhere else entirely, a second
later.

That was always true and never mattered, because nothing the handler ran could
fault. Widening changed it: `+` is a trapping instruction now, so an interrupt
server that adds two large numbers takes a second trap while the first is still
in progress. That is a legitimate thing to do, so the stub was made to handle
it rather than the code being told to avoid it.

**How it works.** `mscratch` names the frame the next trap saves into:

- `lg-trapdepth` counts traps in progress. The stub bumps it on the way in and
  drops it on the way out.
- At depth 1 the frame is the running task's own context block, which is what
  makes a task switch a matter of editing it and pointing `mscratch` somewhere
  else.
- Deeper than that, the frame comes from `trap-nest`, an array of eight. Each
  entry is a frame plus a link word holding the frame it interrupted, so the
  way out can put `mscratch` back.
- The trap stack is only reset at the outermost level. A nested trap is
  already running on it and pushes below what is there.
- Nine deep is a handler faulting on every attempt rather than a program doing
  anything reasonable, so the stub stops the machine with exit code 9 instead
  of writing over a frame that is still in use.

The awkward part is the entry sequence: at the moment a trap arrives there are
no free registers at all. Swapping `mscratch` frees one, and working out
*which* frame needs a second, so `t1` is parked in a fixed low-memory cell
(`lg-traptmp`) for the dozen instructions it takes. Nothing in between can
fault, so that cell cannot be re-entered.

`(nesting)` at the prompt is the regression test: it installs a vertical-blank
server whose arithmetic widens - a trap inside the handler, several hundred
times - and checks that the answers are right and the depth unwound.

**What still must not be done on the interrupt path,** even though it now
works: `timer-set-in` sets the next quantum from the timer interrupt, and it
does its thirty-two bit arithmetic sixteen bits at a time with fixnum
operations. The promoting `+` would be correct, and would take a second trap
and allocate a bignum every quantum. That is a choice about the hottest path
in the system rather than a rule.

**A trap worth remembering.** `%ash` takes its shift count modulo thirty-two,
which is the machine's rule and the right one for a primitive - and it made
`(ash 1 100)` answer 16. That was there before bignums and could not be seen,
because there was no answer to give instead. `ash` is no longer an inline alias
for it.

**Two readers, one answer.** A literal wider than a fixnum is a bignum on both
sides of the bootstrap. That took more than it looks: the forge reads its own
later sources with the *machine's* reader running on host primitives, and the
machine's reader builds a number by multiplying by ten - so `%*o` on the host
had to be arbitrary precision too. It was i64 for one build, and a twenty-six
digit constant in a source file quietly became its bottom sixty-four bits while
the same constant typed at the prompt was correct.

The host's arithmetic is `num_bigint`'s. It runs at build time on a machine
with a real allocator and a crate registry, and the only thing it has to be is
right; there is nothing to learn from a second hand-rolled kernel. `rug` would
be faster and is GMP behind a C build - this way the build stays a plain
`cargo build`. The interesting implementation is the machine's own, which has
to work in sixteen-bit pieces because a Lisp value there cannot hold a limb.

`(numbers)` at the prompt checks all of this - the boundaries, the one number
whose magnitude is not a number, promotion, demotion, division with negatives,
sorting a mixed list, and the three explicit families.

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

## Fixed: the scheduler lost tasks

A task could be taken off the ready list by something that had nothing to do
with it, and then never run again: not woken late, not corrupted - on no list
at all, marked ready, holding a signal it had already been sent.

`remove-node` spliced a node out of its list and left the node's *own* links
pointing at the neighbours it had at the time. A second removal therefore
joined those two stale neighbours to each other, and anything that had been
inserted between them in the meantime came out with it. And a second removal
is normal:

    switch-tasks takes the next task off the ready list with rem-head, which
    is remove-node. That task runs, signals somebody - who is enqueued on the
    ready list, quite possibly exactly between the two neighbours the running
    task still remembers - and then ends. Ending reaps it, and reaping is
    forget-node, which removed it a second time.

So it needed one task to exit while another was newly ready, which took four
or five tasks and a particular interleaving. Everything about it looked like a
lost wakeup, which is where two sessions of suspicion went. Removal is
idempotent now: taking a node out says so in the node.

The same audit turned up a second one in `wait`, which added itself to the
wait list on *every* pass of its loop rather than once. `add-tail` does not
unlink first either, so a task that was rescheduled without being signalled
stitched the wait list into itself. Nothing was reaching that path, but it is
the same mistake and it is fixed the same way.

## Devices are tasks, and talking to one is sending it a message

The blitter bug was not a hard bug to fix once it was found. What was wrong was
that the API let it be written: a resource with no owner, reachable from any
context, and a corruption that surfaced minutes later somewhere else. So the
mechanism is now the one AmigaOS used for `QBlit` and Go uses for everything -
a server you send to, rather than a lock you take.

**A driver is a task with a port.** `make-server` spawns it; `request` sends
and waits for the answer; `send` does not wait; `notify` is an edge with no
message, which is what an interrupt server posts because a server must not
allocate. There is no device registry and no `OpenDevice`: a driver is reached
by naming the symbol that holds it, which is the one thing a Lisp machine gets
for free and an Amiga needed a string-keyed table of IO ports for.

**One blocker per task.** `wait` takes a signal mask, and a port has a signal
bit - so a task waiting for a message, a device interrupt and the vertical
blank is doing one `wait` over the union, and does not have to know which kind
of thing woke it. That is the orthogonality worth protecting: interrupts and
messages are the same mechanism seen from the two ends. `wait-ports` is the
`select` on top of it, for a server with a control port beside its work port.

**Multiplex by making more tasks.** `spawn` makes a dependent one - a
goroutine, near enough - that is removed when its parent is, so a server that
fans work out does not have to remember what it started. The one place that
was multiplexing by hand is fixed: input used to be a single global naming the
one task allowed to hear about it, so every kind of event had to be decoded in
one loop. `input-listen` answers a port now, and any number of tasks can have
one.

**The blitter belongs to task context.** `blit-block` refuses in an interrupt
server, and says to signal a task instead. That is the rule the original bug
broke, made explicit and checked: a server runs with the world half saved, it
must not allocate, it must not block, and anything it draws is drawn over by
the next task that composites. The collector is the exception and has a block
of its own rather than a borrowed one - it can run in either context, it holds
interrupts off from end to end, and it is not drawing.

`(talking)` at the prompt exercises all of it.

**The disk is a driver now** - see *disk.driver* in docs/drivers.md. Moving it
turned up three problems that had nothing to do with disks, all fixed:
`error` had halted the machine since the first commit, because the slot it
calls through was never filled in; a caller could be left blocked for ever by
a server that died or failed, and now gets a failure instead; and a task woken
by an interrupt waited up to a quantum even when it outranked the task that
was running, where the handler now switches on the way out.

**The keyboard and mouse are a driver too**, input.driver, and every listener
now hears every event instead of whichever read the chip first.

**What is not done.** Graphics is not a driver yet; the timer stays the
kernel's. A blit is ten instructions
and a message is a task switch, so routing every blit through a server would
be the wrong trade - the shape that fits is a server for whole operations that
are already batched, which the compositor is close to being. And `wait-ports`
returns the first ready port, not a random one, so a busy port can starve a
quiet one; Go shuffles, and this should too when it matters.

## The forge got twice as fast, and the rest of it is known

A build was 15.7 seconds and is now 7.2, with a byte-identical image.

All of it was one thing: the build's global and macro tables were
`HashMap<String, V>`, so **every global reference in the build allocated a
String out of the machine's heap and hashed it**, and a macro check did it
twice - once to ask whether the head was a macro and once to fetch it. The
build is the compiler interpreted, and the compiler is mostly calls to named
functions, so that was most of the time.

They are now `Vec`s indexed by a dense *name* id. Name rather than symbol on
purpose: the sources read before packages.lisp go through a flat reader with
one namespace and call things that are defined later inside a package -
hostio.lisp calls `compile-top`, which is `compiler:compile-top`. Keyed by
symbol those get separate cells and the build stops with "undefined function".
`Heap::name_id` hands out one id per spelling, which is exactly what the old
map did.

The ids are filled at intern time and *also* on demand, because there are two
interners: `Heap::intern_in` in Rust and `intern-in` in runtime.lisp, and the
second one runs interpreted during the build and makes symbols the first has
never seen.

Also: the environment walk cloned an `Rc` per frame per variable reference,
which is now a borrow.

**What is left, unmeasured but obvious:** `call_prim` dispatches on the
primitive's *name* - a match over two hundred string literals on every
primitive call. It should switch on the index it is already handed. That is a
large mechanical edit and nobody has needed it yet.

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

**Fixed: long blits blocked interrupts.** A full-screen fill used to charge
786,432 cycles inside one store, against a frame of 333,333. The blitter is
asynchronous now: the commit returns in about 750 cycles, time passes while
the chip works, and other tasks run meanwhile - four task switches during one
full-screen fill, measured. See *The blitter becomes a real asynchronous
device* in docs/drivers.md.

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

**The mouse path does not work.** Raising, closing and dragging a window are
all reported not to work in practice on macOS, which is where this gets used
by a person rather than by a script.

That is worth saying plainly because the previous version of this item said
the opposite: it said there was "more of it than it looks", on the grounds
that `wb-button-down` contains a raise, a close and a drag, and `wb-event`
wires them to the mouse. All of that is in the source and none of it is
evidence that it works. Read the code to find out what was *meant*; the only
thing that says what happens is running it.

So there are two items here, and the first one has to be found before the
second is worth starting:

- **Why the mouse does nothing.** Unknown. Somewhere between the host's mouse
  events, the input task, the event decode and `wb-button-down`. Reproduce it
  on macOS first - the Windows build is where this is being developed, which
  is circumstance and not a statement about which one matters.

And then, what was never written at all:

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

## The collector is fifteen times faster, and still stops the world

A collection on a machine with a twenty-five megabyte frontier was 856 million
cycles - four or five seconds with interrupts off, which reads as a hung
machine. It is now 56 million. A bare prompt is 79 -> 41 million, and a desktop
with five windows open 107 -> 42 million.

What did it, in order of size:

- **Blanking moved to image time.** The dead part of cons space was blanked at
  the end of every compaction, a word at a time, which on that heap was seventy
  million cycles - nearly half the collection - to tidy memory nobody would
  look at. Object space and code space were already blanked only for an image;
  cons space is now the third. `*cons-dirty-top*` remembers the high water mark
  so `gc-for-image` still knows what to blank, and images are the same size.
- **The three cons passes skip dead runs.** A word of the mark bitmap covers
  two hundred and fifty-six bytes of heap, and on a mostly-dead heap almost
  every one of them is zero. Each pass now walks a pointer into the bitmap
  alongside its pointer into the heap.
- **The forwarding table is sparse.** `gc-plan-cons` filled an entry for every
  sixty-four bytes of frontier - four hundred thousand stores - when only
  blocks that contain a live pair are ever asked about.
- **`gc-forward-cons` is a popcount.** A block is eight pairs, which is exactly
  one byte of the mark bitmap, and the block index is that byte's index: the
  answer is three loads, a mask and a `cpop`. It was a bit-at-a-time count
  under an eight-byte pin scan, and it is the hottest question in the
  collector.
- **`defsubst`.** The collector's small helpers are open-coded now; a
  collection used to be a million and a half calls to functions two
  instructions long.
- **Type tests fuse into the branch** (`fusable-type-test?` in the compiler).
  `(if (%cons? v) ...)` was mask, two set-if-zeros, an and, a literal load and
  a conditional move, then a branch on the result - eight instructions to ask
  about three bits, where branching on the tag is three. That one speeds up
  everything, not just the collector, and the image got *smaller*.

What is left is proportional to the live set rather than to the heap, which is
the right shape: on a machine with two hundred thousand live pairs, marking
and pointer-updating are two thirds of the collection and each visits every
live pointer once. Getting past that means not visiting them - a generational
collector, with a write barrier and a remembered set - which is a real project
and not a tuning pass.

**It still stops the world.** Interrupts are off for the whole collection, so a
quarter of a second is a quarter of a second in which the mouse does not move.
That is no longer a hang but it is still a hitch, and it is the reason to care
about the paragraph above.

### One trap worth remembering

The first version of the run-skipping read the bitmap word with `%ld-fixnum`,
and a tagged load is `(w << 1) | 1` - it drops bit 31. A map word of
`0x80000000` therefore read back as *zero*, so a run whose only live pair was
its last one was skipped by all three passes and left behind by the move. It
happened a hundred and seventy-three times in one collection, every one at
offset `0xf8`, and it corrupted the image at build time - which is also why the
check loop that would have caught it appeared to report nothing: it was
printing on the build's output and the run's was being read.

`%ld-fixnum` cannot represent a full machine word. Use `%ld-word` for a raw
one, or two `%ld-half` loads when the value has to be a fixnum.

## Fixed: closing a window and the compositor reading it

`window-close` handed the pixels back with `free-pool` and nulled the field,
while the compositor reads window bitmaps outside any critical section - so it
could be part way through that window, reading memory that had just been given
away, or asking a null bitmap how wide it was.

Both halves are gone, and not by adding a lock. A bitmap's pixels are a byte
object now rather than a pool allocation, so closing a window drops the window
from the list and does nothing else: a compositor holding the old list draws
one more stale frame from a bitmap that is still perfectly valid, the damage
repaints over it, and the collector takes the pixels when the last reference
to them goes. See *The blitter: a bitmap is a type, not an address* in
docs/drivers.md.

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
