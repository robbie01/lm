# The machine is RV32 with CHERI

The reference for the capability format, the values built from it, and the
instructions that use them: the contract between the processor, the forge,
the compiler, the collector and the kernel. Where it says *is*, every part of
the system agrees, and `src/cap.rs`, `src/cpu.rs` and `src/mach.rs` are the
code it describes. The README says what the machine does with all this;
this note says exactly how.

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

Metadata:

```
31  LD   load data                 27  LM   load mutable (see below)
30  SD   store data                26  EX   execute
29  LC   load capabilities         25  SR   system registers: CSRs, SCRs, DDC
28  SC   store capabilities        24  SE   seal and unseal (authority over otypes)
                                   23  HD   headed: a Lisp object with a header
22..19  otype   0 unsealed, 1 sentry, 2 closure, 3 a task's stack or context,
                4 a blitter ring or descriptor; 5..15 unused
18      IE      internal exponent
17..10  T[7:0]  top mantissa
9..0    B[9:0]  base mantissa
```

`cgetperm` returns the nine permissions in bits 8..0, LD in bit 8 and HD in
bit 0, and `candperm` takes a mask in the same positions; in the metadata
they sit 23 bits higher. The layout names them `perm-ld` to `perm-hd`.

**Bounds** are CHERI Concentrate with mantissa width MW = 10 for a 32-bit
address. With IE clear the exponent is 0 and B and T are the low bits of
the base and the top, so every length below 256 is exact at any base. With
IE set the exponent E is `{T[2:0], B[2:0]}`, those six bits read as zero in
the mantissas, and base and top are multiples of 2^(E+3). T[9:8] are not
stored: they are B's, plus a carry when T's low bits are below B's, plus
one with IE. E is at most 24, for which T = 0x100 is a top of 2^32. The
representable region, the corrections, and the instructions that round
(`crrl`, `cram`) are as ISAv9 defines them for this MW. The allocators ask
`crrl` and `cram` what a length rounds to, and pad and align objects,
machine code, stacks and contexts among them, and cons runs to bounds that
are exact.

The root is every permission over `[0, 2^32)`. `cgetlen` and `cgettop` of
it saturate at 0xffffffff.

**HD** is a software-defined permission. It says the capability's base is
the payload of a Lisp object whose header is the granule just below the
base. Only the root mints it: `csetbounds` keeps HD when the base stays
where it was or the authority is the whole address space, and drops it
otherwise, and `cbuildcap` refuses HD by the same rule, so narrowing an
object to one of its slots can never pass the slot below off as a header. Clearing it, like clearing any
permission, only takes authority away: a headed object with HD cleared
looks like an unheaded block, which is safe. A pair can never acquire it, so
the processor never reads a header that is not there. The root has HD
because it has every permission; it is not an object, because there is no
header below address 0 in object space.

**LM**: a tagged, unsealed capability loaded through an authority that lacks
LM has SD, SC and LM cleared. Immutability is deep: a read-only list hands
out read-only tails. nil has none of the three, so loading nil through
anything leaves it nil.

**Sealing.** A sealed capability cannot be dereferenced or modified; moving
its address or changing its permissions clears its tag. otype 1, the
sentry, is unsealed by jumping to it, at its own address only. otype 2, the
closure, is unsealed by calling it (`jcl`, below). Neither needs an
authority to make: anyone may seal their own code (`csealentry`) or closure
object (`csealclo`), and nobody may open one except by entering it, or with
an authority. `cseal` and `cunseal` with an explicit authority, for any
otype from 1 to 15, need a capability with SE whose address, inside its
bounds, is the otype; the root is one, which is how the escape hatch opens a
closure. Exec seals a task's stack and context in its record with otype 3,
and only Exec unseals them; hw seals a blitter ring, and a descriptor
anywhere another task could read it, with otype 4, and only hw unseals
them.

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
tagged, the nil cell      nil
tagged, unsealed, no HD   a pair: 16 bytes at its base, car at 0, cdr at 8
tagged, HD                an object: header at base-8, payload from base
tagged, HD, otype 2       a closure
tagged, otherwise         a raw capability: an entry or a return address, a stack
                          or frame pointer, a device, a cons run
```

The layout names the untagged kinds `imm-fixnum` to `imm-default`.

**nil** is a tagged capability to the 16-byte cell at address 0, with LD and
LC and nothing else (`perms-nil`), whose car and cdr hold nil. `tp` holds it
for the life of the machine.

**Identity.** `eq?` is exact equality: tag, metadata and address. Two
capabilities to the same object with different permissions are not `eq?`;
nothing in the system makes such a pair by accident.

**Constants are read-only.** The compiler takes SD and SC off a quoted
constant and off every pair, vector, string, byte object and bignum inside
it, rewriting it in place, so every literal naming an object is the same
capability and `eq?` to every other; LM stays, so a symbol loaded out of a
constant is the symbol itself. A capability to the object taken before it
was compiled, which only a macro splicing a live object into a quote can
hold, keeps its permissions and is not `eq?` to the literal.

**Objects.** An object occupies a header granule and its payload:

```
header word 0   (len << 8) | type      len counts elements
header word 1   0
payload         len 8-byte slots (value types) or len bytes (string, bytes)
```

The capability to an object has bounds exactly its payload and HD set; the
header is outside the bounds, so a holder of the object can never write its
header. A payload whose length cannot be exact is rounded up to one that
can, and its base aligned to match; the space the alignment skips is a free
hole the sweep walks like any other.

| type | permissions | payload |
|---|---|---|
| 0 free | | len = size in granules including the header; slot 0 the next hole's address |
| 1 symbol | `perms-object` | name value function plist flags package |
| 2 string | `perms-bytes` | bytes |
| 3 vector | `perms-object` | values |
| 4 bytes | `perms-bytes` | bytes |
| 5 closure | `perms-object`, sealed | 0 entry (EX capability), 1 code object, 2.. free variables |
| 6 record | `perms-object` | 0 the type symbol, then fields |
| 7 float | `perms-object` | the bits, as a fixnum |
| 8 port | `perms-object` | values |
| 9 bignum | `perms-object` | 0 the sign, then 32-bit limbs as fixnums, least significant first |
| 10 code | `perms-object` | 0 entry, 1 name, 2.. literals |
| 11 text | `perms-bytes` | a function's machine code |
| 12 stack | `perms-object` | a task's stack, in value slots |
| 13 context | `perms-object` | a task's 32 saved registers, or a trap frame's 32 and a link |

`perms-pair` is LD SD LC SC LM; `perms-object` is that and HD; `perms-bytes`
is LD SD HD, so no capability can be stored in a string, a byte object or a
text, and none is ever found there. A value slot starts as nil, and a
stack's or a context's as zero. A stack pointer is a stack's capability
with `perms-pair`, standing at its top.

**Code** is an object. A function's machine code is a text, its length in
bytes in the header, allocated and aligned as any byte object is. A code
object's entry capability is derived from the root at the text's payload:
EX, and SR when the source said `unsafe`, and nothing else, with bounds
exactly the code, so the code's length is the capability's length. The
text's own headed capability goes no further than the assembler that fills
it. Every return address is a sentry, so a frame's saved `ra` can only be
returned through.

An entry or a return address is a capability based in object space, so it
keeps the text it lies in alive by the same rule as any other (see the
write barrier below); nothing in a text says which code object it belongs
to, and nothing needs to. A pc names its function by a walk of object space
for the code object whose entry starts the same text, which only a
backtrace and the debugging tools ask. A jump within a function is relative
to its pc, and anything else reaches code through a capability, so a text
can be anywhere and the forge slides it with the rest of object space.

The one piece of code that is not an object is the reset stub, in the
`reset-reserve` bytes at `reset-vector` in the low block. The trap stub is a
text, and its entry is kept in `lg-trap-entry`.

**Stacks and contexts** are objects. The collector marks one as it marks
any object, by what holds it, a task's record, a frame pointer into it or a
low global, and never traces it: what is live in a stack runs from its
stack pointer to its top, which the roots scan, as they scan every context
in use. The write barrier lets a store through one's own capability.

## Authority

At reset PCC, DDC and MTCC are the root and the general registers are NULL.
The reset stub derives nil and the empty cons run from DDC, loads `sp`,
MScratchC and MTCC from `lg-boot-stack`, `lg-trapsave` and
`lg-trap-entry`, and leaves the root in DDC.

**Integer addressing is a privilege.** A load or store whose base register
is `x0`, and the explicit DDC loads and stores, address memory through DDC
with the integer as the address. Both need SR in PCC, and the permission
for the access in DDC. This is CHERI's hybrid mode kept for the code that
must name memory by number, the collector, the kernel and the image writer;
everything else holds only capabilities. `(%root)` reads DDC.

**SR is `unsafe`.** The compiler gives a code object SR when its source was
compiled in an `(unsafe-file)` or contains an `(unsafe ...)` form, and no
other. Without SR in PCC these fault with code 0x18 on PCC: writing any
CSR; reading a machine-level CSR (0x300 to 0x3ff, and 0x7c0 and up but for
the counters 0xc00 to 0xc9f); `cspecialrw`, even to read; `mret`; `wfi`;
and integer addressing. `ecall` and `ebreak` need nothing. So `unsafe` is
enforced twice: the compiler refuses a raw name outside it, and the
processor refuses the act to code that did not say it.

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
reached with `cspecialrw`: 0 PCC (read only), 1 DDC, 28 MTCC, 29 MTDC, 30
MScratchC, 31 MEPCC; the layout names them `scr-*`. The CSRs `mtvec`,
`mscratch` and `mepc` read and write the addresses of MTCC, MScratchC and
MEPCC. A trap sets MEPCC to PCC with the faulting address and PCC to MTCC;
`mret` sets PCC to MEPCC.

Fetch needs PCC tagged, unsealed, with EX, and the instruction inside its
bounds. A jump or branch whose target leaves PCC's bounds faults at the
jump, code 0x01 on PCC.

### Base instructions in capability mode

- Loads and stores take `cs1` as their authority, checked for tag, seal,
  permission and bounds; with `x0` as the base they go through DDC. `lc`
  (load capability) takes the encoding of RV64 `ld` (opcode 0x03, funct3 3),
  `sc` that of `sd` (0x23, funct3 3). Both need 8-byte alignment. `lc`
  through an authority without LC clears the loaded tag; through one
  without LM it clears SD, SC and LM as above.
- Compressed: `c.lc` and `c.sc` take the `c.flw`/`c.fsw` slots (quadrant 0,
  funct3 3 and 7), `c.lcsp`/`c.scsp` the `c.flwsp`/`c.fswsp` slots
  (quadrant 2, funct3 3 and 7). Their offsets are encoded as RV64C's `c.ld`,
  `c.sd`, `c.ldsp`, `c.sdsp`: multiples of 8.
- `c.addi16sp` and `c.addi4spn` are `cincoffset` on `csp`. `c.mv` is
  `cmove`. `addi`, `c.add` and every other integer instruction are integer:
  the result is untagged.
- `jal`, `jalr`, `c.j`, `c.jal`, `c.jr`, `c.jalr`, `cjalr`: the target is
  formed from PCC (`jal`) or `cs1` (`jalr`), which must be tagged with EX,
  and may be a sentry, which is then unsealed and may only be entered at its
  own address; the link is a sentry for the next instruction.
- `auipc` is `auipcc`: PCC with its address moved.

### CHERI instructions, custom-2, opcode 0x5b

```
funct3 0, R-type, funct7:
  0x01  cspecialrw  cd, scr, cs1      scr in the rs2 field; cs1 = c0 only reads
  0x08  csetbounds  cd, cs1, rs2      rounds outward
  0x09  csetboundsexact cd, cs1, rs2  0x0a if it would round
  0x0b  cseal       cd, cs1, cs2      cs2 an SE authority whose address is the otype
  0x0c  cunseal     cd, cs1, cs2      likewise, and the otype must match
  0x0d  candperm    cd, cs1, rs2      rs2 the mask, in the permission positions 8..0
  0x10  csetaddr    cd, cs1, rs2
  0x11  cincoffset  cd, cs1, rs2
  0x14  csub        rd, cs1, cs2      address difference
  0x16  csethigh    cd, cs1, rs2      untagged result, metadata = rs2
  0x1d  cbuildcap   cd, cs1, cs2      cs2's bits re-tagged under the authority cs1
  0x20  ctestsubset rd, cs1, cs2      1 if cs2's bounds and permissions lie in cs1's
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

`csetbounds` and its forms need `cs1` tagged and unsealed and the region
inside its bounds, else code 0x02, 0x03 or 0x01 on `cs1`. `csealentry` needs
EX (0x11). `csealclo` needs a headed capability whose header type is
closure (0x04). `cseal` without SE in the authority is 0x17 and `cunseal`
0x1b; an otype outside 1..15, or one that does not match, is 0x04 on the
authority. `cbuildcap` refuses bounds outside its authority (0x01),
permissions its authority lacks, or HD at a base other than its authority's
when the authority is not the whole address space (0x08), and an otype past
the sentry (0x04 on `cs2`); it keeps a sentry sealed. `crrl` and `cram` read their length
from the address of `cs1`.

### Xlm: the Lisp instructions

An Xlm instruction is one CHERI operation and one Lisp type check, done
together. CHERI knows where a capability points and what it may do there;
it does not know a pair from a vector, a fixnum from a character, or a
bound variable from an unbound one. Those are the checks Xlm adds, and
nothing else: memory safety is never an Xlm instruction's job. An
instruction whose check CHERI already makes, or that the compiler can prove
by construction (a closure's own environment after `jcl`), is not one.

Each checks its operands as it uses them, so the check costs no extra
instructions. A wrong kind of operand is cause 24 with `mtval` the number of
the register that held it; the handler reads the value from the trap frame.
A right kind with a missing permission or an address outside its bounds is
a capability fault, cause 28.

**custom-0, opcode 0x0b: references.**

```
f3 0  lref  rd, imm(rs1)    rs1 a pair (tagged, unsealed, no HD) with LD and
                            LC; nil qualifies. rd <- the capability at rs1+imm.
f3 1  vkind rd, rs1         rd <- the kind of rs1 (below). imm must be 0.
f3 2  lvar  rd, imm(rs1)    rs1 a symbol, unsealed; rd <- the slot at rs1+imm,
                            and if that is the unbound marker, cause 24 with
                            mtval the number of rs1: an unbound variable.
f3 3  jcl   rd, rs1         rs1 a closure (tagged, otype 2). rs1 <- it
                            unsealed; rd <- a sentry for pc+4; pc <- its
                            slot 0, which must be tagged with EX.
f3 4  sref  rs2, imm(rs1)   rs1 a pair with SD and SC; nil is refused with
                            cause 24.
f3 5  lhdr  rd, rs1, type   rs1 an object (HD, unsealed or a closure) of
                            header type `type` (imm; 0 any); rd <- its length.
f3 6  beqx  rs1, rs2, off   B-type: branch if rs1 and rs2 are identical
f3 7  bnex  rs1, rs2, off   B-type: branch if not
```

`car` and `cdr` are offsets 0 and 8 of `lref`. A null test is `beqx rs, tp`.
`jcl` faults 0x02 or 0x11 on rs1 when slot 0 is untagged or not executable,
and 0x01 when the entry is outside its own bounds.

Kinds, as `vkind` returns them, named `kind-*` in the layout:

```
0..15    an untagged value: its metadata (0 fixnum, 1 character, ...); 15 if
         the metadata is 15 or more
16       nil
17       a pair: tagged, unsealed, no HD, sixteen bytes long
32 + t   an object of header type t, unsealed or sealed as a closure, with
         its header in object space
31       any other capability
```

**custom-1, opcode 0x2b: indexed access.** funct7 the type the object must
be (0 for any), funct3 bit 0 store, bit 1 byte, bit 2 the index is the
five-bit immediate in the rs2 field; rs1 the object (tagged, HD, unsealed,
its header in RAM), rs2 the index, a fixnum; rd the result or the value
stored. The value forms move 8-byte capabilities and refuse a string or
byte object; the byte forms move a byte, zero-extended, and refuse anything
but a string or byte object; a wrong object is cause 24 on rs1 and an index
that is not a fixnum cause 24 on rs2. The index must be below the header's
length: cause 25 with `mtval` the number of the index register, or 32 for
an immediate index. The address is checked against the capability's bounds
as well (0x01), a load needs LD, and a store SD, and SC too when the value
is tagged (0x13, 0x15).

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
widens an overflow into a bignum and resumes after the instruction.
`char->integer` is `retag rd, rs, (1<<6)|0`; `integer->char` is
`retag rd, rs, (0<<6)|1`.

### Traps

```
24  wrong type           mtval: the register holding the offending value
25  index out of range   mtval: the register holding the index, or 32
26  fixnum overflow      mtval 0; the handler decodes the instruction
27  division by zero     mtval 0
28  capability fault     mtval = (register << 5) | code; register 32 is PCC,
                         33 is DDC. Codes as ISAv9: 0x01 length, 0x02 tag,
                         0x03 seal, 0x04 type, 0x08 permit (cbuildcap),
                         0x0a representability, 0x11 execute, 0x12 load,
                         0x13 store, 0x14 load capability, 0x15 store
                         capability, 0x17 seal permission, 0x18 system
                         registers, 0x1b unseal
29  write barrier        mtval: the address of the granule being overwritten
30  stack overflow       mtval: where sp would have gone; sp is left as it was
```

The layout names the causes `cause-*` and the codes `capex-*`.

**The stack limit** (CSR 0x7c0) is checked when a `cincoffset` of `sp`
moves it down, with interrupts on; zero means no limit. `sp` is also a
capability bounded to its task's whole stack, so nothing below the stack
can be written whatever the limit says; past it the fault is a length fault
on `sp`, which the handler also reports as a stack overflow.

**The write barrier** (`gcmode`, CSR 0x7c1, bit 0): while it is on, any
store of any width, through a capability or through DDC, that would
overwrite a tagged granule in cons or object space whose capability points
at an unmarked heap object traps with cause 29, before writing, unless the
store is into a stack or a context: its authority is based at the payload
of an object whose header, at an object start, says stack or context, and
the granule lies in that payload. Every stack pointer, frame pointer and
context capability is so based, and a store through DDC never is. A tagged
capability keeps alive the block its base lies in, whatever its length: one
without HD based in cons space, the pair at its base rounded down to 16; one
based in object space, headed or not, the object whose header is the
nearest set bit of the object-start map (`OBJ_STARTS`, one bit per 8 bytes
of object space, set at every allocated block's header) at or below the
granule before its base. So a capability narrowed to a cdr or to a slot
keeps its pair or its vector. Its mark bit is the bit of that granule in the
bitmap at `GC_BITMAP`, one bit per 8 bytes from `CONS_BASE`. The handler marks it and
the store re-executes. Nothing can overwrite the last copy of a pointer
unseen.

## Memory

```
0x0000_0000  the nil cell, 16 bytes
0x0000_0100  low-memory globals, one 8-byte slot each
0x0000_0400  the free bins of object space, one 8-byte slot each
0x0000_0800  the reset stub, `reset-reserve` bytes at `reset-vector`
0x0100_0000  cons space, 128 MiB, eight million pairs
0x0900_0000  object space, 64 MiB, machine code, stacks and contexts among the objects
0x0D00_0000  the mark bitmap, the object-start map, the mark stack, scratch
0xF000_0000  device pages, 4 KiB each, 32-bit registers and two capability registers
```

The low page ends at `low-end`, 4 KiB; nothing lies between it and cons
space.

A low global that held an address holds it as a fixnum; authority to what
it names comes from DDC. One that holds a value holds the value, and starts
as nil. Their offsets come from `src/map.rs` through the generated layout.
Every slot below 0x800 is one load or store off `x0`.

Tags exist for RAM only. A device page hands out no capabilities: `lc` from
one is a load fault. Two registers take one: the blitter's list register
and the disk's buffer register, each 8 bytes at the start of its page. An
`sc` to either writes the capability, tag and all, into the chip; an `sc`
to any other register is a store fault, and a word store to one of the two
writes a number, which the chip refuses. DMA goes through capabilities: a
blitter descriptor's source, destination and link are capability slots,
which the chip loads as `lc` would through the descriptor's capability, and
each chip refuses a transfer its capability does not allow, as the
processor would refuse the access (see drivers.md).

## Contexts and the cons run

**Contexts.** A task's register save area is a context object of 32
capability slots, 256 bytes: slot 0 the pc (MEPCC), slots 1..31 `x1..x31`.
MScratchC names the one the trap stub saves into, and switching tasks is
pointing MScratchC at another task's. A trap inside the handler saves into
a frame of its own, the one for its depth in the vector of eight at
`lg-trap-nest`, each a context with a slot after the registers for a link
to the frame it interrupted. The handler runs on the trap stack at
`lg-trap-stack`.

**The cons run** is `gp`: a capability with `perms-pair` bounded to the
running task's current run of cons space, its address the next free pair.
A pair is

```
csetboundsimm a0, gp, 16      ; faults (length, register gp) when the run is used up
cincoffsetimm gp, gp, 16
sc car, 0(a0)
sc cdr, 8(a0)
```

The fault is the refill. The trap handler takes cause 28 with `mtval`
`(3 << 5) | 0x01` at a `csetboundsimm` whose `cs1` is `gp` as a request
for a fresh run, takes one for the task without allocating a pair, writes
it into the saved `gp` and the live one, and returns to the instruction. A
run is the front of a hole the sweep left or fresh ground, never past a
256 KiB boundary, its base rounded up and its length down to what `cram`
makes exact; a task's first is 4 KiB and each after it twice the last, up
to 256 KiB. The empty run is `perms-pair` bounded to no bytes at
`CONS_BASE`: the reset stub, every new task and every task whose run a
collection gave up start on it, and their first pair asks for a real one. It is not sixteen
bytes long, so it is never taken for a pair.

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
| `%cap-set-addr` `%cap-inc` `%cap-bounds` `%cap-bounds-exact` `%cap-and-perms` `%cap-clear-tag` `%cap-seal-entry` `%cap-seal-closure` | narrowing or sealing one | safe |
| `(%cap-seal c key)` `(%cap-unseal c key)` | with an SE authority, which only the root is | safe |
| `(%cap-set-high c n)` `(%cap=? a b)` `(%cap-subset? a b)` `(%rrl n)` `(%ram n)` | | safe |
| `%slot` `%set-slot!` `%bit-ref` `%bit-set!` | any-type indexed access, bits by number | unsafe |
| `%cons-run` `%set-cons-run!` | read and write `gp` | unsafe |
| `open-closure` | a closure unsealed with the root | unsafe |
| the machine-state operations | contexts, the stack limit, `gcmode`, interrupts, `ecall`, halt | unsafe |

`(%cap-subset? a b)` is true when `b`'s bounds and permissions lie within
`a`'s. A word loaded by number is a fixnum, so there is no `%ld-fixnum`, and
`peek` and `poke` need no signed and unsigned family.
