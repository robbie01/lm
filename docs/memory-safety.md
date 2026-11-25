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
that is not, the root, is reachable only from code compiled `unsafe`.

The sentence this note is about: **code that does not say it is unsafe
reaches only what it was handed.** It can get a typed error or a refused
access, each a report naming the value; it cannot forge a pointer, cannot
write past an object, cannot write an object's header, and cannot lose a
pointer the collector needs to see.

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
one too. A transfer is made only if its capability is tagged, unsealed,
holds the permission (LD to read memory, SD to write it) and covers every
byte the transfer touches, a rectangle's rows and stride included.
Otherwise the chip moves nothing: a blit's done word says which capability
refused it and why, and the blitter's status keeps a bit until it is
cleared; a disk command answers `disk-refused`. What either chip writes is
data, its tags cleared.

**And in time.** A capability a chip holds for a transfer it has not
finished keeps its object alive. A blitter descriptor is a run of slots in
its task's ring, a vector the task's binding holds, so the collector marks
what a blit in flight names as it marks through any vector; the chip clears
a descriptor's capability slots only once it has finished with them, and a
task that ends waits for its ring to drain before it lets go of it. A
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
address, and nothing else. A task's stack and saved registers are sealed in
its record with an otype of the kernel's, so anyone can name a task and
only the task and the kernel can read its frames. A task's descriptor ring,
and a descriptor anywhere but in the hands of the code filling it, is
sealed with an otype of the chips' the same way. Each seals with a key to
its own otype, which it mints once and keeps in its own closures, so
opening a sealed capability by other means takes the root, the escape
hatch. This is what a driver's device page rests on: the driver keeps it in
its closures and its frames, and nothing else holds it.

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
which takes SR. The compiler gives SR only to
code compiled in an unsafe file or containing an `unsafe` form.

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

Two things, the second new with the port. The compiler refuses a raw name
outside an `unsafe` form or an unsafe file, as it did before: every raw
operation and every function that hands out raw memory carries the
`sym-unsafe` bit in its symbol, set by `unsafe-names`. And the code compiled
from such a site carries SR in its entry capability, so the processor
refuses the raw act to code that did not say it, however that code was
made. `unsafe` is `begin` to the interpreter and a permission to the
compiler and the processor.

| what | reaches | on a bad argument |
|---|---|---|
| `%root` | the root | any capability at all, every permission |
| `%ld-word` `%st-word!` `%ld-half` `%st-half!` `%ld-byte` `%st-byte!` `%ld-cap` `%st-cap!`, and `peek`/`poke` over them | memory by number, through the root | any RAM word, live heap, headers and code included |
| `%kernel`, `kernel-ref` `kernel-set!` `all-symbols` | the kernel block and its slots: the trap stub's state, the symbol list, the region and device capabilities | every region the reset stub minted, every device |
| `%slot` `%set-slot!` | any type of object, by index | a closure's slots, if it has been opened |
| `open-closure` | a closure unsealed with the root | its free variables and entry |
| `sealing-key` | a key to an otype, made from the kernel block's otypes | to seal and unseal with that otype, as its manager does |
| `%set-context!` `%set-stack-limit!` `%set-gc-mode!` `%ecall` `%disable` `%enable` `%cons-run` `%set-cons-run!` `%set-this-task!` `%halt` | the machine's own state | arbitrary machine state |
| `task-stack` `task-context` `task-seal` `task-unseal` | a task's stack or saved registers, unsealed, or a seal with Exec's key | another task's frames and registers |
| `device-page` | any device's page, from the kernel block | any register of any device, one a driver holds included |
| `blit-descriptor` `blit-go` `blit-seal` `blit-unseal` | a descriptor the chip reads, unsealed, or a seal with the chips' key | a descriptor written after it was linked, under the chip |
| `code-object-at`, `refill-cons-run` in gc | a code object by its text's address, a fresh cons run | the collector's invariants |

What left the list with the port: `%addr-of` is safe, because a number is
no authority; the operations on a capability already held, `%cap-ld`,
`%cap-st!`, the field readers, narrowing, dropping permissions and sealing,
are safe, because they cannot reach past it; `%ld-fixnum` and `%st-fixnum!`
are gone, a word being a fixnum. `disk-go` and the disk driver's transfers
left it when the controller came to take a capability: a transfer reaches
only what the buffer it is handed covers. A register access left it when a
driver came to hold its device's page: a load or store through a page
already held cannot reach past it, and making the page is the unsafe act.

Where it is said: the collector, the kernel, the chips, the trap handler,
the image writer, the core runtime, the bignums and the compiler are unsafe
files. Outside those there are about forty sites, each inside an `unsafe`
form: the printer and the explorer walking objects by slot and opening
closures, the console's raw line and its wait, the assembler placing the
reset stub, and the suites that exercise raw memory on purpose. The UI
stack, wb, ui, platinum, eyes and the fonts, has none: glyphs and plots
store into a bitmap's pixels through their byte object, which is the design
working. Each driver has one, where it makes its device's page as it
starts; past that, the disk driver hands the controller the byte object it
was given.

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
gone. Building a descriptor names no memory by number, and the disk
driver's one `unsafe` is making its page.

**4. Audit `%from-addr`. RESOLVED.** It is gone: nothing makes a capability
from a number but `%root` with its address set, which reads the root's CSR,
so it faults in code without SR, and the compiler refuses its name outside
`unsafe`. The list of places a pointer can be made from a number is the
list of unsafe files and forms, and the processor enforces it.

**5. State the invariant as a fuzz target. OPEN.** The exec fuzzer already
hands random code random capabilities, bounds and permissions included, and
takes SR away from PCC, and asserts that nothing reaches the host. A
Lisp-level target would generate programs from the checked vocabulary only
and assert that each ends in a value or a report: no fault outside the
typed errors and the refused accesses, and no corrupted heap after.

## Closed before the port

**The raw vocabulary has to be named as such.** The `sym-unsafe` bit and
the compiler's refusal, above. The machine's own compiler enforces it on a
rebuild of itself.

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
Every task keeps its reach into every symbol, every package and every
device whose page it holds. CHERI is what lets one address space be safe
without either: the friction is at the point of writing the code, in the
name it has to say, and in the processor refusing the acts that nothing
ordinary ever needs.
