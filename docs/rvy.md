# LM and RVY

LM is RVY, the RISC-V CHERI extension, as RV32 in machine mode and
capability mode, with an RV32 capability encoding of LM's own and the Xlm
extension. This note says which RVY that is, what LM's encoding is, how Xlm
is encoded, and every place LM departs from RVY, why, and what the
RVY-conformant alternative would cost. [cheri.md](cheri.md) is the contract
the machine keeps; this is how that contract stands against the
specification.

## The specification

`riscv/riscv-cheri` at commit `6a2890608d` (2026-11-24, "Zca HINTs are all
NOPs"), which its Makefile names v0.9.11-draft. Section numbers are those of
the full build, `riscv-cheri-full.html`, which holds the chapters outside
the v1.0 ratification package: RV32Y and its encoding RV32LYA are among
them, and so is Zyseal, which is experimental.

What LM implements of it:

| | |
|---|---|
| base | RV32Y: XLEN 32, YLEN 64, MW 10, CAP_MAX_E 24 |
| privilege | Smy, machine mode only |
| mode | capability mode only; no Zyhybrid |
| compressed | Zca and Zcy, every Zca HINT a nop |
| sealing | `YSEALE`, `YUNSEALS`, and Zyseal's `YSEALT` and `YUNSEALT` |
| other | Zba with `YSH1ADD`, `YSH2ADD` and `YSH3ADD`; Zbb, Zbs, Zicond, M, Zicsr |
| CSRs | `mtvec`, `mscratch`, `mepc`, `mtidc` and `utidc` as capabilities |
| causes | 32, 33 and 34 for capability faults, `mtval` the address |

Not implemented: Zybndsrdw (`YBNDSRDW`), Zyhybrid (`YMODEW`, `YMODER`,
`YMODESWY`, `YMODESWI`, the `ddc` CSR at 0x03F), the A extension's
`LR.Y`, `SC.Y` and `AMOSWAP.Y`, the cache-block and prefetch instructions,
and Zylevels. Their encodings are illegal instructions.

## The capability encoding

RVY lets a platform define its own RV32 capability encodings (§12.1), and LM
does. Its metadata word is nine independent permissions in bits 31..23, a
four-bit otype in 22..19, and bounds in 18..0:

```
31 LD   30 SD   29 LC   28 SC   27 LM   26 EX   25 SR   24 SE   23 HD
22..19 otype    18 IE    17..10 T[7:0]    9..0 B[9:0]
```

LD, SD, LC with SC, LM, EX and SR are RVY's R, W, C, LM, X and ASR; SE is
Zyseal's S and U together; HD is Xlm's. The otypes are 0 unsealed, 1 the
sentry, 2 the closure, and 3 to 15 for a key's holder. RV32LYA, RVY's own
RV32 encoding, has a five-bit compressed permission field and a one-bit
type, and so holds neither closures nor typed seals, nor SE, nor HD, nor an
execute-only code capability.

The permissions are read and cleared in RVY's bit field, as cheri.md lists
it: SC and HD in bits 6 and 7, which RVY leaves to extensions, SE as both S
and U, and every bit no permission occupies reading as 1. `YPERMC` applies
RVY's base dependency rules (C needs R or W, LM needs C and R, ASR needs X)
and Xlm's (SC needs C). RV32LYA's further rules are its own and do not
apply.

The bounds are CHERI Concentrate with MW = 10 and a largest exponent of 24,
as RV32LYA's are, in the encoding CHERI ISAv9 defines: an internal-exponent
bit set for an exponent above 0, the exponent stored as it is in six bits of
the mantissas, base and top in multiples of 2^(E+3), and ISAv9's
representable region. Malformed bounds decode as empty, as RVY decodes them,
and `YBLD` refuses bits that are not the encoding of their own bounds.

**Why not RVY's bounds encoding.** RV32LYA's bounds take 20 bits: the
exponent-format bit with its polarity inverted, so that all-zero metadata is
the infinite capability, an exponent stored as 24 less itself in five bits,
and the LE bit, which makes every length below 512 exact. Nine independent
permissions and a four-bit otype leave 19 bits, so the LE bit does not fit.
Without it the polarity and the inversion change nothing a program can see
but `YBASER` and `YLENR` of an integer, which LM never asks, and every
exact allocation is already exact. The cost of the fit would be three
permission or otype bits: SC folded into LC and an otype of three bits, or
the format's other choices given up.

## Xlm

Xlm is in custom-0, opcode 0x0b, the only major opcode RVY leaves to custom
use (§2.8): RVY-A takes custom-3's opcode, and RVY-B and RVY-C, which it
reserves, custom-2's and custom-1's. An Xlm instruction is one CHERI
operation and one Lisp type check.

```
funct3 0  lref  rd, imm(rs1)       I-type: a capability from a pair
funct3 1  sref  rs2, imm(rs1)      S-type: a capability into a pair
funct3 2  lvar  rd, imm(rs1)       I-type: a symbol's slot, unless unbound
funct3 3  beqx  rs1, rs2, off      B-type: branch if identical
funct3 4  bnex  rs1, rs2, off      B-type: branch if not
funct3 5  faddi faddio fandi fori  I-type: imm[11:10] the operation, imm[9:0]
                                   a signed immediate
funct3 6  R-type, funct7:
          0x00..0x15  fop          two fixnums: add sub mul div rem and or
                                   xor, addo subo mulo, sll srl sra, lt ltu eq
          0x18..0x1a  fshi         a fixnum shifted by the rs2 field
          0x20 jcl     0x21 vkind  0x22 lhdr (rs2 the type)
          0x23 sealcl  0x24 npair
          0x40 | from  retag       rs2 the metadata given
funct3 7  indexed access           R-type: funct7 the form (store, byte,
                                   immediate index) above the object's type
```

Xlm's causes are 24, a wrong kind of operand; 25, an index outside the
object; 26, fixnum overflow; 27, division by zero; and 28, a cons run with
no pair left. RISC-V leaves 24 to 31 to the implementation. Xlm's CSRs are
0x7c0, the stack limit, 0x7c1, `gcmode`, and 0x7c2 and 0x7c3, capabilities
to the collector's mark bitmap and object-start map, which the write
barrier reads through, in the machine mode's custom read-write range, clear
of RVY's debug CSRs at 0x7b1 to 0x7bf; and 0xfc0, the root, in its custom
read-only range. Every one takes SR, as every machine-level CSR does.

**The root CSR.** RVY gives the root to PCC and `mtvec` at reset and leaves
where it goes after that to software. LM keeps it in a read-only CSR, so
that nothing need hold it in a register or in memory: the reset stub reads
it to mint the memory map into capabilities, once each time the machine
starts, and after that only `peek`, `poke`, the debugging views and the
escape hatch that opens a sealed capability read it, each inside an `unsafe` block.
*Alternative:* the reset stub keeping the root sealed in memory with a key
only the trap handler holds, at the cost of an unseal at each use; or the
root dropped after boot, and `peek` and `poke` bounded to the regions.

The services a Lisp machine leans on and RVY does not give are Xlm's:
`npair` carves a pair from the cons run and traps with cause 28 when the run
is used up, so a cons is four instructions with no compare and branch;
`sealcl` seals a closure object without an authority; `jcl` checks, unseals
and enters a closure in one instruction.

## Where LM departs from RVY

Each is deliberate. For each: what LM does, why, and the RVY-conformant
alternative.

**The capability encoding.** LM's own, above. *Why:* closures are opaque
values that only a call opens, which needs an otype of their own, and Exec
and the chips seal what their records hold, which needs more; HD lets an Xlm
type check cost no instructions. *Alternative:* RV32LYA, with closures as
sentry trampolines (three more instructions and an indirect jump per call,
sixteen bytes per closure, executable closures), or unsealed and read-only
(one or two more instructions per call, free variables readable); typed
seals need Zyseal's S and U, which RV32LYA cannot yet encode.

**HD's rule on the bounds instructions and `YBLD`.** The bounds
instructions keep HD only at their authority's base or, from an authority
that spans the whole of object space, at a base in it, and `YBLD` leaves
bits with HD anywhere else untagged: the root and object space's own
capability mint headed objects, and nothing else does. *Why:* `lhdr`, `vkind`, `lvar`, indexed access and `sealcl` trust
that the granule below a headed capability's base is a header. *Alternative:*
no HD, and every typed access consulting the object-start map at its base:
one more memory access each.

**Otypes past the sentry in `YBLD`.** A sentry and a closure, which anyone
may seal, are kept; any other otype is cleared, as RVY's `YBLD` clears every
type that is not ambient. The closure otype is LM's.

**The write barrier.** While `gcmode` is on, a store that would overwrite a
pointer to an unmarked object traps with cause 29 before writing, with
`mtval` naming the overwritten granule as Xlm's other faults name a value,
by register: the store's base register in bits 4..0, and the granule's
offset from that capability's base, in granules, above them. The mark bits
are read through the capability in CSR 0x7c2, and the object starts through
the one in 0x7c3. *Why:* the collector marks while everything else runs,
and nothing reachable when marking began can be lost; the handler reads
the old value through the store's own capability, and needs no authority
of its own. *Alternative:* the same check reported as a store access fault,
cause 7, with the address in `mtval`, which the handler tells from a real
one by `gcmode` and the mark bit and reads through the region it lies in,
at no run-time cost; or a barrier in software, several instructions every
pointer store.

**The stack limit.** A `YADD`, `YADDI` or `c.addi16sp` that moves `sp`
below the limit CSR with interrupts on traps with cause 30. *Why:* a stack
overflow is reported while there is still stack to report it on.
*Alternative:* `sp` narrowed to the limit while interrupts are on, widened
from a saved capability by the code that runs with them off; or a prologue
check, two instructions a frame.

**Jumps fault where they stand.** A jump or a taken branch whose target PCC
could not fetch, and a `jcl` whose entry could not run, take the capability
fault on PCC at the jump, with the target's address, where RVY takes it at
the target's fetch. The JALR page's note envisages exactly this as a future
extension. *Why:* `mepc` and `ra` still say who jumped, which the report
and the backtrace need. *Alternative:* the fault at the target, and the
handler finding the jump from the link register.

**Device pages refuse an eight-byte access.** `SY` to a device page is a
store access fault except at the three capability registers, the blitter's
list register, the disk's buffer register and the display's scan-out
register, and `LY` from one is a load access fault except at the scan-out
register, which hands back the capability it holds as `LY` would load it
through the page. This is a platform's choice of supported access widths
for a region, which RISC-V lets a PMA make; RVY's "tag strip" and "tag store
fault" PMAs are about regions that take such an access.

**A load or store based on `x0` is illegal.** RVY reserves the encoding
(§2.7). LM gives it no meaning, with SR or without: memory is reached
through a capability, and `x0` is NULL.

**Stores keep their tag only through SC.** RVY's `SY` stores the tag only
through C, and LM's C is LC and SC: `SY`, `sref` and indexed stores store a
tagged capability's tag only through an authority with SC, which no
capability has without LC. A loaded tag likewise needs LC.

**`YBNDSWI` lengths.** The immediate encodes RVY's lengths; those this
format cannot bound exactly where they are asked for, 4080 among them,
leave the result untagged, as an exact request that would round always
does.

## What follows from RVY as it is

Some of LM's behaviour that is RVY's own, which a reader coming from CHERI
ISAv9 should expect: the capability instructions clear tags rather than
trap; capability faults are causes 32, 33 and 34 with the address in
`mtval`, and the handler finds the register and the reason from the
instruction and the saved context; a privileged act without SR is an
illegal instruction; `wfi` needs nothing; `mtvec` is not unsealed by a trap;
a misaligned `LY` or `SY` is an access fault; and `YADD` by `x0` is `YMV`,
which keeps a sealed capability.
