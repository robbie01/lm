# The machine is RV32 with CHERI

A Lisp machine needs three things from its processor: a pointer that cannot
be forged, a way to tell a pointer from a number without asking the
program, and a way to hand someone a thing they can use but not open. CHERI
gives all three, as hardware, in a RISC-V. The tag bit is the type
discrimination a Lisp machine always wanted; bounds make every object its
own protection domain in one address space; sealing is how a closure keeps
its environment to itself. This note is the contract between the processor,
the forge, the compiler, the collector and the kernel. Where it says *is*,
every part of the system must agree.

The guiding rule: a Lisp value **is** a capability. A pointer is a tagged
capability whose bounds are exactly its object; a number is an untagged
one. Everything else follows.

## Capabilities

A capability is 64 bits plus a tag bit kept out of band.

```
bits  31..0   address   (the low word in memory)
bits  63..32  metadata  (the high word in memory)
tag           1 bit per 8-byte granule of RAM, not addressable
```

Metadata of a tagged capability:

```
31  LD   load data                 27  LM   load mutable (see below)
30  SD   store data                26  EX   execute
29  LC   load capabilities         25  SR   system registers: CSRs, SCRs, DDC
28  SC   store capabilities        24  SE   seal and unseal (authority over otypes)
                                   23  HD   headed: a Lisp object with a header
22..19  otype   0 unsealed, 1 sentry, 2 closure, 3..15 reserved
18      IE      internal exponent
17..10  T[7:0]  top mantissa
9..0    B[9:0]  base mantissa
```

Bounds are CHERI Concentrate with mantissa width MW = 10 for a 32-bit
address: with IE = 0, E = 0 and B and T are exact; with IE = 1, E =
{T[2:0], B[2:0]} and those six bits read as zero in the mantissas. T[9:8]
are derived from B and the carry, as in the ISAv9 specification. The
representable region, the corrections, and the instructions that round
(`CRRL`, `CRAM`) are as ISAv9 defines them for this MW. Small objects are
exact; a large object's base and length are rounded to a power of two that
grows with its size, and the allocator asks the processor what to round to.
`src/cap.rs` is the reference: the processor, the forge and the bench all
use it.

**HD** is a software-defined permission. It says the capability's base is
the payload of a Lisp object whose header is the granule just below the
base. Only the allocators mint it. Clearing it, like clearing any
permission, only takes authority away: a headed object with HD cleared
looks like an unheaded block, which is safe. A pair can never acquire it, so
the processor never reads a header that is not there.

**LM**: a capability loaded through an authority that lacks LM has SD, SC
and LM cleared, unless it is sealed. Immutability is deep: a read-only list
hands out read-only tails.

**Sealing.** A sealed capability cannot be dereferenced or modified; any
modification clears its tag. otype 1, the sentry, is unsealed by jumping to
it. otype 2, the closure, is unsealed by calling it (`jcl`, below). Neither
needs an authority to make: anyone may seal their own code or closure
object, and nobody may open one except by entering it, or with an authority.
Sealing or unsealing with an explicit authority, for any otype, needs a
capability with SE whose address is the otype; the root is one, which is how
the escape hatch opens a closure.

**Untagged capabilities are data.** Every integer instruction reads the
address field of its operands and writes an untagged result whose metadata
is 0. Loads of data (`lw`, `lb`, ...) write the same. Any store that is not
a capability store clears the tag of every granule it touches. A capability
store (`sc`) writes the tag of its source register, and needs SC in its
authority to store a tagged one.

The NULL capability is all zero and untagged. It is also the integer 0.

## Values

```
untagged, meta 0          fixnum: the address field, a 32-bit signed integer
untagged, meta 1          character: the code point in the address
untagged, meta 2          the unbound marker
untagged, meta 3          eof
untagged, meta 4          void
untagged, meta 5          the default marker
tagged, unsealed, no HD   a pair: 16 bytes at its base, car at 0, cdr at 8
tagged, HD                an object: header at base-8, payload from base
tagged, HD, otype 2       a closure
tagged, otherwise         a raw capability: code, a stack, a device, a pool block
```

**Fixnums are machine integers.** 32 bits, two's complement, no tag shift:
`li a0, 5` makes the fixnum 5, `add` adds two of them, and a machine word
loaded from memory is a fixnum. Arithmetic that leaves 32 bits promotes to a
bignum through the overflow trap, as before. `peek` and `poke` no longer
need a signed and an unsigned family: a word is a fixnum.

**nil** is a tagged capability to the 16-byte cell at address 0, with LD, LC
and nothing else, whose car and cdr hold nil. `(car nil)` is nil because the
cell says so; `(set-car! nil 1)` is refused because the capability says so.
`tp` holds nil for the life of the machine.

**Identity.** `eq?` is exact equality: tag, metadata and address. Two
capabilities to the same object with different permissions are not `eq?`;
nothing in the system makes such a pair by accident. A fixnum and a
character with the same payload differ in metadata.

**Objects.** An object occupies a header granule and its payload:

```
header word 0   (len << 8) | type      len counts elements
header word 1   0, reserved
payload         len 8-byte slots (value types) or len bytes (string, bytes)
```

The capability to an object has bounds exactly its payload and HD set; the
header is outside the bounds, so a holder of the object can never write its
header. Strings and byte objects have LD and SD only: no capability can be
stored in them, and none is ever found there. Everything else holds values
in 8-byte slots, every slot tagged or not by what was stored. An object that
needs rounding for its bounds is padded; the padding is a free hole the
sweep walks like any other object.

| type | | payload |
|---|---|---|
| 0 free | a hole | len = size in granules including the header; slot 0 the next hole's address |
| 1 symbol | | name value function plist flags package |
| 2 string | | bytes |
| 3 vector | | values |
| 4 bytes | | bytes |
| 5 closure | | 0 entry (EX capability), 1 code object, 2.. free variables |
| 6 record | | 0 the type symbol, then fields |
| 7 float | | reserved |
| 8 port | | values |
| 9 bignum | | 0 the sign, then 32-bit limbs as fixnums, least significant first |
| 10 code | | 0 entry (EX capability whose bounds are the machine code), 1 name, 2.. literals |

**A closure is sealed.** The compiler seals every closure it makes with
`csealclo`; calling one is `jcl`, which unseals it into the callee's `t0`
and jumps to its slot 0. So a closure's free variables can be read only by
the closure's own code. The explorer and the printer look inside through
the escape hatch.

**Code** lives in code space. A code object's entry capability has EX, and
SR when the source said `unsafe` (see below); its bounds are the machine
code, so the code's length is the capability's length. Compiled code holds
no heap addresses: a function reaches its symbols and constants through its
code object in `s1`, which is CHERI's capability table under another name.
Every return address is a sentry, so a frame's saved `ra` is a capability
that can only be returned through.

## Authority

At reset PCC, DDC and MTCC are the root: every permission, the whole address
space. The general registers are NULL. The kickstart keeps the root in DDC.

**Integer addressing is a privilege.** A load or store whose base register
is `x0`, and the explicit `.ddc` loads and stores, address memory through
DDC with the integer as the address. Both need SR in PCC. This is CHERI's
hybrid mode kept for the code that must name memory by number, the
collector, the kernel and the chips; everything else holds only
capabilities. `(%root)` reads DDC.

**SR is `unsafe`.** The compiler gives a code object SR when its source was
compiled in an `(unsafe-file)` or contains an `(unsafe ...)` form, and no
other. Writing a CSR, reading a machine-level CSR (0x300 to 0x3ff, 0x7c0 and
up), accessing an SCR, and integer addressing all fault without it. The
counters (0xc00 to 0xc9f) are readable by anyone; `mret` and `wfi` need SR,
`ecall` does not. So `unsafe` is enforced
twice: the compiler refuses a raw name outside it, and the processor refuses
the act to code that did not say it.

**The escape hatch is the root.** Everything a program can reach it reaches
through a capability someone handed it, and every capability is bounded,
except the root. `%root` and the operations that work through DDC are the
raw vocabulary. Bounded operations on a capability you hold, loading a word
from a byte object, narrowing bounds, dropping permissions, sealing your
own closure, are safe, because they cannot reach past what you were given.

## The processor

`rv32imc_zba_zbb_zbs_zicond_xcheri_xlm`, machine mode, always in capability
mode (purecap encodings).

### Registers

32 capability registers. `c0` reads as NULL. Special capability registers,
reached with `CSpecialRW` and needing SR: 0 PCC (read only), 1 DDC, 28 MTCC,
29 MTDC, 30 MScratchC, 31 MEPCC. `mtvec` and `mepc` are the addresses of
MTCC and MEPCC. A trap sets MEPCC to PCC with the faulting address and PCC
to MTCC; `mret` sets PCC to MEPCC.

Fetch needs PCC tagged, unsealed, with EX, and the instruction inside its
bounds. A jump that leaves PCC's bounds faults at the jump.

### Base instructions in capability mode

- Loads and stores take `cs1` as their authority, checked for tag, seal,
  permission and bounds. `lc` (load capability) takes the encoding of RV64
  `ld` (opcode 0x03, funct3 3), `sc` that of `sd` (0x23, funct3 3). Both need
  8-byte alignment. `lc` through an authority without LC clears the loaded
  tag; through one without LM it clears SD, SC and LM as above.
- Compressed: `c.lc` and `c.sc` take the `c.flw`/`c.fsw` slots (quadrant 0,
  funct3 3 and 7), `c.lcsp`/`c.scsp` the `c.flwsp`/`c.fswsp` slots
  (quadrant 2, funct3 3 and 7). Their offsets are encoded as RV64C's `c.ld`,
  `c.sd`, `c.ldsp`, `c.sdsp`: multiples of 8.
- `c.addi16sp` and `c.addi4spn` are `cincoffset` on `csp`. `c.mv` is
  `cmove`. `addi` and every other integer instruction are integer: the
  result is untagged.
- `jal`, `jalr`, `c.j`, `c.jal`, `c.jr`, `c.jalr`: the target is formed from
  PCC (jal) or `cs1` (jalr), which may be a sentry and is then unsealed; the
  link is a sentry for the next instruction.
- `auipc` is `auipcc`: PCC with its address moved.

### CHERI instructions, opcode 0x5b

```
funct3 0, R-type, funct7:
  0x01  cspecialrw  cd, scr, cs1      scr in the rs2 field; cs1 = c0 reads only
  0x08  csetbounds  cd, cs1, rs2      rounds outward
  0x09  csetboundsexact cd, cs1, rs2
  0x0b  cseal       cd, cs1, cs2
  0x0c  cunseal     cd, cs1, cs2
  0x0d  candperm    cd, cs1, rs2      rs2 is the mask, in the permission positions 8..0
  0x10  csetaddr    cd, cs1, rs2
  0x11  cincoffset  cd, cs1, rs2
  0x14  csub        rd, cs1, cs2      address difference
  0x16  csethigh    cd, cs1, rs2      untagged result, metadata = rs2
  0x1d  cbuildcap   cd, cs1, cs2      cs2's bits re-tagged under the authority cs1
  0x20  ctestsubset rd, cs1, cs2
  0x21  cseqx       rd, cs1, cs2      exact equality
  0x7c  stores via DDC, rd field selects: 0 sb.ddc 1 sh.ddc 2 sw.ddc 3 sc.ddc
                                      (rs1 integer address, rs2 the value)
  0x7d  loads via DDC, rs2 field selects: 0 lb.ddc 1 lh.ddc 2 lw.ddc 3 lc.ddc
                                      4 lbu.ddc 5 lhu.ddc (rs1 integer address)
  0x7f  one operand, rs2 field selects:
        0x00 cgetperm  0x01 cgettype  0x02 cgetbase  0x03 cgetlen
        0x04 cgettag   0x05 cgetsealed 0x06 cgetoffset 0x08 crrl
        0x09 cram      0x0a cmove     0x0b ccleartag  0x0c cjalr (cd link, cs1)
        0x0f cgetaddr  0x11 csealentry 0x17 cgethigh  0x18 cgettop
        0x1c csealclo  (Xlm: seal a headed closure object as a closure)
funct3 1  cincoffsetimm cd, cs1, imm12   (signed)
funct3 2  csetboundsimm cd, cs1, uimm12
```

`cgetperm` returns the nine permission bits in bits 8..0 (LD is bit 8, HD
bit 0); `candperm` takes the same positions. `cgetlen` of a whole-space
capability saturates at 0xffffffff. `cgettop` likewise.

### Xlm: the Lisp instructions

Each checks its operands as it uses them, so the check costs no extra
instructions. A wrong kind of operand is cause 24 with `mtval` the number of
the register that held it; the handler reads the value from the trap frame.

**custom-0, opcode 0x0b: references.**

```
f3 0  lref  rd, imm(rs1)    rs1 a pair (tagged, unsealed, no HD) with LC;
                            nil qualifies. rd <- the capability at rs1+imm.
f3 1  vkind rd, rs1         rd <- the kind of rs1 (below). imm must be 0.
f3 2  lvar  rd, imm(rs1)    rs1 a symbol; rd <- the slot at rs1+imm, and if
                            that is the unbound marker, cause 24 with mtval
                            the number of rs1: an unbound variable.
f3 3  jcl   rd, rs1         rs1 a closure (tagged, otype 2). rs1 <- it
                            unsealed; rd <- a sentry for pc+4; pc <- its
                            slot 0, which must be tagged with EX.
f3 4  sref  rs2, imm(rs1)   rs1 a pair with SC; nil is refused with cause 24.
f3 5  lhdr  rd, rs1, type   rs1 an object (HD) of header type `type` (imm;
                            0 any); rd <- its length.
f3 6  beqx  rs1, rs2, off   B-type: branch if rs1 and rs2 are identical
f3 7  bnex  rs1, rs2, off   B-type: branch if not
```

`car` and `cdr` are offsets 0 and 8 of `lref`. A null test is `beqx rs, tp`.

Kinds, as `vkind` returns them:

```
0..15    an untagged value: its metadata (0 fixnum, 1 character, ...); 15 if
         the metadata is 15 or more
16       nil
17       a pair
32 + t   an object of header type t, sealed as a closure or not
31       any other capability
```

**custom-1, opcode 0x2b: indexed access.** As before: funct7 the type the
object must be (0 for any), funct3 bit 0 store, bit 1 byte, bit 2 the index
is the five-bit immediate in the rs2 field; rs1 the object (HD, unsealed),
rs2 the index, a fixnum; rd the result or the value stored. The value forms
move 8-byte capabilities and refuse a string or byte object; the byte forms
move a byte, zero-extended, and refuse anything but a string or byte
object. The index must be below the header's length: cause 25 with `mtval`
the number of the index register, or 32 for an immediate index.

**custom-3, opcode 0x7b: fixnums.** Every operand must be a fixnum
(untagged, metadata 0); the result is one.

```
f3 0  faddi  rd, rs1, imm     wrapping
f3 1  faddio rd, rs1, imm     cause 26 on overflow
f3 2  fandi  rd, rs1, imm
f3 3  fori   rd, rs1, imm
f3 4  fshi   rd, rs1, imm     imm[4:0] amount, imm[6:5] 0 sll, 1 srl, 2 sra
f3 5  fop    rd, rs1, rs2     R-type, funct7:
        0x00 add 0x01 sub 0x02 mul 0x03 div 0x04 rem 0x05 and 0x06 or 0x07 xor
        0x08 addo 0x09 subo 0x0a mulo          cause 26 on overflow
        0x10 sll 0x11 srl 0x12 sra             amount taken mod 32
        0x13 lt 0x14 ltu 0x15 eq               leave the fixnum 0 or 1
f3 7  retag  rd, rs1, imm     rs1 untagged, of kind imm[11:6] (63 for any);
                              rd <- its address with metadata imm[5:0]
```

Every immediate here is the I-type's twelve bits sign-extended, except
`retag`'s, which is read unsigned.

Division by zero is cause 27; `div` of -2^31 by -1 is cause 26. The handler
widens an overflow into a bignum and resumes after the instruction, as
before. `char->integer` is `retag rd, rs, (1<<6)|0`; `integer->char` is
`retag rd, rs, (0<<6)|1`.

### Traps

```
24  wrong type           mtval: the register holding the offending value
25  index out of range   mtval: the register holding the index, or 32
26  fixnum overflow      the handler decodes the instruction
27  division by zero
28  capability fault     mtval = (register << 5) | code; register 32 is PCC,
                         33 is DDC. Codes as ISAv9: 0x01 length, 0x02 tag,
                         0x03 seal, 0x04 type, 0x0a representability,
                         0x11 execute, 0x12 load, 0x13 store, 0x14 load
                         capability, 0x15 store capability, 0x18 system
                         registers, 0x19 unseal
29  write barrier        mtval: the address of the granule being overwritten
30  stack overflow       sp went below the stack-limit CSR (0x7c0)
```

The stack limit CSR stays: it is checked when `sp` is written, with
interrupts on, as before. `sp` is also a capability bounded to its task's
whole stack, so nothing below the stack can be written whatever the limit
says.

**The write barrier** (`gcmode`, CSR 0x7c1, bit 0): while it is on, any store
of any width that would overwrite a tagged granule in cons or object space
whose capability points at an unmarked heap object traps with cause 29,
before writing. The object of a pair capability is its base; the object of
a headed capability is the header at base-8. Its mark bit is the bit of
that granule in the bitmap at `GC_BITMAP`, one bit per 8 bytes from
`CONS_BASE`. The handler marks it and the store re-executes. Every store
goes through this, raw or checked, so nothing can overwrite the last copy of
a pointer unseen.

## Memory

```
0x0000_0000  the nil cell, 16 bytes
0x0000_0100  low-memory globals, one 8-byte slot each
0x0000_1000  trap vectors and the exception stub
0x0000_2000  the pool: stacks, contexts, descriptors
0x0100_0000  code space, 16 MiB
0x0200_0000  cons space, 128 MiB, eight million pairs
0x0A00_0000  object space, 64 MiB
0x0E00_0000  the mark bitmap, scratch
0xF000_0000  device pages, 4 KiB each, 32-bit registers
```

A low global that held an address holds it as a fixnum; authority to what
it names comes from DDC. One that held a value holds the value. Their
offsets come from `src/map.rs` through the generated layout, as before.

Tags exist for RAM only. A device page holds no capabilities. DMA (the
blitter's descriptors, the disk's requests) addresses memory by number,
which only privileged code can write into a descriptor.

## Registers and calling

```
ra   the return sentry          a0..a7  arguments, a0 the result
sp   the stack, a capability    t0      the closure being entered (unsealed)
gp   the cons run               t1      the argument count, an integer
tp   nil                        s0      the frame
s1   the running code object    s2      the running task
s3..s10 a leaf's locals         s11     a leaf's caller's code object
```

**The cons run is a capability.** `gp` is bounded to the running task's
current run of cons space, and its address is the next free pair. A pair is

```
csetboundsimm a0, gp, 16      ; faults (length, register gp) when the run is used up
cincoffsetimm gp, gp, 16
sc car, 0(a0)
sc cdr, 8(a0)
```

and the bounds check is the limit check. The fault is the refill: the trap
handler sees a length fault on `gp` at a `csetboundsimm`, takes a fresh run
for the task without allocating, writes it into the saved `gp` and the live
one, and returns to the instruction. A collection begun there sees every
register in the trap frame exactly, because registers say what they hold.

**Frames.** Every slot is 8 bytes and says what it holds:

```
s0 + 8k       argument 8 + k
s0 - 8        saved ra         a sentry
s0 - 16       saved s0         a stack capability; NULL at the bottom
s0 - 24       the closure
s0 - 32       saved s1
s0 - 40 - 8i  local slot i
```

Leaves are unchanged: no frame, locals in `s3..s10`, the caller's code
object in `s11`.

**Contexts.** A task's register save area is 32 capability slots, 256
bytes: slot 0 the pc (MEPCC), slots 1..31 `x1..x31`. MScratchC names the
one the trap stub saves into. Switching tasks is still pointing MScratchC at
another block.

## The collector

Precise everywhere. A granule is a pointer if and only if its tag is set, so:

- Stacks are scanned granule by granule from `sp` to the top; the frame
  chain is for backtraces only.
- Saved registers are scanned the same way; nothing is conservative and
  nothing is pinned.
- The allocator's slow path needs no mask of live registers.
- Marking an object is marking each tagged granule of its payload; the
  object's type matters only to skip the byte types, which hold none.

A tagged capability is a heap reference if its base lies in cons space,
it has no HD, and its length is 16 (a pair), or it has HD and its header
lies in object space (an object). Anything else, a run, a code entry, a
stack, a device, is not the collector's.

The pair compactor, on the way into an image, rewrites every tagged pair
capability it finds; every tag in RAM is a pointer it may need to rewrite,
and the tags say exactly where they are.

## The Lisp vocabulary

The checked vocabulary is unchanged in meaning. The raw vocabulary:

| name | | |
|---|---|---|
| `(%root)` | the root (DDC) | unsafe |
| `(%from-addr n)` | the root with its address set to n | unsafe |
| `(%ld-word a)` `(%ld-half a)` `(%ld-byte a)` `(%ld-cap a)` | integer address, through DDC | unsafe |
| `(%st-word! a v)` `(%st-half! a v)` `(%st-byte! a v)` `(%st-cap! a v)` | likewise | unsafe |
| `(%cap-ld c off)` `(%cap-st! c off v)` | a capability at byte offset off within c | safe |
| `(%cap-ld-word c off)` `(%cap-st-word! c off v)` `(%cap-ld-byte c off)` `(%cap-st-byte! c off v)` | data within c | safe |
| `(%addr-of x)` | `cgetaddr`; an immediate's payload | safe |
| `%cap-base` `%cap-len` `%cap-top` `%cap-perms` `%cap-otype` `%cap-offset` `%cap-tag?` `%cap-sealed?` `%cap-high` | reading a capability | safe |
| `%cap-set-addr` `%cap-inc` `%cap-bounds` `%cap-bounds-exact` `%cap-and-perms` `%cap-clear-tag` `%cap-seal-entry` | narrowing one | safe |
| `(%cap-seal c key)` `(%cap-unseal c key)` | with an SE authority | safe |
| `(%cap-set-high c n)` `(%cap=? a b)` `(%cap-subset? a b)` `(%rrl n)` `(%ram n)` | | safe |
| `%slot` `%set-slot!` | any-type indexed access | unsafe |
| the machine-state operations | as before | unsafe |

`%ld-fixnum` and `%st-fixnum!` are gone: a word is a fixnum, so they are
`%ld-word` and `%st-word!`.
