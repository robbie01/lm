//! RV32IMC instruction encoders. Used to build test programs and, later, as
//! the reference the Lisp assembler is differential-tested against.

#![allow(dead_code)]

pub const ZERO: u32 = 0;
pub const RA: u32 = 1;
pub const SP: u32 = 2;
pub const GP: u32 = 3;
pub const TP: u32 = 4;
pub const T0: u32 = 5;
pub const T1: u32 = 6;
pub const T2: u32 = 7;
pub const S0: u32 = 8;
pub const S1: u32 = 9;
pub const A0: u32 = 10;
pub const A1: u32 = 11;
pub const A2: u32 = 12;
pub const A3: u32 = 13;
pub const A4: u32 = 14;
pub const A5: u32 = 15;
pub const A6: u32 = 16;
pub const A7: u32 = 17;
pub const S2: u32 = 18;
pub const T3: u32 = 28;
pub const T4: u32 = 29;
pub const T5: u32 = 30;
pub const T6: u32 = 31;

#[inline]
fn r_type(f7: u32, rs2: u32, rs1: u32, f3: u32, rd: u32, op: u32) -> u32 {
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
}
#[inline]
fn i_type(imm: i32, rs1: u32, f3: u32, rd: u32, op: u32) -> u32 {
    (((imm as u32) & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
}
#[inline]
fn s_type(imm: i32, rs2: u32, rs1: u32, f3: u32, op: u32) -> u32 {
    let i = imm as u32;
    ((i & 0xfe0) << 20) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1f) << 7) | op
}
#[inline]
fn b_type(imm: i32, rs2: u32, rs1: u32, f3: u32, op: u32) -> u32 {
    let i = imm as u32;
    ((i & 0x1000) << 19)
        | ((i & 0x7e0) << 20)
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | ((i & 0x1e) << 7)
        | ((i & 0x800) >> 4)
        | op
}
#[inline]
fn j_type(imm: i32, rd: u32, op: u32) -> u32 {
    let i = imm as u32;
    ((i & 0x100000) << 11)
        | ((i & 0x7fe) << 20)
        | ((i & 0x800) << 9)
        | (i & 0xff000)
        | (rd << 7)
        | op
}

pub fn lui(rd: u32, imm: u32) -> u32 {
    (imm & 0xfffff) << 12 | (rd << 7) | 0x37
}
pub fn auipc(rd: u32, imm: u32) -> u32 {
    (imm & 0xfffff) << 12 | (rd << 7) | 0x17
}
pub fn jal(rd: u32, off: i32) -> u32 {
    j_type(off, rd, 0x6f)
}
pub fn jalr(rd: u32, rs1: u32, off: i32) -> u32 {
    i_type(off, rs1, 0, rd, 0x67)
}

pub fn beq(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 0, 0x63)
}
pub fn bne(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 1, 0x63)
}
pub fn blt(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 4, 0x63)
}
pub fn bge(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 5, 0x63)
}
pub fn bltu(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 6, 0x63)
}
pub fn bgeu(a: u32, b: u32, o: i32) -> u32 {
    b_type(o, b, a, 7, 0x63)
}

pub fn lb(rd: u32, rs1: u32, o: i32) -> u32 {
    i_type(o, rs1, 0, rd, 0x03)
}
pub fn lh(rd: u32, rs1: u32, o: i32) -> u32 {
    i_type(o, rs1, 1, rd, 0x03)
}
pub fn lw(rd: u32, rs1: u32, o: i32) -> u32 {
    i_type(o, rs1, 2, rd, 0x03)
}
pub fn lbu(rd: u32, rs1: u32, o: i32) -> u32 {
    i_type(o, rs1, 4, rd, 0x03)
}
pub fn lhu(rd: u32, rs1: u32, o: i32) -> u32 {
    i_type(o, rs1, 5, rd, 0x03)
}
pub fn sb(rs2: u32, rs1: u32, o: i32) -> u32 {
    s_type(o, rs2, rs1, 0, 0x23)
}
pub fn sh(rs2: u32, rs1: u32, o: i32) -> u32 {
    s_type(o, rs2, rs1, 1, 0x23)
}
pub fn sw(rs2: u32, rs1: u32, o: i32) -> u32 {
    s_type(o, rs2, rs1, 2, 0x23)
}

// ---- B extension: Zba, Zbb, Zbs; and Zicond ----
// Ratified RISC-V, not our own. They are here because the collector's bit
// maps, the boolean materialisation and the compositor's clipping all want
// them, and because reaching for a standard extension is what keeps the
// custom opcodes small.
pub fn sh1add(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x10, rs2, rs1, 2, rd, 0x33)
}
pub fn sh2add(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x10, rs2, rs1, 4, rd, 0x33)
}
pub fn sh3add(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x10, rs2, rs1, 6, rd, 0x33)
}
pub fn andn(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x20, rs2, rs1, 7, rd, 0x33)
}
pub fn orn(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x20, rs2, rs1, 6, rd, 0x33)
}
pub fn xnor(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x20, rs2, rs1, 4, rd, 0x33)
}
pub fn min(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x05, rs2, rs1, 4, rd, 0x33)
}
pub fn minu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x05, rs2, rs1, 5, rd, 0x33)
}
pub fn max(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x05, rs2, rs1, 6, rd, 0x33)
}
pub fn maxu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x05, rs2, rs1, 7, rd, 0x33)
}
pub fn rol(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x30, rs2, rs1, 1, rd, 0x33)
}
pub fn ror(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x30, rs2, rs1, 5, rd, 0x33)
}
pub fn rori(rd: u32, rs1: u32, sh: u32) -> u32 {
    r_type(0x30, sh, rs1, 5, rd, 0x13)
}
pub fn bset(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x14, rs2, rs1, 1, rd, 0x33)
}
pub fn bclr(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x24, rs2, rs1, 1, rd, 0x33)
}
pub fn binv(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x34, rs2, rs1, 1, rd, 0x33)
}
pub fn bext(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x24, rs2, rs1, 5, rd, 0x33)
}
pub fn bseti(rd: u32, rs1: u32, sh: u32) -> u32 {
    r_type(0x14, sh, rs1, 1, rd, 0x13)
}
pub fn bclri(rd: u32, rs1: u32, sh: u32) -> u32 {
    r_type(0x24, sh, rs1, 1, rd, 0x13)
}
pub fn binvi(rd: u32, rs1: u32, sh: u32) -> u32 {
    r_type(0x34, sh, rs1, 1, rd, 0x13)
}
pub fn bexti(rd: u32, rs1: u32, sh: u32) -> u32 {
    r_type(0x24, sh, rs1, 5, rd, 0x13)
}
pub fn clz(rd: u32, rs1: u32) -> u32 {
    r_type(0x30, 0, rs1, 1, rd, 0x13)
}
pub fn ctz(rd: u32, rs1: u32) -> u32 {
    r_type(0x30, 1, rs1, 1, rd, 0x13)
}
pub fn cpop(rd: u32, rs1: u32) -> u32 {
    r_type(0x30, 2, rs1, 1, rd, 0x13)
}
pub fn sextb(rd: u32, rs1: u32) -> u32 {
    r_type(0x30, 4, rs1, 1, rd, 0x13)
}
pub fn sexth(rd: u32, rs1: u32) -> u32 {
    r_type(0x30, 5, rs1, 1, rd, 0x13)
}
pub fn zexth(rd: u32, rs1: u32) -> u32 {
    r_type(0x04, 0, rs1, 4, rd, 0x33)
}
pub fn rev8(rd: u32, rs1: u32) -> u32 {
    r_type(0x34, 0x18, rs1, 5, rd, 0x13)
}
pub fn orcb(rd: u32, rs1: u32) -> u32 {
    r_type(0x14, 7, rs1, 5, rd, 0x13)
}
pub fn czeroeqz(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x07, rs2, rs1, 5, rd, 0x33)
}
pub fn czeronez(rd: u32, rs1: u32, rs2: u32) -> u32 {
    r_type(0x07, rs2, rs1, 7, rd, 0x33)
}

// ---- custom-1: indexed access, checked ----
/// `ty` is the object type the access requires, or 0 for any object.
pub fn ldx(rd: u32, rs1: u32, rs2: u32, ty: u32) -> u32 {
    r_type(ty, rs2, rs1, 0, rd, 0x2b)
}
pub fn stx(rs3: u32, rs1: u32, rs2: u32, ty: u32) -> u32 {
    r_type(ty, rs2, rs1, 1, rs3, 0x2b)
}
pub fn ldxb(rd: u32, rs1: u32, rs2: u32, ty: u32) -> u32 {
    r_type(ty, rs2, rs1, 2, rd, 0x2b)
}
pub fn stxb(rs3: u32, rs1: u32, rs2: u32, ty: u32) -> u32 {
    r_type(ty, rs2, rs1, 3, rs3, 0x2b)
}
/// The same four, with the index as a five-bit immediate in the rs2 field.
pub fn ldxi(rd: u32, rs1: u32, i: u32, ty: u32) -> u32 {
    r_type(ty, i, rs1, 4, rd, 0x2b)
}
pub fn stxi(rs3: u32, rs1: u32, i: u32, ty: u32) -> u32 {
    r_type(ty, i, rs1, 5, rs3, 0x2b)
}
pub fn ldxbi(rd: u32, rs1: u32, i: u32, ty: u32) -> u32 {
    r_type(ty, i, rs1, 6, rd, 0x2b)
}
pub fn stxbi(rs3: u32, rs1: u32, i: u32, ty: u32) -> u32 {
    r_type(ty, i, rs1, 7, rs3, 0x2b)
}

// ---- custom-2: fixnum arithmetic, checked ----
fn fx(f7: u32, rd: u32, rs1: u32, rs2: u32, f3: u32) -> u32 {
    r_type(f7, rs2, rs1, f3, rd, 0x5b)
}
pub fn fadd(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 0)
}
pub fn fsub(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 1)
}
pub fn fmul(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 2)
}
pub fn fdiv(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 3)
}
pub fn frem(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 4)
}
pub fn fand(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 5)
}
pub fn f_or(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 6)
}
pub fn fxor(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x00, rd, rs1, rs2, 7)
}
/// The same five arithmetic forms, trapping rather than wrapping.
pub fn faddo(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x20, rd, rs1, rs2, 0)
}
pub fn fsubo(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x20, rd, rs1, rs2, 1)
}
pub fn fmulo(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x20, rd, rs1, rs2, 2)
}
pub fn fsll(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 0)
}
pub fn fsrl(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 1)
}
pub fn fsra(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 2)
}
pub fn flt(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 3)
}
pub fn fltu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 4)
}
pub fn feq(rd: u32, rs1: u32, rs2: u32) -> u32 {
    fx(0x01, rd, rs1, rs2, 5)
}

// ---- custom-3: a fixnum against a constant, and tagged-address memory ----
pub fn faddi(rd: u32, rs1: u32, imm: i32) -> u32 {
    i_type(imm, rs1, 0, rd, 0x7b)
}
pub fn fandi(rd: u32, rs1: u32, imm: i32) -> u32 {
    i_type(imm, rs1, 1, rd, 0x7b)
}
pub fn fori(rd: u32, rs1: u32, imm: i32) -> u32 {
    i_type(imm, rs1, 2, rd, 0x7b)
}
/// kind: 0 shift left, 1 shift right logical, 2 shift right arithmetic.
pub fn fshi(rd: u32, rs1: u32, kind: u32, sh: u32) -> u32 {
    i_type(((kind << 5) | sh) as i32, rs1, 3, rd, 0x7b)
}
pub fn tlw(rd: u32, rs1: u32, off: i32) -> u32 {
    i_type(off, rs1, 4, rd, 0x7b)
}
pub fn tlb(rd: u32, rs1: u32, off: i32) -> u32 {
    i_type(off, rs1, 5, rd, 0x7b)
}
pub fn tsw(rs2: u32, rs1: u32, off: i32) -> u32 {
    s_type(off, rs2, rs1, 6, 0x7b)
}
pub fn tsb(rs2: u32, rs1: u32, off: i32) -> u32 {
    s_type(off, rs2, rs1, 7, 0x7b)
}

// ---- custom-0: a load or store through a checked reference ----
/// LOAD and STORE shaped, always a word, funct3 saying what the base must be.
pub fn lref(rd: u32, rs1: u32, off: i32) -> u32 {
    i_type(off, rs1, 0, rd, 0x0b)
}
pub fn lobj(rd: u32, rs1: u32, off: i32) -> u32 {
    i_type(off, rs1, 1, rd, 0x0b)
}
pub fn sref(rs2: u32, rs1: u32, off: i32) -> u32 {
    s_type(off, rs2, rs1, 4, 0x0b)
}
pub fn sobj(rs2: u32, rs1: u32, off: i32) -> u32 {
    s_type(off, rs2, rs1, 5, 0x0b)
}
pub fn car(rd: u32, rs1: u32) -> u32 {
    lref(rd, rs1, 0)
}
pub fn cdr(rd: u32, rs1: u32) -> u32 {
    lref(rd, rs1, 4)
}
pub fn setcar(rs2: u32, rs1: u32) -> u32 {
    sref(rs2, rs1, 0)
}
pub fn setcdr(rs2: u32, rs1: u32) -> u32 {
    sref(rs2, rs1, 4)
}

pub fn addi(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 0, rd, 0x13)
}
pub fn slti(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 2, rd, 0x13)
}
pub fn sltiu(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 3, rd, 0x13)
}
pub fn xori(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 4, rd, 0x13)
}
pub fn ori(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 6, rd, 0x13)
}
pub fn andi(rd: u32, rs1: u32, i: i32) -> u32 {
    i_type(i, rs1, 7, rd, 0x13)
}
pub fn slli(rd: u32, rs1: u32, s: u32) -> u32 {
    r_type(0, s, rs1, 1, rd, 0x13)
}
pub fn srli(rd: u32, rs1: u32, s: u32) -> u32 {
    r_type(0, s, rs1, 5, rd, 0x13)
}
pub fn srai(rd: u32, rs1: u32, s: u32) -> u32 {
    r_type(0x20, s, rs1, 5, rd, 0x13)
}

pub fn add(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 0, rd, 0x33)
}
pub fn sub(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0x20, b, a, 0, rd, 0x33)
}
pub fn sll(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 1, rd, 0x33)
}
pub fn slt(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 2, rd, 0x33)
}
pub fn sltu(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 3, rd, 0x33)
}
pub fn xor(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 4, rd, 0x33)
}
pub fn srl(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 5, rd, 0x33)
}
pub fn sra(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0x20, b, a, 5, rd, 0x33)
}
pub fn or(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 6, rd, 0x33)
}
pub fn and(rd: u32, a: u32, b: u32) -> u32 {
    r_type(0, b, a, 7, rd, 0x33)
}

pub fn mul(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 0, rd, 0x33)
}
pub fn mulh(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 1, rd, 0x33)
}
pub fn mulhsu(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 2, rd, 0x33)
}
pub fn mulhu(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 3, rd, 0x33)
}
pub fn div(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 4, rd, 0x33)
}
pub fn divu(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 5, rd, 0x33)
}
pub fn rem(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 6, rd, 0x33)
}
pub fn remu(rd: u32, a: u32, b: u32) -> u32 {
    r_type(1, b, a, 7, rd, 0x33)
}

pub fn ecall() -> u32 {
    0x0000_0073
}
pub fn ebreak() -> u32 {
    0x0010_0073
}
pub fn mret() -> u32 {
    0x3020_0073
}
pub fn wfi() -> u32 {
    0x1050_0073
}
pub fn csrrw(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73
}
pub fn csrrs(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73
}
pub fn csrrc(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x73
}
pub fn csrrwi(rd: u32, csr: u32, i: u32) -> u32 {
    (csr << 20) | (i << 15) | (5 << 12) | (rd << 7) | 0x73
}
pub fn csrrsi(rd: u32, csr: u32, i: u32) -> u32 {
    (csr << 20) | (i << 15) | (6 << 12) | (rd << 7) | 0x73
}
pub fn csrrci(rd: u32, csr: u32, i: u32) -> u32 {
    (csr << 20) | (i << 15) | (7 << 12) | (rd << 7) | 0x73
}
pub fn fence() -> u32 {
    0x0ff0_000f
}

// -------------------------------------------------------------- compressed
pub fn c_addi(rd: u32, i: i32) -> u32 {
    let u = i as u32;
    0x0001 | (rd << 7) | ((u & 0x1f) << 2) | ((u & 0x20) << 7)
}
pub fn c_li(rd: u32, i: i32) -> u32 {
    let u = i as u32;
    0x4001 | (rd << 7) | ((u & 0x1f) << 2) | ((u & 0x20) << 7)
}
pub fn c_mv(rd: u32, rs: u32) -> u32 {
    0x8002 | (rd << 7) | (rs << 2)
}
pub fn c_add(rd: u32, rs: u32) -> u32 {
    0x9002 | (rd << 7) | (rs << 2)
}
pub fn c_jr(rs: u32) -> u32 {
    0x8002 | (rs << 7)
}
pub fn c_jalr(rs: u32) -> u32 {
    0x9002 | (rs << 7)
}
pub fn c_nop() -> u32 {
    0x0001
}
pub fn c_ebreak() -> u32 {
    0x9002
}
pub fn c_slli(rd: u32, s: u32) -> u32 {
    0x0002 | (rd << 7) | ((s & 0x1f) << 2) | ((s & 0x20) << 7)
}
pub fn c_lwsp(rd: u32, off: u32) -> u32 {
    0x4002 | (rd << 7) | ((off & 0x1c) << 2) | ((off & 0x20) << 7) | ((off & 0xc0) >> 4)
}
pub fn c_swsp(rs: u32, off: u32) -> u32 {
    0xc002 | (rs << 2) | ((off & 0x3c) << 7) | ((off & 0xc0) << 1)
}
/// rd must be x8..x15
pub fn c_lw(rd: u32, rs1: u32, off: u32) -> u32 {
    0x4000
        | ((rd - 8) << 2)
        | ((rs1 - 8) << 7)
        | ((off & 0x38) << 7)
        | ((off & 4) << 4)
        | ((off & 0x40) >> 1)
}
pub fn c_sw(rs2: u32, rs1: u32, off: u32) -> u32 {
    0xc000
        | ((rs2 - 8) << 2)
        | ((rs1 - 8) << 7)
        | ((off & 0x38) << 7)
        | ((off & 4) << 4)
        | ((off & 0x40) >> 1)
}
pub fn c_j(off: i32) -> u32 {
    0xa001 | cj_bits(off)
}
pub fn c_jal(off: i32) -> u32 {
    0x2001 | cj_bits(off)
}
fn cj_bits(off: i32) -> u32 {
    let i = off as u32;
    ((i & 0x800) << 1)
        | ((i & 0x10) << 7)
        | ((i & 0x300) << 1)
        | ((i & 0x400) >> 2)
        | ((i & 0x40) << 1)
        | ((i & 0x80) >> 1)
        | ((i & 0xe) << 2)
        | ((i & 0x20) >> 3)
}
pub fn c_beqz(rs: u32, off: i32) -> u32 {
    0xc001 | ((rs - 8) << 7) | cb_bits(off)
}
pub fn c_bnez(rs: u32, off: i32) -> u32 {
    0xe001 | ((rs - 8) << 7) | cb_bits(off)
}
fn cb_bits(off: i32) -> u32 {
    let i = off as u32;
    ((i & 0x100) << 4) | ((i & 0x18) << 7) | ((i & 0xc0) >> 1) | ((i & 0x6) << 2) | ((i & 0x20) >> 3)
}
pub fn c_addi4spn(rd: u32, i: u32) -> u32 {
    ((rd - 8) << 2) | ((i & 0x3c0) << 1) | ((i & 0x30) << 7) | ((i & 4) << 4) | ((i & 8) << 2)
}
pub fn c_addi16sp(i: i32) -> u32 {
    let u = i as u32;
    0x6101
        | ((u & 0x200) << 3)
        | ((u & 0x10) << 2)
        | ((u & 0x40) >> 1)
        | ((u & 0x180) >> 4)
        | ((u & 0x20) >> 3)
}
pub fn c_lui(rd: u32, i: i32) -> u32 {
    let u = i as u32;
    0x6001 | (rd << 7) | ((u & 0x1f) << 2) | ((u & 0x20) << 7)
}
pub fn c_srli(rd: u32, s: u32) -> u32 {
    0x8001 | ((rd - 8) << 7) | ((s & 0x1f) << 2) | ((s & 0x20) << 7)
}
pub fn c_srai(rd: u32, s: u32) -> u32 {
    0x8401 | ((rd - 8) << 7) | ((s & 0x1f) << 2) | ((s & 0x20) << 7)
}
pub fn c_andi(rd: u32, i: i32) -> u32 {
    let u = i as u32;
    0x8801 | ((rd - 8) << 7) | ((u & 0x1f) << 2) | ((u & 0x20) << 7)
}
pub fn c_sub(rd: u32, rs: u32) -> u32 {
    0x8c01 | ((rd - 8) << 7) | ((rs - 8) << 2)
}
pub fn c_xor(rd: u32, rs: u32) -> u32 {
    0x8c21 | ((rd - 8) << 7) | ((rs - 8) << 2)
}
pub fn c_or(rd: u32, rs: u32) -> u32 {
    0x8c41 | ((rd - 8) << 7) | ((rs - 8) << 2)
}
pub fn c_and(rd: u32, rs: u32) -> u32 {
    0x8c61 | ((rd - 8) << 7) | ((rs - 8) << 2)
}

/// Load an arbitrary 32-bit constant into `rd`. Emits one or two words.
pub fn li32(out: &mut Vec<u32>, rd: u32, v: u32) {
    if (v as i32) >= -2048 && (v as i32) < 2048 {
        out.push(addi(rd, ZERO, v as i32));
    } else {
        let hi = (v.wrapping_add(0x800)) >> 12;
        let lo = (v & 0xfff) as i32;
        let lo = if lo >= 2048 { lo - 4096 } else { lo };
        out.push(lui(rd, hi));
        if lo != 0 {
            out.push(addi(rd, rd, lo));
        }
    }
}
