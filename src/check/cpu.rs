//! Processor conformance tests. Each case assembles a small program, runs it,
//! and checks registers, memory or the trap it took. They catch decode bugs
//! and holes in the capability checks before anything is built on top of
//! the core.

use crate::cap::*;
use crate::heap::{T_BYTES, T_CLOSURE, T_CONTEXT, T_KERNEL, T_STACK, T_STRING, T_SYMBOL, T_VECTOR};
use crate::mach::*;
use crate::map::*;
use crate::run;
use crate::rvenc::*;

/// Where test code goes, and where the trap handler is.
const BASE: u32 = 0x0010_0000;
const HANDLER: u32 = 0x2000;
/// The register every test may derive capabilities from: the root.
const ROOT: u32 = S11;
/// Where test objects and pairs live.
const OBJ: u32 = OBJ_BASE + 0x1000;
const PAIR: u32 = CONS_BASE + 0x1000;
/// A data capability's permissions: everything but execute, system
/// registers, sealing and the header.
const DATA: u32 = P_LD | P_SD | P_LC | P_SC | P_LM;

/// Assemble a word list into memory. Values below 0x10000 with the low two
/// bits not equal to 3 are emitted as 16-bit compressed instructions.
fn emit(m: &mut Machine, at: u32, code: &[u32]) -> u32 {
    let mut pc = at;
    for &w in code {
        if w & 3 == 3 || w > 0xffff {
            m.poke32(pc, w);
            pc += 4;
        } else {
            m.poke8(pc, w as u8);
            m.poke8(pc + 1, (w >> 8) as u8);
            pc += 2;
        }
    }
    pc
}

/// A capability to `addr` in `rd`, made from the root in s11.
fn capr(out: &mut Vec<u32>, rd: u32, addr: u32) {
    li32(out, rd, addr);
    out.push(yaddrw(rd, ROOT, rd));
}

/// A finished run: the machine, and the address just past the test body,
/// where the halt sequence begins.
struct Out {
    m: Box<Machine>,
    end: u32,
}

impl Out {
    fn x(&self, r: u32) -> u32 {
        self.m.x[r as usize]
    }
    fn c(&self, r: u32) -> Cap {
        self.m.reg(r)
    }
    /// The trap the run ended in, as (cause, mtval, epc), if it did.
    fn trap(&self) -> Option<(u32, u32, u32)> {
        (self.m.exit_code == 1).then(|| (self.m.mcause, self.m.mtval, self.m.mepc.addr))
    }
    fn clean(&self) -> bool {
        self.m.halted && self.m.exit_code == 0
    }
    /// Whether the run trapped with this cause and mtval.
    fn took(&self, cause: u32, tval: u32) -> bool {
        matches!(self.trap(), Some((c, t, _)) if c == cause && t == tval)
    }
}

/// Run `code` at BASE on a fresh machine prepared by `setup`, then halt. A
/// trap goes to a handler that halts with exit code 1, so a test reads the
/// trap from mcause, mtval and mepc.
fn go_with(code: &[u32], setup: impl FnOnce(&mut Machine)) -> Out {
    let mut m = Machine::new();
    m.set_reg(ROOT, Cap::ROOT);
    let end = emit(&mut m, BASE, code);
    let mut tail = vec![];
    halt_through_root(&mut tail, ZERO);
    emit(&mut m, end, &tail);
    // The handler halts with exit code 1, through the root.
    let mut stub = vec![addi(T2, ZERO, 1)];
    halt_through_root(&mut stub, T2);
    emit(&mut m, HANDLER, &stub);
    m.mtvec = Cap::ROOT.with_addr(HANDLER);
    m.set_pcc(Cap::ROOT.with_addr(BASE));
    m.mtimecmp = u64::MAX;
    m.gfx.next_vbl = u64::MAX;
    setup(&mut m);
    run::run(&mut m, 200_000);
    Out { m, end }
}

/// Stop the machine with the exit code in `code`, through the system
/// device's page made from the root, which takes SR to read.
fn halt_through_root(out: &mut Vec<u32>, code: u32) {
    out.push(csrrs(T0, CSR_ROOT, ZERO));
    li32(out, T1, MMIO_BASE);
    out.push(yaddrw(T0, T0, T1));
    out.push(sw(code, T0, 0));
}

fn go(code: &[u32]) -> Out {
    go_with(code, |_| {})
}

/// A capability with bounds `[at, at + len)` and permissions `perms`.
fn region(at: u32, len: u32, perms: u32) -> Cap {
    Cap::ROOT.with_addr(at).with_bounds_exact(len).unwrap().and_perms(perms)
}

/// Lay down an object of header type `ty` with `len` elements at `at`, its
/// header in the granule below, and answer the capability to it.
fn object(m: &mut Machine, at: u32, ty: u32, len: u32) -> Cap {
    m.poke32(at - 8, (len << 8) | ty);
    m.poke32(at - 4, 0);
    let bytes = ty == T_STRING || ty == T_BYTES;
    let size = if bytes { len } else { len * 8 };
    let perms = if bytes { P_LD | P_SD | P_HD } else { DATA | P_HD };
    region(at, size, perms)
}

/// A pair at `at` holding `car` and `cdr`.
fn pair(m: &mut Machine, at: u32, car: Cap, cdr: Cap) -> Cap {
    m.store_cap(at, car);
    m.store_cap(at + 8, cdr);
    region(at, 16, DATA)
}

/// Lay down a blitter descriptor at `d`, pending: `op` over `w` by `h` with
/// rows `w` apart, from `src` to `dst`, with 0xAB for its value, linked to
/// `next`.
#[allow(clippy::too_many_arguments)]
fn put_descriptor(m: &mut Machine, d: u32, op: u32, dst: Cap, src: Cap, w: u32, h: u32, next: Cap) {
    use crate::dev::blit::*;
    for i in (0..LIST_BYTES).step_by(4) {
        m.poke32(d + i, 0);
    }
    m.store_cap(d + L_SRC, src);
    m.store_cap(d + L_DST, dst);
    m.store_cap(d + L_NEXT, next);
    for (at, v) in [(L_W, w), (L_H, h), (L_SMOD, w), (L_DMOD, w), (L_VAL, 0xAB), (L_OP, op), (L_STATUS, DONE_PENDING)] {
        m.poke32(d + at, v);
    }
}

pub fn run_all() -> bool {
    let mut checks: Vec<(String, bool)> = Vec::new();
    let mut ok = |name: &str, v: bool| checks.push((name.to_string(), v));
    // A case whose result is the address in one register, with no trap.
    let mut reg_case = |ok: &mut dyn FnMut(&str, bool), name: &str, code: Vec<u32>, r: u32, want: u32| {
        let o = go(&code);
        let got = o.x(r);
        if !(o.clean() && got == want) {
            println!("     {name}: x{r} = {got:#010x}, want {want:#010x}, trap {:x?}", o.trap());
        }
        ok(name, o.clean() && got == want);
    };
    let c = &mut reg_case;

    // ---- arithmetic and immediates ----
    c(&mut ok, "addi", vec![addi(A0, ZERO, 42)], A0, 42);
    c(&mut ok, "addi neg", vec![addi(A0, ZERO, -1)], A0, 0xffff_ffff);
    c(&mut ok, "add", vec![addi(A0, ZERO, 7), addi(A1, ZERO, 35), add(A0, A0, A1)], A0, 42);
    c(&mut ok, "sub wrap", vec![addi(A0, ZERO, 1), addi(A1, ZERO, 2), sub(A0, A0, A1)], A0, 0xffff_ffff);
    c(&mut ok, "lui", vec![lui(A0, 0xabcde)], A0, 0xabcd_e000);
    c(&mut ok, "x0 stays zero", vec![addi(ZERO, ZERO, 99), add(A0, ZERO, ZERO)], A0, 0);
    c(&mut ok, "slti signed", vec![addi(A0, ZERO, -5), slti(A1, A0, -4)], A1, 1);
    c(&mut ok, "sltiu unsigned", vec![addi(A0, ZERO, -5), sltiu(A1, A0, -4)], A1, 1);
    c(&mut ok, "sltiu vs zero", vec![addi(A0, ZERO, -1), sltiu(A1, A0, 1)], A1, 0);
    c(&mut ok, "srai", vec![addi(A0, ZERO, -16), srai(A1, A0, 2)], A1, 0xffff_fffc);
    c(&mut ok, "srli", vec![addi(A0, ZERO, -16), srli(A2, A0, 28)], A2, 0xf);
    c(&mut ok, "sll by reg mod32", vec![addi(A0, ZERO, 1), addi(A1, ZERO, 33), sll(A2, A0, A1)], A2, 2);
    c(&mut ok, "sra by reg", vec![lui(A0, 0x80000), addi(A1, ZERO, 31), sra(A2, A0, A1)], A2, 0xffff_ffff);
    c(&mut ok, "xori inverts", vec![addi(A0, ZERO, 0x55), xori(A1, A0, -1)], A1, 0xffff_ffaa);

    // ---- B extension and Zicond ----
    c(&mut ok, "sh1add", vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh1add(A0, A1, A2)], A0, 106);
    c(&mut ok, "sh2add", vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh2add(A0, A1, A2)], A0, 112);
    c(&mut ok, "sh3add", vec![addi(A1, ZERO, 3), addi(A2, ZERO, 100), sh3add(A0, A1, A2)], A0, 124);
    c(&mut ok, "andn", vec![addi(A1, ZERO, 0xff), addi(A2, ZERO, 0x0f), andn(A0, A1, A2)], A0, 0xf0);
    c(&mut ok, "orn", vec![addi(A1, ZERO, 1), addi(A2, ZERO, 2), orn(A0, A1, A2)], A0, 0xffff_fffd);
    c(&mut ok, "xnor", vec![addi(A1, ZERO, 5), addi(A2, ZERO, 3), xnor(A0, A1, A2)], A0, 0xffff_fff9);
    c(&mut ok, "min", vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), min(A0, A1, A2)], A0, 0xffff_fffb);
    c(&mut ok, "minu", vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), minu(A0, A1, A2)], A0, 3);
    c(&mut ok, "max", vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), max(A0, A1, A2)], A0, 3);
    c(&mut ok, "maxu", vec![addi(A1, ZERO, -5), addi(A2, ZERO, 3), maxu(A0, A1, A2)], A0, 0xffff_fffb);
    c(&mut ok, "cpop", vec![addi(A1, ZERO, -1), cpop(A0, A1)], A0, 32);
    c(&mut ok, "clz", vec![addi(A1, ZERO, 1), clz(A0, A1)], A0, 31);
    c(&mut ok, "ctz", vec![addi(A1, ZERO, 8), ctz(A0, A1)], A0, 3);
    c(&mut ok, "sext.b", vec![addi(A1, ZERO, 0xff), sextb(A0, A1)], A0, 0xffff_ffff);
    c(&mut ok, "sext.h", vec![lui(A1, 8), sexth(A0, A1)], A0, 0xffff_8000);
    c(&mut ok, "zext.h", vec![addi(A1, ZERO, -1), zexth(A0, A1)], A0, 0xffff);
    c(&mut ok, "rev8", vec![addi(A1, ZERO, 0x123), rev8(A0, A1)], A0, 0x2301_0000);
    c(&mut ok, "orc.b", vec![addi(A1, ZERO, 0x100), orcb(A0, A1)], A0, 0xff00);
    c(&mut ok, "rol", vec![lui(A1, 0x80000), addi(A2, ZERO, 1), rol(A0, A1, A2)], A0, 1);
    c(&mut ok, "ror", vec![addi(A1, ZERO, 1), addi(A2, ZERO, 1), ror(A0, A1, A2)], A0, 0x8000_0000);
    c(&mut ok, "rori", vec![addi(A1, ZERO, 1), rori(A0, A1, 4)], A0, 0x1000_0000);
    c(&mut ok, "bset", vec![addi(A2, ZERO, 31), bset(A0, ZERO, A2)], A0, 0x8000_0000);
    c(&mut ok, "bclr", vec![addi(A1, ZERO, -1), bclr(A0, A1, ZERO)], A0, 0xffff_fffe);
    c(&mut ok, "binv", vec![addi(A1, ZERO, 1), binv(A0, A1, ZERO)], A0, 0);
    c(&mut ok, "bext wraps at 32", vec![addi(A1, ZERO, 8), addi(A2, ZERO, 35), bext(A0, A1, A2)], A0, 1);
    c(&mut ok, "bseti", vec![bseti(A0, ZERO, 31)], A0, 0x8000_0000);
    c(&mut ok, "bclri", vec![addi(A1, ZERO, -1), bclri(A0, A1, 0)], A0, 0xffff_fffe);
    c(&mut ok, "binvi", vec![addi(A1, ZERO, 1), binvi(A0, A1, 0)], A0, 0);
    c(&mut ok, "bexti", vec![addi(A1, ZERO, 8), bexti(A0, A1, 3)], A0, 1);
    c(&mut ok, "czero.eqz", vec![addi(A1, ZERO, 42), czeroeqz(A0, A1, ZERO)], A0, 0);
    c(&mut ok, "czero.nez", vec![addi(A1, ZERO, 42), czeronez(A0, A1, ZERO)], A0, 42);

    // ---- M extension ----
    c(&mut ok, "mul", vec![addi(A0, ZERO, -6), addi(A1, ZERO, 7), mul(A2, A0, A1)], A2, (-42i32) as u32);
    c(&mut ok, "mulh", vec![lui(A0, 0x10000), addi(A1, ZERO, 16), mulh(A2, A0, A1)], A2, 1);
    c(&mut ok, "mulhu", vec![addi(A0, ZERO, -1), addi(A1, ZERO, -1), mulhu(A2, A0, A1)], A2, 0xffff_fffe);
    c(&mut ok, "mulhsu", vec![addi(A0, ZERO, -1), addi(A1, ZERO, -1), mulhsu(A2, A0, A1)], A2, 0xffff_ffff);
    c(&mut ok, "div", vec![addi(A0, ZERO, -7), addi(A1, ZERO, 2), div(A2, A0, A1)], A2, (-3i32) as u32);
    c(&mut ok, "rem", vec![addi(A0, ZERO, -7), addi(A1, ZERO, 2), rem(A2, A0, A1)], A2, (-1i32) as u32);
    c(&mut ok, "div by zero", vec![addi(A0, ZERO, 5), div(A2, A0, ZERO)], A2, 0xffff_ffff);
    c(&mut ok, "rem by zero", vec![addi(A0, ZERO, 5), rem(A2, A0, ZERO)], A2, 5);
    c(&mut ok, "div overflow", vec![lui(A0, 0x80000), addi(A1, ZERO, -1), div(A2, A0, A1)], A2, 0x8000_0000);
    c(&mut ok, "divu", vec![addi(A0, ZERO, -1), addi(A1, ZERO, 2), divu(A2, A0, A1)], A2, 0x7fff_ffff);

    // ---- branches ----
    c(&mut ok, "beq taken", vec![addi(A0, ZERO, 1), beq(ZERO, ZERO, 8), addi(A0, ZERO, 2)], A0, 1);
    c(
        &mut ok,
        "bne loop",
        vec![addi(A1, ZERO, 5), addi(A0, A0, 3), addi(A1, A1, -1), bne(A1, ZERO, -8)],
        A0,
        15,
    );
    c(
        &mut ok,
        "blt signed",
        vec![addi(A0, ZERO, -1), addi(A1, ZERO, 1), blt(A0, A1, 8), addi(A2, ZERO, 9)],
        A2,
        0,
    );
    c(
        &mut ok,
        "bltu unsigned",
        vec![addi(A0, ZERO, -1), addi(A1, ZERO, 1), bltu(A0, A1, 8), addi(A2, ZERO, 9)],
        A2,
        9,
    );
    c(&mut ok, "bgeu", vec![addi(A0, ZERO, -1), bgeu(A0, ZERO, 8), addi(A2, ZERO, 9)], A2, 0);

    // ---- jumps ----
    c(&mut ok, "jal links", vec![jal(RA, 8), addi(A0, ZERO, 1)], RA, BASE + 4);
    c(&mut ok, "jal negative", vec![jal(ZERO, 8), jal(ZERO, 8), jal(ZERO, -4)], ZERO, 0);
    c(
        &mut ok,
        "jalr clears bit 0",
        vec![auipc(A1, 0), yaddi(A1, A1, 13), jalr(RA, A1, 0), addi(A0, ZERO, 1), addi(A0, ZERO, 7)],
        A0,
        7,
    );
    c(&mut ok, "auipc", vec![auipc(A0, 1)], A0, BASE + 0x1000);
    c(
        &mut ok,
        "c.jr",
        vec![auipc(A1, 0), yaddi(A1, A1, 12), c_jr(A1), c_li(A0, 1), c_li(A0, 9)],
        A0,
        9,
    );
    c(&mut ok, "c.j skips", vec![c_li(A0, 1), c_j(4), c_li(A0, 2)], A0, 1);
    c(&mut ok, "c.jal links", vec![c_jal(4), c_li(A0, 1)], RA, BASE + 2);

    // ---- memory through a capability ----
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x3000);
        li32(&mut code, A0, 0x1234_5678);
        code.extend([sw(A0, A1, 0), lw(A2, A1, 0), lbu(A3, A1, 0), lb(A4, A1, 3), lhu(A5, A1, 2)]);
        c(&mut ok, "store/load word", code.clone(), A2, 0x1234_5678);
        c(&mut ok, "lbu low byte", code.clone(), A3, 0x78);
        c(&mut ok, "lb sign extends", code.clone(), A4, 0x12);
        c(&mut ok, "lhu high half", code, A5, 0x1234);
    }
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x3001);
        li32(&mut code, A0, 0xdead_beef);
        code.extend([sw(A0, A1, 0), lw(A2, A1, 0)]);
        c(&mut ok, "unaligned word", code, A2, 0xdead_beef);
    }
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x3000);
        code.extend([addi(A0, ZERO, 99), sw(A0, A1, -8), lw(A2, A1, -8)]);
        c(&mut ok, "negative offset", code, A2, 99);
    }

    // ---- compressed forms ----
    c(&mut ok, "c.li", vec![c_li(A0, -3)], A0, 0xffff_fffd);
    c(&mut ok, "c.addi", vec![c_li(A0, 5), c_addi(A0, 31)], A0, 36);
    c(&mut ok, "c.add", vec![c_li(A0, 20), c_li(A1, 22), c_add(A0, A1)], A0, 42);
    c(&mut ok, "c.lui", vec![c_lui(A0, -1)], A0, 0xffff_f000);
    c(&mut ok, "c.slli", vec![c_li(A0, 1), c_slli(A0, 31)], A0, 0x8000_0000);
    c(&mut ok, "c.srli", vec![c_li(S0, -1), c_srli(S0, 28)], S0, 0xf);
    c(&mut ok, "c.srli keeps the high bits", vec![c_li(S0, -1), c_srli(S0, 4)], S0, 0x0fff_ffff);
    c(&mut ok, "c.srai", vec![c_li(S0, -16), c_srai(S0, 2)], S0, 0xffff_fffc);
    c(&mut ok, "c.andi", vec![c_li(S0, -1), c_andi(S0, 12)], S0, 12);
    c(&mut ok, "c.sub", vec![c_li(S0, 10), c_li(S1, 3), c_sub(S0, S1)], S0, 7);
    c(&mut ok, "c.xor", vec![c_li(S0, 12), c_li(S1, 10), c_xor(S0, S1)], S0, 6);
    c(&mut ok, "c.or", vec![c_li(S0, 12), c_li(S1, 3), c_or(S0, S1)], S0, 15);
    c(&mut ok, "c.and", vec![c_li(S0, 12), c_li(S1, 10), c_and(S0, S1)], S0, 8);
    c(&mut ok, "c.beqz", vec![c_li(S0, 0), c_li(A0, 1), c_beqz(S0, 4), c_li(A0, 2)], A0, 1);
    c(&mut ok, "c.bnez", vec![c_li(S0, 0), c_li(A0, 1), c_bnez(S0, 4), c_li(A0, 2)], A0, 2);
    c(&mut ok, "mixed widths", vec![c_li(A0, 1), addi(A0, A0, 1), c_addi(A0, 1), addi(A0, A0, 1)], A0, 4);
    {
        let mut code = vec![];
        capr(&mut code, SP, 0x3000);
        code.extend([c_li(A0, 31), c_swsp(A0, 8), c_lwsp(A1, 8), c_addi4spn(S0, 8), c_lw(S1, S0, 0)]);
        c(&mut ok, "c.swsp/c.lwsp", code.clone(), A1, 31);
        c(&mut ok, "c.addi4spn is yaddi", code, S1, 31);
    }
    {
        let mut code = vec![];
        capr(&mut code, S0, 0x3100);
        code.extend([c_li(S1, 21), c_sw(S1, S0, 4), c_li(S1, 0), c_lw(S1, S0, 4)]);
        c(&mut ok, "c.sw/c.lw", code, S1, 21);
    }

    // ---- CSRs; mscratch holds a capability, here an integer ----
    c(&mut ok, "csrrw", vec![addi(A0, ZERO, 0x123), csrrw(ZERO, 0x340, A0), csrrs(A1, 0x340, ZERO)], A1, 0x123);
    c(
        &mut ok,
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
        &mut ok,
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
    c(&mut ok, "csrrwi", vec![csrrwi(ZERO, 0x340, 21), csrrs(A1, 0x340, ZERO)], A1, 21);

    // ---- Xlm: fixnums are machine integers ----
    let two = |x: i32, y: i32, op: fn(u32, u32, u32) -> u32| -> Vec<u32> {
        let mut v = vec![];
        li32(&mut v, A1, x as u32);
        li32(&mut v, A2, y as u32);
        v.push(op(A0, A1, A2));
        v
    };
    c(&mut ok, "fadd", two(5, 3, fadd), A0, 8);
    c(&mut ok, "fsub", two(5, 8, fsub), A0, (-3i32) as u32);
    c(&mut ok, "fmul wraps", two(1 << 30, 4, fmul), A0, 0);
    c(&mut ok, "fdiv truncates", two(-7, 2, fdiv), A0, (-3i32) as u32);
    c(&mut ok, "frem", two(17, 5, frem), A0, 2);
    c(&mut ok, "fand", two(12, 10, fand), A0, 8);
    c(&mut ok, "for", two(12, 10, f_or), A0, 14);
    c(&mut ok, "fxor", two(12, 10, fxor), A0, 6);
    c(&mut ok, "faddo", two(5, 3, faddo), A0, 8);
    c(&mut ok, "fsubo", two(5, 3, fsubo), A0, 2);
    c(&mut ok, "fmulo", two(-5, 3, fmulo), A0, (-15i32) as u32);
    c(&mut ok, "fsll", two(3, 34, fsll), A0, 12);
    c(&mut ok, "fsrl", two(-1, 28, fsrl), A0, 15);
    c(&mut ok, "fsra", two(-8, 1, fsra), A0, (-4i32) as u32);
    c(&mut ok, "flt", two(-1, 1, flt), A0, 1);
    c(&mut ok, "fltu", two(-1, 1, fltu), A0, 0);
    c(&mut ok, "feq", two(5, 5, feq), A0, 1);
    c(&mut ok, "faddi", vec![addi(A1, ZERO, 11), faddi(A0, A1, -20)], A0, (-9i32) as u32);
    c(&mut ok, "faddio", vec![addi(A1, ZERO, 11), faddio(A0, A1, 20)], A0, 31);
    c(&mut ok, "fandi", vec![addi(A1, ZERO, 0xff), fandi(A0, A1, 0x0f)], A0, 0x0f);
    c(&mut ok, "fori", vec![addi(A1, ZERO, 0xf0), fori(A0, A1, 0x0f)], A0, 0xff);
    c(&mut ok, "fshi left", vec![addi(A1, ZERO, 3), fshi(A0, A1, 0, 4)], A0, 48);
    c(&mut ok, "fshi logical", vec![addi(A1, ZERO, -1), fshi(A0, A1, 1, 28)], A0, 15);
    c(&mut ok, "fshi arithmetic", vec![addi(A1, ZERO, -16), fshi(A0, A1, 2, 2)], A0, (-4i32) as u32);
    {
        // retag: integer->char and back; the address survives, the
        // metadata is what the immediate says.
        let o = go(&[addi(A1, ZERO, 65), retag(A0, A1, 0, IMM_CHAR), retag(A2, A0, IMM_CHAR, 0)]);
        ok("retag integer->char", o.c(A0) == Cap::imm(IMM_CHAR, 65));
        ok("retag char->integer", o.c(A2) == Cap::int(65));
        let o = go(&[addi(A1, ZERO, 65), retag(A0, A1, IMM_CHAR, 0)]);
        ok("retag refuses the wrong kind", o.took(C_TYPE, A1));
        let o = go(&[addi(A1, ZERO, 65), retag(A0, A1, 0, IMM_CHAR), retag(A2, A0, 31, IMM_EOF)]);
        ok("retag of any kind", o.c(A2) == Cap::imm(IMM_EOF, 65));
    }
    {
        let ov = |x: i32, y: i32, op: fn(u32, u32, u32) -> u32| go(&two(x, y, op)).took(C_OVER, 0);
        ok("faddo traps", ov(i32::MAX, 1, faddo));
        ok("fsubo traps", ov(i32::MIN, 1, fsubo));
        ok("fmulo traps", ov(1 << 16, 1 << 16, fmulo));
        ok("fdiv of MIN by -1 traps", ov(i32::MIN, -1, fdiv));
        ok("fadd wraps", go(&two(i32::MAX, 1, fadd)).clean());
        let mut v = vec![];
        li32(&mut v, A1, i32::MAX as u32);
        v.push(faddio(A0, A1, 1));
        ok("faddio traps", go(&v).took(C_OVER, 0));
        ok("fdiv by zero", go(&two(1, 0, fdiv)).took(C_DIVZERO, 0));
        ok("frem by zero", go(&two(1, 0, frem)).took(C_DIVZERO, 0));
        // An operand that is not a fixnum names its register.
        let o = go(&[addi(A2, ZERO, 1), ymv(A1, ROOT), fadd(A0, A1, A2)]);
        ok("fop refuses a capability in rs1", o.took(C_TYPE, A1));
        let o = go(&[addi(A1, ZERO, 1), retag(A2, A1, 0, IMM_CHAR), fadd(A0, A1, A2)]);
        ok("fop refuses a character in rs2", o.took(C_TYPE, A2));
        let o = go(&[ymv(A1, ROOT), faddi(A0, A1, 1)]);
        ok("faddi refuses a capability", o.took(C_TYPE, A1));
    }

    // ---- capability inspection and manipulation ----
    {
        let o = go(&[
            ypermr(A0, ROOT),
            ytagr(A1, ROOT),
            ylenr(A2, ROOT),
            ytopr(A3, ROOT),
            ybaser(A4, ROOT),
            ytyper(A5, ROOT),
        ]);
        ok("root: every permission", o.x(A0) == AP_ALL | AP_ONES);
        ok("root: tagged", o.x(A1) == 1);
        ok("root: length saturates", o.x(A2) == u32::MAX);
        ok("root: top saturates", o.x(A3) == u32::MAX);
        ok("root: base 0, unsealed", o.x(A4) == 0 && o.x(A5) == 0);
        ok("integer results are untagged", o.c(A0).meta == 0 && !o.c(A0).tag);
        ok("NULL has no permissions", go(&[ypermr(A0, ZERO)]).x(A0) == AP_ONES);
    }
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x4010);
        code.extend([
            addi(A2, ZERO, 100),
            ybndsrw(A0, A1, A2),
            ybaser(A3, A0),
            ylenr(A4, A0),
            addi(A6, A0, 0),
            yaddi(A7, A0, 4),
            ybaser(S2, A7),
            sub(S2, A7, S2),
        ]);
        let o = go(&code);
        ok("ybndsrw exact", o.x(A3) == 0x4010 && o.x(A4) == 100 && o.c(A0).tag);
        ok("an integer instruction reads the address", o.x(A6) == 0x4010 && !o.c(A6).tag);
        ok("yaddi moves the address", o.x(S2) == 4 && o.c(A7).tag);
    }
    {
        // A length that cannot be exact is rounded out, and the result is
        // still inside its source.
        let mut code = vec![];
        capr(&mut code, A1, 0x0012_3457);
        li32(&mut code, A2, 0x0001_2345);
        code.extend([
            ybndsrw(A0, A1, A2),
            ybaser(A3, A0),
            ylenr(A4, A0),
            yss(A5, ROOT, A0),
            yss(A6, A0, ROOT),
            yamask(S2, A2),
            ybndsw(A7, A1, A2),
            ytagr(S3, A7),
        ]);
        let o = go(&code);
        ok("ybndsrw rounds the base down", o.x(A3) < 0x0012_3457 && o.x(A3) & 7 == 0 && o.c(A0).tag);
        ok("...and the length up", o.x(A4) as u64 + o.x(A3) as u64 >= 0x0012_3457 + 0x1_2345);
        ok("yss", o.x(A5) == 1 && o.x(A6) == 0);
        ok("yamask", o.x(S2) == ram(0x1_2345));
        ok("ybndsw of bounds that would round is untagged", o.x(S3) == 0 && o.c(A7).bounds() == o.c(A0).bounds());
    }
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        code.extend([ybndswi(A0, A1, 16), addi(A2, ZERO, 17), ybndsrw(A3, A0, A2), ytagr(A4, A3)]);
        code.extend([addi(A1, ZERO, 64), ybndswi(A5, A1, 8), ytagr(A6, A5)]);
        let o = go(&code);
        ok("bounds past the authority's are untagged", o.clean() && o.x(A4) == 0);
        ok("bounds of an integer are untagged", o.x(A6) == 0);
        for len in [1, 255, 256, 264, 504, 512, 528, 4032, 4096] {
            let mut code = vec![];
            capr(&mut code, A1, 0x10_0000);
            code.extend([ybndswi(A0, A1, len), ylenr(A2, A0), ytagr(A3, A0)]);
            let o = go(&code);
            ok(&format!("ybndswi {len}"), o.x(A2) == len && o.x(A3) == 1);
        }
    }
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        li32(&mut code, A2, AP_W);
        code.extend([ypermc(A0, A1, A2), ypermr(A3, A0), lw(A4, A0, 0), sw(A4, A0, 0)]);
        let o = go(&code);
        ok("ypermc", o.x(A3) == ap_of(P_ALL & !P_SD) | AP_ONES);
        ok("a store without SD faults", o.took(C_CAP_STORE, 0x4000));
        // What depends on a permission goes with it: C takes SC and LM, R
        // takes LM, X takes ASR, and the bits no permission occupies stay.
        let perms = |mask: u32| {
            let mut code = vec![];
            li32(&mut code, A2, mask);
            code.extend([ypermc(A0, ROOT, A2), ypermr(A1, A0)]);
            go(&code).x(A1)
        };
        ok("clearing C clears SC and LM", perms(AP_C) == ap_of(P_ALL & !(P_LC | P_SC | P_LM)) | AP_ONES);
        ok("clearing R clears LM", perms(AP_R) == ap_of(P_ALL & !(P_LD | P_LM)) | AP_ONES);
        ok("clearing X clears ASR", perms(AP_X) == ap_of(P_ALL & !(P_EX | P_SR)) | AP_ONES);
        ok("clearing S or U clears SE", perms(AP_U) == ap_of(P_ALL & !P_SE) | AP_ONES);
        ok("clearing SC clears only SC", perms(AP_SC) == ap_of(P_ALL & !P_SC) | AP_ONES);
        ok("clearing a reserved bit clears nothing", perms(AP_ONES) == AP_ALL | AP_ONES);
    }
    {
        // An address far outside a small capability's representable region
        // loses the tag; one nearby keeps it.
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        li32(&mut code, A2, 0x0800_0000);
        code.extend([
            ybndswi(A0, A1, 64),
            yaddrw(A3, A0, A2),
            ytagr(A4, A3),
            addi(A2, ZERO, 0x40),
            yadd(A5, A0, A2),
            ytagr(A6, A5),
            addi(A7, ZERO, 3),
            ysh3add(S2, A7, A0),
            ybaser(S3, S2),
            sub(S3, S2, S3),
        ]);
        let o = go(&code);
        ok("yaddrw out of range clears the tag", o.x(A4) == 0);
        ok("yadd to the end keeps it", o.x(A6) == 1);
        ok("ysh3add", o.x(S3) == 24 && o.c(S2).tag);
    }
    {
        let mut code = vec![];
        li32(&mut code, A1, 0x1234);
        li32(&mut code, A2, 0xA000_4000);
        code.extend([yhiw(A0, A1, A2), yhir(A3, A0), ytagr(A4, A0)]);
        let o = go(&code);
        ok("yhiw makes an untagged capability", o.x(A3) == 0xA000_4000 && o.x(A4) == 0 && o.x(A0) == 0x1234);
        // ybld re-tags what root could have made, and nothing else.
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        code.extend([
            ybndswi(A1, A1, 32),
            yhir(A2, A1),
            yhiw(A2, A1, A2),
            ybld(A3, ROOT, A2),
            yeq(A4, A3, A1),
            yeq(A5, A2, A1),
        ]);
        let o = go(&code);
        ok("ybld re-tags", o.x(A4) == 1 && o.c(A3).tag);
        ok("yeq sees the tag", o.x(A5) == 0);
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        li32(&mut code, A2, AP_ALL & !AP_R);
        code.extend([ybndswi(A1, A1, 32), ypermc(A3, A1, A2), yhir(A4, ROOT), yhiw(A4, ROOT, A4), ybld(A5, A3, A4)]);
        let o = go(&code);
        ok("ybld of more than its authority is untagged", o.clean() && !o.c(A5).tag);
        // ybld under a headed object keeps HD only where the bounds
        // instructions would: at the object's own base.
        let obj = region(OBJ, 64, DATA | P_HD);
        let build = |bits: Cap| {
            let mut code = vec![];
            li32(&mut code, A4, bits.addr);
            li32(&mut code, A5, bits.meta);
            code.extend([yhiw(A2, A4, A5), ybld(A3, A1, A2)]);
            go_with(&code, |m| m.set_reg(A1, obj))
        };
        let head = obj.with_bounds_exact(16).unwrap();
        let o = build(head.without_tag());
        ok("ybld keeps HD at the object's base", o.clean() && o.c(A3) == head);
        let slot = obj.with_addr(OBJ + 16).with_bounds_exact(16).unwrap();
        let forged = Cap { meta: slot.meta | (P_HD << PERM_SHIFT), ..slot }.without_tag();
        ok("ybld of HD at a slot is untagged", !build(forged).c(A3).tag);
        // ybld refuses bits that are not the encoding of their bounds: the
        // root's with an exponent of 25, which reads as no bounds.
        let mut code = vec![];
        li32(&mut code, A5, Cap::ROOT.meta + 1);
        code.extend([yhiw(A2, ZERO, A5), ybld(A3, ROOT, A2)]);
        ok("ybld of a malformed exponent is untagged", !go(&code).c(A3).tag);
        // An otype no one may seal without an authority is cleared, a
        // sentry's and a closure's are kept.
        for (ot, kept) in [(OT_SENTRY, true), (OT_CLOSURE, true), (3, false), (4, false)] {
            let bits = region(0x4000, 32, DATA).seal(ot).without_tag();
            let mut code = vec![];
            li32(&mut code, A4, bits.addr);
            li32(&mut code, A5, bits.meta);
            code.extend([yhiw(A2, A4, A5), ybld(A3, ROOT, A2), ytyper(A6, A3)]);
            let o = go(&code);
            ok(&format!("ybld of otype {ot}"), o.c(A3).tag && o.x(A6) == if kept { ot } else { 0 });
        }
    }
    {
        // Two capabilities to the same bytes with different permissions are
        // not identical, and beqx says so where beq does not.
        let mut code = vec![];
        li32(&mut code, A2, AP_S);
        code.extend([
            ypermc(A1, ROOT, A2),
            yeq(A0, A1, ROOT),
            addi(A3, ZERO, 1),
            beqx(A1, ROOT, 8),
            addi(A3, ZERO, 2),
            addi(A4, ZERO, 1),
            bnex(A1, ROOT, 8),
            addi(A4, ZERO, 2),
            addi(A5, ZERO, 1),
            beq(A1, ROOT, 8),
            addi(A5, ZERO, 2),
        ]);
        let o = go(&code);
        ok("yeq", o.x(A0) == 0);
        ok("beqx not taken on different metadata", o.x(A3) == 2);
        ok("bnex taken", o.x(A4) == 1);
        ok("beq compares addresses only", o.x(A5) == 1);
        let o = go(&[addi(A1, ZERO, 5), retag(A2, A1, 0, IMM_CHAR), addi(A3, ZERO, 1), beqx(A1, A2, 8), addi(A3, ZERO, 2)]);
        ok("a fixnum and a character are not identical", o.x(A3) == 2);
    }
    {
        let o = go(&[ymv(A0, ROOT), c_mv(A1, ROOT), addi(A2, ROOT, 0)]);
        ok("ymv keeps the tag", o.c(A0) == Cap::ROOT);
        ok("c.mv is ymv", o.c(A1) == Cap::ROOT);
        ok("addi is integer", !o.c(A2).tag && o.c(A2).meta == 0);
        // Every Zca HINT is a nop, as RVY has them: the register keeps its
        // capability.
        let o = go(&[ymv(A1, ROOT), c_addi(A1, 0), ymv(S0, ROOT), c_srli(S0, 0), c_srai(S0, 0), ymv(A2, ROOT), c_slli(A2, 0)]);
        ok("c.addi by nothing is a nop", o.c(A1) == Cap::ROOT);
        ok("c.srli and c.srai by nothing are nops", o.c(S0) == Cap::ROOT);
        ok("c.slli by nothing is a nop", o.c(A2) == Cap::ROOT);
        ok("c.lui of x0 is a nop", go(&[c_lui(ZERO, 1), addi(A0, ZERO, 7)]).x(A0) == 7);
    }

    // ---- sealing ----
    {
        let mut code = vec![];
        code.extend([
            yseale(A0, ROOT),
            ytyper(A1, A0),
            addi(A3, ZERO, 5),
            yaddrw(A3, ROOT, A3),
            ysealt(A4, A3, ROOT),
            ytyper(A5, A4),
            yunsealt(A6, A3, A4),
            yeq(A7, A6, ROOT),
        ]);
        let o = go(&code);
        ok("yseale", o.x(A1) == OT_SENTRY && o.c(A0).tag);
        ok("ysealt with an SE key", o.x(A5) == 5 && o.c(A4).tag);
        ok("yunsealt undoes it", o.x(A7) == 1);
        let mut c2 = code.clone();
        c2.push(lw(T2, A4, 0));
        ok("a sealed capability cannot be loaded through", go(&c2).took(C_CAP_LOAD, 0));
        let mut c3 = code[..5].to_vec();
        c3.extend([addi(T2, ZERO, 6), yaddrw(T2, ROOT, T2), yunsealt(A6, T2, A4)]);
        let o = go(&c3);
        ok("yunsealt by the wrong otype is untagged", o.clean() && !o.c(A6).tag);
        let mut c4 = code[..5].to_vec();
        c4.push(yaddi(A6, A4, 8));
        c4.push(ytagr(A7, A6));
        ok("moving a sealed capability clears its tag", go(&c4).x(A7) == 0);
        let o = go(&[yseale(A0, ROOT), yseale(A1, A0)]);
        ok("yseale of a sealed capability is untagged", o.clean() && !o.c(A1).tag);
        // ypermc changes a sealed capability's permissions only by untagging
        // it; a mask that clears nothing it has changes nothing.
        let mut c8 = vec![];
        li32(&mut c8, A3, AP_S);
        c8.extend([yseale(A0, ROOT), ypermc(A1, A0, ZERO), yeq(A4, A1, A0), ypermc(A5, A0, A3), ytagr(A6, A5)]);
        let o = go(&c8);
        ok("ypermc of a sealed capability by nothing keeps it", o.x(A4) == 1);
        ok("...and by a permission untags it", o.x(A6) == 0);
        // yadd by x0 is ymv, so it keeps a sealed capability; by a register
        // holding 0 it does not.
        let o = go(&[yseale(A0, ROOT), yadd(A1, A0, ZERO), yeq(A2, A1, A0), yadd(A3, A0, A4), ytagr(A5, A3)]);
        ok("yadd by x0 is ymv", o.x(A2) == 1);
        ok("...and by a register untags a sealed capability", o.x(A5) == 0);
        // A key at otype 2 opens a closure, and so does the root, by
        // superset.
        let mut c5 = vec![addi(A3, ZERO, 2), yaddrw(A3, ROOT, A3), ysealt(A4, A3, ROOT), ytyper(A5, A4)];
        c5.extend([yunsealt(A6, A3, A4), ytyper(A7, A6), yunseals(S2, ROOT, A4), yeq(S3, S2, ROOT)]);
        let o = go(&c5);
        ok("ysealt and yunsealt reach otype 2", o.x(A5) == OT_CLOSURE && o.x(A7) == 0 && o.c(A6).tag);
        ok("yunseals by the root opens it", o.x(S3) == 1);
        let mut c9 = vec![];
        capr(&mut c9, A1, 0x4000);
        c9.extend([ybndswi(A1, A1, 16), yseale(A2, ROOT), yunseals(A3, A1, A2), yunseals(A4, ROOT, ROOT)]);
        let o = go(&c9);
        ok("yunseals needs a superset", !o.c(A3).tag);
        ok("...and a sealed capability", !o.c(A4).tag);
        let mut c6 = vec![];
        li32(&mut c6, A2, AP_S);
        c6.extend([ypermc(A1, ROOT, A2), addi(A3, ZERO, 5), yaddrw(A3, A1, A3), ysealt(A4, A3, ROOT)]);
        ok("ysealt needs SE", !go(&c6).c(A4).tag);
        let mut c7 = code[..5].to_vec();
        li32(&mut c7, A2, AP_U);
        c7.extend([ypermc(A1, A3, A2), yunsealt(A6, A1, A4)]);
        ok("yunsealt needs SE", !go(&c7).c(A6).tag);
        let mut c10 = vec![addi(A3, ZERO, 16), yaddrw(A3, ROOT, A3), ysealt(A4, A3, ROOT)];
        c10.push(ytagr(A5, A4));
        ok("ysealt to an otype the format cannot hold is untagged", go(&c10).x(A5) == 0);
    }

    // ---- capability loads and stores, and tags in memory ----
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x5000);
        code.extend([sy(ROOT, A1, 8), ly(A0, A1, 8), ytagr(A2, A0), lw(A3, A1, 12)]);
        let o = go(&code);
        ok("sy then ly keeps the tag", o.c(A0) == Cap::ROOT && o.x(A2) == 1);
        ok("the metadata is the high word", o.x(A3) == Cap::ROOT.meta);
        ok("memory holds the tag", o.m.tag_at(0x5008) && o.m.load_cap(0x5008) == Cap::ROOT);
        for (name, st) in [("sw", sw(ZERO, A1, 12)), ("sb", sb(ZERO, A1, 9)), ("sh", sh(ZERO, A1, 14))] {
            let mut c2 = code[..code.len() - 2].to_vec();
            c2.extend([st, ly(A0, A1, 8), ytagr(A2, A0)]);
            let o = go(&c2);
            ok(&format!("{name} into the granule clears its tag"), o.x(A2) == 0 && !o.m.tag_at(0x5008));
        }
        let mut c3 = code[..code.len() - 2].to_vec();
        c3.extend([sw(ZERO, A1, 4), ly(A0, A1, 8), ytagr(A2, A0)]);
        ok("a store next door leaves the tag", go(&c3).x(A2) == 1);
        let mut c4 = vec![];
        capr(&mut c4, A1, 0x5000);
        c4.push(ly(A0, A1, 4));
        // A capability split across two granules has no tag to take, so no
        // handler could emulate the access: it is an access fault.
        ok("a misaligned ly is a load access fault", go(&c4).took(C_LFAULT, 0x5004));
        let mut c5 = vec![];
        capr(&mut c5, A1, 0x5000);
        c5.push(sy(ROOT, A1, 2));
        ok("a misaligned sy is a store access fault", go(&c5).took(C_SFAULT, 0x5002));
        // The capability checks come first.
        let mut c6 = vec![];
        capr(&mut c6, A1, 0x5000);
        c6.extend([ybndswi(A1, A1, 16), ly(A0, A1, 12)]);
        ok("a misaligned ly past the bounds is a capability fault", go(&c6).took(C_CAP_LOAD, 0x500c));
        ok("ld is no instruction", go(&[0x0000_3003]).took(C_ILLEGAL, 0x0000_3003));
        ok("custom-2 is RVY's", go(&[0x0000_005b]).took(C_ILLEGAL, 0x0000_005b));
    }
    {
        // Through an authority without SC a tagged store stores the tag as 0;
        // without LC a load drops it; without LM a loaded capability loses
        // SD, SC and LM.
        let mut base = vec![];
        capr(&mut base, A1, 0x5000);
        base.push(sy(ROOT, A1, 0));
        let without = |ap: u32, tail: &[u32]| -> Out {
            let mut v = base.clone();
            li32(&mut v, A2, ap);
            v.push(ypermc(A3, A1, A2));
            v.extend_from_slice(tail);
            go(&v)
        };
        let o = without(AP_SC, &[sy(ROOT, A3, 8), ly(A0, A1, 8)]);
        ok("sy without SC stores the tag as 0", o.clean() && !o.c(A0).tag && o.c(A0).meta == Cap::ROOT.meta);
        let o = without(AP_C, &[ly(A0, A3, 0)]);
        ok("ly without LC drops the tag", !o.c(A0).tag && o.c(A0).meta == Cap::ROOT.meta);
        let o = without(AP_LM, &[ly(A0, A3, 0), ypermr(A4, A0)]);
        ok("ly without LM drops SD, SC and LM", o.x(A4) == ap_of(P_ALL & !(P_SD | P_SC | P_LM)) | AP_ONES && o.c(A0).tag);
        let o = without(AP_R, &[lw(A0, A3, 0)]);
        ok("a load without LD faults", o.took(C_CAP_LOAD, 0x5000));
    }
    {
        // Compressed capability loads and stores, and the cap-mode stack
        // forms.
        let mut code = vec![];
        capr(&mut code, SP, 0x6000);
        code.extend([
            c_sysp(ROOT, 8),
            c_lysp(A0, 8),
            c_addi4spn(S0, 16),
            c_sy(A0, S0, 8),
            c_ly(S1, S0, 8),
            c_addi16sp(-32),
            ytagr(A2, SP),
            addi(A3, SP, 0),
        ]);
        let o = go(&code);
        ok("c.sysp/c.lysp", o.c(A0) == Cap::ROOT);
        ok("c.sy/c.ly", o.c(S1) == Cap::ROOT);
        ok("c.addi4spn makes a capability", o.c(S0).tag && o.x(S0) == 0x6010);
        ok("c.addi16sp moves csp", o.x(A2) == 1 && o.x(A3) == 0x6000 - 32);
    }

    // ---- bounds, and faults that name the address ----
    {
        let mut code = vec![];
        capr(&mut code, A1, 0x4000);
        code.extend([ybndswi(A1, A1, 16), lw(A0, A1, 12)]);
        ok("a load at the end is inside", go(&code).clean());
        let mut c2 = code.clone();
        c2.push(lw(A0, A1, 13));
        ok("a load across the end faults", go(&c2).took(C_CAP_LOAD, 0x400d));
        let mut c3 = code.clone();
        c3.push(sb(ZERO, A1, -1));
        ok("a store below the base faults", go(&c3).took(C_CAP_STORE, 0x3fff));
        let o = go(&[addi(A1, ZERO, 0x400), lw(A0, A1, 0)]);
        ok("an integer is no authority", o.took(C_CAP_LOAD, 0x400));
    }

    // ---- no integer addressing; the root, and SR ----
    {
        // x0 as a base is an encoding RVY reserves, and nothing gives it a
        // meaning: a load or store by number is refused with SR or without.
        for w in [lw(A1, ZERO, 0x100), sw(A0, ZERO, 0x100), ly(A1, ZERO, 0x108), sy(ROOT, ZERO, 0x108)] {
            ok("x0 is no authority, even with SR", go(&[w]).took(C_ILLEGAL, w));
        }
        // Nor does any Xlm instruction take a number for an address: custom-0's
        // R-type funct7 0x7c and 0x7d are unassigned, and illegal.
        let xr = |f7: u32, rs2: u32, rd: u32| (f7 << 25) | (rs2 << 20) | (A2 << 15) | (6 << 12) | (rd << 7) | 0x0b;
        for w in [xr(0x7d, 2, A1), xr(0x7c, A0, 2)] {
            ok("custom-0 0x7c and 0x7d are illegal", go(&[w]).took(C_ILLEGAL, w));
        }
        // The root is a CSR that takes SR to read and that nothing writes.
        let o = go(&[csrrs(A0, CSR_ROOT, ZERO)]);
        ok("the root CSR reads the root", o.c(A0) == Cap::ROOT);
        ok("writing the root CSR is illegal", go(&[csrrw(ZERO, CSR_ROOT, A0)]).took(C_ILLEGAL, csrrw(ZERO, CSR_ROOT, A0)));
        // Without SR every privileged act is an illegal instruction, as RVY
        // has it without ASR.
        let nosr = |m: &mut Machine| m.set_pcc(Cap::ROOT.and_perms(P_ALL & !P_SR).with_addr(BASE));
        let refused = |w: u32| go_with(&[w], nosr).took(C_ILLEGAL, w);
        ok("reading the root needs SR", refused(csrrs(A0, CSR_ROOT, ZERO)));
        ok("writing a CSR needs SR", refused(csrrw(ZERO, 0x340, A0)));
        ok("reading mstatus needs SR", refused(csrrs(A0, 0x300, ZERO)));
        ok("reading gcmode needs SR", refused(csrrs(A0, CSR_GCMODE, ZERO)));
        ok("reading the mark map's capability needs SR", refused(csrrs(A0, CSR_GCMARKS, ZERO)));
        ok("reading mscratch needs SR", refused(csrrs(A0, CSR_MSCRATCH, ZERO)));
        ok("writing utidc needs SR", refused(csrrw(ZERO, CSR_UTIDC, A0)));
        ok("mret needs SR", refused(mret()));
        ok("writing the cycle counter is illegal", go(&[csrrw(ZERO, 0xc00, A0)]).took(C_ILLEGAL, csrrw(ZERO, 0xc00, A0)));
        // The counters, utidc and mtidc are anyone's to read; this run ends
        // at the halt, which needs SR.
        let o = go_with(&[addi(A1, ZERO, 1), csrrs(A0, 0xc00, ZERO), csrrs(A3, CSR_UTIDC, ZERO), csrrs(A4, CSR_MTIDC, ZERO)], nosr);
        ok("the cycle counter and the thread IDs need nothing", matches!(o.trap(), Some((C_ILLEGAL, _, e)) if e == o.end));
        ok("ecall needs nothing", go_with(&[ecall()], nosr).took(C_ECALL, 0));
    }
    {
        // The capability-wide CSRs, and PCC read with auipc.
        let mut code = vec![csrrs(A0, CSR_ROOT, ZERO), auipc(A1, 0)];
        capr(&mut code, A2, 0x7000);
        code.extend([csrrw(ZERO, CSR_UTIDC, A2), csrrs(A3, CSR_UTIDC, ZERO)]);
        code.extend([csrrw(ZERO, CSR_MSCRATCH, A2), csrrs(A4, CSR_MSCRATCH, ZERO)]);
        code.extend([addi(A5, ZERO, 0x40), csrrs(ZERO, CSR_MSCRATCH, A5), csrrs(A6, CSR_MSCRATCH, ZERO)]);
        code.extend([csrrw(ZERO, CSR_GCMARKS, A2), csrrs(A7, CSR_GCMARKS, ZERO)]);
        let o = go(&code);
        ok("csrrs reads the root whole", o.c(A0) == Cap::ROOT);
        ok("auipc reads PCC", o.c(A1).tag && o.c(A1).has(P_EX) && o.x(A1) == BASE + 4);
        ok("csrrw writes a capability whole", o.c(A3) == o.c(A2));
        ok("mscratch holds a capability", o.c(A4) == o.c(A2));
        ok("csrrs writes its address", o.c(A6) == o.c(A2).with_addr(0x7040));
        ok("the mark map's CSR holds a capability", o.c(A7) == o.c(A2));
        let mut code = vec![yseale(A1, ROOT), csrrw(ZERO, CSR_MTVEC, A1), csrrs(A2, CSR_MTVEC, ZERO)];
        code.extend([auipc(A3, 0), yaddi(A3, A3, 1), csrrw(ZERO, CSR_MEPC, A3), csrrs(A4, CSR_MEPC, ZERO)]);
        let o = go(&code);
        ok("a sealed mtvec reads back untagged", !o.c(A2).tag && o.c(A2).otype() == OT_SENTRY);
        ok("an odd mepc is untagged", !o.c(A4).tag);
    }

    // ---- jumps through capabilities: sentries and bounds ----
    {
        // A call and a return through the sentry it left.
        let code = vec![jal(RA, 12), addi(A0, A0, 1), jal(ZERO, 12), addi(A0, A0, 10), jalr(ZERO, RA, 0)];
        let o = go(&code);
        ok("jal leaves a sentry", o.c(RA).tag && o.c(RA).otype() == OT_SENTRY);
        ok("a return through it", o.x(A0) == 11);
        let o = go(&[jal(RA, 8), jal(ZERO, 8), jalr(ZERO, RA, 4)]);
        ok("a sentry is entered only at its address", o.took(C_CAP_FETCH, BASE + 8));
        // A sentry at an odd address has no address a jump can name, so it
        // stays sealed; the jump would otherwise land on BASE + 16.
        for (name, j) in [("jalr", jalr(ZERO, A1, 0)), ("c.jr", c_jr(A1))] {
            let o = go(&[auipc(A1, 0), yaddi(A1, A1, 17), yseale(A1, A1), j]);
            ok(&format!("{name} leaves an odd sentry sealed"), o.took(C_CAP_FETCH, BASE + 16));
        }
        let o = go(&[jal(RA, 8), jal(ZERO, 8), ytyper(A0, RA), lw(A1, RA, 0)]);
        ok("nor read through", o.took(C_CAP_LOAD, BASE + 4));
        // A jump to a capability without EX.
        let mut v = vec![];
        li32(&mut v, A2, AP_X);
        v.extend([auipc(A1, 0), ypermc(A1, A1, A2), jalr(ZERO, A1, 16)]);
        ok("jalr needs EX", go(&v).took(C_CAP_FETCH, BASE + 4 + 16));
        ok("jalr through an integer faults", go(&[addi(A1, ZERO, 64), jalr(ZERO, A1, 0)]).took(C_CAP_FETCH, 64));
        // Code bounded to itself: jumping or running off the end faults.
        let mut v = vec![];
        capr(&mut v, A1, BASE + 0x100);
        v.extend([ybndswi(A1, A1, 8), jalr(RA, A1, 0)]);
        let target = [addi(A0, ZERO, 1), jal(ZERO, 8)];
        let o = go_with(&v, |m| {
            emit(m, BASE + 0x100, &target);
        });
        ok("a jal out of PCC's bounds faults at the jal", o.took(C_CAP_FETCH, BASE + 0x10c));
        ok("...with mepc at the jal", o.trap().map(|t| t.2) == Some(BASE + 0x104) && o.x(A0) == 1);
        // A taken branch out of PCC's bounds faults at the branch too.
        for (name, br) in [("beq", beq(ZERO, ZERO, 8)), ("beqx", beqx(ZERO, ZERO, 8)), ("c.beqz", c_beqz(S0, 8))] {
            let o = go_with(&v, |m| {
                emit(m, BASE + 0x100, &[addi(A0, ZERO, 1), br]);
            });
            ok(
                &format!("a {name} out of PCC's bounds faults at the branch"),
                o.took(C_CAP_FETCH, BASE + 0x10c) && o.trap().map(|t| t.2) == Some(BASE + 0x104),
            );
        }
        let o = go_with(&v, |m| {
            emit(m, BASE + 0x100, &[addi(A0, ZERO, 1), addi(A0, ZERO, 2)]);
        });
        ok("running off the end of PCC faults", o.took(C_CAP_FETCH, BASE + 0x108) && o.x(A0) == 2);
        let mut v2 = vec![];
        capr(&mut v2, A1, BASE + 0x100);
        v2.extend([ybndswi(A1, A1, 8), jalr(RA, A1, 8)]);
        ok("jalr past the bounds faults", go(&v2).took(C_CAP_FETCH, BASE + 0x108));
        let o = go(&[jalr(RA, ROOT, 0)]);
        ok("jalr to address 0 runs nil's cell", o.trap().is_some());
    }

    // ---- traps ----
    {
        let o = go(&[addi(A0, ZERO, 1), 0xffff_ffff]);
        ok("illegal traps to mtvec", o.took(C_ILLEGAL, 0xffff_ffff));
        ok("mepc is PCC at the fault", o.m.mepc.tag && o.m.mepc.addr == BASE + 4 && o.m.mepc.has(P_EX));
        // mtvec goes into PCC as it is: a sentry is not unsealed, so PCC is
        // untagged and the handler is never reached.
        let o = go_with(&[0xffff_ffff], |m| m.mtvec = m.mtvec.seal(OT_SENTRY));
        ok("a trap does not unseal mtvec", !o.m.halted && o.m.mcause == C_CAP_FETCH && o.m.mtval == HANDLER);
        // ecall, then mret resumes after it: mepc is a capability, moved on
        // with yaddi and written back whole.
        let code = [ecall(), addi(A2, ZERO, 77)];
        let handler = [csrrs(A1, CSR_MEPC, ZERO), yaddi(A1, A1, 4), csrrw(ZERO, CSR_MEPC, A1), mret()];
        let o = go_with(&code, |m| {
            emit(m, 0x2100, &handler);
            m.mtvec = Cap::ROOT.with_addr(0x2100);
        });
        ok("ecall and mret resume", o.x(A2) == 77 && o.clean());
        // A timer interrupt preempts a spin.
        let mut code = vec![];
        li32(&mut code, A0, 1 << 7);
        code.push(csrrw(ZERO, 0x304, A0));
        code.push(csrrwi(ZERO, 0x300, 8));
        code.push(jal(ZERO, 0));
        let o = go_with(&code, |m| {
            emit(m, 0x2100, &[addi(A2, ZERO, 55), jal(ZERO, 0)]);
            m.mtvec = Cap::ROOT.with_addr(0x2100);
            m.mtimecmp = 40;
        });
        ok("timer interrupt", o.x(A2) == 55 && o.m.mcause == 0x8000_0000 | IRQ_TIMER);
    }

    // ---- Xlm: pairs ----
    {
        let nil = Cap::NIL;
        let setup = |m: &mut Machine| {
            let p = pair(m, PAIR, Cap::int(111), Cap::int(222));
            m.set_reg(A1, p);
            m.set_reg(TP, Cap::NIL);
        };
        let o = go_with(&[car(A0, A1), cdr(A2, A1)], setup);
        ok("car", o.c(A0) == Cap::int(111));
        ok("cdr", o.c(A2) == Cap::int(222));
        let o = go_with(&[car(A0, TP), cdr(A2, TP)], |m| {
            m.store_cap(NIL_CELL, nil);
            m.store_cap(NIL_CELL + 8, nil);
            m.set_reg(TP, nil);
        });
        ok("car and cdr of nil are nil", o.c(A0) == nil && o.c(A2) == nil);
        let o = go_with(&[addi(A3, ZERO, 9), setcar(A3, A1), setcdr(A1, A1), car(A0, A1), cdr(A2, A1)], setup);
        ok("set-car!", o.c(A0) == Cap::int(9));
        ok("set-cdr! of a pair", o.c(A2) == o.c(A1) && o.m.tag_at(PAIR + 8));
        let o = go_with(&[addi(A3, ZERO, 9), setcar(A3, TP)], |m| m.set_reg(TP, nil));
        ok("set-car! of nil is a wrong type", o.took(C_TYPE, TP));
        ok("car of a fixnum", go(&[addi(A1, ZERO, 5), car(A0, A1)]).took(C_TYPE, A1));
        let o = go_with(&[car(A0, A1)], |m| {
            let v = object(m, OBJ, T_VECTOR, 2);
            m.set_reg(A1, v);
        });
        ok("car of an object", o.took(C_TYPE, A1));
        ok("lref past the pair", go_with(&[lref(A0, A1, 16)], setup).took(C_CAP_LOAD, PAIR + 16));
        ok("a misaligned lref is a load access fault", go_with(&[lref(A0, A1, 4)], setup).took(C_LFAULT, PAIR + 4));
        ok("a misaligned sref is a store access fault", go_with(&[sref(A1, A1, 4)], setup).took(C_SFAULT, PAIR + 4));
        // A pair read through a capability without LM is read only, and so
        // is everything it leads to.
        let ro = |m: &mut Machine| {
            let inner = pair(m, PAIR + 16, Cap::int(1), Cap::int(2));
            let outer = pair(m, PAIR, inner, Cap::NIL);
            m.set_reg(A1, outer.and_perms(DATA & !P_LM));
        };
        let o = go_with(&[car(A2, A1), addi(A3, ZERO, 7), setcar(A3, A2)], ro);
        ok("a read-only list hands out read-only tails", o.took(C_CAP_STORE, PAIR + 16));
        // cons, as the compiler writes it, from a run in gp.
        let run = |m: &mut Machine| m.set_reg(GP, region(PAIR, 32, DATA));
        let cons = |a: u32| [npair(a, GP), yaddi(GP, GP, 16), sy(A2, a, 0), sy(A3, a, 8)];
        let mut v = vec![addi(A2, ZERO, 1), addi(A3, ZERO, 2)];
        v.extend(cons(A0));
        v.extend([vkind(A4, A0), cdr(A5, A0)]);
        let o = go_with(&v, run);
        ok("cons from the run", o.x(A4) == KIND_PAIR && o.c(A5) == Cap::int(2) && o.c(A0).len() == 16);
        let mut v = vec![];
        for _ in 0..3 {
            v.extend(cons(A0));
        }
        ok("a used-up run traps naming gp", go_with(&v, run).took(C_RUN, GP));
        ok("an integer is no run", go(&[addi(A1, ZERO, 64), npair(A0, A1)]).took(C_RUN, A1));
    }

    // ---- Xlm: kinds, symbols, headers ----
    {
        let o = go_with(
            &[
                vkind(A0, A1),
                vkind(A2, A3),
                vkind(A4, TP),
                vkind(A5, A6),
                vkind(A7, ROOT),
                vkind(S2, S3),
                vkind(S4, S5),
                vkind(S6, S7),
            ],
            |m| {
                m.set_reg(A1, Cap::int(5));
                m.set_reg(A3, Cap::imm(IMM_CHAR, 65));
                m.set_reg(TP, Cap::NIL);
                let p = pair(m, PAIR, Cap::NIL, Cap::NIL);
                m.set_reg(A6, p);
                let v = object(m, OBJ, T_VECTOR, 3);
                m.set_reg(S3, v);
                let k = object(m, OBJ + 0x100, T_CLOSURE, 2);
                m.set_reg(S5, k.seal(OT_CLOSURE));
                m.set_reg(S7, Cap::imm(40, 0));
            },
        );
        ok("vkind fixnum", o.x(A0) == IMM_FIXNUM);
        ok("vkind character", o.x(A2) == IMM_CHAR);
        ok("vkind nil", o.x(A4) == KIND_NIL);
        ok("vkind pair", o.x(A5) == KIND_PAIR);
        ok("vkind other capability", o.x(A7) == KIND_CAP);
        ok("vkind vector", o.x(S2) == KIND_OBJECT + T_VECTOR);
        ok("vkind sealed closure", o.x(S4) == KIND_OBJECT + T_CLOSURE);
        ok("vkind high metadata", o.x(S6) == 15);
    }
    {
        let sym = |unbound: bool| {
            move |m: &mut Machine| {
                let s = object(m, OBJ, T_SYMBOL, 6);
                m.store_cap(OBJ + 8, if unbound { Cap::imm(IMM_UNBOUND, 0) } else { Cap::int(42) });
                m.set_reg(A1, s);
            }
        };
        let o = go_with(&[lvar(A0, A1, 8), lhdr(A2, A1, T_SYMBOL), lhdr(A3, A1, 0)], sym(false));
        ok("lvar reads a bound value", o.c(A0) == Cap::int(42));
        ok("lhdr answers the length", o.x(A2) == 6 && o.x(A3) == 6);
        ok("lvar refuses the unbound marker", go_with(&[lvar(A0, A1, 8)], sym(true)).took(C_TYPE, A1));
        ok("lhdr checks the type", go_with(&[lhdr(A0, A1, T_VECTOR)], sym(false)).took(C_TYPE, A1));
        let vecr = |m: &mut Machine| {
            let v = object(m, OBJ, T_VECTOR, 6);
            m.set_reg(A1, v);
        };
        ok("lvar refuses a vector", go_with(&[lvar(A0, A1, 8)], vecr).took(C_TYPE, A1));
        ok("lhdr refuses a pair", go(&[lhdr(A0, ROOT, 0)]).took(C_TYPE, ROOT));
    }

    // ---- Xlm: closures and jcl ----
    {
        let target = BASE + 0x200;
        let setup = move |m: &mut Machine| {
            let k = object(m, OBJ, T_CLOSURE, 3);
            m.store_cap(OBJ, Cap::ROOT.with_addr(target));
            m.store_cap(OBJ + 8, Cap::int(7));
            m.set_reg(T2, k);
            emit(m, target, &[ldxi(A0, T0, 1, T_CLOSURE), jalr(ZERO, RA, 0)]);
        };
        let o = go_with(&[sealcl(T0, T2), ytyper(A2, T0), jcl(RA, T0), ytyper(A3, T0)], setup);
        ok("sealcl seals a closure", o.x(A2) == OT_CLOSURE);
        ok("jcl enters slot 0 with the closure open", o.c(A0) == Cap::int(7) && o.x(A3) == 0);
        ok("...and returns through its sentry", o.clean() && o.c(RA).otype() == OT_SENTRY);
        ok("jcl of an open closure is a wrong type", go_with(&[jcl(RA, T2)], setup).took(C_TYPE, T2));
        ok("jcl of a fixnum", go(&[addi(T0, ZERO, 3), jcl(RA, T0)]).took(C_TYPE, T0));
        ok("sealcl of a vector", go_with(&[sealcl(T0, A1)], |m| {
            let v = object(m, OBJ, T_VECTOR, 3);
            m.set_reg(A1, v);
        }).took(C_TYPE, A1));
        let bad = move |m: &mut Machine| {
            let k = object(m, OBJ, T_CLOSURE, 3);
            m.store_cap(OBJ, Cap::ROOT.with_addr(target).and_perms(DATA));
            m.set_reg(T0, k.seal(OT_CLOSURE));
        };
        ok("jcl needs an executable entry", go_with(&[jcl(RA, T0)], bad).took(C_CAP_FETCH, target));
        let odd = move |m: &mut Machine| {
            setup(m);
            m.store_cap(OBJ, Cap::ROOT.with_addr(target + 1).seal(OT_SENTRY));
        };
        let askew = move |m: &mut Machine| {
            setup(m);
            let k = m.reg(T2).with_addr(OBJ + 4);
            m.set_reg(T2, k);
        };
        let o = go_with(&[sealcl(T0, T2), jcl(RA, T0)], askew);
        ok("jcl of a misaligned closure is a load access fault", o.took(C_LFAULT, OBJ + 4));
        let o = go_with(&[sealcl(T0, T2), jcl(RA, T0)], odd);
        ok("jcl refuses an entry that is an odd sentry", o.took(C_CAP_FETCH, target));
        // jcl loads the entry through the closure, so the closure needs LD
        // and LC as a capability load would.
        for (name, p) in [("LD", P_LD), ("LC", P_LC)] {
            let without = move |m: &mut Machine| {
                let k = object(m, OBJ, T_CLOSURE, 3);
                m.store_cap(OBJ, Cap::ROOT.with_addr(target));
                emit(m, target, &[jalr(ZERO, RA, 0)]);
                m.set_reg(T0, k.and_perms(P_ALL & !p).seal(OT_CLOSURE));
            };
            ok(&format!("jcl needs {name} in the closure"), go_with(&[jcl(RA, T0)], without).took(C_CAP_LOAD, OBJ));
        }
    }

    // ---- Xlm: indexed access ----
    {
        let vecr = |m: &mut Machine| {
            let v = object(m, OBJ, T_VECTOR, 3);
            for i in 0..3 {
                m.store_cap(OBJ + 8 * i, Cap::int(111 * (i + 1)));
            }
            m.set_reg(A1, v);
            let s = object(m, OBJ + 0x100, T_STRING, 5);
            for (i, b) in b"hello".iter().enumerate() {
                m.poke8(OBJ + 0x100 + i as u32, *b);
            }
            m.set_reg(A2, s);
        };
        let o = go_with(
            &[
                addi(A3, ZERO, 1),
                ldx(A0, A1, A3, T_VECTOR),
                ldxi(A4, A1, 2, 0),
                stxi(A1, A1, 0, T_VECTOR),
                ldxi(A5, A1, 0, T_VECTOR),
                addi(A6, ZERO, 0x4a),
                stxb(A6, A2, A3, T_STRING),
                ldxbi(A7, A2, 1, 0),
                ldxb(S2, A2, A3, 0),
            ],
            vecr,
        );
        ok("ldx", o.c(A0) == Cap::int(222));
        ok("ldxi any type", o.c(A4) == Cap::int(333));
        ok("stxi of a capability", o.c(A5) == o.c(A1));
        ok("stxb/ldxbi", o.c(A7) == Cap::int(0x4a) && o.c(S2) == Cap::int(0x4a));
        let t = |code: &[u32]| go_with(code, vecr);
        ok("index at the length", t(&[addi(A3, ZERO, 3), ldx(A0, A1, A3, 0)]).took(C_RANGE, A3));
        ok("negative index", t(&[addi(A3, ZERO, -1), ldx(A0, A1, A3, 0)]).took(C_RANGE, A3));
        ok("immediate index at the length", t(&[ldxi(A0, A1, 3, 0)]).took(C_RANGE, RANGE_IMM));
        ok("an index that is not a fixnum", t(&[retag(A3, ZERO, 0, IMM_CHAR), ldx(A0, A1, A3, 0)]).took(C_TYPE, A3));
        ok("the wrong type", t(&[ldxi(A0, A1, 0, T_RECORD_TYPE)]).took(C_TYPE, A1));
        ok("a byte form refuses a vector", t(&[ldxbi(A0, A1, 0, 0)]).took(C_TYPE, A1));
        ok("a value form refuses a string", t(&[ldxi(A0, A2, 0, 0)]).took(C_TYPE, A2));
        ok("the root is not an object", t(&[ldxi(A0, ROOT, 0, 0)]).took(C_TYPE, ROOT));
        ok("byte index at the length", t(&[ldxbi(A0, A2, 5, 0)]).took(C_RANGE, RANGE_IMM));
        let o = go_with(&[ldxi(A0, A1, 0, 0), stxi(A0, A1, 0, 0)], |m| {
            vecr(m);
            let v = m.reg(A1).and_perms(P_LD | P_LC | P_HD);
            m.set_reg(A1, v);
        });
        ok("stx needs SD", o.took(C_CAP_STORE, OBJ));
    }

    // ---- the write barrier ----
    {
        // The collector's maps, where the barrier is told they are.
        let maps = |m: &mut Machine| {
            m.csr_cap_write(CSR_GCMARKS, region(GC_BITMAP, GC_BITMAP_BYTES, P_LD | P_SD), true);
            m.csr_cap_write(CSR_GCSTARTS, region(OBJ_STARTS, OBJ_STARTS_BYTES, P_LD | P_SD), true);
        };
        // What the barrier names: the register the store went through, and
        // the granule's offset from its base, in granules.
        let named = |reg: u32, granules: u32| (granules << 5) | reg;
        // A pair in cons space whose car points at another pair. With the
        // barrier on, overwriting the car traps while the target is unmarked.
        let setup = |mark: bool| {
            move |m: &mut Machine| {
                let inner = pair(m, PAIR + 0x100, Cap::NIL, Cap::NIL);
                let outer = pair(m, PAIR, inner, Cap::int(5));
                m.set_reg(A1, outer);
                m.gcmode = 1;
                maps(m);
                if mark {
                    let bit = (PAIR + 0x100 - CONS_BASE) >> 3;
                    let w = GC_BITMAP + (bit >> 5) * 4;
                    let old = m.peek32(w);
                    m.poke32(w, old | (1 << (bit & 31)));
                }
            }
        };
        let store = [addi(A3, ZERO, 9), setcar(A3, A1)];
        ok("the barrier traps on an unmarked pointer", go_with(&store, setup(false)).took(C_BARRIER, named(A1, 0)));
        ok("...and not on a marked one", go_with(&store, setup(true)).clean());
        ok("...nor over a fixnum", go_with(&[addi(A3, ZERO, 9), setcdr(A3, A1)], setup(false)).clean());
        ok("a byte store traps too", go_with(&[sb(ZERO, A1, 3)], setup(false)).took(C_BARRIER, named(A1, 0)));
        ok("a capability store too", go_with(&[sy(ZERO, A1, 0)], setup(false)).took(C_BARRIER, named(A1, 0)));
        // The mark is read through the capability in the CSR: a map it does
        // not cover reads as unmarked.
        let unmapped = |m: &mut Machine| {
            setup(true)(m);
            m.csr_cap_write(CSR_GCMARKS, Cap::NULL, true);
        };
        ok("a map the CSR does not reach reads as unmarked", go_with(&store, unmapped).took(C_BARRIER, named(A1, 0)));
        // The register and the offset name the granule from the store's own
        // capability, wherever its address stands.
        let moved = [addi(A3, ZERO, 9), yaddi(A4, A1, 8), sy(A3, A4, -8)];
        ok("...from the base, not the address", go_with(&moved, setup(false)).took(C_BARRIER, named(A4, 0)));
        let objs = |m: &mut Machine| {
            setup(false)(m);
            let v = object(m, OBJ, T_VECTOR, 2);
            let p = m.reg(A1);
            m.store_cap(OBJ + 8, p);
            m.set_reg(A2, v);
        };
        // The pair at PAIR is unmarked too, so overwriting a pointer to it
        // from object space traps naming the slot.
        ok("an indexed store traps", go_with(&[stxi(ZERO, A2, 1, 0)], objs).took(C_BARRIER, named(A2, 1)));
        // A stack and a register context are scanned whole when marking
        // begins, so the barrier lets a store into one through: the type in
        // the header of the object holding the granule says which it is.
        const STATE: u32 = OBJ + 0x200;
        let state = |ty: u32| {
            move |m: &mut Machine| {
                setup(false)(m);
                let s = object(m, STATE, ty, 4);
                let bit = (STATE - 8 - OBJ_BASE) >> 3;
                let w = OBJ_STARTS + (bit >> 5) * 4;
                let old = m.peek32(w);
                m.poke32(w, old | (1 << (bit & 31)));
                let p = m.reg(A1);
                m.store_cap(STATE + 16, p);
                m.set_reg(A2, s);
            }
        };
        let over = [sy(ZERO, A2, 16)];
        ok("a stack is not watched", go_with(&over, state(T_STACK)).clean());
        ok("...nor a context", go_with(&over, state(T_CONTEXT)).clean());
        ok("...nor the kernel block", go_with(&over, state(T_KERNEL)).clean());
        ok("...but a vector is", go_with(&over, state(T_VECTOR)).took(C_BARRIER, named(A2, 2)));

        // A capability narrowed to the cdr of the inner pair keeps that pair:
        // overwriting it traps while the pair is unmarked, whatever its length.
        let narrow = |mark: bool| {
            move |m: &mut Machine| {
                setup(mark)(m);
                let outer = m.reg(A1);
                let inner = m.load_cap(PAIR);
                let cdr = inner.inc(8).with_bounds(8).unwrap();
                m.store_cap(outer.base(), cdr);
            }
        };
        ok("a narrowed pair traps", go_with(&store, narrow(false)).took(C_BARRIER, named(A1, 0)));
        ok("...and not once its pair is marked", go_with(&store, narrow(true)).clean());

        // A capability into a vector's second slot, HD gone, keeps the
        // vector: the object-start map finds its header from the base.
        const VEC: u32 = OBJ + 0x100;
        let interior_as = |mark: bool, start: bool, hd: bool| {
            move |m: &mut Machine| {
                setup(true)(m);
                let v = object(m, VEC, T_VECTOR, 4);
                let slot = v.inc(8).with_bounds(8).unwrap();
                let slot = if hd { slot } else { slot.and_perms(slot.perms() & !P_HD) };
                let outer = m.reg(A1);
                m.store_cap(outer.base(), slot);
                let set = |m: &mut Machine, map: u32, a: u32, from: u32| {
                    let bit = (a - from) >> 3;
                    let w = map + (bit >> 5) * 4;
                    let old = m.peek32(w);
                    m.poke32(w, old | (1 << (bit & 31)));
                };
                if start {
                    set(m, OBJ_STARTS, VEC, OBJ_BASE);
                }
                if mark {
                    set(m, GC_BITMAP, VEC, CONS_BASE);
                }
            }
        };
        let interior = |mark: bool, start: bool| interior_as(mark, start, false);
        ok("a capability into a payload traps", go_with(&store, interior(false, true)).took(C_BARRIER, named(A1, 0)));
        // A headed capability narrowed by the root keeps HD only within
        // object space; the granule below is a slot, not a header, and the
        // map still finds the vector.
        ok("...headed or not", go_with(&store, interior_as(false, true, true)).took(C_BARRIER, named(A1, 0)));
        ok("...and the vector's mark is what it reads", go_with(&store, interior_as(true, true, true)).clean());
        ok("...and not once its object is marked", go_with(&store, interior(true, true)).clean());
        ok("...nor where no object starts below it", go_with(&store, interior(false, false)).clean());
    }

    // ---- the stack limit ----
    {
        let limit = |mie: bool, drop: i32| {
            let mut code = vec![];
            li32(&mut code, A0, 0x9000);
            code.push(csrrw(ZERO, CSR_STKLIM, A0));
            capr(&mut code, SP, 0x9100);
            code.push(csrrwi(ZERO, 0x300, if mie { 8 } else { 0 }));
            code.push(yaddi(SP, SP, drop));
            code.push(addi(A2, ZERO, 1));
            go(&code)
        };
        let o = limit(true, -512);
        ok("a frame below the limit faults", o.took(C_STACK, 0x8f00) && o.x(SP) == 0x9100);
        let o = limit(true, -128);
        ok("a frame above it does not", o.x(A2) == 1 && o.x(SP) == 0x9080);
        let o = limit(false, -512);
        ok("with interrupts off the reserve is usable", o.x(A2) == 1 && o.x(SP) == 0x8f00);
    }

    // ---- devices ----
    {
        let mut code = vec![];
        li32(&mut code, A0, MMIO_BASE + (DEV_UART << 12));
        code.extend([yaddrw(A0, ROOT, A0), lw(A1, A0, 0)]);
        li32(&mut code, A2, MMIO_BASE);
        code.extend([yaddrw(A2, ROOT, A2), sw(A1, A2, 0)]);
        let mut m = Machine::new();
        m.set_reg(ROOT, Cap::ROOT);
        emit(&mut m, RESET_VECTOR, &code);
        m.uart.feed(b"K");
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 60);
        ok("uart receive and sys halt", m.halted && m.exit_code == b'K' as u32);
        // A device capability reaches its page and nothing else.
        let mut code = vec![];
        capr(&mut code, A0, MMIO_BASE + (DEV_UART << 12));
        code.extend([ybndswi(A0, A0, 0x100), lw(A1, A0, 0)]);
        let o = go_with(&code, |m| m.uart.feed(b"Q"));
        ok("a load through a device capability", o.x(A1) == b'Q' as u32);
        let mut c2 = code[..code.len() - 1].to_vec();
        c2.push(ly(A1, A0, 0));
        ok("a device holds no capabilities", go(&c2).took(C_LFAULT, MMIO_BASE + (DEV_UART << 12)));
        // Holding the page is the authority: a load or a store through it
        // needs nothing more, SR included.
        use crate::dev::{TIMER_HZ, TMR_CMPHI, TMR_FREQ};
        let timer = MMIO_BASE + (DEV_TIMER << 12);
        let nosr = |m: &mut Machine| {
            m.set_reg(A1, region(timer, 4096, P_LD | P_SD));
            m.set_pcc(Cap::ROOT.and_perms(P_ALL & !P_SR).with_addr(BASE));
        };
        let o = go_with(&[lw(A0, A1, TMR_FREQ as i32), addi(A2, ZERO, 1), sw(A2, A1, TMR_CMPHI as i32), lw(A3, A1, TMR_CMPHI as i32)], nosr);
        ok("a device page needs no SR", o.x(A0) == TIMER_HZ && o.x(A3) == 1);
    }
    {
        // The blitter is handed a descriptor's capability with a capability
        // store to its list register, fills, and what it writes is data.
        use crate::dev::blit::*;
        let blit = MMIO_BASE + (DEV_BLIT << 12);
        let d = 0x6000u32;
        let mut m = Machine::new();
        put_descriptor(&mut m, d, OP_FILL, region(0x4000, 64, P_SD), Cap::NULL, 16, 4, Cap::NULL);
        m.store_cap(0x4008, Cap::ROOT);
        m.store_cap(0x4100, Cap::ROOT);
        m.set_reg(A1, region(d, LIST_BYTES, DATA));
        let mut code = vec![];
        li32(&mut code, A0, blit + B_LIST);
        code.extend([yaddrw(A0, ROOT, A0), sy(A1, A0, 0)]);
        code.push(jal(ZERO, 0));
        m.set_reg(ROOT, Cap::ROOT);
        emit(&mut m, RESET_VECTOR, &code);
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 400);
        let filled = (0..64).all(|i| m.peek8(0x4000 + i) == 0xAB) && m.peek8(0x4040) == 0;
        ok("blitter fill", filled);
        ok("the blitter clears the tags it writes", !m.tag_at(0x4008) && m.tag_at(0x4100));
        ok(
            "a finished descriptor is done and holds no capability",
            m.peek32(d + L_STATUS) == DONE && !m.tag_at(d + L_DST) && m.blit.read(B_STATUS) == 0,
        );
    }
    {
        // The blitter walks a chain of descriptors, each link a capability.
        use crate::dev::blit::*;
        let mut m = Machine::new();
        let (a, b) = (0x6000u32, 0x6100u32);
        let desc = |at: u32| region(at, LIST_BYTES, DATA);
        put_descriptor(&mut m, a, OP_FILL, region(0x4000, 64, P_SD), Cap::NULL, 16, 4, desc(b));
        put_descriptor(&mut m, b, OP_FILL, region(0x5000, 64, P_SD), Cap::NULL, 16, 4, Cap::NULL);
        m.poke32(b + L_VAL, 0xCD);
        m.set_reg(A1, desc(a));
        let blit = MMIO_BASE + (DEV_BLIT << 12);
        let mut code = vec![];
        li32(&mut code, A0, blit + B_CTRL);
        code.push(addi(A2, ZERO, CTRL_DRAINED as i32));
        code.extend([yaddrw(A0, ROOT, A0), sw(A2, A0, 0)]);
        li32(&mut code, A0, blit + B_LIST);
        code.extend([yaddrw(A0, ROOT, A0), sy(A1, A0, 0)]);
        li32(&mut code, A0, blit + B_STATUS);
        code.extend([yaddrw(A0, ROOT, A0), lw(A2, A0, 0)]);
        code.push(jal(ZERO, 0));
        m.set_reg(ROOT, Cap::ROOT);
        emit(&mut m, RESET_VECTOR, &code);
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 2000);
        let filled = |m: &Machine, at: u32, v: u8| (0..64).all(|i| m.peek8(at + i) == v);
        ok("blitter chain: both ran", filled(&m, 0x4000, 0xAB) && filled(&m, 0x5000, 0xCD));
        ok("blitter chain: each marked done", m.peek32(a + L_STATUS) == DONE && m.peek32(b + L_STATUS) == DONE);
        ok("blitter chain: busy while it runs", m.x[A2 as usize] & STATUS_BUSY != 0);
        ok("blitter chain: one interrupt at the end", m.intreq & (1 << INT_BLIT) != 0);
    }
    {
        // The blitter refuses what its capabilities do not cover: the
        // transfer is not made, its done word says why, the chain goes on,
        // and the status register keeps a bit until it is cleared.
        use crate::dev::blit::*;
        let mut m = Machine::new();
        let (a, b, c) = (0x6000u32, 0x6100u32, 0x6200u32);
        let desc = |at: u32| region(at, LIST_BYTES, DATA);
        // 16 by 4 with rows 16 apart is 64 bytes, into 63.
        put_descriptor(&mut m, a, OP_FILL, region(0x4000, 63, P_SD), Cap::NULL, 16, 4, desc(b));
        // A copy from a source that may not be read.
        put_descriptor(&mut m, b, OP_COPY, region(0x4000, 64, P_SD), region(0x5000, 64, P_SD), 16, 4, desc(c));
        put_descriptor(&mut m, c, OP_FILL, region(0x7000, 64, P_SD), Cap::NULL, 16, 4, Cap::NULL);
        for i in 0..64 {
            m.poke8(0x5000 + i, 0x11);
        }
        m.set_reg(A1, desc(a));
        let blit = MMIO_BASE + (DEV_BLIT << 12);
        let mut code = vec![];
        li32(&mut code, A0, blit + B_LIST);
        code.extend([yaddrw(A0, ROOT, A0), sy(A1, A0, 0)]);
        // Wait for the chain, then read the status, clear its refused bit,
        // and read it again.
        li32(&mut code, A0, blit + B_STATUS);
        code.extend([yaddrw(A0, ROOT, A0), lw(A2, A0, 0)]);
        code.push(andi(A3, A2, STATUS_BUSY as i32));
        code.push(bne(A3, ZERO, -8));
        code.push(addi(A3, ZERO, STATUS_REFUSED as i32));
        code.extend([yaddrw(A0, ROOT, A0), sw(A3, A0, 0)]);
        code.extend([yaddrw(A0, ROOT, A0), lw(A4, A0, 0)]);
        // A number written to the list register is no capability.
        li32(&mut code, A5, blit + B_LIST);
        li32(&mut code, A6, a);
        code.extend([yaddrw(A5, ROOT, A5), sw(A6, A5, 0)]);
        code.extend([yaddrw(A0, ROOT, A0), lw(A7, A0, 0)]);
        code.push(jal(ZERO, 0));
        m.set_reg(ROOT, Cap::ROOT);
        emit(&mut m, RESET_VECTOR, &code);
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 5000);
        let r = |x: u32| m.x[x as usize];
        let untouched = (0..64).all(|i| m.peek8(0x4000 + i) == 0);
        ok("a destination too small is refused", m.peek32(a + L_STATUS) == REFUSED_DST | crate::dev::REFUSE_LENGTH);
        ok("a source without LD is refused", m.peek32(b + L_STATUS) == REFUSED_SRC | crate::dev::REFUSE_LOAD);
        ok("a refused transfer moves nothing", untouched);
        ok("the chain goes on past a refusal", m.peek32(c + L_STATUS) == DONE && m.peek8(0x7000) == 0xAB);
        ok("the status says something was refused", r(A2) == STATUS_REFUSED && r(A4) == 0);
        ok("a number is no descriptor", r(A7) == STATUS_REFUSED);
    }
    {
        // The display is handed its bitmap as a capability, shows only what
        // that lets it read, says why in its status, and hands the
        // capability back to a capability load, as `LY` would load it.
        use crate::dev::gfx::*;
        use crate::dev::{REFUSE_LENGTH, REFUSE_LOAD, REFUSE_TAG};
        let page = MMIO_BASE + (DEV_GFX << 12);
        let pixels = region(0x4000, 256, P_LD | P_SD);
        let show = |bitmap: Cap| {
            let mut code = vec![];
            capr(&mut code, A0, page);
            code.extend([addi(A2, ZERO, 16), sw(A2, A0, G_WIDTH as i32), sw(A2, A0, G_HEIGHT as i32)]);
            code.extend([sw(A2, A0, G_PITCH as i32), addi(A2, ZERO, 8), sw(A2, A0, G_MODE as i32)]);
            code.extend([addi(A2, ZERO, CTRL_ON as i32), sw(A2, A0, G_CTRL as i32)]);
            code.extend([sy(A1, A0, G_BASE as i32), lw(A3, A0, G_STATUS as i32), ly(A4, A0, G_BASE as i32)]);
            code.push(ly(A6, A5, G_BASE as i32));
            go_with(&code, move |m| {
                m.set_reg(A1, bitmap);
                m.set_reg(A5, region(page, 4096, P_LD | P_SD));
            })
        };
        let o = show(pixels);
        ok("the display takes a bitmap it may read", o.clean() && o.x(A3) == 0);
        ok("the scan-out register hands its capability back", o.c(A4) == pixels);
        ok("...without its tag through a page without LC", !o.c(A6).tag && o.c(A6).addr == pixels.addr);
        ok("a number is no bitmap", show(Cap::int(0x4000)).x(A3) == REFUSE_TAG);
        ok("a bitmap too small is refused", show(pixels.with_bounds_exact(255).unwrap()).x(A3) == REFUSE_LENGTH);
        ok("a bitmap it may not read is refused", show(pixels.and_perms(P_SD)).x(A3) == REFUSE_LOAD);
    }
    {
        // The system device's reset register starts the processor again as
        // from power-on: PCC the root at the reset vector, every register and
        // every other capability CSR NULL, memory as it was.
        let sys = MMIO_BASE + (DEV_SYS << 12);
        let mut code = vec![addi(A2, ZERO, 7)];
        capr(&mut code, A0, sys);
        code.extend([addi(A1, ZERO, 1), sw(A1, A0, crate::dev::SYS_RESET as i32), addi(A3, ZERO, 99)]);
        let o = go_with(&code, |m| {
            let mut at = vec![auipc(A4, 0), csrrs(A5, CSR_MSCRATCH, ZERO)];
            halt_through_root(&mut at, ZERO);
            emit(m, RESET_VECTOR, &at);
            m.mscratch = Cap::ROOT;
        });
        ok("a reset starts at the reset vector with the root", o.clean() && o.c(A4) == Cap::ROOT.with_addr(RESET_VECTOR));
        ok("...with the registers and mscratch NULL", o.x(A2) == 0 && o.x(A3) == 0 && o.c(A5) == Cap::NULL);
    }
    {
        // Only a capability register takes a capability, and the blitter's
        // hands none back.
        use crate::dev::blit::*;
        let blit = MMIO_BASE + (DEV_BLIT << 12);
        let mut code = vec![];
        capr(&mut code, A0, blit);
        code.push(sy(ROOT, A0, B_STATUS as i32));
        ok("a capability store to a word register faults", go(&code).took(C_SFAULT, blit + B_STATUS));
        let mut code = vec![];
        capr(&mut code, A0, blit);
        code.push(ly(A1, A0, B_LIST as i32));
        ok("the list register reads back no capability", go(&code).took(C_LFAULT, blit + B_LIST));
    }
    {
        // The disk is handed its buffer as a capability, completes
        // asynchronously, and a read clears the tags of what it fills. A
        // transfer the buffer does not cover is refused and moves nothing.
        use crate::dev::disk::*;
        let path = std::env::temp_dir().join(format!("lm-check-disk-{}.img", std::process::id()));
        let mut m = Machine::new();
        let attached = m.disk.attach(path.to_str().unwrap()).is_ok();
        for i in 0..512u32 {
            m.poke8(0x4000 + i, (i * 7 + 3) as u8);
            m.poke8(0x6000 + i, 0x5a);
        }
        m.store_cap(0x5100, Cap::ROOT);
        m.set_reg(S2, region(0x4000, 512, P_LD));
        m.set_reg(S3, region(0x5000, 512, P_SD));
        m.set_reg(S4, region(0x6000, 248, P_SD));
        let d = MMIO_BASE + (DEV_DISK << 12);
        let reg = |code: &mut Vec<u32>, r: u32, v: u32| {
            li32(code, A0, d + r);
            li32(code, A1, v);
            code.extend([yaddrw(A0, ROOT, A0), sw(A1, A0, 0)]);
        };
        let buf = |code: &mut Vec<u32>, c: u32| {
            li32(code, A0, d + D_BUF);
            code.extend([yaddrw(A0, ROOT, A0), sy(c, A0, 0)]);
        };
        let wait = |code: &mut Vec<u32>, first: u32, last: u32| {
            li32(code, A0, d + D_STATUS);
            code.extend([yaddrw(A0, ROOT, A0), lw(first, A0, 0)]);
            code.extend([yaddrw(A0, ROOT, A0), lw(last, A0, 0)]);
            code.push(beq(last, T0, -4));
        };
        let mut code = vec![];
        li32(&mut code, T0, STATUS_BUSY);
        buf(&mut code, S2);
        reg(&mut code, D_BLOCK, 3);
        reg(&mut code, D_COUNT, 1);
        reg(&mut code, D_CMD, CMD_WRITE);
        wait(&mut code, A2, A3);
        buf(&mut code, S3);
        reg(&mut code, D_CTRL, 1);
        reg(&mut code, D_CMD, CMD_READ);
        wait(&mut code, A4, A7);
        li32(&mut code, A6, 0x5000);
        code.extend([yaddrw(A6, ROOT, A6), lbu(T1, A6, 0)]);
        code.push(addi(A6, A6, 1));
        code.extend([yaddrw(A6, ROOT, A6), lbu(T2, A6, 0)]);
        // A block into 248 bytes, and a block into a number.
        buf(&mut code, S4);
        reg(&mut code, D_CMD, CMD_READ);
        wait(&mut code, S5, S6);
        reg(&mut code, D_BUF, 0x6000);
        reg(&mut code, D_CMD, CMD_READ);
        wait(&mut code, S7, S8);
        code.push(jal(ZERO, 0));
        m.set_reg(ROOT, Cap::ROOT);
        emit(&mut m, RESET_VECTOR, &code);
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        run::run(&mut m, 100_000);
        let r = |x: u32| m.x[x as usize];
        let on_host = std::fs::read(&path)
            .map(|b| b.len() == 4 * 512 && (0..512).all(|i| b[3 * 512 + i] == (i * 7 + 3) as u8))
            .unwrap_or(false);
        let _ = std::fs::remove_file(&path);
        ok("disk attaches a host file", attached);
        ok("disk busy straight after a command", r(A2) == STATUS_BUSY && r(A4) == STATUS_BUSY);
        ok("disk write lands on the host", r(A3) == STATUS_OK && on_host);
        ok("disk read brings the bytes", r(A7) == STATUS_OK && r(T1) == 3 && r(T2) == 10);
        ok("disk read clears the tags it fills", !m.tag_at(0x5100));
        ok("disk completion raises its interrupt", m.intreq & (1 << INT_DISK) != 0);
        ok("a disk read into a buffer too small is refused", r(S6) == STATUS_REFUSED);
        ok("a disk read into a number is refused", r(S8) == STATUS_REFUSED);
        ok("a refused read moves nothing", (0..512).all(|i| m.peek8(0x6000 + i) == 0x5a));
    }

    let fail = checks.iter().filter(|(_, v)| !v).count();
    for (name, v) in &checks {
        if !v {
            println!("FAIL {name}");
        }
    }
    println!("{} passed, {} failed", checks.len() - fail, fail);
    fail == 0
}

/// A record type number the vector test can be wrong about.
const T_RECORD_TYPE: u32 = crate::heap::T_RECORD;

/// Two loops, timed. The first is the integer mix the core was always
/// measured with, through a data capability; the second is what compiled
/// Lisp does most: frame slots through ly and sy, car and cdr, fixnum
/// arithmetic and a call and return.
pub fn bench() {
    let time = |name: &str, code: Vec<u32>, iters: u64, per: u64, setup: &dyn Fn(&mut Machine)| {
        let mut m = Machine::new();
        m.set_reg(ROOT, Cap::ROOT);
        let end = emit(&mut m, BASE, &code);
        m.poke32(end, jal(ZERO, 0));
        m.set_pcc(Cap::ROOT.with_addr(BASE));
        m.mtimecmp = u64::MAX;
        m.gfx.next_vbl = u64::MAX;
        setup(&mut m);
        let t = std::time::Instant::now();
        run::run(&mut m, iters * per + code.len() as u64);
        let el = t.elapsed().as_secs_f64();
        println!("{name}: {} instructions in {el:.3}s = {:.1} MIPS", m.cycles, m.cycles as f64 / el / 1e6);
        // A loop that trapped would be timing the trap handler.
        if m.mcause != 0 {
            println!("  {name} trapped: cause {} at {:#x}", m.mcause, m.mepc.addr);
        }
    };

    let mut code = vec![];
    li32(&mut code, A1, 40_000_000);
    capr(&mut code, A3, 0x8000);
    code.push(addi(A4, ZERO, 1));
    let top = code.len();
    code.extend([
        add(A0, A0, A4),
        xor(A2, A0, A1),
        sw(A2, A3, 0),
        lw(A5, A3, 0),
        add(A0, A0, A5),
        srli(A0, A0, 1),
        addi(A1, A1, -1),
    ]);
    let back = -(((code.len() - top) * 4) as i32);
    code.push(bne(A1, ZERO, back));
    time("integer", code, 40_000_000, 8, &|_| {});

    // The Lisp-shaped loop: a frame in s0, a list in a1, a leaf call.
    let mut code = vec![];
    li32(&mut code, A1, 20_000_000);
    code.push(sy(A1, S0, -40));
    let top = code.len();
    code.extend([
        ly(A2, S0, -40),     // a local
        car(A3, S1),         // car of a list
        cdr(A4, S1),         // and its cdr
        fadd(A0, A3, A0),    // fixnum arithmetic
        jal(RA, 0),          // patched below: call the leaf
        faddi(A2, A2, -1),
        sy(A2, S0, -40),
        bne(A2, ZERO, 0),    // patched below
    ]);
    let n = code.len();
    let leaf = [faddi(A0, A0, 1), jalr(ZERO, RA, 0)];
    let call_at = top + 4;
    code[call_at] = jal(RA, ((n - call_at) * 4 + 8) as i32);
    code[n - 1] = bne(A2, ZERO, -(((n - 1 - top) * 4) as i32));
    code.push(jal(ZERO, 0));
    code.push(0x13);
    code.extend(leaf);
    time("lisp", code, 20_000_000, 10, &|m| {
        m.set_reg(S0, region(0x9000, 0x100, DATA).with_addr(0x9080));
        let p = pair(m, PAIR, Cap::int(3), Cap::NIL);
        m.set_reg(S1, p);
    });
}
