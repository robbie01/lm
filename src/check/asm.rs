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
(i-ldx a $a0 $a1 $a2 3)
(i-stx a $a3 $a1 $a2 3)
(i-ldxb a $t0 $s1 $a2 2)
(i-stxb a $t0 $s1 $a2 4)
(i-ldx a $a0 $a1 $a2 0)
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
(define *asm-buf* (%vector-ref a 0))
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
    w.push(ldx(A0, A1, A2, 3));
    w.push(stx(A3, A1, A2, 3));
    w.push(ldxb(T0, S1, A2, 2));
    w.push(stxb(T0, S1, A2, 4));
    w.push(ldx(A0, A1, A2, 0));
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
    w.push(addi(A0, A0, lo));
    w.push(addi(ZERO, ZERO, 0)); // nop
    w.push(jalr(ZERO, RA, 0)); // fwd: ret

    let mut out = Vec::with_capacity(w.len() * 4);
    for x in w {
        out.extend_from_slice(&x.to_le_bytes());
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
    let len = crate::heap::unfix(l.global("asm:*asm-len*")) as usize;
    let buf = l.global("asm:*asm-buf*");
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
    let mut bad = 0;
    for i in (0..want.len()).step_by(4) {
        let g = u32::from_le_bytes([got[i], got[i + 1], got[i + 2], got[i + 3]]);
        let x = u32::from_le_bytes([want[i], want[i + 1], want[i + 2], want[i + 3]]);
        if g != x {
            println!("asmdiff: word {:>3}: lisp {g:08x}  rust {x:08x}", i / 4);
            bad += 1;
        }
    }
    if bad == 0 {
        println!("asmdiff: {} instructions identical", want.len() / 4);
    } else {
        println!("asmdiff: {bad} of {} instructions differ", want.len() / 4);
    }
    bad == 0
}
