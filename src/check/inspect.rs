//! Look inside an image without running it.

use crate::cap::P_EX;
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
    /// Entries and return addresses: capabilities with EX.
    code: u32,
    other: u32,
    /// Capabilities in a stack or a context that name nothing: slots that
    /// hold what an earlier call left there. The collector checks a header
    /// before it believes one, and the compactor drops their tags.
    stale: u32,
    /// Granules that hold a capability where none belongs, and capabilities
    /// that name something that is not there.
    wrong: Vec<(u32, String)>,
}

/// A capability that names a pair or an object must name a live one: a pair
/// in cons space below the bump pointer, an object whose header is a live
/// header in object space, except in a stack or a context, where a slot may
/// hold a stale one. One with EX, an entry or a return address, must lie in the
/// text of a function or in the reset stub. A string, a byte object or a
/// function's text holds no capability at all.
fn census(h: &Heap) -> Census {
    let mut c = Census::default();
    let (cons_hi, obj_hi) = (h.g(LG_CONS_PTR), h.g(LG_OBJ_PTR));
    let spans = spans_of(h, is_byte_type);
    let states = spans_of(h, is_state_type);
    let stale = |at: u32| {
        let k = states.partition_point(|s| s.0 <= at);
        k > 0 && at < states[k - 1].1
    };
    let texts: Vec<&(u32, u32, u32)> = spans.iter().filter(|s| s.2 == T_TEXT).collect();
    let stub = RESET_VECTOR..RESET_VECTOR + RESET_RESERVE;
    for at in h.tagged() {
        let v = h.ldc(at);
        let i = spans.partition_point(|s| s.0 <= at);
        if i > 0 && at < spans[i - 1].1 {
            let what = if spans[i - 1].2 == T_TEXT { "machine code" } else { "a string or byte object" };
            c.wrong.push((at, format!("a capability inside {what}")));
            continue;
        }
        if v == NIL {
            c.nils += 1;
        } else if is_obj(v) {
            let hdr = v.base() - HEADER_BYTES;
            let ok = (OBJ_BASE..obj_hi).contains(&hdr) && hdr_type(h.ld(hdr)) != T_FREE;
            if ok {
                c.objects += 1;
            } else if stale(at) {
                c.stale += 1;
            } else {
                c.wrong.push((at, format!("an object capability to {:#x}, where no object is", v.base())));
            }
        } else if is_cons(v) {
            if v.addr < cons_hi {
                c.pairs += 1;
            } else if stale(at) {
                c.stale += 1;
            } else {
                c.wrong.push((at, format!("a pair capability to {:#x}, above the pairs", v.addr)));
            }
        } else if v.perms() & P_EX != 0 {
            let k = texts.partition_point(|s| s.0 <= v.base());
            let in_text = k > 0 && v.top() <= texts[k - 1].1 as u64;
            if in_text || (stub.contains(&v.base()) && v.top() <= stub.end as u64) {
                c.code += 1;
            } else if stale(at) {
                c.stale += 1;
            } else {
                c.wrong.push((at, format!("code at {:#x}, where no function's text is", v.base())));
            }
        } else {
            c.other += 1;
        }
    }
    c
}

/// Where the payload of every object of the types `which` picks lies, in
/// address order, with its type.
fn spans_of(h: &Heap, which: fn(u32) -> bool) -> Vec<(u32, u32, u32)> {
    let blocks = h.blocks().unwrap_or_else(|_| Vec::new());
    blocks
        .into_iter()
        .filter(|&(_, hdr)| which(hdr_type(hdr)))
        .map(|(p, hdr)| (p + HEADER_BYTES, p + block_size(hdr), hdr_type(hdr)))
        .collect()
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
        "  objects {} KiB ({} KiB of it code), pairs {}",
        (h.g(LG_OBJ_PTR) - OBJ_BASE) / 1024,
        h.text_bytes() / 1024,
        (h.g(LG_CONS_PTR) - CONS_BASE) / PAIR_BYTES
    );
    println!(
        "  boot list {} thunks, obarray {:#x}",
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
    // capability, and a function's text is a byte object, so a tag inside
    // one is a pointer compiled into an instruction stream; an integer there
    // can name nothing. Every other capability must name what it says it
    // does.
    let c = census(&h);
    println!(
        "  {} capabilities: {} nil, {} to pairs, {} to objects, {} to code, {} raw",
        c.nils + c.pairs + c.objects + c.code + c.other + c.stale + c.wrong.len() as u32,
        c.nils,
        c.pairs,
        c.objects,
        c.code,
        c.other
    );
    if c.stale > 0 {
        println!("  {} stale capabilities in stacks and contexts, naming nothing", c.stale);
    }
    if c.wrong.is_empty() {
        println!("  no heap addresses baked into code, and no capability names what is not there");
    } else {
        println!("  {} capabilities are where none belongs:", c.wrong.len());
        for (at, what) in c.wrong.iter().take(8) {
            let who = if what.contains("machine code") {
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
