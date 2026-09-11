//! Processor conformance tests. Each case assembles a small program, runs it,
//! and checks a register or a memory word. The point is to catch decode bugs
//! before anything is built on top of the core.

use crate::mach::*;
use crate::map::*;
use crate::run;
use crate::rvenc::*;

const BASE: u32 = 0x0010_0000;

struct Case {
    name: &'static str,
    code: Vec<u32>,
    want: u32,
    reg: u32,
}

/// Assemble a word list into memory. Values below 0x10000 with the low two
/// bits not equal to 3 are emitted as 16-bit compressed instructions.
fn emit(m: &mut Machine, at: u32, code: &[u32]) -> u32 {
    let mut pc = at;
    for &w in code {
        if w & 3 == 3 || w > 0xffff {
            m.poke32(pc, w);
            pc += 4;
        } else {
            m.poke32(pc, (m.peek32(pc) & 0xffff_0000) | (w & 0xffff));
            m.poke8(pc, w as u8);
            m.poke8(pc + 1, (w >> 8) as u8);
            pc += 2;
        }
    }
    pc
}

fn go(code: &[u32]) -> Box<Machine> {
    let mut m = Machine::new();
    let end = emit(&mut m, BASE, code);
    // Park on a store to SYS_HALT so the machine stops itself and the budget
    // can stay generous. t0 is not used by any test body.
    let mut tail = vec![];
    li32(&mut tail, T0, MMIO_BASE);
    tail.push(sw(ZERO, T0, 0));
    emit(&mut m, end, &tail);
    // Somewhere for an unexpected trap to go. A case that faults should fail
    // its assertion, not vanish into a handler that is not there.
    let mut stub = vec![];
    li32(&mut stub, T0, MMIO_BASE);
    stub.push(addi(T1, ZERO, 1));
    stub.push(sw(T1, T0, 0));
    emit(&mut m, 0x2000, &stub);
    m.mtvec = 0x2000;
    m.pc = BASE;
    m.mtimecmp = u64::MAX;
    m.gfx.next_vbl = u64::MAX;
    run::run(&mut m, 100_000);
    m
}

fn cases() -> Vec<Case> {
    let mut v: Vec<Case> = Vec::new();
    let mut c = |name: &'static str, code: Vec<u32>, reg: u32, want: u32| {
        v.push(Case {
            name,
            code,
            want,
            reg,
        })
    };

    // ---- arithmetic and immediates ----
    c("addi", vec![addi(A0, ZERO, 42)], A0, 42);
    c("addi neg", vec![addi(A0, ZERO, -1)], A0, 0xffff_ffff);
    c(
        "add",
        vec![addi(A0, ZERO, 7), addi(A1, ZERO, 35), add(A0, A0, A1)],
        A0,
        42,
    );
    c(
        "sub wrap",
        vec![addi(A0, ZERO, 1), addi(A1, ZERO, 2), sub(A0, A0, A1)],
        A0,
        0xffff_ffff,
    );
    c("lui", vec![lui(A0, 0xabcde)], A0, 0xabcd_e000);

    // ---- custom-2: checked fixnum arithmetic ----
    // A fixnum is 2n+1, so 5 is 11, 3 is 7, and 0 is 1.
    let two = |x: i32, y: i32, op: fn(u32, u32, u32) -> u32| -> Vec<u32> {
        vec![addi(A1, ZERO, x * 2 + 1), addi(A2, ZERO, y * 2 + 1), op(A0, A1, A2)]
    };
    c("fadd", two(5, 3, fadd), A0, 17); // 8
    c("fadd negative", two(5, -8, fadd), A0, (-3i32 * 2 + 1) as u32);
    c("fsub", two(5, 3, fsub), A0, 5); // 2
    c("fmul", two(5, 3, fmul), A0, 31); // 15
    c("fdiv", two(15, 3, fdiv), A0, 11); // 5
    c("fdiv truncates", two(-7, 2, fdiv), A0, (-3i32 * 2 + 1) as u32);
    c("frem", two(17, 5, frem), A0, 5); // 2
    c("fand", two(12, 10, fand), A0, 17); // 8
    c("for", two(12, 10, f_or), A0, 29); // 14
    c("fxor", two(12, 10, fxor), A0, 13); // 6
    c("fsll", two(3, 2, fsll), A0, 25); // 12
    c("fsrl", two(12, 2, fsrl), A0, 7); // 3
    c("fsra", two(-8, 1, fsra), A0, (-4i32 * 2 + 1) as u32);
    c("flt", two(3, 5, flt), A0, 1);
    c("flt not", two(5, 3, flt), A0, 0);
    c("flt signed", two(-1, 1, flt), A0, 1);
    c("feq", two(5, 5, feq), A0, 1);
    c("feq not", two(5, 4, feq), A0, 0);
    // Wrapping is what the software sequences always did, and string-hash
    // depends on it.
    // 3 * 2^29 does not fit in thirty-one bits. Wrapping is what the software
    // sequence always did, and `string-hash` depends on it.
    {
        let mut v = vec![addi(A1, ZERO, 7)];
        li32(&mut v, A2, (1u32 << 30) | 1);
        v.push(fmul(A0, A1, A2));
        c("fmul wraps", v, A0, ((3u32 << 29) << 1) | 1);
    }

    // ---- custom-3: a constant, and memory through a tagged address ----
    c("faddi", vec![addi(A1, ZERO, 11), faddi(A0, A1, -7)], A0, (-2i32 * 2 + 1) as u32);
    c("fandi", vec![addi(A1, ZERO, 25), fandi(A0, A1, 10)], A0, 17);
    c("fori", vec![addi(A1, ZERO, 25), fori(A0, A1, 10)], A0, 29);
    c("fshi left", vec![addi(A1, ZERO, 7), fshi(A0, A1, 0, 2)], A0, 25);
    c("fshi right", vec![addi(A1, ZERO, 25), fshi(A0, A1, 1, 2)], A0, 7);
    c(
        "fshi arithmetic",
        vec![addi(A1, ZERO, -15), fshi(A0, A1, 2, 1)],
        A0,
        (-4i32 * 2 + 1) as u32,
    );
    // A tagged address: 0x3000 is held as 0x6001.
    c(
        "tsw then tlw",
        vec![
            lui(A1, 6),
            addi(A1, A1, 1),
            addi(A2, ZERO, 43), // the fixnum 21
            tsw(A2, A1, 8),
            tlw(A0, A1, 8),
        ],
        A0,
        43,
    );
    c(
        "tsb then tlb",
        vec![
            lui(A1, 6),
            addi(A1, A1, 1),
            addi(A2, ZERO, 511), // the fixnum 255
            tsb(A2, A1, 3),
            tlb(A0, A1, 3),
        ],
        A0,
        511,
    );

    // ---- B extension: Zba, Zbb, Zbs, and Zicond ----
    c(
        "sh2add",
        vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh2add(A0, A1, A2)],
        A0,
        112,
    );
    c(
        "sh3add",
        vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh3add(A0, A1, A2)],
        A0,
        124,
    );
    c(
        "sh1add",
        vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh1add(A0, A1, A2)],
        A0,
        106,
    );
    c(
        "andn",
        vec![addi(A1, ZERO, 0xff), addi(A2, ZERO, 0x0f), andn(A0, A1, A2)],
        A0,
        0xf0,
    );
    c(
        "orn",
        vec![addi(A1, ZERO, 1), addi(A2, ZERO, 2), orn(A0, A1, A2)],
        A0,
        0xffff_fffd,
    );
    c(
        "xnor",
        vec![addi(A1, ZERO, 5), addi(A2, ZERO, 3), xnor(A0, A1, A2)],
        A0,
        0xffff_fff9,
    );
    c(
        "min signed",
        vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), min(A0, A1, A2)],
        A0,
        0xffff_fffb,
    );
    c(
        "minu unsigned",
        vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), minu(A0, A1, A2)],
        A0,
        3,
    );
    c(
        "max signed",
        vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), max(A0, A1, A2)],
        A0,
        3,
    );
    c(
        "maxu unsigned",
        vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), maxu(A0, A1, A2)],
        A0,
        0xffff_fffb,
    );
    // Tagged fixnums are 2n+1, so signed order survives tagging and max works
    // on tagged values as they stand: max(2*-5+1, 2*3+1) = 7 = the tag of 3.
    c(
        "max on tagged fixnums",
        vec![addi(A1, ZERO, -9), addi(A2, ZERO, 7), max(A0, A1, A2)],
        A0,
        7,
    );
    c("cpop", vec![addi(A1, ZERO, -1), cpop(A0, A1)], A0, 32);
    c("cpop of 0", vec![cpop(A0, ZERO)], A0, 0);
    c("clz", vec![addi(A1, ZERO, 1), clz(A0, A1)], A0, 31);
    c("ctz", vec![addi(A1, ZERO, 8), ctz(A0, A1)], A0, 3);
    c("sext.b", vec![addi(A1, ZERO, 0xff), sextb(A0, A1)], A0, 0xffff_ffff);
    c("sext.h", vec![lui(A1, 8), sexth(A0, A1)], A0, 0xffff_8000);
    c("zext.h", vec![addi(A1, ZERO, -1), zexth(A0, A1)], A0, 0xffff);
    c("rev8", vec![addi(A1, ZERO, 0x123), rev8(A0, A1)], A0, 0x2301_0000);
    c("orc.b", vec![addi(A1, ZERO, 0x100), orcb(A0, A1)], A0, 0xff00);
    c(
        "rol",
        vec![lui(A1, 0x80000), addi(A2, ZERO, 1), rol(A0, A1, A2)],
        A0,
        1,
    );
    c(
        "ror",
        vec![addi(A1, ZERO, 1), addi(A2, ZERO, 1), ror(A0, A1, A2)],
        A0,
        0x8000_0000,
    );
    c("rori", vec![addi(A1, ZERO, 1), rori(A0, A1, 4)], A0, 0x1000_0000);
    c(
        "bset",
        vec![addi(A2, ZERO, 31), bset(A0, ZERO, A2)],
        A0,
        0x8000_0000,
    );
    c(
        "bclr",
        vec![addi(A1, ZERO, -1), addi(A2, ZERO, 0), bclr(A0, A1, A2)],
        A0,
        0xffff_fffe,
    );
    c(
        "binv",
        vec![addi(A1, ZERO, 1), addi(A2, ZERO, 0), binv(A0, A1, A2)],
        A0,
        0,
    );
    c(
        "bext",
        vec![addi(A1, ZERO, 8), addi(A2, ZERO, 3), bext(A0, A1, A2)],
        A0,
        1,
    );
    c(
        "bext off",
        vec![addi(A1, ZERO, 8), addi(A2, ZERO, 2), bext(A0, A1, A2)],
        A0,
        0,
    );
    // The shift amount is taken modulo 32, so a bit index past the word wraps
    // rather than reading nothing.
    c(
        "bext wraps at 32",
        vec![addi(A1, ZERO, 8), addi(A2, ZERO, 35), bext(A0, A1, A2)],
        A0,
        1,
    );
    c("bseti", vec![bseti(A0, ZERO, 31)], A0, 0x8000_0000);
    c("bclri", vec![addi(A1, ZERO, -1), bclri(A0, A1, 0)], A0, 0xffff_fffe);
    c("binvi", vec![addi(A1, ZERO, 1), binvi(A0, A1, 0)], A0, 0);
    c("bexti", vec![addi(A1, ZERO, 8), bexti(A0, A1, 3)], A0, 1);
    // czero.eqz: rd is zero when rs2 is zero, otherwise rs1.
    c(
        "czero.eqz taken",
        vec![addi(A1, ZERO, 42), czeroeqz(A0, A1, ZERO)],
        A0,
        0,
    );
    c(
        "czero.eqz not taken",
        vec![addi(A1, ZERO, 42), addi(A2, ZERO, 1), czeroeqz(A0, A1, A2)],
        A0,
        42,
    );
    c(
        "czero.nez taken",
        vec![addi(A1, ZERO, 42), addi(A2, ZERO, 1), czeronez(A0, A1, A2)],
        A0,
        0,
    );
    c(
        "czero.nez not taken",
        vec![addi(A1, ZERO, 42), czeronez(A0, A1, ZERO)],
        A0,
        42,
    );
    c("auipc", vec![auipc(A0, 1)], A0, BASE + 0x1000);
    c("x0 stays zero", vec![addi(ZERO, ZERO, 99), add(A0, ZERO, ZERO)], A0, 0);
    c(
        "slti signed",
        vec![addi(A0, ZERO, -5), slti(A1, A0, -4)],
        A1,
        1,
    );
    c(
        "sltiu unsigned",
        vec![addi(A0, ZERO, -5), sltiu(A1, A0, -4)],
        A1,
        1,
    );
    c(
        "sltiu vs zero",
        vec![addi(A0, ZERO, -1), sltiu(A1, A0, 1)],
        A1,
        0,
    );
    c(
        "shifts",
        vec![addi(A0, ZERO, -16), srai(A1, A0, 2), srli(A2, A0, 28)],
        A1,
        0xffff_fffc,
    );
    c(
        "srli high",
        vec![addi(A0, ZERO, -16), srli(A2, A0, 28)],
        A2,
        0xf,
    );
    c(
        "sll by reg mod32",
        vec![addi(A0, ZERO, 1), addi(A1, ZERO, 33), sll(A2, A0, A1)],
        A2,
        2,
    );
    c(
        "sra by reg",
        vec![lui(A0, 0x80000), addi(A1, ZERO, 31), sra(A2, A0, A1)],
        A2,
        0xffff_ffff,
    );
    c(
        "xori inverts",
        vec![addi(A0, ZERO, 0x55), xori(A1, A0, -1)],
        A1,
        0xffff_ffaa,
    );

    // ---- M extension ----
    c(
        "mul",
        vec![addi(A0, ZERO, -6), addi(A1, ZERO, 7), mul(A2, A0, A1)],
        A2,
        (-42i32) as u32,
    );
    c(
        "mulh",
        vec![lui(A0, 0x10000), addi(A1, ZERO, 16), mulh(A2, A0, A1)],
        A2,
        // 0x10000000 * 16 = 0x1_00000000, high word 1
        1,
    );
    c(
        "mulhu",
        vec![addi(A0, ZERO, -1), addi(A1, ZERO, -1), mulhu(A2, A0, A1)],
        A2,
        0xffff_fffe,
    );
    c(
        "mulhsu",
        vec![addi(A0, ZERO, -1), addi(A1, ZERO, -1), mulhsu(A2, A0, A1)],
        A2,
        0xffff_ffff,
    );
    c(
        "div signed",
        vec![addi(A0, ZERO, -7), addi(A1, ZERO, 2), div(A2, A0, A1)],
        A2,
        (-3i32) as u32,
    );
    c(
        "rem signed",
        vec![addi(A0, ZERO, -7), addi(A1, ZERO, 2), rem(A2, A0, A1)],
        A2,
        (-1i32) as u32,
    );
    c(
        "div by zero",
        vec![addi(A0, ZERO, 5), div(A2, A0, ZERO)],
        A2,
        0xffff_ffff,
    );
    c(
        "rem by zero",
        vec![addi(A0, ZERO, 5), rem(A2, A0, ZERO)],
        A2,
        5,
    );
    c(
        "div overflow",
        vec![lui(A0, 0x80000), addi(A1, ZERO, -1), div(A2, A0, A1)],
        A2,
        0x8000_0000,
    );
    c(
        "rem overflow",
        vec![lui(A0, 0x80000), addi(A1, ZERO, -1), rem(A2, A0, A1)],
        A2,
        0,
    );
    c(
        "divu",
        vec![addi(A0, ZERO, -1), addi(A1, ZERO, 2), divu(A2, A0, A1)],
        A2,
        0x7fff_ffff,
    );

    // ---- branches ----
    c(
        "beq taken",
        vec![
            addi(A0, ZERO, 1),
            beq(ZERO, ZERO, 8),
            addi(A0, ZERO, 2),
            addi(A1, ZERO, 0),
        ],
        A0,
        1,
    );
    c(
        "bne backwards loop",
        vec![
            addi(A0, ZERO, 0),
            addi(A1, ZERO, 5),
            // loop:
            addi(A0, A0, 3),
            addi(A1, A1, -1),
            bne(A1, ZERO, -8),
        ],
        A0,
        15,
    );
    c(
        "blt signed",
        vec![
            addi(A0, ZERO, -1),
            addi(A1, ZERO, 1),
            addi(A2, ZERO, 0),
            blt(A0, A1, 8),
            addi(A2, ZERO, 9),
        ],
        A2,
        0,
    );
    c(
        "bltu unsigned",
        vec![
            addi(A0, ZERO, -1),
            addi(A1, ZERO, 1),
            addi(A2, ZERO, 0),
            bltu(A0, A1, 8),
            addi(A2, ZERO, 9),
        ],
        A2,
        9,
    );
    c(
        "bgeu",
        vec![
            addi(A0, ZERO, -1),
            addi(A2, ZERO, 0),
            bgeu(A0, ZERO, 8),
            addi(A2, ZERO, 9),
        ],
        A2,
        0,
    );

    // ---- jumps ----
    c(
        "jal links",
        vec![jal(RA, 8), addi(A0, ZERO, 1), addi(A0, ZERO, 2)],
        RA,
        BASE + 4,
    );
    c(
        "jalr clears bit 0",
        vec![
            auipc(A1, 0),
            addi(A1, A1, 13), // odd target, 12 bytes ahead + 1
            jalr(RA, A1, 0),
            addi(A0, ZERO, 1),
            addi(A0, ZERO, 7),
        ],
        A0,
        7,
    );
    c("jal negative", vec![jal(ZERO, 8), jal(ZERO, 8), jal(ZERO, -4)], ZERO, 0);

    // ---- memory ----
    {
        let mut code = vec![];
        li32(&mut code, A1, 0x2000);
        li32(&mut code, A0, 0x1234_5678);
        code.push(sw(A0, A1, 0));
        code.push(lw(A2, A1, 0));
        code.push(lbu(A3, A1, 0));
        code.push(lb(A4, A1, 3));
        code.push(lhu(A5, A1, 2));
        c("store/load word", code.clone(), A2, 0x1234_5678);
        c("lbu low byte", code.clone(), A3, 0x78);
        c("lb sign extends", code.clone(), A4, 0x12);
        c("lhu high half", code, A5, 0x1234);
    }
    {
        let mut code = vec![];
        li32(&mut code, A1, 0x2000);
        li32(&mut code, A0, -1i32 as u32);
        code.push(sw(A0, A1, 0));
        code.push(addi(A0, ZERO, 0));
        code.push(sh(A0, A1, 0));
        code.push(lw(A2, A1, 0));
        c("sh writes half only", code, A2, 0xffff_0000);
    }
    {
        // unaligned access is serviced, not trapped
        let mut code = vec![];
        li32(&mut code, A1, 0x2001);
        li32(&mut code, A0, 0xdead_beef);
        code.push(sw(A0, A1, 0));
        code.push(lw(A2, A1, 0));
        c("unaligned word", code, A2, 0xdead_beef);
    }
    {
        // negative store offset
        let mut code = vec![];
        li32(&mut code, A1, 0x2000);
        code.push(addi(A0, ZERO, 99));
        code.push(sw(A0, A1, -8));
        code.push(lw(A2, A1, -8));
        c("negative offset", code, A2, 99);
    }

    // ---- compressed forms ----
    c("c.li", vec![c_li(A0, -3)], A0, 0xffff_fffd);
    c("c.addi", vec![c_li(A0, 5), c_addi(A0, 31)], A0, 36);
    c("c.addi neg", vec![c_li(A0, 5), c_addi(A0, -32)], A0, (-27i32) as u32);
    c("c.mv", vec![c_li(A1, 21), c_mv(A0, A1)], A0, 21);
    c("c.add", vec![c_li(A0, 20), c_li(A1, 22), c_add(A0, A1)], A0, 42);
    c("c.lui", vec![c_lui(A0, 1)], A0, 0x1000);
    c("c.lui neg", vec![c_lui(A0, -1)], A0, 0xffff_f000);
    c("c.slli", vec![c_li(A0, 1), c_slli(A0, 31)], A0, 0x8000_0000);
    c("c.srli", vec![c_li(S0, -1), c_srli(S0, 28)], S0, 0xf);
    c("c.srai", vec![c_li(S0, -16), c_srai(S0, 2)], S0, 0xffff_fffc);
    c("c.andi", vec![c_li(S0, -1), c_andi(S0, 12)], S0, 12);
    c("c.sub", vec![c_li(S0, 10), c_li(S1, 3), c_sub(S0, S1)], S0, 7);
    c("c.xor", vec![c_li(S0, 12), c_li(S1, 10), c_xor(S0, S1)], S0, 6);
    c("c.or", vec![c_li(S0, 12), c_li(S1, 3), c_or(S0, S1)], S0, 15);
    c("c.and", vec![c_li(S0, 12), c_li(S1, 10), c_and(S0, S1)], S0, 8);
    c(
        "c.j skips",
        vec![c_li(A0, 1), c_j(4), c_li(A0, 2)],
        A0,
        1,
    );
    c(
        "c.jal links",
        vec![c_jal(4), c_li(A0, 1)],
        RA,
        BASE + 2,
    );
    c(
        "c.beqz taken",
        vec![c_li(S0, 0), c_li(A0, 1), c_beqz(S0, 4), c_li(A0, 2)],
        A0,
        1,
    );
    c(
        "c.bnez not taken",
        vec![c_li(S0, 0), c_li(A0, 1), c_bnez(S0, 4), c_li(A0, 2)],
        A0,
        2,
    );
    c(
        "c.addi16sp",
        vec![c_li(SP, 0), c_addi16sp(-64)],
        SP,
        (-64i32) as u32,
    );
    c(
        "c.addi4spn",
        vec![c_li(SP, 16), c_addi4spn(S0, 1020)],
        S0,
        1036,
    );
    {
        let mut code = vec![];
        li32(&mut code, SP, 0x3000);
        code.push(c_li(A0, 31));
        code.push(c_swsp(A0, 8));
        code.push(c_lwsp(A1, 8));
        code.push(c_li(S0, 0));
        code.push(c_addi4spn(S0, 8));
        code.push(c_lw(S1, S0, 0));
        c("c.swsp/c.lwsp", code.clone(), A1, 31);
        c("c.lw via sp", code, S1, 31);
    }
    {
        let mut code = vec![];
        li32(&mut code, S0, 0x3100);
        code.push(c_li(S1, 21));
        code.push(c_sw(S1, S0, 4));
        code.push(c_li(S1, 0));
        code.push(c_lw(S1, S0, 4));
        c("c.sw/c.lw", code, S1, 21);
    }
    c("c.jr", vec![auipc(A1, 0), c_addi(A1, 8), c_jr(A1), c_li(A0, 1), c_li(A0, 9)], A0, 9);

    // mixing 16- and 32-bit encodings must keep the pc in step
    c(
        "mixed widths",
        vec![c_li(A0, 1), addi(A0, A0, 1), c_addi(A0, 1), addi(A0, A0, 1)],
        A0,
        4,
    );

    // ---- CSRs ----
    c(
        "csrrw round trip",
        vec![
            addi(A0, ZERO, 0x123),
            csrrw(ZERO, 0x340, A0),
            csrrs(A1, 0x340, ZERO),
        ],
        A1,
        0x123,
    );
    c(
        "csrrs sets bits",
        vec![
            addi(A0, ZERO, 0x0f),
            csrrw(ZERO, 0x340, A0),
            addi(A0, ZERO, 0x30),
            csrrs(A1, 0x340, A0),
            csrrs(A2, 0x340, ZERO),
        ],
        A2,
        0x3f,
    );
    c(
        "csrrc clears bits",
        vec![
            addi(A0, ZERO, 0x3f),
            csrrw(ZERO, 0x340, A0),
            addi(A0, ZERO, 0x0f),
            csrrc(A1, 0x340, A0),
            csrrs(A2, 0x340, ZERO),
        ],
        A2,
        0x30,
    );
    c(
        "csrrwi",
        vec![csrrwi(ZERO, 0x340, 21), csrrs(A1, 0x340, ZERO)],
        A1,
        21,
    );

    // ---- indexed access: custom-1, bounds and type checked ----
    // A three-element vector at 0x3004, header 0x3000: (3 << 8) | T_VECTOR.
    let vec = |mut body: Vec<u32>| -> Vec<u32> {
        let mut v = vec![
            addi(A1, ZERO, 0),
            lui(A1, 3),
            addi(A1, A1, 4),          // the object pointer, tag 4
            addi(A2, ZERO, (3 << 8) | 3),
            sw(A2, A1, -4),           // header: three slots, type vector
            addi(A2, ZERO, 111),
            sw(A2, A1, 0),
            addi(A2, ZERO, 222),
            sw(A2, A1, 4),
            addi(A2, ZERO, 333),
            sw(A2, A1, 8),
        ];
        v.append(&mut body);
        v
    };
    // Indices arrive tagged: 2n+1.
    c("ldx", vec(vec![addi(A3, ZERO, 3), ldx(A0, A1, A3, 3)]), A0, 222);
    c("ldx slot 0", vec(vec![addi(A3, ZERO, 1), ldx(A0, A1, A3, 3)]), A0, 111);
    c("ldx any type", vec(vec![addi(A3, ZERO, 5), ldx(A0, A1, A3, 0)]), A0, 333);
    c(
        "stx",
        vec(vec![
            addi(A3, ZERO, 3),
            addi(A0, ZERO, 99),
            stx(A0, A1, A3, 3),
            lw(A0, A1, 4),
        ]),
        A0,
        99,
    );
    // A byte index is checked against the same length, which counts elements:
    // three slots means three, whatever size the access is.
    c("ldxb", vec(vec![addi(A3, ZERO, 1), ldxb(A0, A1, A3, 3)]), A0, 111);
    // The immediate form takes a raw index, not a tagged one, and needs no
    // register to hold it.
    c("ldxi", vec(vec![ldxi(A0, A1, 1, 3)]), A0, 222);
    c("ldxi slot 0", vec(vec![ldxi(A0, A1, 0, 3)]), A0, 111);
    c("ldxi any type", vec(vec![ldxi(A0, A1, 2, 0)]), A0, 333);
    c(
        "stxi",
        vec(vec![addi(A0, ZERO, 99), stxi(A0, A1, 1, 3), lw(A0, A1, 4)]),
        A0,
        99,
    );
    c("ldxbi", vec(vec![ldxbi(A0, A1, 0, 3)]), A0, 111);

    // ---- pairs: custom-0, with the tag check in the instruction ----
    // A pair at 0x3000: car 111, cdr 222.
    let pair = |mut body: Vec<u32>| -> Vec<u32> {
        let mut v = vec![
            addi(A1, ZERO, 0),
            lui(A1, 3),
            addi(A2, ZERO, 111),
            sw(A2, A1, 0),
            addi(A2, ZERO, 222),
            sw(A2, A1, 4),
        ];
        v.append(&mut body);
        v
    };
    c("car", pair(vec![car(A0, A1)]), A0, 111);
    // car and cdr are offsets 0 and 4 of the same instruction now, and the
    // offset is general: a slot access off an object is the same opcode with
    // funct3 saying "object" instead of "pair".
    c("lref at 4", pair(vec![lref(A0, A1, 4)]), A0, 222);
    c(
        "sref at 4",
        pair(vec![addi(A3, ZERO, 77), sref(A3, A1, 4), lw(A0, A1, 4)]),
        A0,
        77,
    );
    c(
        "lobj reads a header",
        vec(vec![lobj(A0, A1, -4)]),
        A0,
        (3 << 8) | 3,
    );
    c(
        "sobj at a slot",
        vec(vec![addi(A3, ZERO, 88), sobj(A3, A1, 4), lw(A0, A1, 4)]),
        A0,
        88,
    );
    c("cdr", pair(vec![cdr(A0, A1)]), A0, 222);
    c(
        "set-car!",
        pair(vec![addi(A3, ZERO, 99), setcar(A3, A1), lw(A0, A1, 0)]),
        A0,
        99,
    );
    c(
        "set-cdr!",
        pair(vec![addi(A3, ZERO, 99), setcdr(A3, A1), lw(A0, A1, 4)]),
        A0,
        99,
    );
    // nil is the word 0 and is a legal pair, so this must not trap.
    c(
        "car of nil",
        vec![addi(A2, ZERO, 7), sw(A2, ZERO, 0), car(A0, ZERO)],
        A0,
        7,
    );

    v
}

pub fn run_all() -> bool {
    let mut pass = 0;
    let mut fail = 0;
    for t in cases() {
        let m = go(&t.code);
        let got = m.x[t.reg as usize];
        if got == t.want {
            pass += 1;
        } else {
            fail += 1;
            println!(
                "FAIL {:<24} x{} = 0x{:08x}, want 0x{:08x}",
                t.name, t.reg, got, t.want
            );
        }
    }

    // ---- traps and interrupts, which need more than a register check ----
    let mut extra: Vec<(&str, bool)> = Vec::new();

    {
        // An illegal instruction vectors to mtvec with the right cause.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0)); // mtvec = 0x2000
        code.push(0xffff_ffff); // illegal
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        // handler at 0x2000 records mcause
        let h = vec![csrrs(A1, 0x342, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 40);
        extra.push(("illegal traps to mtvec", m.x[A1 as usize] == C_ILLEGAL));
        extra.push(("mepc points at the fault", m.mepc == BASE + 8));
    }

    // The whole point of custom-2: an operand that is not a number is a trap
    // naming the value, not a silently fabricated pointer.
    {
        let trap = |body: Vec<u32>| -> (u32, u32) {
            let mut m = Machine::new();
            let mut code = vec![];
            li32(&mut code, A0, 0x2000);
            code.push(csrrw(ZERO, 0x305, A0));
            code.extend(body);
            let end = emit(&mut m, BASE, &code);
            m.poke32(end, jal(ZERO, 0));
            let h = vec![csrrs(A1, 0x342, ZERO), csrrs(A2, 0x343, ZERO), jal(ZERO, 0)];
            emit(&mut m, 0x2000, &h);
            m.pc = BASE;
            m.mtimecmp = u64::MAX;
            m.gfx.next_vbl = u64::MAX;
            run::run(&mut m, 100);
            (m.x[A1 as usize], m.x[A2 as usize])
        };
        // 0x3004 looks like an object pointer; adding to it used to make a
        // pointer of a different kind.
        let mut body = vec![];
        li32(&mut body, A3, 0x3004);
        body.push(addi(A4, ZERO, 5));
        body.push(fadd(A0, A3, A4));
        let (cause, tval) = trap(body);
        extra.push(("fadd of a non-number traps", cause == C_TYPE));
        extra.push(("...naming the value", tval == 0x3004));

        let mut v = vec![addi(A3, ZERO, 7)];
        li32(&mut v, A4, (1u32 << 30) | 1);
        v.push(fmulo(A0, A3, A4));
        let (cause, _) = trap(v);
        extra.push(("fmulo traps where fmul wraps", cause == C_OVER));

        let (cause, _) = trap(vec![addi(A3, ZERO, 11), addi(A4, ZERO, 0), fdiv(A0, A3, A4)]);
        extra.push(("fdiv by a non-number traps first", cause == C_TYPE));

        let (cause, _) = trap(vec![addi(A3, ZERO, 11), addi(A4, ZERO, 1), fdiv(A0, A3, A4)]);
        extra.push(("fdiv by zero traps", cause == C_DIVZERO));

        // The checking forms exist even though nothing emits them yet.
        let mut big = vec![];
        li32(&mut big, A3, ((1u32 << 30) - 1) * 2 + 1);
        big.push(addi(A4, ZERO, 3));
        big.push(faddo(A0, A3, A4));
        let (cause, _) = trap(big);
        extra.push(("faddo traps past 2^30", cause == C_OVER));

        let mut big = vec![];
        li32(&mut big, A3, ((1u32 << 30) - 1) * 2 + 1);
        big.push(addi(A4, ZERO, 3));
        big.push(fadd(A0, A3, A4));
        let (cause, _) = trap(big);
        extra.push(("fadd does not", cause == 0));

        let (cause, tval) = trap(vec![addi(A3, ZERO, 4), tlw(A0, A3, 0)]);
        extra.push(("tlw of a non-address traps", cause == C_TYPE));
        extra.push(("...naming that value too", tval == 4));

        // A pair reference and an object reference are different checks, and
        // each refuses what the other accepts.
        let mut v = vec![];
        li32(&mut v, A3, 0x3004); // an object pointer
        v.push(lref(A0, A3, 0));
        let (cause, _) = trap(v);
        extra.push(("lref refuses an object", cause == C_TYPE));

        let mut v = vec![];
        li32(&mut v, A3, 0x3000); // a pair pointer
        v.push(lobj(A0, A3, 0));
        let (cause, _) = trap(v);
        extra.push(("lobj refuses a pair", cause == C_TYPE));

        let (cause, _) = trap(vec![lobj(A0, ZERO, 0)]);
        extra.push(("lobj refuses nil", cause == C_TYPE));

        let (cause, _) = trap(vec![addi(A3, ZERO, 77), sref(A3, ZERO, 0)]);
        extra.push(("a store through nil still traps", cause == C_TYPE));
    }

    {
        // The bound is checked against the length in the header, so an index
        // past the end is a trap naming the index rather than a load from
        // somewhere just after the object.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        li32(&mut code, A1, 0x3004);
        code.push(addi(A2, ZERO, (3 << 8) | 3));
        code.push(sw(A2, A1, -4));
        code.push(addi(A3, ZERO, 7)); // the fixnum 3, one past the end
        code.push(ldx(A0, A1, A3, 3));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![csrrs(A1, 0x342, ZERO), csrrs(A2, 0x343, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        extra.push(("index past the end traps", m.x[A1 as usize] == C_RANGE));
        extra.push(("mtval names the index", m.x[A2 as usize] == 7));
    }

    {
        // funct7 names the type the access requires, so reading a string as a
        // vector is caught rather than reinterpreted.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        li32(&mut code, A1, 0x3004);
        code.push(addi(A2, ZERO, (3 << 8) | 2)); // a string, not a vector
        code.push(sw(A2, A1, -4));
        code.push(addi(A3, ZERO, 1));
        code.push(ldx(A0, A1, A3, 3));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![csrrs(A1, 0x342, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        extra.push(("wrong object type traps", m.x[A1 as usize] == C_TYPE));
    }

    {
        // An index that is not a fixnum is a type error, not a wild address.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        li32(&mut code, A1, 0x3004);
        code.push(addi(A2, ZERO, (3 << 8) | 3));
        code.push(sw(A2, A1, -4));
        code.push(addi(A3, ZERO, 4)); // even: not a fixnum
        code.push(ldx(A0, A1, A3, 3));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![csrrs(A1, 0x342, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        extra.push(("index that is not a number traps", m.x[A1 as usize] == C_TYPE));
    }

    {
        // A pair instruction handed something that is not a pair traps with
        // the offending value in mtval, which is what makes the report at the
        // other end able to say what the value was.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        code.push(addi(A0, ZERO, 11)); // the fixnum 5, tagged
        code.push(car(A3, A0));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![csrrs(A1, 0x342, ZERO), csrrs(A2, 0x343, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 40);
        extra.push(("car of a fixnum traps", m.x[A1 as usize] == C_TYPE));
        extra.push(("mtval names the value", m.x[A2 as usize] == 11));
    }

    {
        // Reading nil is fine; writing through it would scribble on the
        // globals at address 0, so the store side rejects it.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        code.push(setcar(A0, ZERO));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![csrrs(A1, 0x342, ZERO), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 40);
        extra.push(("set-car! through nil traps", m.x[A1 as usize] == C_TYPE));
    }

    {
        // ecall, then mret returns to the instruction after it.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        code.push(ecall());
        code.push(addi(A2, ZERO, 77));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        let h = vec![
            csrrs(A1, 0x341, ZERO), // mepc
            addi(A1, A1, 4),
            csrrw(ZERO, 0x341, A1),
            mret(),
        ];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        extra.push(("ecall + mret resumes", m.x[A2 as usize] == 77));
    }

    {
        // A timer interrupt preempts a spin loop.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, 0x2000);
        code.push(csrrw(ZERO, 0x305, A0));
        li32(&mut code, A0, 1 << 7); // MTIE
        code.push(csrrw(ZERO, 0x304, A0));
        li32(&mut code, A0, 8); // MIE
        code.push(csrrw(ZERO, 0x300, A0));
        code.push(jal(ZERO, 0)); // spin forever
        emit(&mut m, BASE, &code);
        let h = vec![addi(A2, ZERO, 55), jal(ZERO, 0)];
        emit(&mut m, 0x2000, &h);
        m.pc = BASE;
        m.mtimecmp = 20;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 400);
        extra.push(("timer interrupt fires", m.x[A2 as usize] == 55));
        extra.push((
            "interrupt cause is the timer",
            m.mcause == 0x8000_0000 | IRQ_TIMER,
        ));
    }

    {
        // Devices: the uart echoes into memory and SYS_HALT stops the machine.
        let mut m = Machine::new();
        let mut code = vec![];
        li32(&mut code, A0, MMIO_BASE + (DEV_UART << 12));
        code.push(lw(A1, A0, 0x00)); // read a byte
        li32(&mut code, A2, MMIO_BASE);
        code.push(sw(A1, A2, 0x00)); // halt with it as the exit code
        emit(&mut m, BASE, &code);
        m.uart.feed(b"K");
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        extra.push(("uart receive", m.exit_code == b'K' as u32));
        extra.push(("sys halt", m.halted));
    }

    {
        // The blitter fills and copies.
        let mut m = Machine::new();
        let b = MMIO_BASE + (DEV_BLIT << 12);
        let mut code = vec![];
        li32(&mut code, A0, b);
        li32(&mut code, A1, 0x4000);
        code.push(sw(A1, A0, 0x04)); // dst
        li32(&mut code, A1, 16);
        code.push(sw(A1, A0, 0x08)); // w
        li32(&mut code, A1, 4);
        code.push(sw(A1, A0, 0x0c)); // h
        li32(&mut code, A1, 16);
        code.push(sw(A1, A0, 0x14)); // dmod
        li32(&mut code, A1, 0xAB);
        code.push(sw(A1, A0, 0x18)); // val
        li32(&mut code, A1, 1); // OP_FILL
        code.push(sw(A1, A0, 0x1c));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 200);
        let ok = (0..64).all(|i| m.peek8(0x4000 + i) == 0xAB) && m.peek8(0x4040) == 0;
        extra.push(("blitter fill", ok));
    }

    {
        // The disk works on its own time: a command reads busy until its
        // moment comes, the memory a read is filling holds the old bytes
        // until then, and the new ones after.
        let path = std::env::temp_dir().join(format!("lm-check-disk-{}.img", std::process::id()));
        let mut m = Machine::new();
        let attached = m.disk.attach(path.to_str().unwrap()).is_ok();
        for i in 0..512u32 {
            m.poke8(0x4000 + i, (i * 7 + 3) as u8);
        }
        let mut code = vec![];
        li32(&mut code, A0, MMIO_BASE + (DEV_DISK << 12));
        li32(&mut code, A6, 0x5000);
        li32(&mut code, T0, crate::dev::disk::STATUS_BUSY);
        li32(&mut code, A1, 0x4000);
        code.push(sw(A1, A0, 0x00)); // addr
        li32(&mut code, A1, 3);
        code.push(sw(A1, A0, 0x04)); // block 3
        li32(&mut code, A1, 1);
        code.push(sw(A1, A0, 0x08)); // one block
        li32(&mut code, A1, 2);
        code.push(sw(A1, A0, 0x0c)); // write
        code.push(lw(A2, A0, 0x10)); // straight away: busy
        code.push(lw(A3, A0, 0x10)); // until it is not
        code.push(beq(A3, T0, -4));
        code.push(sw(A6, A0, 0x00)); // and back, somewhere else
        li32(&mut code, A1, 1);
        code.push(sw(A1, A0, 0x18)); // with the completion interrupt this time
        code.push(sw(A1, A0, 0x0c)); // read
        code.push(lw(A4, A0, 0x10)); // busy again
        code.push(lbu(A5, A6, 0)); // and the old byte still there
        code.push(lw(A7, A0, 0x10));
        code.push(beq(A7, T0, -4));
        code.push(lbu(T1, A6, 0));
        code.push(lbu(T2, A6, 1));
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        m.pc = BASE;
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 5000);
        let r = |x: u32| m.x[x as usize];
        let on_host = std::fs::read(&path)
            .map(|b| b.len() == 4 * 512 && (0..512).all(|i| b[3 * 512 + i] == (i * 7 + 3) as u8))
            .unwrap_or(false);
        let _ = std::fs::remove_file(&path);
        extra.push(("disk attaches a host file", attached));
        extra.push(("disk busy straight after a command", r(A2) == 0x80 && r(A4) == 0x80));
        extra.push(("disk write lands on the host", r(A3) == 0 && on_host));
        extra.push(("disk read leaves the old bytes until it is done", r(A5) == 0));
        extra.push(("disk read brings the new ones after", r(A7) == 0 && r(T1) == 3 && r(T2) == 10));
        extra.push(("disk completion raises its interrupt", m.intreq & (1 << INT_DISK) != 0));
    }

    for (name, ok) in extra {
        if ok {
            pass += 1;
        } else {
            fail += 1;
            println!("FAIL {name}");
        }
    }

    println!("{pass} passed, {fail} failed");
    fail == 0
}

pub fn bench() {
    // A tight loop that exercises dispatch, arithmetic, memory and branches,
    // in roughly the mix a compiled Lisp program produces.
    let mut m = Machine::new();
    let mut code = vec![];
    li32(&mut code, A0, 0); // accumulator
    li32(&mut code, A1, 40_000_000); // trip count
    li32(&mut code, A3, 0x8000); // scratch buffer
    li32(&mut code, A4, 1);
    // loop:
    let loop_at = code.len();
    code.push(add(A0, A0, A4));
    code.push(xor(A2, A0, A1));
    code.push(sw(A2, A3, 0));
    code.push(lw(A5, A3, 0));
    code.push(add(A0, A0, A5));
    code.push(srli(A0, A0, 1));
    code.push(addi(A1, A1, -1));
    let back = -(((code.len() - loop_at) * 4) as i32);
    code.push(bne(A1, ZERO, back));
    let n = code.len();
    let mut mm = Machine::new();
    std::mem::swap(&mut m, &mut mm);
    let end = emit(&mut m, BASE, &code);
    m.poke32(end, jal(ZERO, 0));
    m.pc = BASE;
    m.mtimecmp = u64::MAX;
    m.gfx.next_vbl = u64::MAX;

    let iters = 40_000_000u64;
    let total = iters * 8 + n as u64;
    let t = std::time::Instant::now();
    run::run(&mut m, total);
    let el = t.elapsed();
    let mips = (m.cycles as f64) / el.as_secs_f64() / 1e6;
    println!(
        "{} instructions in {:.3}s = {:.1} MIPS",
        m.cycles,
        el.as_secs_f64(),
        mips
    );
}
