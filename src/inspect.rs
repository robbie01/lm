//! Look inside an image without running it.

use crate::heap::*;
use crate::image;
use crate::mach::Machine;
use crate::map::*;

pub fn run(args: &[String]) -> i32 {
    let path = args.first().map(|s| s.as_str()).unwrap_or("kick.img");
    let mut m = Machine::new();
    let loaded = match image::load(&mut m, path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("lm: cannot load {path}: {e}");
            return 1;
        }
    };
    let h = Heap::new(&mut m);
    println!("{path}: entry {:#x}", loaded.entry);
    println!(
        "  code {} KiB, objects {} KiB, pairs {}",
        (h.g(LG_CODE_PTR) - CODE_BASE) / 1024,
        (h.g(LG_OBJ_PTR) - OBJ_BASE) / 1024,
        (h.g(LG_CONS_PTR) - CONS_BASE) / 8
    );
    println!(
        "  cons run {:#x}..{:#x}, boot list {} thunks, obarray {:#x}",
        h.g(LG_CONS_RUN),
        h.g(LG_CONSRUNEND),
        h.list_len(h.g(LG_BOOTLIST)),
        h.g(LG_OBARRAY)
    );

    // Walk every symbol and count how many carry a value.
    let mut total = 0;
    let mut bound = 0;
    let mut dups: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut p = h.g(LG_SYMLIST);
    while is_cons(p) {
        let s = h.car(p);
        let name = h.sym_name(s);
        *dups.entry(name).or_insert(0) += 1;
        total += 1;
        if h.sym_value(s) != UNBOUND {
            bound += 1;
        }
        p = h.cdr(p);
    }
    println!("  {total} symbols, {bound} bound");
    let mut repeated: Vec<(&String, &u32)> = dups.iter().filter(|(_, &n)| n > 1).collect();
    if !repeated.is_empty() {
        repeated.sort();
        println!("  {} names interned more than once", repeated.len());
        for (n, c) in repeated.iter().take(10) {
            println!("    {n} x{c}");
        }
    }

    // The invariant that makes everything movable: no instruction anywhere in
    // code space may materialise an address in the heap. Data is reached only
    // through the literal vector, so a `lui` whose immediate lands in cons or
    // object space would be a pointer the collector cannot find or update.
    {
        let lo = h.g(LG_CODE_PTR);
        let mut baked = Vec::new();
        let mut a = CODE_BASE;
        while a + 4 <= lo {
            let w = h.ld(a);
            if w & 0x7f == 0x37 {
                // lui rd, hi  [; addi rd, rd, lo]. Decode the pair, because a
                // fixnum constant is 2n+1 and its high half can land in the
                // heap range by coincidence. Only an even, correctly aligned
                // result is a pointer the collector would have to fix up.
                let rd = (w >> 7) & 31;
                let mut v = w & 0xffff_f000;
                let nx = h.ld(a + 4);
                if nx & 0x7f == 0x13 && (nx >> 12) & 7 == 0
                    && (nx >> 7) & 31 == rd && (nx >> 15) & 31 == rd
                {
                    v = v.wrapping_add(((nx as i32) >> 20) as u32);
                }
                let tag = v & 7;
                if (CONS_BASE..OBJ_END).contains(&v) && (tag == 0 || tag == 4) {
                    baked.push((a, v));
                }
            }
            a += 2;
        }
        if baked.is_empty() {
            println!("  no heap addresses baked into code");
        } else {
            println!("  {} instructions bake a heap address in:", baked.len());
            for (at, v) in baked.iter().take(8) {
                // Name the function it landed in, by looking for the code
                // object whose extent covers it.
                let mut who = String::from("?");
                let mut p = h.g(LG_SYMLIST);
                while is_cons(p) {
                    let sym = h.car(p);
                    let f = h.sym_value(sym);
                    if h.is_type(f, T_CLOSURE) {
                        let code = h.slot(f, CLO_CODE);
                        if h.is_type(code, T_CODE) {
                            let e = h.slot(code, CODE_ENTRY);
                            let n = h.slot(code, CODE_LEN);
                            if *at >= e && *at < e + n {
                                who = h.sym_name(sym);
                                break;
                            }
                        }
                    }
                    p = h.cdr(p);
                }
                let w0 = h.ld(*at);
                let w1 = h.ld(*at + 4);
                println!("    {at:#x} -> {v:#x}  in {who}  [{w0:08x} {w1:08x}]");
            }
        }
    }

    // Anything named on the command line gets reported in full.
    for want in &args[1..] {
        let mut p = h.g(LG_SYMLIST);
        let mut found = false;
        while is_cons(p) {
            let s = h.car(p);
            if h.sym_name(s) == *want {
                found = true;
                println!(
                    "  {want}: symbol {:#x} value {} function {} flags {}",
                    s,
                    h.write(h.sym_value(s)),
                    h.write(h.sym_function(s)),
                    h.write(h.slot(s, SYM_FLAGS))
                );
            }
            p = h.cdr(p);
        }
        if !found {
            println!("  {want}: no such symbol");
        }
    }
    0
}
