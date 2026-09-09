//! What each package can reach.
//!
//! Every package is a set of symbols, and every symbol is a root: its name,
//! its value, its function, its properties, and whatever those lead to. This
//! walks the heap once per package from exactly those roots and records, for
//! every cell it finds, the set of packages that can get to it.
//!
//! The interesting number is not the totals, which overlap almost completely -
//! compiled code calls other packages' functions through their symbols, so a
//! walk from anywhere ends up nearly everywhere. It is the exclusive weight:
//! what would go away if a package did.

use crate::heap::*;
use crate::image;
use crate::mach::Machine;
use crate::map::*;
use std::collections::{HashMap, HashSet};

/// A pair is two words; an object is its header and payload rounded to eight;
/// a code object is that plus the machine code it points at, which is the
/// only weight in code space anything can be said to own.
fn weight(h: &Heap, v: V) -> u32 {
    if is_cons(v) {
        return 8;
    }
    let hdr = h.hdr(v);
    let mut n = obj_size(hdr);
    if hdr_type(hdr) == T_CODE {
        n += h.slot(v, CODE_LEN);
    }
    n
}

/// The tagged words inside `v`, by the same rule the collector uses.
fn edges(h: &Heap, v: V, out: &mut Vec<V>) {
    if is_cons(v) {
        out.push(h.car(v));
        out.push(h.cdr(v));
        return;
    }
    let hdr = h.hdr(v);
    let len = hdr_len(hdr);
    let (from, to) = match hdr_type(hdr) {
        T_SYMBOL => (0, SYM_SLOTS),
        T_STRING | T_BYTES | T_FLOAT => (0, 0),
        // Slots 0 and 1 are a raw address and a raw length.
        T_CODE => (CODE_NAME, len),
        // Slot 0 is a raw entry address; following it would be a bug.
        T_CLOSURE => (1, len),
        _ => (0, len),
    };
    for i in from..to {
        out.push(h.slot(v, i));
    }
}

fn walkable(v: V) -> bool {
    is_cons(v) || is_obj(v)
}

/// Everything reachable from `roots`, as addresses.
fn reach(h: &Heap, roots: &[V]) -> HashSet<V> {
    let mut seen: HashSet<V> = HashSet::new();
    let mut stack: Vec<V> = Vec::new();
    let mut kids: Vec<V> = Vec::new();
    for r in roots {
        if walkable(*r) && seen.insert(*r) {
            stack.push(*r);
        }
    }
    while let Some(v) = stack.pop() {
        kids.clear();
        edges(h, v, &mut kids);
        for k in kids.drain(..) {
            if walkable(k) && seen.insert(k) {
                stack.push(k);
            }
        }
    }
    seen
}

struct Pkg {
    name: String,
    syms: Vec<V>,
}

pub fn run(path: &str, json: bool) -> i32 {
    let mut m = Machine::new();
    if let Err(e) = image::load(&mut m, path) {
        eprintln!("lm: cannot load {path}: {e}");
        return 1;
    }
    let h = Heap::new(&mut m);

    let mut pkgs: Vec<Pkg> = Vec::new();
    let mut index: HashMap<V, usize> = HashMap::new();
    let mut p = h.g(LG_PACKAGES);
    while is_cons(p) {
        let rec = h.car(p);
        index.insert(rec, pkgs.len());
        pkgs.push(Pkg {
            name: h.str_of(h.slot(rec, PKG_NAME)),
            syms: Vec::new(),
        });
        p = h.cdr(p);
    }
    if pkgs.len() > 32 {
        eprintln!("lm: {} packages is more than a mask holds", pkgs.len());
        return 1;
    }

    let mut homeless = 0;
    let mut p = h.g(LG_SYMLIST);
    while is_cons(p) {
        let s = h.car(p);
        match index.get(&h.slot(s, SYM_PACKAGE)) {
            Some(i) => pkgs[*i].syms.push(s),
            None => homeless += 1,
        }
        p = h.cdr(p);
    }

    // One walk per package, ORing its bit into every cell it reached.
    let mut mask: HashMap<V, u32> = HashMap::new();
    let mut totals: Vec<u64> = vec![0; pkgs.len()];
    for (i, pkg) in pkgs.iter().enumerate() {
        let seen = reach(&h, &pkg.syms);
        for v in seen {
            let w = weight(&h, v) as u64;
            totals[i] += w;
            *mask.entry(v).or_insert(0) |= 1 << i;
        }
    }

    // Context for the picture: everything the collector would keep, and how
    // much of object space is neither kept nor given back. Objects are never
    // moved, so what the build threw away stays in the file as holes.
    let root_slots = [
        LG_SYMLIST,
        LG_OBARRAY,
        LG_PACKAGES,
        LG_PACKAGE,
        LG_BOOTLIST,
        LG_ROOTS,
        LG_TOPLEVEL,
        LG_ERRHANDLER,
        LG_TRAPHOOK,
        LG_REFILL,
        LG_STARTUP,
    ];
    let roots: Vec<V> = root_slots.iter().map(|a| h.g(*a)).collect();
    let (mut live_pairs, mut live_objs, mut live_code) = (0u64, 0u64, 0u64);
    for v in reach(&h, &roots) {
        if is_cons(v) {
            live_pairs += 8;
        } else {
            let hdr = h.hdr(v);
            live_objs += obj_size(hdr) as u64;
            if hdr_type(hdr) == T_CODE {
                live_code += h.slot(v, CODE_LEN) as u64;
            }
        }
    }
    let live_all = live_pairs + live_objs + live_code;
    let obj_high = (h.g(LG_OBJ_PTR) - OBJ_BASE) as u64;
    let code_high = (h.g(LG_CODE_PTR) - CODE_BASE) as u64;
    let pair_high = (h.g(LG_CONS_PTR) - CONS_BASE) as u64;

    // Dead object space, split by whether it can leave the file. The writer
    // skips a page of zeroes, and `gc-for-image` blanks every free block, so a
    // page with nothing live on it costs nothing. A page with one survivor on
    // it costs the whole page - that part is what compacting would reclaim.
    let obj_pages = (obj_high as usize + 4095) / 4096;
    let mut page_used = vec![false; obj_pages.max(1)];
    for v in reach(&h, &roots) {
        if is_cons(v) {
            continue;
        }
        let start = v - 4;
        let end = start + obj_size(h.hdr(v));
        let mut a = start;
        while a < end {
            let i = ((a - OBJ_BASE) / 4096) as usize;
            if i < page_used.len() {
                page_used[i] = true;
            }
            a += 4096 - (a % 4096);
        }
    }
    let empty_pages = page_used.iter().filter(|u| !**u).count();
    // The regions of the diagram: bytes that exactly this set of packages can
    // reach, and nobody else.
    let mut region: HashMap<u32, u64> = HashMap::new();
    let mut live: u64 = 0;
    for (v, bits) in &mask {
        let w = weight(&h, *v) as u64;
        *region.entry(*bits).or_insert(0) += w;
        live += w;
    }

    if json {
        println!("{{");
        println!("  \"image\": {path:?},");
        println!("  \"reachable_bytes\": {live},");
        println!("  \"live_bytes\": {live_all},");
        println!("  \"live\": {{\"pairs\": {live_pairs}, \"objects\": {live_objs}, \"code\": {live_code}}},");
        println!("  \"object_pages\": {{\"total\": {obj_pages}, \"empty\": {empty_pages}}},");
        println!("  \"high_water\": {{\"pairs\": {pair_high}, \"objects\": {obj_high}, \"code\": {code_high}}},");
        println!("  \"packages\": [");
        for (i, pkg) in pkgs.iter().enumerate() {
            let excl = region.get(&(1u32 << i)).copied().unwrap_or(0);
            println!(
                "    {{\"name\": {:?}, \"symbols\": {}, \"total\": {}, \"exclusive\": {}}}{}",
                pkg.name,
                pkg.syms.len(),
                totals[i],
                excl,
                if i + 1 == pkgs.len() { "" } else { "," }
            );
        }
        println!("  ],");
        println!("  \"regions\": [");
        let mut rs: Vec<(&u32, &u64)> = region.iter().collect();
        rs.sort_by(|a, b| b.1.cmp(a.1));
        for (n, (bits, bytes)) in rs.iter().enumerate() {
            println!(
                "    {{\"mask\": {bits}, \"bytes\": {bytes}}}{}",
                if n + 1 == rs.len() { "" } else { "," }
            );
        }
        println!("  ]");
        println!("}}");
        return 0;
    }

    println!("{path}: {live} bytes reachable from {} packages", pkgs.len());
    println!("  {live_all} bytes live in all, against what the image carries:");
    println!("    pairs   {live_pairs:>9} live of {pair_high:>9}");
    println!("    objects {live_objs:>9} live of {obj_high:>9}");
    println!("    code    {live_code:>9} live of {code_high:>9}");
    let dead = obj_high - live_objs;
    let blanked = (empty_pages * 4096) as u64;
    println!(
        "    {} KiB of object space is dead: {} KiB on {empty_pages} empty pages the writer skips,",
        dead / 1024,
        blanked / 1024
    );
    println!(
        "      {} KiB stranded on {} pages that still hold something live",
        dead.saturating_sub(blanked) / 1024,
        obj_pages - empty_pages
    );
    if homeless > 0 {
        println!("  ({homeless} symbols belong to no package)");
    }
    println!();
    println!("  {:<10} {:>7} {:>12} {:>12}", "package", "symbols", "reaches", "exclusive");
    let mut order: Vec<usize> = (0..pkgs.len()).collect();
    order.sort_by(|a, b| totals[*b].cmp(&totals[*a]));
    for i in order {
        let excl = region.get(&(1u32 << i)).copied().unwrap_or(0);
        println!(
            "  {:<10} {:>7} {:>12} {:>12}",
            pkgs[i].name,
            pkgs[i].syms.len(),
            totals[i],
            excl
        );
    }

    println!();
    println!("  the ten heaviest regions");
    let mut rs: Vec<(&u32, &u64)> = region.iter().collect();
    rs.sort_by(|a, b| b.1.cmp(a.1));
    for (bits, bytes) in rs.iter().take(10) {
        let names: Vec<&str> = (0..pkgs.len())
            .filter(|i| *bits & (1 << i) != 0)
            .map(|i| pkgs[i].name.as_str())
            .collect();
        println!("  {:>12}  {}", bytes, names.join(" "));
    }
    0
}
