# Memory safety

What the processor guarantees, what `unsafe` still means, what is left
unchecked, and what became of the proposals this note used to make. This is
about what the language lets you say and what the processor lets you do,
not about who may say it: there is one address space, every task can reach
every symbol, and that stays.

## The principle

Safety here is scoping, not supervision, as [drivers.md](drivers.md) says of
the devices: a thing is safe because the ordinary vocabulary cannot express
the unsafe act, not because a supervisor catches it. Since the port to
capabilities the scoping is the processor's. A program reaches memory only
through capabilities it was handed, every capability is bounded, and the one
that is not, the root, is reachable only from code inside an `unsafe` block.

The sentence this note is about: **every raw authority that safe code holds
was handed to it by a site that says `unsafe`.** Safe code can get a typed
error or a refused access, each a report naming the value; it cannot forge a
pointer, cannot write past an object, cannot write an object's header,
cannot open a device, and cannot lose a pointer the collector needs to see.
A site that says `unsafe` may hand out what it holds, the root included, and
that is the rule, not a hole: `(unsafe (symbol-function 'peek))` and
`(lambda (a) (unsafe (peek a)))` are such sites.

## What the processor guarantees

**Spatial safety, by bounds.** Every load and store through a capability is
checked against its bounds, its permissions, its tag and its seal, in the
same comparison that the fast path of the core already makes. The capability
to an object is bounded to exactly its payload, so the header is out of
reach and an access one byte past the end is a capability fault. A pair is its
sixteen bytes, a bitmap's pixels their byte object, a device its 4 KiB
page, a task's stack its stack and a cons run its run. Indexed access checks
the index against the length in the header and the address against the
bounds, so a header that lied could not reach past the object either.
Narrowing is the only direction: bounds outside the capability they start
from leave the result untagged, and its first use traps.

**And by the chips.** The two chips that move memory are handed
capabilities, not numbers, and check them as the processor would. A
blitter descriptor's source, destination and link are capability slots and
the list register a capability register; the disk's buffer register is
one too. A transfer is made only if its capability is tagged, unsealed (a
sealed one, a device among them, is refused as `refuse-seal`), holds the
permission (LD to read memory, SD to write it) and covers every
byte the transfer touches, a rectangle's rows and stride included.
Otherwise the chip moves nothing: a blit's done word says which capability
refused it and why, and the blitter's status keeps a bit until it is
cleared; a disk command answers `disk-refused`. What either chip writes is
data, its tags cleared. In object space a chip goes no further than the
typed operations a program that says nothing unsafe is left with (below):
it moves data only in and out of a byte object or a string, and reads a
descriptor only from a vector, so a symbol, a closure, a code object or a
task's state is no transfer's memory, `refuse-object`, whoever holds the
blitter's device. The one exception is a
capability based at object space's first byte, which only the kernel's
region narrows to: the image writer hands the disk object space that way.

**And in time.** A capability a chip holds for a transfer it has not
finished keeps its object alive. A blitter descriptor is a run of slots in
its task's ring, a vector, and the chip's list register hands the
descriptor it is working on back to a capability load, as the display's
scan-out register hands back its bitmap; the collector's roots read it
there, so the ring, every descriptor linked after it and what each blit in
flight names stay alive even when the task has let go of its ring. The
chip clears a descriptor's capability slots only once it has finished with
them, a ring serves only the task it was made for, so no two tasks fill
one descriptor, and a task that ends waits for its ring to drain. A
bitmap dropped while a blit into it is still running is freed by a later
collection, after the blit has landed. The disk takes its buffer out of the
register when a command starts and drops it when the command ends, and the
command's caller is blocked holding the buffer throughout. The display is
handed its bitmap as a capability in its scan-out register, shows only what
that lets it read, and keeps it for as long as it shows it: the register
hands the capability back to a capability load, and the collector's roots
read it there, so a bitmap on show that nothing else holds stays alive.

**Unforgeability, by tags.** A granule's tag is out of band, and only a
capability store from a tagged register sets it. Integer instructions write
untagged results, data stores clear the tags they touch, and a capability
moved outside what its bounds can represent loses its tag. So a pointer
cannot be made from its bits; the one way to make a capability from a number
is through the root, which is in a CSR that only code with SR can read.

**Encapsulation, by sealing.** Every closure is sealed. It can be called,
with `jcl`, which unseals it into the callee's `t0`, and it cannot be loaded
from, stored into, narrowed or moved; its free variables are the closure's
own code's. A return address is a sentry: it can be jumped to, at its own
address, and nothing else. A task's descriptor ring, and a descriptor
anywhere but in the hands of the code filling it, is sealed with an otype
of the chips'. Each seals with a key to
its own otype, which it mints once and keeps in its own closures, so
opening a sealed capability by other means takes the root, the escape
hatch.

**Immutability, by permission.** nil is the read-only cell at address 0, so
`(set-car! nil 1)` is refused by the capability, not by a test. A capability
with SD dropped refuses stores, and one with LM dropped hands out read-only
capabilities to everything loaded through it, so read-only is deep. A
string or a byte object cannot hold a capability, because it has no SC: a
capability stored into one is stored untagged.

**Privilege, by SR.** Writing a CSR, reading a privileged one, the root's
and `mscratch`'s among them, and `mret` are illegal instructions without SR
in PCC, which is RVY's ASR. A load or store by number is illegal with SR or
without: there is no default capability, and `x0` is no authority, so code
names memory by number only by reading the root and setting its address,
which takes SR. The compiler gives SR only to the code of an `unsafe` block.

**And what the Lisp instructions always checked.** `car`, `cdr`, `set-car!`
and `set-cdr!` check for a pair; the indexed forms check the type in the
header, that the index is a fixnum, and the bound; a call checks for a
closure and the prologue the arity; fixnum arithmetic checks both operands
and widens on overflow; the stack limit stops a frame before it is built;
and the write barrier watches every store, raw or checked, while a
collection is marking, but one through a stack's, a register context's or
the kernel block's own capability, which the collector scanned whole when
marking began.

`(capabilities)` checks each of these at the prompt.

## What `unsafe` means now

It is Rust's two words, with Rust 2024's rule between them.

**`(unsafe ...)` is a block**: "I use raw things soundly here; anyone may
call me." The compiler refuses a raw name anywhere else, and the processor
refuses the raw act anywhere else: only the block's code runs with SR. The
compiler lifts the block's body into an island, a text of its own whose
entry has SR, which runs on the enclosing function's frame and registers
and jumps back; the function around it has no SR. A function whose whole
body is one block is placed with SR whole, and a lambda written inside a
block is the block's authority handed out, so it has SR whole too.

**`(declare unsafe)` is a contract**: "calling me is unsafe." It sets the
`sym-unsafe` bit at the definition, so the name is a raw name from then on:
`(define (peek a) (declare unsafe) (unsafe (%ld-word a)))`, or `(define
*pacer* (declare unsafe))` for a variable whose value raw code trusts. The
body is not a block because it is declared: it says `unsafe` around its raw
operations like any other code. A raw name is defined again only by a
definition that says so, an assignment to one is refused outside a block,
and a name that is defined and safe, or that compiled code has called
outside a block before it was defined, cannot become unsafe, since code
compiled against it calls it without saying so. The intrinsics, which have
no definition, are marked by `unsafe-names` in compile.lisp.

**A block relies only on what it established itself, or on what it checks
itself**, never on a safe caller's promise. That is what makes a block
sound to call from anywhere, and what decides between a block and a
declaration: a function whose raw operations are sound for any argument
is a block, `make-vector-n` checking its length or `uart-string` writing the
line; one whose arguments or moment of calling it trusts is declared,
`alloc-object`, the collector's internals, `blit-go` handed a descriptor.

**Devices.** A device's page is the authority over the device, as RVY has
it: a load or store through it needs nothing more. Pages stay in the
kernel's hands: the reset stub mints them into the kernel block, which only
`unsafe` code reads. What a driver holds, and anything may hold and pass,
is a device, the page sealed with otype 5, and only the accessors
generated from src/dev/*.rs open one, each in a small block of its own, by
checking that the page's base is its own chip's. The promise is exactly
this: **a safe accessor only ever touches a register of the device it was
written for.** It keeps code from touching the wrong chip by accident, a
gfx device handed to a disk accessor traps; it does not stop deliberate
escalation, and opening a device without an accessor is `unsafe` (see
[drivers.md](drivers.md)).

**Names given as data are checked where they become values.** A symbol
handed over at run time names something only if its name is not unsafe or
the site resolving it is inside a block: `%symbol-value` and its setter, the
fluid forms of both, and so `symbol-value`, `symbol-function` (this is a
Lisp-1, so they are one cell), `funcall` and `apply` of a symbol, all test
the bit first and refuse an unsafe name, so `(funcall 'peek a)` from safe
code is a report and not a word of cons space. The test is one load and a
branch on that dynamic path only; a compiled reference to a global by name
pays nothing, since the compiler checked it. Written inside a block, a call
to `symbol-value` or `symbol-function` is open-coded without the test.
`%set-symbol-flags!`, which could clear the bit, is itself a raw name, and
so is every load and store through a capability (below), which would reach
a symbol's cells through the symbol.

**A block relies on no name a program can define again.** Every global is
public, a function's name among them, so what a block hands a raw
capability to, a context, a frame, a region, a descriptor, and what it
takes an answer from that its soundness rests on, is an unsafe name or is
open-coded, and so is the state it keeps between calls: the collector's
phase, its sweeps' bounds, its holes and its marks are unsafe names, its
helpers that are handed a region are declared, and its arithmetic, a
length's check, an object's size, are `defsubst`s. A hook a block calls,
an interrupt server, a sleeper, a restart, is handed nothing raw, and what
it answers is not believed: the scheduler runs a task, and the collector
keeps its frames, by Exec's own table of every task's stack and context
(`*tasks*`), not by the lists a task is on or its record, both anybody's.

`unsafe` is `begin` to the interpreter, `(declare unsafe)` nothing, and both
a permission to the compiler and the processor.

| what | reaches | on a bad argument |
|---|---|---|
| `%root` | the root | any capability at all, every permission |
| `%ld-word` `%st-word!` `%ld-half` `%st-half!` `%ld-byte` `%st-byte!` `%ld-cap` `%st-cap!`, and `peek`/`poke` over them | memory by number, through the root | any RAM word, live heap, headers and code included |
| `%kernel`, `kernel-ref` `kernel-set!` `all-symbols` | the kernel block and its slots: the trap stub's state, the symbol list, the region and device capabilities | every region the reset stub minted, every device |
| `%slot` `%set-slot!` | any type of object, by index | a symbol's cells, a code object's literals, a closure's slots once opened |
| `%cap-ld` `%cap-st!`, their `-word`, `-byte` and `-at` forms, `%bit-ref` `%bit-set!` | whatever a capability the caller holds bounds, by offset or address | a symbol's value cell and flags, a code object's literals, a frame, a region |
| `%stack-pointer` | the running task's stack, from its top down | every frame of the task |
| `%set-symbol-flags!` | a symbol's flags | the bit that makes a name unsafe |
| `open-closure` | a closure unsealed with the root | its free variables and entry |
| `sealing-key` | a key to an otype, made from the kernel block's otypes | to seal and unseal with that otype, as its manager does |
| `%set-context!` `%set-stack-limit!` `%set-gc-mode!` `%ecall` `%disable` `%enable` `%cons-run` `%set-cons-run!` `%set-this-task!` `%halt` | the machine's own state | arbitrary machine state |
| `alloc-object` `make-closure` `compile-function` `place` `code-object` | an object of any type; a closure open to stores; code and its placement | a forged closure, code object or stack; machine code nobody checked |
| `task-stack` `task-context` `*tasks*` | a task's stack or saved registers, from Exec's own table | another task's frames and registers |
| `device-page` `device` `device-seal` `device-open` | any device's page, from the kernel block, sealed or opened | any register of any device |
| `blit-descriptor` `blit-go` `blit-seal` `blit-unseal` | a descriptor the chip reads, unsealed, or a seal with the chips' key | a descriptor written after it was linked, under the chip |
| the collector's internals, `code-object-at`, `refill-cons-run` and `blank` among them, its state, `*phase*`, `*holes*`, the sweeps' bounds and `*keep-marks*` among it, and its hooks `*object-allocator*` `*collector*` `*pacer*` `extra-roots` `invalidate-runs` | a code object by its text's address, a fresh cons run, where a header goes, a region, what the next sweep frees | the collector's invariants |
| the trap handler's internals, `ctx-ref` `ctx-set!` `fault-value` `print-backtrace` and `compose-report` among them | a saved context, a register, a frame | the frames and registers of the code that trapped |
| `disk-go` `disk:read-blocks` `disk:write-blocks` `disk:exclusive` `input:inject` | raw block numbers, a job run with interrupts off, a keystroke | the image on the disk, the person at the keyboard |

**A dereference is unsafe.** A capability is bounded, so a load or a store
through one cannot reach past it, but what it bounds is not data to every
holder: a symbol's capability bounds its value cell and its flags, a code
object's its literals, a region's everything in it. So the loads and
stores through a capability the caller holds are raw names, as
dereferencing a raw pointer is unsafe in Rust, and a program that says
nothing unsafe reaches a slot or a byte only through the typed operations,
which check the type in the header: `vector-ref`, `bytes-ref`,
`%record-ref`, `%bignum-ref` and the rest. What is not on the list:
`%addr-of` is safe, because a number is no authority; the field readers,
narrowing, dropping permissions, and sealing and unsealing with a key are
safe, because without a dereference none of them reaches anything;
`%ld-fixnum` and `%st-fixnum!` are gone, a word being a fixnum. The
generated accessors are safe, since each opens a device only for its own
chip, and opens it and touches its one register in a block of its own.

Where it is said: there are no unsafe files. Every raw act in the system is
inside a block, and every function that is unsafe to call says so at its
definition. In the kernel files, the collector, Exec, the trap handler, the
image writer and the chips, most functions with a raw operation are
declared unsafe and are blocks whole; their public entry points, `gc`,
`room`, `make-task`, `wait`, `eval`, `save-image` and the chips' register
calls among them, are blocks that anyone may call. Outside them the sites
are blocks where they stand: the printer and the explorer walking objects
by slot and opening closures, the console's wait, each driver's start
taking its device, the accessors opening theirs, a float's comparison, and
the suites that exercise raw memory on purpose. The explorer shows what
only a block may hold, an unsafe name's value, a closure's slots, a code
object's literals and what is reached through them, but keeps each in a
table only its window's closures hold, its rows holding a token and naming
the value by its kind and its capability's fields; what it hands a caller
says such a value is there and holds nothing. The
UI stack, wb, ui, platinum, eyes and the fonts, has none: glyphs and plots
store into a bitmap's pixels through their byte object, which is the design
working.

## What remains unchecked

**Temporal safety, outside the capabilities.** Nothing is freed by hand.
Every block of RAM the machine hands out is a pair or an object in the
collector's heap: a value, a function's text, a task's stack and register
context, a trap frame, the trap and boot stacks, a descriptor ring. The
collector frees a block only when no tag anywhere names it, and zeroes
whatever in it could hold a pointer as it frees it, so a capability always
names the block it was made for. What a capability cannot vouch for:

- an address held as a number. A number is no authority, but code that
  holds a region's capability can follow it there, and by then the block
  may be free or somebody else's. The collector and the image writer work
  by addresses within their regions, and `peek`/`poke` by addresses through
  the root, inside `unsafe`.
- the collector's own scratch above object space, the mark map, the mark
  stack and the image writer's tag maps, which no allocator hands out and
  which hold addresses, not capabilities. Each is reached through the
  region capability the reset stub minted for it, so an index gone wrong
  stays in its region.

**Inside `unsafe`.** Code with SR can read the root, and the root reaches
everything: an object's header, the nil cell, a sealed closure's slots, a
function's text, another task's stack. The write barrier still sees a raw
store, so a pointer cannot be lost during a mark, but a raw store can still
corrupt one. Headers are written only by the allocators and the collector,
through object space's capability.

**Stale frame slots.** A frame's local slots are not cleared on entry, so a
slot an earlier call left tagged is a root until it is written. The
collector checks an object's header before believing a stack slot; the
cost is floating garbage, not a wrong pointer.

## Around the model

Rust's position on `/proc/self/mem` is that a safe program writing its own
memory through the file system goes around the language's model rather
than breaking an unsafe block, and the language does not try to stop it.
LM has the same kind of door, and the same position. These are outside what
`unsafe` promises:

- **`eval`.** The compiler is the machine's, and anybody may hand it a
  form: `(eval '(unsafe (%root)))` from safe code compiles a block, and the
  block is the form's own site, which says `unsafe`.
- **Input.** `input:inject` and the input chip's device type for whoever is
  at the keyboard, and what is typed at a prompt is `eval`.
- **The disk.** `disk:read-blocks`, `disk:write-blocks` and the disk's
  device name raw blocks, the image's among them: as much as a file system.
- **Messages to ports.** A declared call such as `disk:write-blocks` or
  `input:inject` is a message to a driver's port, and the port is anybody's
  to send to. A safe program that sends the message itself writes the disk
  or types a key without saying `unsafe`; the declaration marks the call,
  not the protocol. The chips still check every capability they are
  handed, so no message reaches memory it does not cover.
- **Live patching.** Every global is public and every function can be
  defined again; that is what lets a driver's logic be patched while it
  runs. The system's own safe functions are no exception, the compiler's
  among them, its globals and tables included, and patching the compiler
  that checks raw names, or a macro the kernel's blocks expand, changes what
  the next compiled block means. A raw name cannot be redefined or assigned
  without `unsafe`; anything else can be, by design, and that is why no
  block hands a safe name anything raw or rests on its answer: defining one
  again changes what the system does, not what a block reaches.

None is a hole in a block: each is a safe program changing the system it
runs on, through a door the system leaves open on purpose.

## Not a goal: availability

LM protects the integrity and confidentiality of memory, not availability.
Any task can spin at the top priority, hold interrupts off in a critical
section, fill the heap, send a driver garbage, or end a shell. What it
cannot do is read or write what it was not handed.

## The old proposals

**1. Refuse the wild store into the heap. CLOSED** outside `unsafe`, by
the processor: a store by number needs the root, which needs SR, so code
that did not say `unsafe` has no way to name a heap word it was not handed.
The barrier checks every store, raw or checked, so a raw store during a
mark cannot lose a pointer. A store from `unsafe` code through the root
into the heap is still possible, by design: it is `poke`. The collector and
the image writer store through their regions' capabilities instead.

**2. Poison the pool on free. CLOSED**, by retiring the pool. Its stacks,
register contexts, trap frames and descriptor rings are objects, freed by
the collector when nothing names them, so there is no free to poison and no
capability to revoke.

**3. Make the blitter's guard the chip's behaviour. CLOSED**, by handing
the chips capabilities. The blitter's descriptors and the disk's buffer
register hold capabilities, written with capability stores, and both chips
refuse a transfer their capability does not cover and report it, which is
what the old debugging guard checked for, now for every transfer and
against the object itself rather than a guess at its block. The guard is
gone. Building a descriptor names no memory by number.

**4. Audit `%from-addr`. RESOLVED.** It is gone: nothing makes a capability
from a number but `%root` with its address set, which reads the root's CSR,
so it faults in code without SR, and the compiler refuses its name outside
`unsafe`. The list of places a pointer can be made from a number is the
list of `unsafe` blocks, and the processor enforces it.

**5. State the invariant as a fuzz target. OPEN.** The exec fuzzer already
hands random code random capabilities, bounds and permissions included, and
takes SR away from PCC, and asserts that nothing reaches the host. A
Lisp-level target would generate programs from the checked vocabulary only
and assert that each ends in a value or a report: no fault outside the
typed errors and the refused accesses, and no corrupted heap after.

## Closed before the port

**The raw vocabulary has to be named as such.** The `sym-unsafe` bit and
the compiler's refusal, above. The machine's own compiler enforces it on a
rebuild of itself, and a name declared unsafe after code had called it
outside `unsafe` is refused at the declaration.

Three holes in the checked vocabulary, all in the instructions the compiler
emits: the indexed bound used a byte object's count as a word count, so a
word access through `%slot` passed up to three words past the end; the one
quotient that did not fit a fixnum wrapped silently; and the symbol
accessors and the three length reads checked less than their names said.
All three were fixed then, and the port made each structural: the bound is
now checked again by the capability, every quotient that leaves 32 bits
traps, and a symbol slot or a length is read through a typed instruction
whose object is bounded.

## What this is not

There is no MMU and no supervisor, by design, and this does not add one.
Every task keeps its reach into every symbol and every package, and any
task that says `unsafe` can take any device's page. CHERI is what lets one address space be safe
without either: the friction is at the point of writing the code, in the
name it has to say, and in the processor refusing the acts that nothing
ordinary ever needs.
