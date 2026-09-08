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
        (h.g(LG_CONS_RUN) - CONS_BASE) / 8
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
