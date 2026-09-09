//! Object memory.
//!
//! A Lisp value is one 32-bit word:
//!
//!     w == 0            nil. Also a legal cons whose car and cdr are both
//!                       nil, so `car`/`cdr` need no null check at all and
//!                       `null?` is a single `beqz`.
//!     w & 1 == 1        fixnum, value = (i32)w >> 1, range +-2^30. Tagging is
//!                       order preserving, so signed compares work untagged,
//!                       and `add`/`sub` need only a single correction.
//!     w & 7 == 0        cons.   car at [w], cdr at [w+4].
//!     w & 7 == 4        object. header at [w-4], payload from [w].
//!     w & 7 == 2        immediate: kind = (w >> 3) & 31, payload = w >> 8.
//!
//! Header word: (len << 8) | type. `len` counts payload elements - words for
//! the tagged types, bytes for the byte types.
//!
//! Nothing ever moves. The collector is conservative over task stacks, which
//! is what lets compiled code keep values in registers and lets the Exec
//! kernel hold raw pointers into the same heap without any cooperation.

#![allow(dead_code)]

use crate::mach::Machine;
use crate::map::*;

pub type V = u32; // a tagged Lisp value

pub const NIL: V = 0;

// ---- tags ----
#[inline]
pub fn is_fixnum(v: V) -> bool {
    v & 1 == 1
}
#[inline]
pub fn is_cons(v: V) -> bool {
    v != NIL && v & 7 == 0
}
#[inline]
pub fn is_obj(v: V) -> bool {
    v & 7 == 4
}
#[inline]
pub fn is_imm(v: V) -> bool {
    v & 7 == 2
}
#[inline]
pub fn is_ptr(v: V) -> bool {
    v != NIL && (v & 3) == 0
}
#[inline]
pub fn fix(n: i32) -> V {
    ((n as u32) << 1) | 1
}
#[inline]
pub fn unfix(v: V) -> i32 {
    (v as i32) >> 1
}
#[inline]
pub fn obj_addr(v: V) -> u32 {
    v - 4
}

// ---- immediate kinds ----
pub const IMM_CHAR: u32 = 0;
pub const IMM_UNBOUND: u32 = 1;
pub const IMM_EOF: u32 = 2;
pub const IMM_VOID: u32 = 3;
pub const IMM_DEFAULT: u32 = 4;

#[inline]
pub const fn imm(kind: u32, payload: u32) -> V {
    (payload << 8) | (kind << 3) | 2
}
#[inline]
pub fn imm_kind(v: V) -> u32 {
    (v >> 3) & 31
}
#[inline]
pub fn imm_payload(v: V) -> u32 {
    v >> 8
}
pub const UNBOUND: V = imm(IMM_UNBOUND, 0);
pub const EOF: V = imm(IMM_EOF, 0);
pub const VOID: V = imm(IMM_VOID, 0);
#[inline]
pub fn chr(c: u32) -> V {
    imm(IMM_CHAR, c)
}
#[inline]
pub fn is_char(v: V) -> bool {
    is_imm(v) && imm_kind(v) == IMM_CHAR
}

// ---- object types ----
pub const T_FREE: u32 = 0; // a hole in object space: size in granules, then next
pub const T_SYMBOL: u32 = 1; // 5 tagged words: name value function plist flags
pub const T_STRING: u32 = 2; // len bytes
pub const T_VECTOR: u32 = 3; // len tagged words
pub const T_BYTES: u32 = 4; // len raw bytes; machine code lives here
pub const T_CLOSURE: u32 = 5; // word0 raw entry address, rest tagged
pub const T_RECORD: u32 = 6; // len tagged words, word0 is a type tag
pub const T_FLOAT: u32 = 7; // one raw word
pub const T_PORT: u32 = 8; // len tagged words
pub const T_CODE: u32 = 10; // word0 raw entry, word1 raw length, word2 name,
                            // then the literal vector - all tagged from 2 on

pub const SYM_SLOTS: u32 = 6;
pub const SYM_NAME: u32 = 0;
pub const SYM_VALUE: u32 = 1;
pub const SYM_FUNCTION: u32 = 2;
pub const SYM_PLIST: u32 = 3;
pub const SYM_FLAGS: u32 = 4;
pub const SYM_PACKAGE: u32 = 5;

/// Flags, in the low eight bits of SYM_FLAGS. The symbol's identity lives
/// above them. Bit 0 says the symbol names a macro, which the compiler sets
/// and reads; bit 1 says the package it belongs to has made it public.
pub const SYM_MACRO: i32 = 1;
pub const SYM_EXPORTED: i32 = 2;

/// A package: a name, and the list of packages whose exports it inherits.
/// What a package holds is not stored here - the obarray is keyed by package
/// and name together, and a symbol knows which package is its home.
pub const PKG_TAG: u32 = 0;
pub const PKG_NAME: u32 = 1;
pub const PKG_USE: u32 = 2;
pub const PKG_SLOTS: u32 = 3;

/// Closure slot 0 is the raw entry address; slot 1 is the code object; free
/// variables start at slot 2. An entry of 0 marks a closure the build-time
/// interpreter made, whose slots are (0, params, body, env, name).
pub const CODE_ENTRY: u32 = 0;
pub const CODE_LEN: u32 = 1;
pub const CODE_NAME: u32 = 2;
pub const CODE_LITS: u32 = 3;

pub const CLO_ENTRY: u32 = 0;
pub const CLO_CODE: u32 = 1;
pub const CLO_FREE: u32 = 2;
pub const CLO_PARAMS: u32 = 1;
pub const CLO_BODY: u32 = 2;
pub const CLO_ENV: u32 = 3;
pub const CLO_NAME: u32 = 4;

#[inline]
pub fn header(len: u32, ty: u32) -> u32 {
    (len << 8) | ty
}
#[inline]
pub fn hdr_len(h: u32) -> u32 {
    h >> 8
}
#[inline]
pub fn hdr_type(h: u32) -> u32 {
    h & 0xff
}

/// Payload size in bytes for a given header.
pub fn payload_bytes(h: u32) -> u32 {
    let len = hdr_len(h);
    match hdr_type(h) {
        T_SYMBOL => SYM_SLOTS * 4,
        T_STRING | T_BYTES => len,
        T_FLOAT => 4,
        _ => len * 4,
    }
}

/// Total bytes an object occupies, header included, rounded to 8.
pub fn obj_size(h: u32) -> u32 {
    (4 + payload_bytes(h) + 7) & !7
}

// ============================================================== the heap view
/// A view onto the machine's RAM that knows about Lisp objects. The build-time
/// interpreter and the image writer both work through this, so what the
/// compiler builds is literally what the machine will run.
pub struct Heap<'a> {
    pub m: &'a mut Machine,
}

impl<'a> Heap<'a> {
    pub fn new(m: &'a mut Machine) -> Heap<'a> {
        Heap { m }
    }

    // ---- raw words ----
    #[inline]
    pub fn ld(&self, a: u32) -> u32 {
        self.m.peek32(a)
    }
    #[inline]
    pub fn st(&mut self, a: u32, v: u32) {
        self.m.poke32(a, v)
    }
    pub fn g(&self, off: u32) -> u32 {
        self.m.peek32(off)
    }
    pub fn set_g(&mut self, off: u32, v: u32) {
        self.m.poke32(off, v)
    }

    /// Lay out the empty heap. Everything after this is allocation.
    pub fn format(&mut self) {
        // Covers the nil cell, the global block and the object free
        // list bins at 0x200.
        for a in (0..0x300u32).step_by(4) {
            self.st(a, 0);
        }
        self.set_g(LG_CONS_PTR, CONS_BASE);
        self.set_g(LG_CONS_END, CONS_END);
        self.set_g(LG_OBJ_PTR, OBJ_BASE);
        self.set_g(LG_OBJ_END, OBJ_END);
        self.set_g(LG_CODE_PTR, CODE_BASE);
        self.set_g(LG_CODE_END, CODE_END);
        self.set_g(LG_POOLPTR, POOL_BASE);
        self.set_g(LG_POOLEND, POOL_END);
        self.set_g(LG_CONS_FREE, NIL);
        self.set_g(LG_OBJ_FREE, NIL);
        self.set_g(LG_SYMLIST, NIL);
        self.set_g(LG_GCTHRESH, 1 << 20);
    }

    // ---- allocation (bump only; the collector lives in Lisp) ----
    pub fn cons(&mut self, a: V, d: V) -> V {
        let p = self.g(LG_CONS_PTR);
        if p + 8 > self.g(LG_CONS_END) {
            panic!("cons space exhausted at build time");
        }
        self.set_g(LG_CONS_PTR, p + 8);
        self.st(p, a);
        self.st(p + 4, d);
        p
    }

    pub fn alloc_obj(&mut self, ty: u32, len: u32) -> V {
        let h = header(len, ty);
        let sz = obj_size(h);
        let p = self.g(LG_OBJ_PTR);
        if p + sz > self.g(LG_OBJ_END) {
            panic!("object space exhausted at build time");
        }
        self.set_g(LG_OBJ_PTR, p + sz);
        self.st(p, h);
        // Tagged payloads start life as nil; raw payloads as zero. Same thing.
        for i in (4..sz).step_by(4) {
            self.st(p + i, 0);
        }
        p + 4
    }

    pub fn alloc_code(&mut self, nbytes: u32) -> u32 {
        let p = self.g(LG_CODE_PTR);
        let sz = (nbytes + 7) & !7;
        if p + sz > self.g(LG_CODE_END) {
            panic!("code space exhausted");
        }
        self.set_g(LG_CODE_PTR, p + sz);
        p
    }

    /// Exec pool. Raw memory, never collected, never moved.
    pub fn alloc_pool(&mut self, nbytes: u32) -> u32 {
        let p = self.g(LG_POOLPTR);
        let sz = (nbytes + 7) & !7;
        if p + sz > self.g(LG_POOLEND) {
            panic!("exec pool exhausted");
        }
        self.set_g(LG_POOLPTR, p + sz);
        for i in (0..sz).step_by(4) {
            self.st(p + i, 0);
        }
        p
    }

    // ---- cons accessors ----
    #[inline]
    pub fn car(&self, v: V) -> V {
        self.ld(v)
    }
    #[inline]
    pub fn cdr(&self, v: V) -> V {
        self.ld(v + 4)
    }
    pub fn set_car(&mut self, v: V, x: V) {
        self.st(v, x)
    }
    pub fn set_cdr(&mut self, v: V, x: V) {
        self.st(v + 4, x)
    }
    pub fn cadr(&self, v: V) -> V {
        self.car(self.cdr(v))
    }
    pub fn cddr(&self, v: V) -> V {
        self.cdr(self.cdr(v))
    }
    pub fn caddr(&self, v: V) -> V {
        self.car(self.cddr(v))
    }
    pub fn cdddr(&self, v: V) -> V {
        self.cdr(self.cddr(v))
    }
    pub fn cadddr(&self, v: V) -> V {
        self.car(self.cdddr(v))
    }

    // ---- object accessors ----
    #[inline]
    pub fn hdr(&self, v: V) -> u32 {
        self.ld(v - 4)
    }
    pub fn otype(&self, v: V) -> u32 {
        if is_obj(v) {
            hdr_type(self.hdr(v))
        } else {
            0
        }
    }
    pub fn olen(&self, v: V) -> u32 {
        hdr_len(self.hdr(v))
    }
    #[inline]
    pub fn slot(&self, v: V, i: u32) -> V {
        self.ld(v + i * 4)
    }
    #[inline]
    pub fn set_slot(&mut self, v: V, i: u32, x: V) {
        self.st(v + i * 4, x)
    }
    pub fn is_type(&self, v: V, t: u32) -> bool {
        is_obj(v) && hdr_type(self.hdr(v)) == t
    }

    // ---- lists ----
    pub fn list(&mut self, items: &[V]) -> V {
        let mut r = NIL;
        for &x in items.iter().rev() {
            r = self.cons(x, r);
        }
        r
    }
    pub fn list_len(&self, mut v: V) -> u32 {
        let mut n = 0;
        while is_cons(v) {
            n += 1;
            v = self.cdr(v);
        }
        n
    }
    pub fn list_vec(&self, mut v: V) -> Vec<V> {
        let mut out = Vec::new();
        while is_cons(v) {
            out.push(self.car(v));
            v = self.cdr(v);
        }
        out
    }
    pub fn nth(&self, mut v: V, mut n: u32) -> V {
        while n > 0 && is_cons(v) {
            v = self.cdr(v);
            n -= 1;
        }
        self.car(v)
    }
    /// Append in place is not needed; this builds a fresh list.
    pub fn append2(&mut self, a: V, b: V) -> V {
        let items = self.list_vec(a);
        let mut r = b;
        for &x in items.iter().rev() {
            r = self.cons(x, r);
        }
        r
    }
    pub fn reverse(&mut self, v: V) -> V {
        let items = self.list_vec(v);
        self.list(&items)
    }

    // ---- strings ----
    pub fn string(&mut self, s: &str) -> V {
        let b = s.as_bytes();
        let p = self.alloc_obj(T_STRING, b.len() as u32);
        for (i, &c) in b.iter().enumerate() {
            self.m.poke8(p + i as u32, c);
        }
        p
    }
    pub fn str_of(&self, v: V) -> String {
        if !self.is_type(v, T_STRING) {
            return String::new();
        }
        let n = self.olen(v);
        let mut s = String::with_capacity(n as usize);
        for i in 0..n {
            s.push(self.m.peek8(v + i) as char);
        }
        s
    }

    pub fn bytes(&mut self, b: &[u8]) -> V {
        let p = self.alloc_obj(T_BYTES, b.len() as u32);
        for (i, &c) in b.iter().enumerate() {
            self.m.poke8(p + i as u32, c);
        }
        p
    }

    pub fn vector(&mut self, items: &[V]) -> V {
        let p = self.alloc_obj(T_VECTOR, items.len() as u32);
        for (i, &x) in items.iter().enumerate() {
            self.set_slot(p, i as u32, x);
        }
        p
    }

    pub fn float(&mut self, f: f32) -> V {
        let p = self.alloc_obj(T_FLOAT, 1);
        self.st(p, f.to_bits());
        p
    }
    pub fn float_of(&self, v: V) -> f32 {
        f32::from_bits(self.ld(v))
    }

    // ---- symbols ----
    /// Symbols are chained through the obarray, a vector of buckets, and also
    /// threaded onto a flat list so the collector can walk every one of them.
    pub fn obarray(&mut self) -> V {
        let o = self.g(LG_OBARRAY);
        if o != NIL {
            return o;
        }
        let v = self.alloc_obj(T_VECTOR, 1021);
        self.set_g(LG_OBARRAY, v);
        v
    }

    /// djb2, masked to 30 bits every round. The mask is not decoration: the
    /// same hash is computed in Lisp by `string-hash`, where intermediates are
    /// fixnums, and a symbol interned at build time has to land in the same
    /// bucket as one interned by the running machine or they would not be eq.
    pub fn sym_hash(name: &str) -> u32 {
        let mut h: u32 = 5381;
        for &b in name.as_bytes() {
            h = (h.wrapping_mul(33).wrapping_add(b as u32)) & 0x3fff_ffff;
        }
        h
    }

    /// djb2 again, but over the package name, a colon, and the symbol name,
    /// so that two packages can each have a `draw-char` without colliding.
    /// `qualified_hash` in Lisp computes exactly this, and the two agreeing is
    /// what makes a symbol read at build time eq to one read by the machine.
    pub fn qual_hash(pkg: &str, name: &str) -> u32 {
        let mut h: u32 = 5381;
        for &b in pkg.as_bytes() {
            h = (h.wrapping_mul(33).wrapping_add(b as u32)) & 0x3fff_ffff;
        }
        h = (h.wrapping_mul(33).wrapping_add(b':' as u32)) & 0x3fff_ffff;
        for &b in name.as_bytes() {
            h = (h.wrapping_mul(33).wrapping_add(b as u32)) & 0x3fff_ffff;
        }
        h
    }

    pub fn package_name(&self, p: V) -> String {
        self.str_of(self.slot(p, PKG_NAME))
    }

    /// Find a package by name, or make one. The first one made is `lm`, which
    /// has to exist before any symbol can, so its tag is filled in afterwards.
    pub fn package(&mut self, name: &str) -> V {
        let mut p = self.g(LG_PACKAGES);
        while p != NIL {
            let pkg = self.car(p);
            if self.package_name(pkg) == name {
                return pkg;
            }
            p = self.cdr(p);
        }
        let nm = self.string(name);
        let pkg = self.alloc_obj(T_RECORD, PKG_SLOTS);
        self.set_slot(pkg, PKG_TAG, NIL);
        self.set_slot(pkg, PKG_NAME, nm);
        self.set_slot(pkg, PKG_USE, NIL);
        let all = self.g(LG_PACKAGES);
        let cell = self.cons(pkg, all);
        self.set_g(LG_PACKAGES, cell);
        let tag = self.intern("package");
        self.set_slot(pkg, PKG_TAG, tag);
        pkg
    }

    /// The package everything lands in until something says otherwise.
    pub fn base_package(&mut self) -> V {
        self.package("lm")
    }

    pub fn exported(&self, s: V) -> bool {
        unfix(self.slot(s, SYM_FLAGS)) & SYM_EXPORTED != 0
    }

    pub fn set_exported(&mut self, s: V) {
        let f = unfix(self.slot(s, SYM_FLAGS));
        self.set_slot(s, SYM_FLAGS, fix(f | SYM_EXPORTED));
    }

    /// The symbol of this name in this package, if it is already there.
    pub fn find_in(&mut self, pkg: V, name: &str) -> V {
        let ob = self.obarray();
        let n = self.olen(ob);
        let b = Heap::qual_hash(&self.package_name(pkg), name) % n;
        let mut chain = self.slot(ob, b);
        while chain != NIL {
            let s = self.car(chain);
            if self.slot(s, SYM_PACKAGE) == pkg && self.str_of(self.slot(s, SYM_NAME)) == name {
                return s;
            }
            chain = self.cdr(chain);
        }
        NIL
    }

    pub fn intern_in(&mut self, pkg: V, name: &str) -> V {
        let found = self.find_in(pkg, name);
        if found != NIL {
            return found;
        }
        let ob = self.obarray();
        let n = self.olen(ob);
        let b = Heap::qual_hash(&self.package_name(pkg), name) % n;
        let nm = self.string(name);
        let s = self.alloc_obj(T_SYMBOL, SYM_SLOTS);
        self.set_slot(s, SYM_NAME, nm);
        self.set_slot(s, SYM_VALUE, UNBOUND);
        self.set_slot(s, SYM_FUNCTION, NIL);
        self.set_slot(s, SYM_PLIST, NIL);
        // Flags in the low eight bits, the symbol's identity above them.
        // Interning is the only place a symbol is made, on either side of the
        // bootstrap, so the counter in low memory is what keeps the two from
        // ever handing out the same number.
        let idx = self.g(LG_SYMCOUNT);
        self.set_g(LG_SYMCOUNT, idx + 1);
        self.set_slot(s, SYM_FLAGS, fix((idx << 8) as i32));
        self.set_slot(s, SYM_PACKAGE, pkg);
        let head = self.slot(ob, b);
        let cell = self.cons(s, head);
        self.set_slot(ob, b, cell);
        let all = self.g(LG_SYMLIST);
        let cell2 = self.cons(s, all);
        self.set_g(LG_SYMLIST, cell2);
        s
    }

    pub fn intern(&mut self, name: &str) -> V {
        let p = self.base_package();
        self.intern_in(p, name)
    }

    /// `pkg:name`, for the places on the Rust side that reach into the Lisp
    /// by name. A bare name means the prelude, which is where the primitives
    /// and the special forms live.
    pub fn intern_path(&mut self, path: &str) -> V {
        match path.split_once(':') {
            Some((pkg, name)) => {
                let p = self.package(pkg);
                let name = name.strip_prefix(':').unwrap_or(name);
                self.intern_in(p, name)
            }
            None => self.intern(path),
        }
    }

    pub fn sym_name(&self, s: V) -> String {
        self.str_of(self.slot(s, SYM_NAME))
    }
    pub fn is_symbol(&self, v: V) -> bool {
        self.is_type(v, T_SYMBOL)
    }
    pub fn sym_value(&self, s: V) -> V {
        self.slot(s, SYM_VALUE)
    }
    pub fn set_sym_value(&mut self, s: V, v: V) {
        self.set_slot(s, SYM_VALUE, v)
    }
    pub fn sym_function(&self, s: V) -> V {
        self.slot(s, SYM_FUNCTION)
    }
    pub fn set_sym_function(&mut self, s: V, v: V) {
        self.set_slot(s, SYM_FUNCTION, v)
    }

    /// A property list lookup on a symbol, used for compiler annotations.
    pub fn get_prop(&self, s: V, key: V) -> V {
        let mut p = self.slot(s, SYM_PLIST);
        while is_cons(p) {
            if self.car(p) == key {
                return self.cadr(p);
            }
            p = self.cddr(p);
        }
        NIL
    }
    pub fn put_prop(&mut self, s: V, key: V, val: V) {
        let mut p = self.slot(s, SYM_PLIST);
        while is_cons(p) {
            if self.car(p) == key {
                let c = self.cdr(p);
                self.set_car(c, val);
                return;
            }
            p = self.cddr(p);
        }
        let old = self.slot(s, SYM_PLIST);
        let c1 = self.cons(val, old);
        let c2 = self.cons(key, c1);
        self.set_slot(s, SYM_PLIST, c2);
    }

    // ---- printing ----
    pub fn write(&self, v: V) -> String {
        let mut s = String::new();
        self.write_into(v, &mut s, true, 0);
        s
    }
    pub fn display(&self, v: V) -> String {
        let mut s = String::new();
        self.write_into(v, &mut s, false, 0);
        s
    }

    fn write_into(&self, v: V, out: &mut String, quoted: bool, depth: u32) {
        if depth > 24 {
            out.push_str("...");
            return;
        }
        if v == NIL {
            out.push_str("nil");
            return;
        }
        if is_fixnum(v) {
            out.push_str(&unfix(v).to_string());
            return;
        }
        if is_imm(v) {
            match imm_kind(v) {
                IMM_CHAR => {
                    let c = imm_payload(v);
                    if quoted {
                        out.push_str("#\\");
                        match c {
                            32 => out.push_str("space"),
                            10 => out.push_str("newline"),
                            9 => out.push_str("tab"),
                            _ => out.push(char::from_u32(c).unwrap_or('?')),
                        }
                    } else {
                        out.push(char::from_u32(c).unwrap_or('?'));
                    }
                }
                IMM_UNBOUND => out.push_str("#<unbound>"),
                IMM_EOF => out.push_str("#<eof>"),
                IMM_VOID => out.push_str("#<void>"),
                _ => out.push_str("#<immediate>"),
            }
            return;
        }
        if is_cons(v) {
            // (quote x) prints as 'x, which keeps compiler dumps readable.
            let h = self.car(v);
            if self.is_symbol(h) && is_cons(self.cdr(v)) && self.cddr(v) == NIL {
                let n = self.sym_name(h);
                let pre = match n.as_str() {
                    "quote" => Some("'"),
                    "quasiquote" => Some("`"),
                    "unquote" => Some(","),
                    "unquote-splicing" => Some(",@"),
                    _ => None,
                };
                if let Some(p) = pre {
                    out.push_str(p);
                    self.write_into(self.cadr(v), out, quoted, depth + 1);
                    return;
                }
            }
            out.push('(');
            let mut p = v;
            let mut n = 0;
            loop {
                if n > 0 {
                    out.push(' ');
                }
                if n > 512 {
                    out.push_str("...");
                    break;
                }
                self.write_into(self.car(p), out, quoted, depth + 1);
                p = self.cdr(p);
                n += 1;
                if p == NIL {
                    break;
                }
                if !is_cons(p) {
                    out.push_str(" . ");
                    self.write_into(p, out, quoted, depth + 1);
                    break;
                }
            }
            out.push(')');
            return;
        }
        if is_obj(v) {
            match self.otype(v) {
                T_SYMBOL => {
                    // The bootstrap prints a bare name: it has one package,
                    // and the machine's own printer is the one that has to
                    // decide when a name needs qualifying.
                    out.push_str(&self.sym_name(v))
                }
                T_STRING => {
                    let s = self.str_of(v);
                    if quoted {
                        out.push('"');
                        for c in s.chars() {
                            match c {
                                '"' => out.push_str("\\\""),
                                '\\' => out.push_str("\\\\"),
                                '\n' => out.push_str("\\n"),
                                _ => out.push(c),
                            }
                        }
                        out.push('"');
                    } else {
                        out.push_str(&s);
                    }
                }
                T_VECTOR => {
                    out.push_str("#(");
                    let n = self.olen(v);
                    for i in 0..n.min(256) {
                        if i > 0 {
                            out.push(' ');
                        }
                        self.write_into(self.slot(v, i), out, quoted, depth + 1);
                    }
                    if n > 256 {
                        out.push_str(" ...");
                    }
                    out.push(')');
                }
                T_BYTES => {
                    out.push_str(&format!("#<bytes {} @{:#x}>", self.olen(v), v));
                }
                T_CODE => {
                    let nm = self.slot(v, CODE_NAME);
                    let nm = if self.is_symbol(nm) {
                        self.sym_name(nm)
                    } else {
                        "anonymous".to_string()
                    };
                    out.push_str(&format!(
                        "#<code {} {:#x} {} bytes, {} literals>",
                        nm,
                        self.slot(v, CODE_ENTRY),
                        self.slot(v, CODE_LEN),
                        self.olen(v).saturating_sub(CODE_LITS)
                    ));
                }
                T_CLOSURE => {
                    let entry = self.slot(v, CLO_ENTRY);
                    if entry == 0 {
                        let nm = self.slot(v, CLO_NAME);
                        if self.is_symbol(nm) {
                            out.push_str(&format!("#<interpreted {}>", self.sym_name(nm)));
                        } else {
                            out.push_str("#<interpreted>");
                        }
                    } else {
                        // A compiled closure knows its own name, through the
                        // code object it shares with every frame that runs it.
                        let code = self.slot(v, CLO_CODE);
                        let nm = if is_obj(code) && self.otype(code) == T_CODE {
                            self.slot(code, CODE_NAME)
                        } else {
                            NIL
                        };
                        if self.is_symbol(nm) {
                            out.push_str(&format!("#<function {}>", self.sym_name(nm)));
                        } else if nm != NIL {
                            out.push_str("#<function ");
                            self.write_into(nm, out, quoted, depth + 1);
                            out.push('>');
                        } else {
                            out.push_str(&format!("#<function {entry:#x}>"));
                        }
                    }
                }
                T_FLOAT => out.push_str(&format!("{}", self.float_of(v))),
                T_RECORD => {
                    let tag = self.slot(v, 0);
                    out.push_str("#[");
                    self.write_into(tag, out, quoted, depth + 1);
                    for i in 1..self.olen(v).min(64) {
                        out.push(' ');
                        self.write_into(self.slot(v, i), out, quoted, depth + 1);
                    }
                    out.push(']');
                }
                t => out.push_str(&format!("#<type{t} {v:#x}>")),
            }
            return;
        }
        out.push_str(&format!("#<raw {v:#x}>"));
    }
}
