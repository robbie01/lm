//! Look inside an image without running it.

use crate::heap::*;
use crate::image;
use crate::mach::Machine;
use crate::map::*;

/// What every tagged granule in RAM is, by where it lies and what it names.
#[derive(Default)]
struct Census {
    nils: u32,
    pairs: u32,
    objects: u32,
    other: u32,
    /// Granules that hold a capability where none belongs, and capabilities
    /// that name something that is not there.
    wrong: Vec<(u32, String)>,
}

/// A capability that names a pair or an object must name a live one: a pair
/// in cons space below the bump pointer, an object whose header is a live
/// header in object space. Code space holds machine code and never a
/// capability, and neither does a string or a byte object.
fn census(h: &Heap) -> Census {
    let mut c = Census::default();
    let (cons_hi, obj_hi, code_hi) = (h.g(LG_CONS_PTR), h.g(LG_OBJ_PTR), h.g(LG_CODE_PTR));
    let byte_objects = byte_object_spans(h);
    for at in h.tagged() {
        let v = h.ldc(at);
        if (CODE_BASE..code_hi).contains(&at) {
            c.wrong.push((at, "a capability in code space".into()));
            continue;
        }
        let i = byte_objects.partition_point(|s| s.0 <= at);
        if i > 0 && at < byte_objects[i - 1].1 {
            c.wrong.push((at, "a capability inside a string or byte object".into()));
            continue;
        }
        if v == NIL {
            c.nils += 1;
        } else if is_obj(v) {
            let hdr = v.addr.wrapping_sub(HEADER_BYTES);
            let ok = (OBJ_BASE..obj_hi).contains(&hdr) && hdr_type(h.ld(hdr)) != T_FREE;
            if ok {
                c.objects += 1;
            } else {
                c.wrong.push((at, format!("an object capability to {:#x}, where no object is", v.addr)));
            }
        } else if is_cons(v) {
            if v.addr < cons_hi {
                c.pairs += 1;
            } else {
                c.wrong.push((at, format!("a pair capability to {:#x}, above the pairs", v.addr)));
            }
        } else {
            c.other += 1;
        }
    }
    c
}

/// Where the payload of every string and byte object lies, in address order.
fn byte_object_spans(h: &Heap) -> Vec<(u32, u32)> {
    let mut out = Vec::new();
    let hi = h.g(LG_OBJ_PTR);
    let mut p = OBJ_BASE;
    while p < hi {
        let hdr = h.ld(p);
        let sz = block_size(hdr);
        if sz == 0 {
            break;
        }
        if is_byte_type(hdr_type(hdr)) {
            out.push((p + HEADER_BYTES, p + sz));
        }
        p += sz;
    }
    out
}

/// The function whose code holds `at`, by its code object's entry.
fn owner(h: &Heap, at: u32) -> String {
    let mut p = h.gv(LG_SYMLIST);
    while is_cons(p) {
        let sym = h.car(p);
        let f = h.sym_value(sym);
        if h.is_type(f, T_CLOSURE) {
            let entry = h.slot(f, CLO_ENTRY);
            if entry.tag && entry.covers(at, 1) {
                return h.sym_name(sym);
            }
        }
        p = h.cdr(p);
    }
    "?".into()
}

pub fn run(path: &str, names: &[String]) -> i32 {
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
        (h.g(LG_CONS_PTR) - CONS_BASE) / PAIR_BYTES
    );
    println!(
        "  cons run {:#x}..{:#x}, boot list {} thunks, obarray {:#x}",
        h.g(LG_CONS_RUN),
        h.g(LG_CONSRUNEND),
        h.list_len(h.gv(LG_BOOTLIST)),
        h.gv(LG_OBARRAY).addr
    );

    // Walk every symbol and count how many carry a value.
    let mut total = 0;
    let mut bound = 0;
    let mut dups: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut p = h.gv(LG_SYMLIST);
    while is_cons(p) {
        let s = h.car(p);
        *dups.entry(h.sym_name(s)).or_insert(0) += 1;
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

    // Invariant: code holds no heap addresses. A pointer is a tagged
    // capability, and code space is machine code reached through its code
    // objects, so a tag in code space is a pointer compiled into an
    // instruction stream; an integer there can name nothing. Every other
    // capability must name what it says it does.
    let c = census(&h);
    println!(
        "  {} capabilities: {} nil, {} to pairs, {} to objects, {} raw",
        c.nils + c.pairs + c.objects + c.other + c.wrong.len() as u32,
        c.nils,
        c.pairs,
        c.objects,
        c.other
    );
    if c.wrong.is_empty() {
        println!("  no heap addresses baked into code, and no capability names what is not there");
    } else {
        println!("  {} capabilities are where none belongs:", c.wrong.len());
        for (at, what) in c.wrong.iter().take(8) {
            let who = if (CODE_BASE..CODE_END).contains(at) {
                format!(" in {}", owner(&h, *at))
            } else {
                String::new()
            };
            println!("    {at:#x}: {what}{who}");
        }
    }

    // Anything named on the command line gets reported in full.
    for want in names {
        let mut p = h.gv(LG_SYMLIST);
        let mut found = false;
        while is_cons(p) {
            let s = h.car(p);
            if h.sym_name(s) == *want {
                found = true;
                println!(
                    "  {want}: symbol {:#x} value {} function {} flags {}",
                    s.addr,
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
    i32::from(!c.wrong.is_empty())
}
