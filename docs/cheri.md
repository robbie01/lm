# The machine is RVY with an LM capability encoding, and Xlm

The reference for the capability format, the values built from it, and the
instructions that use them: the contract between the processor, the forge,
the compiler, the collector and the kernel. Where it says *is*, every part of
the system agrees, and `src/cap.rs`, `src/cpu.rs` and `src/mach.rs` are the
code it describes. The README says what the machine does with all this;
[rvy.md](rvy.md) says how it stands against the RISC-V CHERI specification,
and this note says exactly how it works.

The machine is RV32 with RVY, the RISC-V CHERI extension, in machine mode
and capability mode only, with a capability encoding of LM's own and Xlm,
the Lisp instructions, in custom-0.

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

Metadata, in LM's encoding:

```
31  LD   load data                 27  LM   load mutable (see below)
30  SD   store data                26  EX   execute
29  LC   load capabilities         25  SR   system registers: ASR
28  SC   store capabilities        24  SE   seal and unseal (authority over otypes)
                                   23  HD   headed: a Lisp object with a header
22..19  otype   0 unsealed, 1 sentry, 2 closure, 3 a task's stack or context,
                4 a blitter ring or descriptor; 5..15 unused
18      IE      internal exponent
17..10  T[7:0]  top mantissa
9..0    B[9:0]  base mantissa
```

The nine permissions are independent bits. The instructions read and take
them in RVY's permission bit field, which `YPERMR` reports and whose bits
`YPERMC` clears:

```
bit  0  W    SD             bit 16  ASR  SR
bit  1  LM   LM             bit 17  X    EX
bit  5  C    LC             bit 18  R    LD
bit  6  SC   SC (Xlm)       bit 24  S    SE
bit  7  HD   HD (Xlm)       bit 25  U    SE
```

Every other bit of 23..0 reads as 1, as RVY has the bits no implemented
permission occupies read. SC and HD sit in bits RVY leaves to extensions. SE
is both of Zyseal's S and U: it reads as both, and clearing either clears
it. `YPERMC` then clears whatever depends on a permission it took away, by
these rules in order: C needs R or W, LM needs C and R, ASR needs X (RVY's
base rules), and SC needs C (Xlm's). The layout names the permissions
`perm-ld` to `perm-hd`, in the bit field's positions.

**Bounds** are CHERI Concentrate with mantissa width MW = 10 for a 32-bit
address. With IE clear the exponent is 0 and B and T are the low bits of the
base and the top, so every length below 256 is exact at any base. With IE
set the exponent E is `{T[2:0], B[2:0]}`, those six bits read as zero in the
mantissas, and base and top are multiples of 2^(E+3). T[9:8] are not stored:
they are B's, plus a carry when T's low bits are below B's, plus one with
IE. E is at most 24, for which T = 0x100 is a top of 2^32; a larger exponent
is malformed, and its bounds decode as empty, base and top 0, as RVY decodes
malformed bounds. The representable region and the corrections are as
CHERI ISAv9 defines them for this MW, and `YAMASK` answers the alignment a
length needs. The allocators ask it what a length rounds to, and pad and
align objects, machine code, stacks and contexts among them, and cons runs
to bounds that are exact.

The root is every permission over `[0, 2^32)`. `YLENR` and `YTOPR` of it
saturate at 0xffffffff.

**HD** is a permission Xlm defines. It says the capability's base is the
payload of a Lisp object whose header is the granule just below the base.
Only an authority over the whole of object space mints it, object space's
own capability or the root: the bounds instructions keep HD when the base
stays where it was or the authority spans object space and the new base
lies in it, and drop it otherwise, and `YBLD` leaves bits with HD anywhere else untagged, so
narrowing an object to one of its slots can never pass the slot below off
as a header. Clearing it, like clearing any permission, only takes authority
away: a headed object with HD cleared looks like an unheaded block, which is
safe. A pair can never acquire it, so the processor never reads a header
that is not there. The root and object space's capability have HD so that
they can mint it; neither is an object, because a headed capability is an
object only when its base lies past the start of object space.

**LM**: a tagged, unsealed capability loaded through an authority that lacks
LM has SD, SC and LM cleared, as RVY's `LY` clears W and LM. Immutability is
deep: a read-only list hands out read-only tails. nil has none of the three,
so loading nil through anything leaves it nil.

**Sealing.** A sealed capability cannot be dereferenced or modified; moving
its address or changing its permissions clears its tag, and a `YPERMC` that
clears nothing it has changes nothing and keeps it. otype 1, the sentry, is
unsealed by jumping to it, at its own address only. otype 2, the closure, is
unsealed by calling it (`jcl`, below). Neither needs an authority to make:
anyone may seal their own code (`YSEALE`) or closure object (`sealcl`), and
nobody may open one except by entering it, or with an authority. Any other
otype is sealed and unsealed with a key: a capability with SE whose address,
inside its bounds, is the otype (`YSEALT` and `YUNSEALT`). A manager of
sealed things mints one key to its own otype, the reset stub's capability
to every otype narrowed to that one (`sealing-key`), and keeps it in its own
closures and nowhere else: Exec seals a task's stack and context in its record with otype 3, and
hw seals a blitter ring, and a descriptor anywhere another task could read
it, with otype 4. `YUNSEALS` unseals any sealed capability that lies inside
an unsealed authority, and with the root that is the escape hatch:
`open-closure`.

**Public and private.** A global name is public: anything compiled can name
it. A lexical binding is private: only the code inside its scope can name
it, and once that code is a sealed closure, nothing else can reach it.
Sealing is how private state lives inside a public record: a task record is
anybody's to read, and its stack and context are sealed with a key only
Exec's closures hold. The root is the escape hatch, for debugging, where the
printer and the explorer open sealed things and `peek` and `poke` name
memory by number. The system's own floor, the trap handler, the collector
and the image writer, works through the capabilities the reset stub minted
from it, each to its own region.

**Untagged capabilities are data.** Every integer instruction reads the
address field of its operands and writes an untagged result whose metadata
is 0. Loads of data (`lw`, `lb`, ...) write the same. Any store that is not
a capability store clears the tag of every granule it touches. A capability
store (`SY`) writes the tag of its source register only through an
authority with SC, and stores it as 0 otherwise.

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
| 14 kernel | `perms-object` | the kernel block, below |

`perms-pair` is LD SD LC SC LM; `perms-object` is that and HD; `perms-bytes`
is LD SD HD, so no capability can be stored in a string, a byte object or a
text, and none is ever found there. A value slot starts as nil, and a
stack's or a context's as zero. A stack pointer is a stack's capability
with `perms-pair`, standing at its top.

**Code** is an object. A function's machine code is a text, its length in
bytes in the header, allocated and aligned as any byte object is. A code
object's entry capability is derived from object space's capability at the
text's payload:
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
text, and the kernel block holds its entry.

**Stacks and contexts** are objects. The collector marks one as it marks
any object, by what holds it, a task's record, a frame pointer into it or
the kernel block, and never traces it: what is live in a stack runs from
its stack pointer to its top, which the roots scan, as they scan every
context in use. The write barrier lets a store through one's own
capability.

**The kernel block** is the kernel's own state, one object of type 14, the
first in object space, where the forge makes it and nothing moves it.
`mscratch` names it, so only code with SR reaches it. Its slots, named
`kb-*` in the layout, are the frame the next trap saves into and the trap
depth; the trap stack, hook, nest and entry; the boot stack and context;
the top level and the task exit; the obarray, the symbol list, the
packages, the current package and the symbol count; extra roots; the
frontiers of cons and object space, object space's free bytes and its free
bins; the device pages; two slots the trap stub parks registers in; and
the capabilities the reset stub mints from the memory map. The collector
scans the slots before the parked registers as roots, marks the block as
the object it is, and never traces it; the write barrier lets a store
through its own capability, as through a stack's. Lisp state that is not
the kernel's is in ordinary globals: the collector's free pairs and holes,
the error handler, the boot list, the startup closure.

## Authority

At reset PCC and `mtvec` are the root, every general register and every
other capability CSR is NULL, and the processor starts at the reset vector.
The reset stub turns the memory map into capabilities, once: from the root,
which it reads from its CSR, it mints nil, the kernel block, which goes in
`mscratch`, and into the kernel block the low block (LD), cons space
(`perms-pair`), object space (`perms-space`: every permission but SE),
the mark bitmap, the object-start map and the collector's scratch (LD and
SD), a capability to every otype (SE), and each device's page. It writes
the two maps' capabilities into the barrier's CSRs, points the kernel
block's frame at the boot context, loads `mtvec` and `sp` from it, makes
the empty cons run from cons space, and enters the top level with no
register holding anything it minted but nil. A store to the system
device's reset register starts the processor at the reset vector again,
as from power-on, with memory as it is, which is how a machine that has
built a fresh image hands over to it.

Nothing else addresses memory by number. The collector, the allocator, the
assembler, Exec and the image writer hold the region capabilities and work
by addresses within them: a capability's address set, and an access made
through it. Knowing an address is arithmetic; following one takes a
capability that covers it. A pair the compactor moves is re-derived from
cons space's capability at its new address.

**The root** is in a read-only CSR, 0xfc0, which takes SR to read. The
reset stub, `peek` and `poke`, the explorer's and the printer's raw views,
and `open-closure` read it, and nothing else does. `(%root)` reads it. A
load or store whose base register is `x0`, an encoding RVY reserves, is an
illegal instruction, with SR or without: `x0` is NULL, no authority.

**SR is `unsafe`.** SR is RVY's ASR. The compiler gives a code object SR
when its source was compiled in an `(unsafe-file)` or contains an
`(unsafe ...)` form, and no other. Without SR in PCC these are illegal
instructions, as RVY has them without ASR: writing any CSR; reading a
privileged CSR, which is any whose number's bits 9 and 8 are not 0, the
root's among them, but `mtidc`; and `mret`. `wfi`, `ecall` and `ebreak` need
nothing. So `unsafe` is enforced twice: the compiler refuses a raw name
outside it, and the processor refuses the act to code that did not say it.

**The escape hatch is the root.** Everything a program can reach it reaches
through a capability someone handed it, and every capability is bounded,
except the root. `%root` and the operations that work through it are the
raw vocabulary. Bounded operations on a capability you hold, loading a word
from a byte object, narrowing bounds, dropping permissions, sealing your
own closure, are safe, because they cannot reach past what you were given.

## The processor

RV32IMC with Zba, Zbb, Zbs, Zicond and Zicsr; RVY as RV32Y with Smy, in
machine mode and always in capability mode; and Xlm.

### Registers and CSRs

32 capability registers. `c0` reads as NULL. PCC is read with `auipc rd,
0`. The CSRs that hold capabilities are RVY's `mtvec`, `mscratch` and
`mepc`, its thread identifiers `mtidc` (0x37f) and `utidc` (0x07f), and
Xlm's: the mark bitmap (0x7c2) and the object-start map (0x7c3), which the
write barrier reads through, and the root (0xfc0), which reads as the root
and which nothing writes. A CSR instruction reads one whole; `csrrw` writes one whole, and the other forms write its address as
`YADDRW` would. `mtvec` written whole takes the address it already has as
`YADDRW` would, so a sealed one reads back untagged; `mepc` written whole at
an odd address is untagged. A trap sets `mepc` to PCC with the faulting
address and PCC to `mtvec`; `mret` sets PCC to `mepc`, unsealed if it is a
sentry. `mtvec` is not unsealed: a sealed one leaves PCC untagged, and the
trap's first fetch faults again.

Fetch needs PCC tagged, unsealed, with EX, and the instruction inside its
bounds.

### Base instructions in capability mode

- Loads and stores take `cs1` as their authority, checked for tag, seal,
  permission and bounds, as RVY checks them; with `x0` as the base they are
  illegal. `LY` and `SY` move a capability with its tag and need 8-byte
  alignment. A misaligned one that passes its authority's checks is an
  access fault, 5 for a load and 7 for a store: a tag belongs to an aligned
  granule, so no handler could emulate the access. The same holds for
  `lref`, `sref`, `lvar` and `jcl`'s load of slot 0. `LY` through an
  authority without LC clears the loaded tag; through one without LM it
  clears SD, SC and LM as above. LOAD and STORE's funct3 3, RV64's `ld` and
  `sd`, are illegal.
- Compressed: `c.ly` and `c.sy` take the `c.flw`/`c.fsw` slots (quadrant 0,
  funct3 3 and 7), `c.lysp`/`c.sysp` the `c.flwsp`/`c.fswsp` slots
  (quadrant 2, funct3 3 and 7). Their offsets are encoded as RV64C's `c.ld`,
  `c.sd`, `c.ldsp`, `c.sdsp`: multiples of 8.
- `c.addi16sp` and `c.addi4spn` are `YADDI` on `csp`. `c.mv` is `C.YMV`.
  `addi`, `c.add` and every other integer instruction are integer: the
  result is untagged. Every Zca HINT is a nop: `c.addi` of 0 and the
  compressed shifts by 0 leave their register as it was.
- `jal`, `jalr`, `c.j`, `c.jal`, `c.jr`, `c.jalr`: the target is formed from
  PCC (`jal`) or `cs1` (`jalr`), which must be tagged with EX, and may be a
  sentry, which is then unsealed and may only be entered at its own
  address: with no offset, and at an even address, since a jump clears bit 0
  of its target. A jump or a taken branch that would leave PCC unable to
  fetch at its target faults where it stands, with the target's address, as
  RVY envisages an extension may. `YSEALE` does not look at the address, so
  it makes a sentry at an odd address as readily as any other, and nothing
  can enter it. The link is a sentry for the next instruction.
- `auipc` is PCC with its address moved.

### RVY's instructions, RVY-A, opcode 0x7b

```
funct3 0, R-type, funct7:
  0x01  YHIW     cd, rs1, rs2    untagged, rs1's address with metadata rs2
  0x03  YADD     cd, cs1, rs2    rs2 = x0 is YMV
  0x05  YSH1ADD  cd, rs1, cs2    cs2 moved by rs1 << 1; 0x0d by << 2, 0x15 by << 3
  0x06  YEQ      rd, cs1, cs2    exact equality
  0x07  YUNSEALS cd, cs1, cs2    cs2 unsealed if it lies inside cs1
  0x0b  YADDRW   cd, cs1, rs2
  0x0e  YSS      rd, cs1, cs2    1 if cs2's bounds and permissions lie in cs1's
  0x0f  YBLD     cd, cs1, cs2    cs2's bits tagged if cs1 could have made them
  0x13  YPERMC   cd, cs1, rs2    rs2 a mask of the permissions to clear
  0x17  YSEALE   cd, cs2         with rs1 = x0: a sentry
        YSEALT   cd, cs1, cs2    cs1 the key, cs2 what is sealed
  0x1b  YBNDSW   cd, cs1, rs2    exact bounds
  0x1f  YUNSEALT cd, cs1, cs2    cs1 the key, cs2 what is unsealed
  0x23  YBNDSRW  cd, cs1, rs2    bounds rounded outward
  0x78  YAMASK   rd, rs1         rs2 = 0: the alignment mask a length needs
  0x7a  two operands, rs2 choosing:
        0 YBASER  1 YPERMR  2 YTOPR  3 YLENR  4 YTAGR  5 YTYPER  7 YHIR
funct3 1  LY      cd, imm(cs1)
funct3 2  SY      cs2, imm(cs1)
funct3 4  YADDI   cd, cs1, imm
funct3 5  YBNDSWI cd, cs1, len  imm[11:9] = 7, imm[8:0] the length: 1 to 255,
                                256 to 504 by 8, 512 to 4080 by 16, 0 for 4096
```

Where RVY clears a tag rather than trapping, so does the machine: an address
moved out of a capability's representable region or of a sealed one, bounds
outside the authority's or, asked to be exact, needing rounding, a
permission changed on a sealed capability, a sealing or unsealing whose key
does not allow it, and bits `YBLD` could not have made. `YBLD` also refuses
bits that are not exactly what the bounds instructions would encode for the
bounds they decode to, so that capabilities with the same bounds and
permissions are the same bits and `eq?`; it keeps a sentry and a closure
sealed, the two otypes anyone may seal, and clears any other otype, as RVY's
`YBLD` clears every type that is not ambient. `YSEALT` seals only with an
otype the format holds, 1 to 15. A `YBNDSWI` length this format cannot bound
exactly where it is asked for, 4080 among them, leaves the result untagged.

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
a capability fault, as the CHERI operation would take it.

Every Xlm instruction is in custom-0, opcode 0x0b:

```
f3 0  lref  rd, imm(rs1)    rs1 a pair (tagged, unsealed, no HD) with LD and
                            LC; nil qualifies. rd <- the capability at rs1+imm.
f3 1  sref  rs2, imm(rs1)   S-type: rs1 a pair with SD; nil is refused with
                            cause 24. The tag goes as SY takes it.
f3 2  lvar  rd, imm(rs1)    rs1 a symbol, unsealed; rd <- the slot at rs1+imm,
                            and if that is the unbound marker, cause 24 with
                            mtval the number of rs1: an unbound variable.
f3 3  beqx  rs1, rs2, off   B-type: branch if rs1 and rs2 are identical
f3 4  bnex  rs1, rs2, off   B-type: branch if not
f3 5  fixnum immediates     imm[11:10] the operation, imm[9:0] a signed
                            immediate, -512 to 511:
        0 faddi  rd, rs1, imm    wrapping
        1 faddio rd, rs1, imm    cause 26 on overflow
        2 fandi  rd, rs1, imm
        3 fori   rd, rs1, imm
f3 6  R-type, funct7 the operation:
        0x00..0x15  fop   rd, rs1, rs2   two fixnums:
              0x00 add 0x01 sub 0x02 mul 0x03 div 0x04 rem 0x05 and 0x06 or
              0x07 xor 0x08 addo 0x09 subo 0x0a mulo (cause 26 on overflow)
              0x10 sll 0x11 srl 0x12 sra (amount mod 32)
              0x13 lt 0x14 ltu 0x15 eq (the fixnum 0 or 1)
        0x18..0x1a  fshi  rd, rs1, n     a fixnum shifted by the rs2 field:
                                         sll, srl, sra
        0x20  jcl    rd, rs1             call a closure (below)
        0x21  vkind  rd, rs1             rd <- the kind of rs1 (below)
        0x22  lhdr   rd, rs1, type       rs1 an object (HD, unsealed or a
                                         closure) of header type rs2 field
                                         (0 any); rd <- its length
        0x23  sealcl cd, cs1             cs1 a headed, unsealed object whose
                                         header says closure; cd <- it sealed
                                         as a closure
        0x24  npair  cd, cs1             cs1 a cons run (tagged, unsealed, no
                                         HD) with 16 bytes left at its
                                         address; cd <- those 16 bytes, a pair.
                                         Otherwise cause 28, mtval the number
                                         of cs1
        0x40 | from  retag rd, rs1, to   rs1 untagged of kind `from` (31 any);
                                         rd <- its address with metadata the
                                         rs2 field
f3 7  indexed access, below
```

Every fixnum operand must be a fixnum (untagged, metadata 0), and the result
is one. Division by zero is cause 27; `div` of -2^31 by -1 is cause 26. The
handler widens an overflow into a bignum and resumes after the instruction.
`char->integer` is `retag rd, rs, 1, 0`; `integer->char` is
`retag rd, rs, 0, 1`.

`car` and `cdr` are offsets 0 and 8 of `lref`. A null test is `beqx rs, tp`.

`jcl rd, rs1` takes rs1 a closure (tagged, otype 2), leaves it unsealed in
rs1, puts a sentry for pc+4 in rd, and jumps to the entry in its slot 0. The
entry is loaded through the closure as `LY` would load it, so a closure
without LD or LC, or one whose slot 0 is outside its bounds, is a load
fault on that slot. An entry that is untagged, sealed other than as a
sentry a jump may enter, not executable, or whose first instruction is
outside its bounds faults at the `jcl`, as a capability fault on PCC with
the entry's address.

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

**Indexed access**, funct3 7: funct7 is the form in bits 6..4, bit 4 store,
bit 5 byte, bit 6 the index is the five-bit immediate in the rs2 field, and
in bits 3..0 the type the object must be (0 for any); rs1 the object
(tagged, HD, unsealed, its header in RAM), rs2 the index, a fixnum; rd the
result or the value stored. The value forms move 8-byte capabilities and
refuse a string or byte object; the byte forms move a byte, zero-extended,
and refuse anything but a string or byte object; a wrong object is cause 24
on rs1 and an index that is not a fixnum cause 24 on rs2. The index must be
below the header's length: cause 25 with `mtval` the number of the index
register, or 32 for an immediate index. The address is checked against the
capability's bounds as well, a load needs LD, and a store SD, as `LY` and
`SY` check them, and a capability stored keeps its tag only through SC.

### Traps

```
 2  illegal instruction  mtval: the instruction; without SR, every privileged act
24  wrong type           mtval: the register holding the offending value
25  index out of range   mtval: the register holding the index, or 32
26  fixnum overflow      mtval 0; the handler decodes the instruction
27  division by zero     mtval 0
28  cons run used up     mtval: the register `npair` was given
29  write barrier        mtval: the store's register in bits 4..0, and the
                         overwritten granule's offset from that
                         capability's base, in granules, above them
30  stack overflow       mtval: where sp would have gone; sp is left as it was
32  capability fault on PCC     mtval: the instruction's address, or the
                                target of the jump or branch that would leave
                                PCC's bounds
33  capability fault on a load  mtval: the address of the access
34  capability fault on a store mtval: the address of the access
```

Causes 32 to 34 are RVY's, and RISC-V leaves 24 to 31 to the
implementation, which is where Xlm's are. A capability fault names an
address; the handler finds the capability from the instruction at the pc,
the register it named, and the saved context, and asks it what refused. The
layout names the causes `cause-*`.

**The stack limit** (CSR 0x7c0) is checked when a `YADD`, a `YADDI` or a
`c.addi16sp` of `sp` moves it down, with interrupts on; zero means no limit.
It is a number, an address in the running task's stack: it is no authority,
only the point below which a task with interrupts on is stopped, so that
the reserve under it is left for code that runs with them off. `sp` is the
authority, a capability bounded to its task's whole stack, so nothing below
the stack can be written whatever the limit says; past it the fault is a
capability fault through `sp`, which the handler also reports as a stack
overflow.

**The write barrier** (`gcmode`, CSR 0x7c1, bit 0): while it is on, any
store of any width that would overwrite a tagged granule in cons or object
space whose capability points at an unmarked heap object traps with cause
29, before writing, unless the store is into a stack, a context or the
kernel block: its authority is based at the payload of an object whose
header, at an object start, says stack, context or kernel, and the granule
lies in that payload. Every stack pointer, frame pointer and context
capability is so based. A tagged capability keeps alive the block its base
lies in, whatever its length: one without HD based in cons space, the pair
at its base rounded down to 16; one based in object space, past its start
and before its end, headed or not, the object whose header is the nearest
set bit of the object-start map at or below the granule before its base.
So a capability narrowed to a cdr or to a slot keeps its pair or its
vector. Its mark bit is the bit of that granule in the mark bitmap, one bit
per 8 bytes from `CONS_BASE`.

The processor reads both maps through the capabilities in their CSRs,
`gcmarks` (0x7c2) and `gcstarts` (0x7c3): the mark bitmap, bit i of the
word at index i/32 from the capability's base, and the object-start map,
one bit per 8 bytes of object space from `OBJ_BASE`, set at every allocated
block's header. A word the capability does not let it read reads as zero.
The reset stub writes them, from the regions it mints; the layout of a map
is the machine's, where it lies is the capability's.

`mtval` names the granule the way Xlm's other faults name a value, by
register: bits 4..0 are the store's base register, and bits 31..5 the
granule's offset from that capability's base, rounded down to a granule,
in granules. The handler reads the overwritten capability through the
store's own capability, from the register in the trap frame, when that may
load the granule whole, and through the region it lies in otherwise, marks
its object, and the store re-executes. Nothing can overwrite the last copy
of a pointer unseen.

## Memory

```
0x0000_0000  the nil cell, 16 bytes
0x0000_0800  the reset stub, `reset-reserve` bytes at `reset-vector`
0x0100_0000  cons space, 128 MiB, eight million pairs
0x0900_0000  object space, 64 MiB: the kernel block first, then every object,
             machine code, stacks and contexts among them
0x0D00_0000  the mark bitmap, the object-start map, the collector's scratch
0xF000_0000  device pages, 4 KiB each, 32-bit registers and three capability registers
```

The low block ends at `low-end`, 4 KiB, and holds nil's cell and the reset
stub: the one cell and the one piece of code with a fixed address, the
first because nil is a capability to it that `tp` holds, the second because
the processor starts there. Nothing lies between it and cons space. This
map is the emulator's and the forge's, which build the image at these
addresses, and the reset stub's, which mints it; after reset the machine
holds it as capabilities and names nothing in it by number.

Tags exist for RAM only. A device page is a region of 32-bit registers, and
an 8-byte access there is an access fault, as a RISC-V platform refuses an
access width a region does not support. Three registers take a capability:
the blitter's list register, the disk's buffer register and the display's
scan-out register, each 8 bytes at the start of its page. An `SY` to one
writes the capability, tag and all, into the chip; an `SY` to any other
register is a store fault, and a word store to one of the three writes a
number, which the chip refuses. The scan-out register alone hands back
what it holds: an `LY` from it loads the bitmap's capability as `LY` would
through the page, because the display keeps its bitmap for as long as it
shows it, and the collector's roots read it there; an `LY` from any other
register is a load fault. DMA goes through capabilities: a blitter
descriptor's source, destination and link are capability slots, which the
chip loads as `LY` would through the descriptor's capability, and each chip
refuses a transfer its capability does not allow, saying which check
failed (see drivers.md).

## Contexts and the cons run

**Contexts.** A task's register save area is a context object of 32
capability slots, 256 bytes: slot 0 the pc (`mepc`), slots 1..31
`x1..x31`. The kernel block's frame names the one the trap stub saves
into, and switching tasks is pointing the frame at another task's. A trap
inside the handler saves into a frame of its own, the one for its depth in
the kernel block's trap nest, a vector of eight, each a context with a slot
after the registers for a link to the frame it interrupted. The handler
runs on the kernel block's trap stack. The stub swaps `mscratch` into `t0`
to have a register to work with, parks `t1` and `t2` in the kernel block
while it finds the frame, and saves every register there.

**The cons run** is `gp`: a capability with `perms-pair` bounded to the
running task's current run of cons space, its address the next free pair.
A pair is

```
npair a0, gp           ; traps (cause 28, register gp) when the run is used up
yaddi gp, gp, 16
sy    car, 0(a0)
sy    cdr, 8(a0)
```

The trap is the refill. The trap handler takes cause 28 naming `gp` as a
request for a fresh run, takes one for the task without allocating a pair,
writes it into the saved `gp` and the live one, and returns to the
instruction. A run is the front of a hole the sweep left or fresh ground,
never past a 256 KiB boundary, its base rounded up and its length down to
what `YAMASK` makes exact; a task's first is 4 KiB and each after it twice
the last, up to 256 KiB. The empty run is `perms-pair` bounded to no bytes
at `CONS_BASE`: the reset stub, every new task and every task whose run a
collection gave up start on it, and their first pair asks for a real one.
It is not sixteen bytes long, so it is never taken for a pair.

## The Lisp vocabulary

The checked vocabulary is unchanged in meaning. The raw vocabulary:

| name | | |
|---|---|---|
| `(%root)` | the root, from its CSR | unsafe |
| `(%ld-word a)` `(%ld-half a)` `(%ld-byte a)` `(%ld-cap a)` | memory by number, through the root | unsafe |
| `(%st-word! a v)` `(%st-half! a v)` `(%st-byte! a v)` `(%st-cap! a v)` | likewise | unsafe |
| `(%kernel)` `kernel-ref` `kernel-set!` `all-symbols` | the kernel block, from `mscratch`, and its slots | unsafe |
| `(%cap-ld c off)` `(%cap-st! c off v)` | a capability at byte offset off within c | safe |
| `(%cap-ld-word c off)` `(%cap-st-word! c off v)` `(%cap-ld-byte c off)` `(%cap-st-byte! c off v)` | data within c | safe |
| `(%cap-ld-at c a)` `(%cap-st-at! c a v)`, and `-word` and `-byte` forms | the same at address a, which c must cover | safe |
| `(%bit-ref c i)` `(%bit-set! c i)` | bit i of the bit array c stands at | safe |
| `(%addr-of x)` | the address; an immediate's payload | safe |
| `%cap-base` `%cap-len` `%cap-top` `%cap-perms` `%cap-otype` `%cap-offset` `%cap-tag?` `%cap-sealed?` `%cap-high` | reading a capability | safe |
| `%cap-set-addr` `%cap-inc` `%cap-bounds` `%cap-bounds-exact` `%cap-and-perms` `%cap-clear-tag` `%cap-seal-entry` `%cap-seal-closure` | narrowing or sealing one | safe |
| `(%cap-seal c key)` `(%cap-unseal c key)` | with a key to the otype | safe |
| `(%cap-unseal-within c outer)` | c unsealed if it lies within outer | safe |
| `(%cap-set-high c n)` `(%cap=? a b)` `(%cap-subset? a b)` `(%rrl n)` `(%ram n)` | | safe |
| `%slot` `%set-slot!` | any-type indexed access | unsafe |
| `%cons-run` `%set-cons-run!` | read and write `gp` | unsafe |
| `open-closure` | a closure unsealed with the root | unsafe |
| `(sealing-key ot)` | a key to otype ot, made from the kernel block's otypes | unsafe |
| the machine-state operations | contexts, the stack limit, `gcmode`, interrupts, `ecall`, halt | unsafe |

`%cap-perms` answers `YPERMR`'s bit field, reserved bits and all, and
`(%cap-and-perms c mask)` keeps the permissions `mask` names, which is
`YPERMC` of its complement. `(%cap-subset? a b)` is true when `b`'s bounds
and permissions lie within `a`'s. `(%rrl n)` is `n` rounded up to the
alignment `YAMASK` gives. A word loaded by number is a fixnum, so there is
no `%ld-fixnum`, and `peek` and `poke` need no signed and unsigned family.
`peek` and `poke` are the gun in the safe: memory by number through the
root, which nothing gets in the way of, and which only code that says
`unsafe` can reach for.
