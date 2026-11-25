//! What each package can reach.
//!
//! Every package is a set of symbols, and every symbol is a root: its name,
//! its value, its function, its properties, and whatever those lead to. This
//! walks the heap once per package from exactly those roots and records, for
//! every cell it finds, the set of packages that can get to it.
//!
//! The totals overlap almost completely: compiled code calls other packages'
//! functions through their symbols, so a walk from anywhere reaches nearly
//! everything. The exclusive weight is the useful number: the bytes that
//! would go away if the package did.

use crate::heap::*;
use crate::image;
use crate::mach::Machine;
use crate::map::*;
use std::collections::HashMap;

/// A pair is its 16 bytes. An object is its block, header included. A code
/// object also counts the block of its text, which its entry reaches and
/// which is how machine code is attributed.
fn weight(h: &Heap, v: V) -> u32 {
    if is_cons(v) {
        return PAIR_BYTES;
    }
    let hdr = h.hdr(v);
    let mut n = block_size(hdr);
    if hdr_type(hdr) == T_CODE {
        n += text_block(h, v).map_or(0, |(_, size)| size);
    }
    n
}

/// Where the text a code object's entry covers starts, header included, and
/// how many bytes its block occupies.
fn text_block(h: &Heap, code: V) -> Option<(u32, u32)> {
    let entry = h.slot(code, CODE_ENTRY);
    let at = entry.base().wrapping_sub(HEADER_BYTES);
    let hdr = h.ld(at);
    (entry.tag && hdr_type(hdr) == T_TEXT).then(|| (at, block_size(hdr)))
}

/// What `v` holds, by the rule the collector uses: every slot of a pair or
/// of an object of a value type. Only the ones that name a pair or an object
/// are followed.
fn edges(h: &Heap, v: V, out: &mut Vec<V>) {
    if is_cons(v) {
        out.push(h.car(v));
        out.push(h.cdr(v));
        return;
    }
    let hdr = h.hdr(v);
    if is_byte_type(hdr_type(hdr)) {
        return;
    }
    for i in 0..hdr_len(hdr) {
        out.push(h.slot(v, i));
    }
}

fn walkable(v: V) -> bool {
    is_cons(v) || is_obj(v)
}

/// Everything reachable from `roots`, keyed by the base of each pair or
/// object: two capabilities to one object, a sealed closure and the same
/// closure unsealed or a read-only view and the original, are one cell.
fn reach(h: &Heap, roots: &[V]) -> HashMap<u32, V> {
    let mut seen: HashMap<u32, V> = HashMap::new();
    let mut stack: Vec<V> = roots.to_vec();
    let mut kids: Vec<V> = Vec::new();
    while let Some(v) = stack.pop() {
        if !walkable(v) || seen.insert(v.base(), v).is_some() {
            continue;
        }
        kids.clear();
        edges(h, v, &mut kids);
        stack.extend_from_slice(&kids);
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
    let mut p = h.gv(LG_PACKAGES);
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
    let mut p = h.gv(LG_SYMLIST);
    while is_cons(p) {
        let s = h.car(p);
        match index.get(&h.slot(s, SYM_PACKAGE)) {
            Some(i) => pkgs[*i].syms.push(s),
            None => homeless += 1,
        }
        p = h.cdr(p);
    }

    // One walk per package, ORing its bit into every cell it reached.
    let mut mask: HashMap<u32, (V, u32)> = HashMap::new();
    let mut totals: Vec<u64> = vec![0; pkgs.len()];
    for (i, pkg) in pkgs.iter().enumerate() {
        for (base, v) in reach(&h, &pkg.syms) {
            totals[i] += weight(&h, v) as u64;
            mask.entry(base).or_insert((v, 0)).1 |= 1 << i;
        }
    }

    // Context: everything the collector would keep, against what the image
    // carries. A page of zeroes costs the file nothing, and
    // `collect-for-image` blanks every free block, so only a page with
    // something live on it is written; what is dead on such a page stays
    // until the forge compacts the image.
    let roots: Vec<V> = VALUE_GLOBALS.iter().map(|a| h.gv(*a)).collect();
    let obj_high = (h.g(LG_OBJ_PTR) - OBJ_BASE) as u64;
    let code_high = h.text_bytes() as u64;
    let pair_high = (h.g(LG_CONS_PTR) - CONS_BASE) as u64;
    let obj_pages = (obj_high as usize).div_ceil(4096);
    let mut page_used = vec![false; obj_pages.max(1)];
    let mut used = |at: u32, size: u32| {
        let start = at - OBJ_BASE;
        for page in start / 4096..=(start + size - 1) / 4096 {
            if let Some(u) = page_used.get_mut(page as usize) {
                *u = true;
            }
        }
    };
    let (mut live_pairs, mut live_objs, mut live_code) = (0u64, 0u64, 0u64);
    for v in reach(&h, &roots).into_values() {
        if is_cons(v) {
            live_pairs += PAIR_BYTES as u64;
            continue;
        }
        let hdr = h.hdr(v);
        live_objs += block_size(hdr) as u64;
        used(v.base() - HEADER_BYTES, block_size(hdr));
        if hdr_type(hdr) == T_CODE {
            if let Some((at, size)) = text_block(&h, v) {
                live_code += size as u64;
                used(at, size);
            }
        }
    }
    let live_all = live_pairs + live_objs + live_code;
    let empty_pages = page_used.iter().filter(|u| !**u).count();

    // The regions: bytes that exactly this set of packages can reach and no
    // other package does.
    let mut region: HashMap<u32, u64> = HashMap::new();
    let mut reachable: u64 = 0;
    for (v, bits) in mask.values() {
        let w = weight(&h, *v) as u64;
        *region.entry(*bits).or_insert(0) += w;
        reachable += w;
    }

    if json {
        println!("{{");
        println!("  \"image\": {path:?},");
        println!("  \"reachable_bytes\": {reachable},");
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

    println!("{path}: {reachable} bytes reachable from {} packages", pkgs.len());
    println!("  {live_all} bytes live in all, against what the image carries:");
    println!("    pairs   {live_pairs:>9} live of {pair_high:>9}");
    println!("    objects {live_objs:>9} live of {:>9}", obj_high - code_high);
    println!("    code    {live_code:>9} live of {code_high:>9}");
    let dead = obj_high - live_objs - live_code;
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
