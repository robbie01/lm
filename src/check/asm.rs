//! Differential test for the Lisp assembler.
//!
//! The same instruction sequence is written twice - once in Lisp, once with
//! the Rust encoders - and the two byte streams must match exactly. The
//! duplication is the point: two independent encodings of the RISC-V manual
//! agreeing is real evidence, one encoding agreeing with itself is not.

use crate::forge::boot_host;
use crate::forge::hostlisp::Lisp;
use crate::mach::Machine;
use crate::rvenc::*;

/// The Lisp half. Leaves the placed address in the global `*asm-start*` and
/// the length in `*asm-len*`.
const LISP_SIDE: &str = r#"
(in-package asm)
(define a (asm-new))
(i-addi a $a0 $a1 -5)
(i-addi a $a0 $a1 2047)
(i-addi a $a0 $a1 -2048)
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
(i-lb a $a0 $a1 7)
(i-lh a $a0 $a1 -2048)
(i-lbu a $a0 $a1 2047)
(i-lhu a $a0 $a1 0)
(i-sw a $a2 $sp 44)
(i-sb a $a2 $sp -44)
(i-sh a $a2 $sp 2047)
(i-jalr a $ra $a0 16)
(i-ecall a)
(i-ebreak a)
(i-mret a)
(i-wfi a)
(i-csrrw a $a0 #x340 $a1)
(i-csrrs a $a0 #x342 $zero)
(i-csrrc a $zero #x304 $a1)
(i-csrrwi a $zero #x300 8)
(i-car a $a0 $a1)
(i-cdr a $t0 $s1)
(i-set-car a $a2 $a3)
(i-set-cdr a $a2 $a3)
(i-lref a $a0 $a1 -8)
(i-lobj a $t0 $s1 2047)
(i-sref a $a2 $sp 100)
(i-sobj a $a2 $sp -2048)
(i-ldx a $a0 $a1 $a2 3)
(i-stx a $a3 $a1 $a2 3)
(i-ldxb a $t0 $s1 $a2 2)
(i-stxb a $t0 $s1 $a2 4)
(i-ldx a $a0 $a1 $a2 0)
(i-ldxi a $a0 $a1 0 5)
(i-stxi a $a3 $a1 31 3)
(i-ldxbi a $t0 $s1 7 2)
(i-stxbi a $t0 $s1 12 4)
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
(i-faddi a $a0 $a1 -7)
(i-fandi a $a0 $a1 2047)
(i-fori a $a0 $a1 -2048)
(i-fshi a $a0 $a1 0 31)
(i-fshi a $a0 $a1 1 3)
(i-fshi a $a0 $a1 2 17)
(i-tlw a $a0 $a1 100)
(i-tlb a $t0 $s1 -4)
(i-tsw a $a2 $sp 44)
(i-tsb a $a2 $sp -44)
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
(i-li a $a0 #x12345678)
(i-li a $a0 -1)
(i-li a $a0 #x800)
(i-li a $a0 mmio-base)
(i-beq a $a0 $a1 'fwd)
(i-bne a $a0 $zero 'fwd)
(i-bltu a $a1 $a2 'fwd)
(asm-label a 'back)
(i-blt a $a0 $a1 'back)
(i-bge a $a0 $a1 'back)
(i-bgeu a $a0 $a1 'back)
(i-j a 'fwd)
(i-jal a $ra 'back)
(i-la a $a0 'fwd)
(i-nop a)
(asm-label a 'fwd)
(i-ret a)
(asm-resolve a)
(define *asm-len* (asm-len a))
(define *asm-buf* (asm-buf a))
"#;

fn rust_side() -> Vec<u8> {
    let mut w: Vec<u32> = Vec::new();
    w.push(addi(A0, A1, -5));
    w.push(addi(A0, A1, 2047));
    w.push(addi(A0, A1, -2048));
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
    w.push(mul(S0, S1, 18));
    w.push(mulh(S0, S1, 18));
    w.push(mulhsu(S0, S1, 18));
    w.push(mulhu(S0, S1, 18));
    w.push(div(S0, S1, 18));
    w.push(divu(S0, S1, 18));
    w.push(rem(S0, S1, 18));
    w.push(remu(S0, S1, 18));
    w.push(slli(T0, T1, 31));
    w.push(srli(T0, T1, 1));
    w.push(srai(T0, T1, 17));
    w.push(lui(A0, 0xabcde));
    w.push(auipc(A0, 0x12345));
    w.push(lw(A0, A1, -100));
    w.push(lb(A0, A1, 7));
    w.push(lh(A0, A1, -2048));
    w.push(lbu(A0, A1, 2047));
    w.push(lhu(A0, A1, 0));
    w.push(sw(A2, SP, 44));
    w.push(sb(A2, SP, -44));
    w.push(sh(A2, SP, 2047));
    w.push(jalr(RA, A0, 16));
    w.push(ecall());
    w.push(ebreak());
    w.push(mret());
    w.push(wfi());
    w.push(csrrw(A0, 0x340, A1));
    w.push(csrrs(A0, 0x342, ZERO));
    w.push(csrrc(ZERO, 0x304, A1));
    w.push(csrrwi(ZERO, 0x300, 8));
    w.push(car(A0, A1));
    w.push(cdr(T0, S1));
    w.push(setcar(A2, A3));
    w.push(setcdr(A2, A3));
    w.push(lref(A0, A1, -8));
    w.push(lobj(T0, S1, 2047));
    w.push(sref(A2, SP, 100));
    w.push(sobj(A2, SP, -2048));
    w.push(ldx(A0, A1, A2, 3));
    w.push(stx(A3, A1, A2, 3));
    w.push(ldxb(T0, S1, A2, 2));
    w.push(stxb(T0, S1, A2, 4));
    w.push(ldx(A0, A1, A2, 0));
    w.push(ldxi(A0, A1, 0, 5));
    w.push(stxi(A3, A1, 31, 3));
    w.push(ldxbi(T0, S1, 7, 2));
    w.push(stxbi(T0, S1, 12, 4));
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
    w.push(faddi(A0, A1, -7));
    w.push(fandi(A0, A1, 2047));
    w.push(fori(A0, A1, -2048));
    w.push(fshi(A0, A1, 0, 31));
    w.push(fshi(A0, A1, 1, 3));
    w.push(fshi(A0, A1, 2, 17));
    w.push(tlw(A0, A1, 100));
    w.push(tlb(T0, S1, -4));
    w.push(tsw(A2, SP, 44));
    w.push(tsb(A2, SP, -44));
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
    li32(&mut w, A0, 0x1234_5678);
    li32(&mut w, A0, -1i32 as u32);
    li32(&mut w, A0, 0x800);
    li32(&mut w, A0, 0xF000_0000);

    // Branch targets, counted in instructions from here.
    let here = w.len(); // index of the first branch
    let n_after = 9; // beq bne bltu back: blt bge bgeu j jal, then la(2) nop
    let _ = n_after;
    // Lay the rest out explicitly so the offsets are obvious.
    // indices: here+0 beq, +1 bne, +2 bltu, +3 blt(back=+3), +4 bge, +5 bgeu,
    //          +6 j, +7 jal, +8..+9 la, +10 nop, +11 fwd: ret
    let back = (here + 3) as i32;
    let fwd = (here + 11) as i32;
    let off = |from: usize, to: i32| (to - from as i32) * 4;
    w.push(beq(A0, A1, off(here, fwd)));
    w.push(bne(A0, ZERO, off(here + 1, fwd)));
    w.push(bltu(A1, A2, off(here + 2, fwd)));
    w.push(blt(A0, A1, off(here + 3, back)));
    w.push(bge(A0, A1, off(here + 4, back)));
    w.push(bgeu(A0, A1, off(here + 5, back)));
    w.push(jal(ZERO, off(here + 6, fwd)));
    w.push(jal(RA, off(here + 7, back)));
    // la = auipc + addi, with the usual +0x800 rounding
    let d = off(here + 8, fwd);
    let lo = d & 0xfff;
    let lo = if lo >= 2048 { lo - 4096 } else { lo };
    let hi = ((d - lo) >> 12) & 0xfffff;
    w.push(auipc(A0, hi as u32));
    // `la` patches itself later and so keeps its width on both sides.
    let la_addi = w.len();
    w.push(addi(A0, A0, lo));
    w.push(addi(ZERO, ZERO, 0)); // nop
    w.push(jalr(ZERO, RA, 0)); // fwd: ret

    // The Lisp side compresses as it emits; this side builds wide instructions
    // and compresses at the end. Two routes to the same bytes, which is the
    // point of having two encoders.
    let mut out = Vec::with_capacity(w.len() * 4);
    for (i, x) in w.into_iter().enumerate() {
        let c = if i == la_addi { x } else { compress(x) };
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
        got.push(l.h.m.peek8(buf + i as u32));
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
    // Instruction by instruction, because they are not all the same length any
    // more: a halfword whose low two bits are not both set is a compressed one.
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
