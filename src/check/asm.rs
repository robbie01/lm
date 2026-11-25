//! Differential test for the Lisp assembler.
//!
//! The same instruction sequence is written twice, once in Lisp and once with
//! the Rust encoders, and the two byte streams must match exactly. The two
//! encoders are independent readings of the RISC-V manual, the CHERI ISAv9
//! specification and docs/cheri.md.

use crate::forge::boot_host;
use crate::forge::hostlisp::Lisp;
use crate::mach::Machine;
use crate::rvenc::*;

/// The Lisp half. Leaves the buffer in the global `*asm-buf*` and the length
/// in `*asm-len*`.
const LISP_SIDE: &str = r#"
(in-package asm)
(define a (make-assembler))
(i-addi a $a0 $a1 -5)
(i-addi a $a0 $a1 2047)
(i-addi a $a0 $a1 -2048)
(i-addi a $a0 $a1 0)
(i-addi a $a0 $a0 7)
(i-addi a $a0 $zero -32)
(i-add a $a0 $a1 $a2)
(i-sub a $a0 $a1 $a2)
(i-sll a $a0 $a1 $a2)
(i-slt a $a0 $a1 $a2)
(i-sltu a $a0 $a1 $a2)
(i-xor a $a0 $a1 $a2)
(i-srl a $a0 $a1 $a2)
(i-sra a $a0 $a1 $a2)
(i-or a $a0 $a1 $a2)
(i-and a $a0 $a1 $a2)
(i-slti a $a0 $a1 -1)
(i-sltiu a $a0 $a1 1)
(i-xori a $a0 $a1 -1)
(i-ori a $a0 $a1 255)
(i-andi a $a0 $a1 -256)
(i-mul a $s0 $s1 $s2)
(i-mulh a $s0 $s1 $s2)
(i-mulhsu a $s0 $s1 $s2)
(i-mulhu a $s0 $s1 $s2)
(i-div a $s0 $s1 $s2)
(i-divu a $s0 $s1 $s2)
(i-rem a $s0 $s1 $s2)
(i-remu a $s0 $s1 $s2)
(i-slli a $t0 $t1 31)
(i-srli a $t0 $t1 1)
(i-srai a $t0 $t1 17)
(i-lui a $a0 #xabcde)
(i-auipc a $a0 #x12345)
(i-lw a $a0 $a1 -100)
(i-lw a $a0 $a1 64)
(i-lw a $ra $sp 12)
(i-lb a $a0 $a1 7)
(i-lh a $a0 $a1 -2048)
(i-lbu a $a0 $a1 2047)
(i-lhu a $a0 $a1 0)
(i-sw a $a2 $sp 44)
(i-sw a $a2 $a3 124)
(i-sw a $a2 $t0 8)
(i-sb a $a2 $sp -44)
(i-sh a $a2 $sp 2047)
(i-lc a $a0 $a1 -96)
(i-lc a $a0 $a1 248)
(i-lc a $a0 $sp 504)
(i-lc a $a0 $sp 4)
(i-lc a $t0 $s1 16)
(i-sc a $a2 $t0 16)
(i-sc a $a2 $a3 8)
(i-sc a $a2 $sp 0)
(i-sc a $zero $sp 496)
(i-sc a $a2 $a3 256)
(i-jalr a $ra $a0 16)
(i-jalr a $zero $a0 0)
(i-call-reg a $t1)
(i-ecall a)
(i-ebreak a)
(i-mret a)
(i-wfi a)
(i-csrrw a $a0 #x340 $a1)
(i-csrrs a $a0 #x342 $zero)
(i-csrrc a $zero #x304 $a1)
(i-csrrwi a $zero #x300 8)
(i-csrrsi a $zero #x300 8)
(i-csrrci a $zero #x300 8)
(i-mv a $a0 $a1)
(i-mv a $sp $t0)
(i-mv a $a0 $zero)
(i-cmove a $t0 $t1)
(i-cincoffsetimm a $sp $sp -64)
(i-cincoffsetimm a $sp $sp 496)
(i-cincoffsetimm a $sp $sp -512)
(i-cincoffsetimm a $sp $sp 8)
(i-cincoffsetimm a $s0 $sp 32)
(i-cincoffsetimm a $a5 $sp 1020)
(i-cincoffsetimm a $t0 $sp 16)
(i-cincoffsetimm a $a0 $a1 -2048)
(i-cincoffsetimm-w a $sp $sp -16)
(i-cincoffset a $a0 $a1 $a2)
(i-csetboundsimm a $a0 $gp 16)
(i-csetboundsimm a $a0 $a1 4095)
(i-csetbounds a $a0 $a1 $a2)
(i-csetboundsexact a $a0 $a1 $a2)
(i-cseal a $a0 $a1 $a2)
(i-cunseal a $a0 $a1 $a2)
(i-candperm a $a0 $a1 $a2)
(i-csetaddr a $a0 $a1 $a2)
(i-csub a $a0 $a1 $a2)
(i-csethigh a $a0 $a1 $a2)
(i-cbuildcap a $a0 $a1 $a2)
(i-ctestsubset a $a0 $a1 $a2)
(i-cseqx a $a0 $a1 $a2)
(i-cspecialrw a $t0 scr-ddc $zero)
(i-cspecialrw a $zero scr-mtcc $t1)
(i-cspecialrw a $t0 scr-mscratchc $t0)
(i-cspecialrw a $a0 scr-mepcc $zero)
(i-cgetperm a $a0 $a1)
(i-cgettype a $a0 $a1)
(i-cgetbase a $a0 $a1)
(i-cgetlen a $a0 $a1)
(i-cgettag a $a0 $a1)
(i-cgetsealed a $a0 $a1)
(i-cgetoffset a $a0 $a1)
(i-cgetaddr a $a0 $a1)
(i-cgethigh a $a0 $a1)
(i-cgettop a $a0 $a1)
(i-crrl a $a0 $a1)
(i-cram a $a0 $a1)
(i-ccleartag a $a0 $a1)
(i-csealentry a $a0 $a1)
(i-csealclo a $a0 $a1)
(i-cjalr a $ra $t2)
(i-lb-ddc a $a0 $a1)
(i-lh-ddc a $a0 $a1)
(i-lw-ddc a $a0 $a1)
(i-lc-ddc a $a0 $a1)
(i-lbu-ddc a $a0 $a1)
(i-lhu-ddc a $a0 $a1)
(i-sb-ddc a $a2 $a1)
(i-sh-ddc a $a2 $a1)
(i-sw-ddc a $a2 $a1)
(i-sc-ddc a $a2 $a1)
(i-lw-abs a $a0 #x108)
(i-lw-abs a $a0 #x12345678)
(i-lc-abs a $a1 #x110)
(i-lc-abs a $a1 mmio-base)
(i-sw-abs a $a2 #x100 $t0)
(i-sw-abs a $a2 #x20000 $t0)
(i-sc-abs a $a2 #x1f8 $t0)
(i-sc-abs a $a2 #x4000 $t0)
(i-car a $a0 $a1)
(i-cdr a $t0 $s1)
(i-set-car a $a2 $a3)
(i-set-cdr a $a2 $a3)
(i-lref a $a0 $a1 -8)
(i-sref a $a2 $sp 100)
(i-lvar a $t1 $t6 8)
(i-vkind a $a0 $a1)
(i-jcl a $ra $t0)
(i-lhdr a $a0 $a1 3)
(i-lhdr a $t2 $a0 0)
(i-ldx a $a0 $a1 $a2 3)
(i-stx a $a3 $a1 $a2 3)
(i-ldxb a $t0 $s1 $a2 2)
(i-stxb a $t0 $s1 $a2 4)
(i-ldx a $a0 $a1 $a2 0)
(i-ldxi a $a0 $a1 0 5)
(i-stxi a $a3 $a1 31 3)
(i-ldxbi a $t0 $s1 7 2)
(i-stxbi a $t0 $s1 12 4)
(i-faddi a $a0 $a1 -7)
(i-faddio a $a0 $a1 2047)
(i-fandi a $a0 $a1 2047)
(i-fori a $a0 $a1 -2048)
(i-fshi a $a0 $a1 0 31)
(i-fshi a $a0 $a1 1 3)
(i-fshi a $a0 $a1 2 17)
(i-fadd a $a0 $a1 $a2)
(i-fsub a $a0 $a1 $a2)
(i-fmul a $t0 $t1 $t2)
(i-fdiv a $t0 $t1 $t2)
(i-frem a $t0 $t1 $t2)
(i-fand a $s0 $s1 $a0)
(i-for a $s0 $s1 $a0)
(i-fxor a $s0 $s1 $a0)
(i-faddo a $a0 $a1 $a2)
(i-fsubo a $a0 $a1 $a2)
(i-fmulo a $a0 $a1 $a2)
(i-fsll a $a3 $a4 $a5)
(i-fsrl a $a3 $a4 $a5)
(i-fsra a $a3 $a4 $a5)
(i-flt a $a3 $a4 $a5)
(i-fltu a $a3 $a4 $a5)
(i-feq a $a3 $a4 $a5)
(i-retag a $a0 $a1 1 0)
(i-retag a $a0 $a1 0 1)
(i-retag a $t0 $t1 63 2)
(i-sh1add a $a0 $a1 $a2)
(i-sh2add a $a0 $a1 $a2)
(i-sh3add a $a0 $a1 $a2)
(i-andn a $t0 $t1 $t2)
(i-orn a $t0 $t1 $t2)
(i-xnor a $t0 $t1 $t2)
(i-min a $s0 $s1 $a0)
(i-minu a $s0 $s1 $a0)
(i-max a $s0 $s1 $a0)
(i-maxu a $s0 $s1 $a0)
(i-rol a $a1 $a2 $a3)
(i-ror a $a1 $a2 $a3)
(i-rori a $a1 $a2 13)
(i-bset a $a0 $a1 $a2)
(i-bclr a $a0 $a1 $a2)
(i-binv a $a0 $a1 $a2)
(i-bext a $a0 $a1 $a2)
(i-bseti a $a0 $a1 31)
(i-bclri a $a0 $a1 0)
(i-binvi a $a0 $a1 17)
(i-bexti a $a0 $a1 5)
(i-clz a $t3 $t4)
(i-ctz a $t3 $t4)
(i-cpop a $t3 $t4)
(i-sextb a $t3 $t4)
(i-sexth a $t3 $t4)
(i-zexth a $t3 $t4)
(i-rev8 a $t3 $t4)
(i-orcb a $t3 $t4)
(i-czero-eqz a $a0 $a1 $a2)
(i-czero-nez a $a0 $a1 $a2)
(i-neg a $a0 $a1)
(i-not a $a0 $a1)
(i-seqz a $a0 $a1)
(i-snez a $a0 $a1)
(i-li a $a0 #x12345678)
(i-li a $a0 -1)
(i-li a $a0 #x800)
(i-li a $a0 mmio-base)
(i-li a $a0 -2147483648)
(i-beq a $a0 $a1 'fwd)
(i-bne a $a0 $zero 'fwd)
(i-bltu a $a1 $a2 'fwd)
(i-beqx a $a0 $tp 'fwd)
(label a 'back)
(i-blt a $a0 $a1 'back)
(i-bge a $a0 $a1 'back)
(i-bgeu a $a0 $a1 'back)
(i-bnex a $a1 $a2 'back)
(i-j a 'fwd)
(i-jal a $ra 'back)
(i-la a $a0 'fwd)
(i-nop a)
(label a 'fwd)
(i-ret a)
(resolve a)
(define *asm-len* (asm-len a))
(define *asm-buf* (asm-buf a))
"#;

fn rust_side() -> Vec<u8> {
    let mut w: Vec<u32> = Vec::new();
    // Instructions the Lisp side emits wide although a shorter form exists:
    // the `-w` emitters, and `cmove` itself, which `mv` is the short form of.
    let mut wide: Vec<usize> = Vec::new();
    w.push(addi(A0, A1, -5));
    w.push(addi(A0, A1, 2047));
    w.push(addi(A0, A1, -2048));
    w.push(addi(A0, A1, 0));
    w.push(addi(A0, A0, 7));
    w.push(addi(A0, ZERO, -32));
    w.push(add(A0, A1, A2));
    w.push(sub(A0, A1, A2));
    w.push(sll(A0, A1, A2));
    w.push(slt(A0, A1, A2));
    w.push(sltu(A0, A1, A2));
    w.push(xor(A0, A1, A2));
    w.push(srl(A0, A1, A2));
    w.push(sra(A0, A1, A2));
    w.push(or(A0, A1, A2));
    w.push(and(A0, A1, A2));
    w.push(slti(A0, A1, -1));
    w.push(sltiu(A0, A1, 1));
    w.push(xori(A0, A1, -1));
    w.push(ori(A0, A1, 255));
    w.push(andi(A0, A1, -256));
    w.push(mul(S0, S1, S2));
    w.push(mulh(S0, S1, S2));
    w.push(mulhsu(S0, S1, S2));
    w.push(mulhu(S0, S1, S2));
    w.push(div(S0, S1, S2));
    w.push(divu(S0, S1, S2));
    w.push(rem(S0, S1, S2));
    w.push(remu(S0, S1, S2));
    w.push(slli(T0, T1, 31));
    w.push(srli(T0, T1, 1));
    w.push(srai(T0, T1, 17));
    w.push(lui(A0, 0xabcde));
    w.push(auipc(A0, 0x12345));
    w.push(lw(A0, A1, -100));
    w.push(lw(A0, A1, 64));
    w.push(lw(RA, SP, 12));
    w.push(lb(A0, A1, 7));
    w.push(lh(A0, A1, -2048));
    w.push(lbu(A0, A1, 2047));
    w.push(lhu(A0, A1, 0));
    w.push(sw(A2, SP, 44));
    w.push(sw(A2, A3, 124));
    w.push(sw(A2, T0, 8));
    w.push(sb(A2, SP, -44));
    w.push(sh(A2, SP, 2047));
    w.push(lc(A0, A1, -96));
    w.push(lc(A0, A1, 248));
    w.push(lc(A0, SP, 504));
    w.push(lc(A0, SP, 4));
    w.push(lc(T0, S1, 16));
    w.push(sc(A2, T0, 16));
    w.push(sc(A2, A3, 8));
    w.push(sc(A2, SP, 0));
    w.push(sc(ZERO, SP, 496));
    w.push(sc(A2, A3, 256));
    w.push(jalr(RA, A0, 16));
    w.push(jalr(ZERO, A0, 0));
    w.push(jalr(RA, T1, 0));
    w.push(ecall());
    w.push(ebreak());
    w.push(mret());
    w.push(wfi());
    w.push(csrrw(A0, 0x340, A1));
    w.push(csrrs(A0, 0x342, ZERO));
    w.push(csrrc(ZERO, 0x304, A1));
    w.push(csrrwi(ZERO, 0x300, 8));
    w.push(csrrsi(ZERO, 0x300, 8));
    w.push(csrrci(ZERO, 0x300, 8));
    w.push(cmove(A0, A1));
    w.push(cmove(SP, T0));
    w.push(cmove(A0, ZERO));
    wide.push(w.len());
    w.push(cmove(T0, T1));
    w.push(cincoffsetimm(SP, SP, -64));
    w.push(cincoffsetimm(SP, SP, 496));
    w.push(cincoffsetimm(SP, SP, -512));
    w.push(cincoffsetimm(SP, SP, 8));
    w.push(cincoffsetimm(S0, SP, 32));
    w.push(cincoffsetimm(A5, SP, 1020));
    w.push(cincoffsetimm(T0, SP, 16));
    w.push(cincoffsetimm(A0, A1, -2048));
    wide.push(w.len());
    w.push(cincoffsetimm(SP, SP, -16));
    w.push(cincoffset(A0, A1, A2));
    w.push(csetboundsimm(A0, GP, 16));
    w.push(csetboundsimm(A0, A1, 4095));
    w.push(csetbounds(A0, A1, A2));
    w.push(csetboundsexact(A0, A1, A2));
    w.push(cseal(A0, A1, A2));
    w.push(cunseal(A0, A1, A2));
    w.push(candperm(A0, A1, A2));
    w.push(csetaddr(A0, A1, A2));
    w.push(csub(A0, A1, A2));
    w.push(csethigh(A0, A1, A2));
    w.push(cbuildcap(A0, A1, A2));
    w.push(ctestsubset(A0, A1, A2));
    w.push(cseqx(A0, A1, A2));
    w.push(cspecialrw(T0, 1, ZERO));
    w.push(cspecialrw(ZERO, 28, T1));
    w.push(cspecialrw(T0, 30, T0));
    w.push(cspecialrw(A0, 31, ZERO));
    w.push(cgetperm(A0, A1));
    w.push(cgettype(A0, A1));
    w.push(cgetbase(A0, A1));
    w.push(cgetlen(A0, A1));
    w.push(cgettag(A0, A1));
    w.push(cgetsealed(A0, A1));
    w.push(cgetoffset(A0, A1));
    w.push(cgetaddr(A0, A1));
    w.push(cgethigh(A0, A1));
    w.push(cgettop(A0, A1));
    w.push(crrl(A0, A1));
    w.push(cram(A0, A1));
    w.push(ccleartag(A0, A1));
    w.push(csealentry(A0, A1));
    w.push(csealclo(A0, A1));
    w.push(cjalr(RA, T2));
    w.push(lb_ddc(A0, A1));
    w.push(lh_ddc(A0, A1));
    w.push(lw_ddc(A0, A1));
    w.push(lc_ddc(A0, A1));
    w.push(lbu_ddc(A0, A1));
    w.push(lhu_ddc(A0, A1));
    w.push(sb_ddc(A2, A1));
    w.push(sh_ddc(A2, A1));
    w.push(sw_ddc(A2, A1));
    w.push(sc_ddc(A2, A1));
    // Absolute addresses: base x0 is DDC with the offset as the address, and
    // anything out of its reach is formed in a register for the DDC form.
    w.push(lw(A0, ZERO, 0x108));
    li32(&mut w, A0, 0x1234_5678);
    w.push(lw_ddc(A0, A0));
    w.push(lc(A1, ZERO, 0x110));
    li32(&mut w, A1, 0xF000_0000);
    w.push(lc_ddc(A1, A1));
    w.push(sw(A2, ZERO, 0x100));
    li32(&mut w, T0, 0x20000);
    w.push(sw_ddc(A2, T0));
    w.push(sc(A2, ZERO, 0x1f8));
    li32(&mut w, T0, 0x4000);
    w.push(sc_ddc(A2, T0));
    w.push(car(A0, A1));
    w.push(cdr(T0, S1));
    w.push(setcar(A2, A3));
    w.push(setcdr(A2, A3));
    w.push(lref(A0, A1, -8));
    w.push(sref(A2, SP, 100));
    w.push(lvar(T1, T6, 8));
    w.push(vkind(A0, A1));
    w.push(jcl(RA, T0));
    w.push(lhdr(A0, A1, 3));
    w.push(lhdr(T2, A0, 0));
    w.push(ldx(A0, A1, A2, 3));
    w.push(stx(A3, A1, A2, 3));
    w.push(ldxb(T0, S1, A2, 2));
    w.push(stxb(T0, S1, A2, 4));
    w.push(ldx(A0, A1, A2, 0));
    w.push(ldxi(A0, A1, 0, 5));
    w.push(stxi(A3, A1, 31, 3));
    w.push(ldxbi(T0, S1, 7, 2));
    w.push(stxbi(T0, S1, 12, 4));
    w.push(faddi(A0, A1, -7));
    w.push(faddio(A0, A1, 2047));
    w.push(fandi(A0, A1, 2047));
    w.push(fori(A0, A1, -2048));
    w.push(fshi(A0, A1, 0, 31));
    w.push(fshi(A0, A1, 1, 3));
    w.push(fshi(A0, A1, 2, 17));
    w.push(fadd(A0, A1, A2));
    w.push(fsub(A0, A1, A2));
    w.push(fmul(T0, T1, T2));
    w.push(fdiv(T0, T1, T2));
    w.push(frem(T0, T1, T2));
    w.push(fand(S0, S1, A0));
    w.push(f_or(S0, S1, A0));
    w.push(fxor(S0, S1, A0));
    w.push(faddo(A0, A1, A2));
    w.push(fsubo(A0, A1, A2));
    w.push(fmulo(A0, A1, A2));
    w.push(fsll(A3, A4, A5));
    w.push(fsrl(A3, A4, A5));
    w.push(fsra(A3, A4, A5));
    w.push(flt(A3, A4, A5));
    w.push(fltu(A3, A4, A5));
    w.push(feq(A3, A4, A5));
    w.push(retag(A0, A1, 1, 0));
    w.push(retag(A0, A1, 0, 1));
    w.push(retag(T0, T1, 63, 2));
    w.push(sh1add(A0, A1, A2));
    w.push(sh2add(A0, A1, A2));
    w.push(sh3add(A0, A1, A2));
    w.push(andn(T0, T1, T2));
    w.push(orn(T0, T1, T2));
    w.push(xnor(T0, T1, T2));
    w.push(min(S0, S1, A0));
    w.push(minu(S0, S1, A0));
    w.push(max(S0, S1, A0));
    w.push(maxu(S0, S1, A0));
    w.push(rol(A1, A2, A3));
    w.push(ror(A1, A2, A3));
    w.push(rori(A1, A2, 13));
    w.push(bset(A0, A1, A2));
    w.push(bclr(A0, A1, A2));
    w.push(binv(A0, A1, A2));
    w.push(bext(A0, A1, A2));
    w.push(bseti(A0, A1, 31));
    w.push(bclri(A0, A1, 0));
    w.push(binvi(A0, A1, 17));
    w.push(bexti(A0, A1, 5));
    w.push(clz(T3, T4));
    w.push(ctz(T3, T4));
    w.push(cpop(T3, T4));
    w.push(sextb(T3, T4));
    w.push(sexth(T3, T4));
    w.push(zexth(T3, T4));
    w.push(rev8(T3, T4));
    w.push(orcb(T3, T4));
    w.push(czeroeqz(A0, A1, A2));
    w.push(czeronez(A0, A1, A2));
    w.push(sub(A0, ZERO, A1));
    w.push(xori(A0, A1, -1));
    w.push(sltiu(A0, A1, 1));
    w.push(sltu(A0, ZERO, A1));
    li32(&mut w, A0, 0x1234_5678);
    li32(&mut w, A0, -1i32 as u32);
    li32(&mut w, A0, 0x800);
    li32(&mut w, A0, 0xF000_0000);
    li32(&mut w, A0, 0x8000_0000);

    // Branch targets, counted in instructions from the first branch. Every
    // instruction from there to `fwd` is wide, so a distance is four bytes an
    // instruction:
    //   +0 beq  +1 bne  +2 bltu  +3 beqx  +4 back: blt  +5 bge  +6 bgeu
    //   +7 bnex  +8 j  +9 jal  +10 +11 la  +12 nop  +13 fwd: ret
    let here = w.len();
    let back = (here + 4) as i32;
    let fwd = (here + 13) as i32;
    let off = |from: usize, to: i32| (to - from as i32) * 4;
    w.push(beq(A0, A1, off(here, fwd)));
    w.push(bne(A0, ZERO, off(here + 1, fwd)));
    w.push(bltu(A1, A2, off(here + 2, fwd)));
    w.push(beqx(A0, TP, off(here + 3, fwd)));
    w.push(blt(A0, A1, off(here + 4, back)));
    w.push(bge(A0, A1, off(here + 5, back)));
    w.push(bgeu(A0, A1, off(here + 6, back)));
    w.push(bnex(A1, A2, off(here + 7, back)));
    w.push(jal(ZERO, off(here + 8, fwd)));
    w.push(jal(RA, off(here + 9, back)));
    // la is auipcc and cincoffsetimm, with the usual +0x800 rounding, and
    // stays wide because it is patched after placement.
    let d = off(here + 10, fwd);
    let lo = d & 0xfff;
    let lo = if lo >= 2048 { lo - 4096 } else { lo };
    let hi = ((d - lo) >> 12) & 0xfffff;
    w.push(auipc(A0, hi as u32));
    wide.push(w.len());
    w.push(cincoffsetimm(A0, A0, lo));
    w.push(addi(ZERO, ZERO, 0)); // nop
    w.push(jalr(ZERO, RA, 0)); // fwd: ret

    // The Lisp side compresses as it emits; this side builds wide instructions
    // and compresses at the end.
    let mut out = Vec::with_capacity(w.len() * 4);
    for (i, x) in w.into_iter().enumerate() {
        let c = if wide.contains(&i) { x } else { compress(x) };
        if c & 3 == 3 {
            out.extend_from_slice(&c.to_le_bytes());
        } else {
            out.extend_from_slice(&(c as u16).to_le_bytes());
        }
    }
    out
}

pub fn run() -> bool {
    let mut m = Machine::new();
    let mut l = Lisp::new(&mut m);
    if let Err(e) = boot_host(&mut l) {
        eprint!("{e}");
        return false;
    }
    if let Err(e) = l.eval_string(LISP_SIDE, "<asmdiff>") {
        eprint!("{e}");
        return false;
    }
    let len = crate::heap::unfix(l.global("*asm-len*")) as usize;
    let buf = l.global("*asm-buf*");
    let mut got = Vec::with_capacity(len);
    for i in 0..len {
        got.push(l.h.m.peek8(buf.addr + i as u32));
    }

    let want = rust_side();
    if got.len() != want.len() {
        println!(
            "asmdiff: length mismatch, lisp emitted {} bytes, rust {}",
            got.len(),
            want.len()
        );
        return false;
    }
    // Compared instruction by instruction, since lengths vary: a halfword whose
    // low two bits are not both set is a compressed instruction.
    let mut bad = 0;
    let mut n = 0;
    let mut i = 0;
    while i < want.len() {
        let half = u16::from_le_bytes([want[i], want[i + 1]]) as u32;
        let wide = half & 3 == 3;
        let sz = if wide { 4 } else { 2 };
        let pick = |v: &[u8]| -> u32 {
            if wide {
                u32::from_le_bytes([v[i], v[i + 1], v[i + 2], v[i + 3]])
            } else {
                u16::from_le_bytes([v[i], v[i + 1]]) as u32
            }
        };
        let (g, x) = (pick(&got), pick(&want));
        if g != x {
            println!("asmdiff: instruction {n:>3}: lisp {g:08x}  rust {x:08x}");
            bad += 1;
        }
        n += 1;
        i += sz;
    }
    if bad == 0 {
        println!("asmdiff: {n} instructions identical, {} bytes", want.len());
    } else {
        println!("asmdiff: {bad} of {n} instructions differ");
    }
    bad == 0
}
