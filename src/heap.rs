//! Object memory.
//!
//! A Lisp value is a capability (`src/cap.rs`), 64 bits and a tag:
//!
//! ```text
//! untagged, metadata 0     a fixnum: the address field, 32 bits signed
//! untagged, metadata k     an immediate of kind k: a character, the
//!                          unbound marker, eof, void, the default marker
//! tagged, no HD            a pair: 16 bytes in cons space, car at 0 and
//!                          cdr at 8
//! tagged, HD               an object: the header is the granule below
//!                          the base, and the bounds are the payload
//! tagged, HD, otype 2      a closure, sealed
//! tagged, otherwise        a raw capability: code, a stack, a pool block
//! ```
//!
//! nil is a read-only capability to the 16-byte cell at address 0, whose car
//! and cdr hold nil, so `car` and `cdr` of nil need no test.
//!
//! An object's header word 0 is `(len << 8) | type`, and word 1 is 0. `len`
//! counts elements: 8-byte value slots, or bytes for a string or a byte
//! object. A payload whose length is not exactly representable as bounds is
//! rounded up to one that is, and its base aligned to match; the space the
//! alignment skips is a free hole.
//!
//! This is the forge's view of the heap: the bootstrap interpreter, the image
//! writer and the bench all build and read objects through it, so what the
//! compiler builds is what the machine runs.

use crate::cap::{self, Cap, P_EX, P_HD, P_LC, P_LD, P_LM, P_SC, P_SD};
use crate::mach::Machine;
use crate::map::*;
use num_bigint::{BigInt, Sign};
use num_traits::ToPrimitive;

/// A Lisp value.
pub type V = Cap;

/// The size of a value slot, and of a granule: one capability.
pub const VALUE_BYTES: u32 = 8;
/// An object's header is one granule, just below its payload.
pub const HEADER_BYTES: u32 = 8;

// ---- permissions, in `cgetperm` positions ----
/// A pair can be read and written, and holds capabilities.
pub const PERMS_PAIR: u32 = P_LD | P_SD | P_LC | P_SC | P_LM;
/// An object of a value type: a pair's permissions and HD.
pub const PERMS_OBJECT: u32 = PERMS_PAIR | P_HD;
/// A string or a byte object holds data and never a capability.
pub const PERMS_BYTES: u32 = P_LD | P_SD | P_HD;
/// nil can be read, and nothing else.
pub const PERMS_NIL: u32 = P_LD | P_LC;
/// A code object's entry: execute, and nothing else. `unsafe` code adds SR.
pub const PERMS_CODE: u32 = P_EX;

/// The bytes nil names: its car and its cdr.
pub const NIL_BYTES: u32 = 16;
/// A pair's bounds.
pub const PAIR_BYTES: u32 = 16;

/// nil: the capability to the cell at 0, with LD and LC.
pub const NIL: V = Cap::NIL;

/// The immediate kinds: the metadata of an untagged value.
pub use crate::cap::{IMM_CHAR, IMM_DEFAULT, IMM_EOF, IMM_FIXNUM, IMM_UNBOUND, IMM_VOID};

pub const UNBOUND: V = Cap::imm(IMM_UNBOUND, 0);
pub const EOF: V = Cap::imm(IMM_EOF, 0);
pub const VOID: V = Cap::imm(IMM_VOID, 0);
pub const DEFAULT: V = Cap::imm(IMM_DEFAULT, 0);

// ---- kinds, as `vkind` answers them ----
/// 0..15 is an untagged value's metadata; these are the tagged kinds.
pub const VK_NIL: u32 = 16;
pub const VK_PAIR: u32 = 17;
pub const VK_CAP: u32 = 31;
/// An object's kind is this plus its header type.
pub const VK_OBJECT: u32 = 32;

// ---- values ----
#[inline]
pub const fn fix(n: i32) -> V {
    Cap::int(n as u32)
}
#[inline]
pub fn unfix(v: V) -> i32 {
    v.addr as i32
}
#[inline]
pub fn is_fixnum(v: V) -> bool {
    !v.tag && v.meta == IMM_FIXNUM
}
/// An untagged value that is not a fixnum.
#[inline]
pub fn is_imm(v: V) -> bool {
    !v.tag && v.meta != IMM_FIXNUM
}
#[inline]
pub fn imm_kind(v: V) -> u32 {
    v.meta
}
#[inline]
pub fn imm_payload(v: V) -> u32 {
    v.addr
}
#[inline]
pub const fn chr(c: u32) -> V {
    Cap::imm(IMM_CHAR, c)
}
#[inline]
pub fn is_char(v: V) -> bool {
    !v.tag && v.meta == IMM_CHAR
}
/// A tagged, unsealed capability without HD to a pair's 16 bytes in cons
/// space. nil is not one.
#[inline]
pub fn is_cons(v: V) -> bool {
    v.tag
        && (CONS_BASE..CONS_END).contains(&v.addr)
        && !v.is_sealed()
        && !v.has(P_HD)
        && v.bounds() == (v.addr, (v.addr + PAIR_BYTES) as u64)
}
/// A tagged capability with HD into object space: an object, sealed or not.
/// The root has HD as it has every permission, but it is not an object.
#[inline]
pub fn is_obj(v: V) -> bool {
    v.tag && v.has(P_HD) && (OBJ_BASE + HEADER_BYTES..OBJ_END).contains(&v.addr)
}
/// What `vkind` answers for this value.
pub fn vkind(h: &Heap, v: V) -> u32 {
    if !v.tag {
        v.meta.min(15)
    } else if v == NIL {
        VK_NIL
    } else if is_obj(v) {
        VK_OBJECT + hdr_type(h.hdr(v))
    } else if is_cons(v) {
        VK_PAIR
    } else {
        VK_CAP
    }
}

/// The cons run with nothing in it: no bytes at the base of cons space, so
/// the first pair cut from it faults and asks for a real one. It is not a
/// pair, being no pair's length.
pub fn empty_cons_run() -> Cap {
    cap_to(CONS_BASE, 0, PERMS_PAIR)
}

/// A capability to `len` bytes at `base`, with `perms`, derived from the
/// root. The bounds must be exactly representable.
pub fn cap_to(base: u32, len: u32, perms: u32) -> Cap {
    match Cap::root().with_addr(base).with_bounds_exact(len) {
        Some(c) => c.and_perms(perms),
        None => panic!("{len} bytes at {base:#x} are not representable"),
    }
}

/// `x` rounded up to the alignment `mask` asks for, as CRAM answers it.
#[inline]
pub fn align_up(x: u32, mask: u32) -> u32 {
    x.wrapping_add(!mask) & mask
}
#[inline]
pub fn round8(x: u32) -> u32 {
    (x + 7) & !7
}

// ---- object types ----
pub const T_FREE: u32 = 0; // a hole: its size in granules, header included
pub const T_SYMBOL: u32 = 1; // name value function plist flags package
pub const T_STRING: u32 = 2; // bytes
pub const T_VECTOR: u32 = 3; // values
pub const T_BYTES: u32 = 4; // bytes
pub const T_CLOSURE: u32 = 5; // entry, code object, free variables
pub const T_RECORD: u32 = 6; // the type symbol, then fields
pub const T_FLOAT: u32 = 7; // the bits, as a fixnum
pub const T_PORT: u32 = 8; // values
/// Slot 0 is the sign, 0 for positive and 1 for negative; the rest are the
/// magnitude as 32-bit limbs held as fixnums, least significant first.
/// Normalised: the top limb is never zero and the value never fits a fixnum,
/// so any value that fits is a fixnum and `eq?` works on small numbers.
pub const T_BIGNUM: u32 = 9;
pub const T_CODE: u32 = 10; // entry, name, literals

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
/// Bit 2 says the name is a raw operation or a function that hands out raw
/// memory: the compiler refuses it outside an `unsafe` form or file.
pub const SYM_UNSAFE: i32 = 4;

/// A package: a name, and the list of packages whose exports it inherits.
/// What a package holds is not stored here: the obarray is keyed by package
/// and name together, and a symbol records its home package.
pub const PKG_TAG: u32 = 0;
pub const PKG_NAME: u32 = 1;
pub const PKG_USE: u32 = 2;
pub const PKG_SLOTS: u32 = 3;

/// A code object: slot 0 the entry, an EX capability whose bounds are the
/// machine code; slot 1 the name; the literals from slot 2.
pub const CODE_ENTRY: u32 = 0;
pub const CODE_NAME: u32 = 1;
pub const CODE_LITS: u32 = 2;

/// A closure: slot 0 the entry, slot 1 the code object, the free variables
/// from slot 2. The machine's closures are sealed. One the bootstrap
/// interpreter makes is not, and holds a fixnum where the entry would be,
/// then its parameters, body, environment and name.
pub const CLO_ENTRY: u32 = 0;
pub const CLO_CODE: u32 = 1;
pub const CLO_FREE: u32 = 2;
pub const CLO_PARAMS: u32 = 1;
pub const CLO_BODY: u32 = 2;
pub const CLO_ENV: u32 = 3;
pub const CLO_NAME: u32 = 4;

/// The low-memory globals that hold values rather than addresses or counts.
/// They start as nil.
pub const VALUE_GLOBALS: &[u32] = &[
    LG_SYMLIST,
    LG_OBARRAY,
    LG_PACKAGES,
    LG_PACKAGE,
    LG_BOOTLIST,
    LG_ROOTS,
    LG_TOPLEVEL,
    LG_ERRHANDLER,
    LG_TRAPHOOK,
    LG_STARTUP,
    LG_TASKEXIT,
    LG_BOOTARG,
];

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
/// Strings and byte objects hold bytes; every other type holds values.
#[inline]
pub fn is_byte_type(ty: u32) -> bool {
    ty == T_STRING || ty == T_BYTES
}

/// The payload's length in bytes, which is the length its bounds round up
/// from.
pub fn payload_bytes(h: u32) -> u32 {
    if is_byte_type(hdr_type(h)) {
        hdr_len(h)
    } else {
        hdr_len(h) * VALUE_BYTES
    }
}

/// The bytes an object's bounds cover: its payload, rounded up to a length
/// the bounds can say exactly.
pub fn bounds_bytes(h: u32) -> u32 {
    cap::rrl(payload_bytes(h))
}

/// The bytes a block in object space occupies, header included: a hole says
/// its size in granules, and an object is its header and its bounds rounded
/// up to a granule.
pub fn block_size(h: u32) -> u32 {
    if hdr_type(h) == T_FREE {
        hdr_len(h) * 8
    } else {
        HEADER_BYTES + round8(bounds_bytes(h))
    }
}

/// The permissions an object of this type is handed out with.
pub fn object_perms(ty: u32) -> u32 {
    if is_byte_type(ty) {
        PERMS_BYTES
    } else {
        PERMS_OBJECT
    }
}

// ============================================================== the heap view
/// A view onto the machine's RAM that knows about Lisp objects.
pub struct Heap<'a> {
    pub m: &'a mut Machine,
}

impl<'a> Heap<'a> {
    pub fn new(m: &'a mut Machine) -> Heap<'a> {
        Heap { m }
    }

    // ---- words and capabilities ----
    #[inline]
    pub fn ld(&self, a: u32) -> u32 {
        self.m.peek32(a)
    }
    /// A data store: it clears the tag of the granule it lands in.
    #[inline]
    pub fn st(&mut self, a: u32, v: u32) {
        self.m.poke32(a, v)
    }
    #[inline]
    pub fn ldc(&self, a: u32) -> V {
        self.m.load_cap(a)
    }
    #[inline]
    pub fn stc(&mut self, a: u32, v: V) {
        self.m.store_cap(a, v)
    }

    /// The address of every granule of RAM that holds a capability, in
    /// ascending order.
    pub fn tagged(&self) -> Vec<u32> {
        let tags = self.m.tags();
        let mut out = Vec::new();
        for (i, chunk) in tags.chunks(8).enumerate() {
            if u64::from_ne_bytes(chunk.try_into().unwrap()) != 0 {
                for (j, &t) in chunk.iter().enumerate() {
                    if t != 0 {
                        out.push(((i * 8 + j) * 8) as u32);
                    }
                }
            }
        }
        out
    }

    /// A low global that holds an address or a count, as that number.
    pub fn g(&self, off: u32) -> u32 {
        self.ldc(off).addr
    }
    pub fn set_g(&mut self, off: u32, v: u32) {
        self.stc(off, fix(v as i32))
    }
    /// A low global that holds a value.
    pub fn gv(&self, off: u32) -> V {
        self.ldc(off)
    }
    pub fn set_gv(&mut self, off: u32, v: V) {
        self.stc(off, v)
    }

    /// Lay out the empty heap. Everything after this is allocation.
    pub fn format(&mut self) {
        // The nil cell, the global block and the object bins.
        for a in (0..LOW_END).step_by(8) {
            self.stc(a, Cap::NULL);
        }
        self.stc(NIL_CELL, NIL);
        self.stc(NIL_CELL + 8, NIL);
        self.set_g(LG_CONS_PTR, CONS_BASE);
        self.set_g(LG_CONS_END, CONS_END);
        self.set_g(LG_OBJ_PTR, OBJ_BASE);
        self.set_g(LG_OBJ_END, OBJ_END);
        self.set_g(LG_CODE_PTR, CODE_BASE);
        self.set_g(LG_CODE_END, CODE_END);
        self.set_g(LG_POOLPTR, POOL_BASE);
        self.set_g(LG_POOLEND, POOL_END);
        for g in VALUE_GLOBALS {
            self.set_gv(*g, NIL);
        }
    }

    // ---- allocation (bump only; the collector lives in Lisp) ----
    pub fn cons(&mut self, a: V, d: V) -> V {
        let p = self.g(LG_CONS_PTR);
        if p + PAIR_BYTES > self.g(LG_CONS_END) {
            panic!("cons space exhausted at build time");
        }
        self.set_g(LG_CONS_PTR, p + PAIR_BYTES);
        self.stc(p, a);
        self.stc(p + 8, d);
        cap_to(p, PAIR_BYTES, PERMS_PAIR)
    }

    /// Write a hole's header over `len` bytes at `at`. It is on no free list:
    /// the sweep and the compactor find it by walking.
    pub fn hole(&mut self, at: u32, len: u32) {
        self.st(at, header(len / 8, T_FREE));
        self.st(at + 4, 0);
    }

    /// A fresh object of `len` elements: values start as nil, bytes as
    /// zero. Its base is aligned for its bounds, and a hole fills whatever
    /// the alignment skipped.
    pub fn alloc_obj(&mut self, ty: u32, len: u32) -> V {
        let h = header(len, ty);
        let bytes = payload_bytes(h);
        let span = bounds_bytes(h);
        let p = self.g(LG_OBJ_PTR);
        let base = align_up(p + HEADER_BYTES, cap::ram(bytes));
        let at = base - HEADER_BYTES;
        let end = base + round8(span);
        if end > self.g(LG_OBJ_END) {
            panic!("object space exhausted at build time");
        }
        if at > p {
            self.hole(p, at - p);
        }
        self.set_g(LG_OBJ_PTR, end);
        self.st(at, h);
        self.st(at + 4, 0);
        let fill = if is_byte_type(ty) { Cap::NULL } else { NIL };
        for a in (base..end).step_by(8) {
            self.stc(a, fill);
        }
        cap_to(base, span, object_perms(ty))
    }

    /// Room for `nbytes` of machine code, aligned so that a capability can
    /// have exactly those bytes as its bounds. Answers the address.
    pub fn alloc_code(&mut self, nbytes: u32) -> u32 {
        let p = align_up(self.g(LG_CODE_PTR), cap::ram(nbytes));
        let end = p + round8(cap::rrl(nbytes));
        if end > self.g(LG_CODE_END) {
            panic!("code space exhausted");
        }
        self.set_g(LG_CODE_PTR, end);
        p
    }

    /// Exec pool: raw memory, never collected, never moved, aligned the same
    /// way so that a block can be handed out as a capability. Answers the
    /// address.
    pub fn alloc_pool(&mut self, nbytes: u32) -> u32 {
        let p = align_up(self.g(LG_POOLPTR), cap::ram(nbytes));
        let end = p + round8(cap::rrl(nbytes));
        if end > self.g(LG_POOLEND) {
            panic!("exec pool exhausted");
        }
        self.set_g(LG_POOLPTR, end);
        for a in (p..end).step_by(8) {
            self.stc(a, Cap::NULL);
        }
        p
    }

    // ---- pairs ----
    #[inline]
    pub fn car(&self, v: V) -> V {
        self.ldc(v.addr)
    }
    #[inline]
    pub fn cdr(&self, v: V) -> V {
        self.ldc(v.addr + 8)
    }
    pub fn set_car(&mut self, v: V, x: V) {
        self.stc(v.addr, x)
    }
    pub fn set_cdr(&mut self, v: V, x: V) {
        self.stc(v.addr + 8, x)
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

    // ---- objects ----
    /// Header word 0 of an object.
    #[inline]
    pub fn hdr(&self, v: V) -> u32 {
        self.ld(v.addr - HEADER_BYTES)
    }
    /// The header type of an object, and 0 for anything else.
    pub fn obj_type(&self, v: V) -> u32 {
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
        self.ldc(v.addr + i * VALUE_BYTES)
    }
    #[inline]
    pub fn set_slot(&mut self, v: V, i: u32, x: V) {
        self.stc(v.addr + i * VALUE_BYTES, x)
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
    /// Builds a fresh list: `a` is copied, `b` is shared.
    pub fn append2(&mut self, a: V, b: V) -> V {
        let items = self.list_vec(a);
        let mut r = b;
        for &x in items.iter().rev() {
            r = self.cons(x, r);
        }
        r
    }
    pub fn reverse(&mut self, v: V) -> V {
        let mut items = self.list_vec(v);
        items.reverse();
        self.list(&items)
    }

    // ---- strings, bytes, vectors, floats ----
    pub fn string(&mut self, s: &str) -> V {
        self.byte_object(T_STRING, s.as_bytes())
    }
    pub fn bytes(&mut self, b: &[u8]) -> V {
        self.byte_object(T_BYTES, b)
    }
    fn byte_object(&mut self, ty: u32, b: &[u8]) -> V {
        let p = self.alloc_obj(ty, b.len() as u32);
        for (i, &c) in b.iter().enumerate() {
            self.m.poke8(p.addr + i as u32, c);
        }
        p
    }
    pub fn str_of(&self, v: V) -> String {
        if !self.is_type(v, T_STRING) {
            return String::new();
        }
        let n = self.olen(v);
        (0..n).map(|i| self.m.peek8(v.addr + i) as char).collect()
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
        self.set_slot(p, 0, fix(f.to_bits() as i32));
        p
    }
    pub fn float_of(&self, v: V) -> f32 {
        f32::from_bits(self.slot(v, 0).addr)
    }

    // ---- bignums ----
    //
    // The magnitude arithmetic here is `num_bigint`'s. This is the host side:
    // it runs at build time, and a number read out of a source file must be
    // the same number the machine would read. The machine's own bignum
    // arithmetic is in lisp/bignum.lisp.

    /// A number of either kind as a `BigInt`.
    pub fn to_big(&self, v: V) -> Option<BigInt> {
        if is_fixnum(v) {
            return Some(BigInt::from(unfix(v)));
        }
        if self.is_type(v, T_BIGNUM) {
            let sign = if unfix(self.slot(v, 0)) != 0 { Sign::Minus } else { Sign::Plus };
            return Some(BigInt::from_slice(sign, &self.bignum_limbs(v)));
        }
        None
    }

    /// A `BigInt` as a value, demoted to a fixnum when it fits. This is the
    /// invariant the machine's `bn-finish` keeps, so a number read at build
    /// time is `eqv` to the same number read at run time.
    pub fn from_big(&mut self, n: &BigInt) -> V {
        if let Some(i) = n.to_i32() {
            return fix(i);
        }
        let (sign, mag) = (n.sign(), n.magnitude().to_u32_digits());
        self.make_bignum(sign == Sign::Minus, &mag)
    }

    /// A value from a magnitude and a sign. The one place that knows the
    /// layout: slot 0 the sign, then the limbs.
    pub fn make_bignum(&mut self, neg: bool, mag: &[u32]) -> V {
        let mut n = mag.len();
        while n > 0 && mag[n - 1] == 0 {
            n -= 1;
        }
        if n == 0 {
            return fix(0);
        }
        if n == 1 {
            let m = mag[0] as i64;
            let v = if neg { -m } else { m };
            if let Ok(i) = i32::try_from(v) {
                return fix(i);
            }
        }
        let b = self.alloc_obj(T_BIGNUM, n as u32 + 1);
        self.set_slot(b, 0, fix(neg as i32));
        for (i, &l) in mag[..n].iter().enumerate() {
            self.set_slot(b, 1 + i as u32, fix(l as i32));
        }
        b
    }

    /// The same, from a value that fits in 64 bits.
    pub fn bignum_of_i64(&mut self, v: i64) -> V {
        let m = v.unsigned_abs();
        self.make_bignum(v < 0, &[m as u32, (m >> 32) as u32])
    }

    /// The three widening operations, host side. The machine's reader, run by
    /// the forge over its own sources, builds a number by multiplying by ten,
    /// so a literal is only as wide as these operations allow.
    pub fn num_add(&mut self, a: V, b: V) -> Option<V> {
        // Two fixnums is the common case, once per digit of every number read.
        if is_fixnum(a) && is_fixnum(b) {
            return Some(self.bignum_of_i64(unfix(a) as i64 + unfix(b) as i64));
        }
        let r = self.to_big(a)? + self.to_big(b)?;
        Some(self.from_big(&r))
    }

    pub fn num_sub(&mut self, a: V, b: V) -> Option<V> {
        if is_fixnum(a) && is_fixnum(b) {
            return Some(self.bignum_of_i64(unfix(a) as i64 - unfix(b) as i64));
        }
        let r = self.to_big(a)? - self.to_big(b)?;
        Some(self.from_big(&r))
    }

    pub fn num_mul(&mut self, a: V, b: V) -> Option<V> {
        if is_fixnum(a) && is_fixnum(b) {
            return Some(self.bignum_of_i64(unfix(a) as i64 * unfix(b) as i64));
        }
        let r = self.to_big(a)? * self.to_big(b)?;
        Some(self.from_big(&r))
    }

    /// -1, 0 or 1.
    pub fn num_cmp(&self, a: V, b: V) -> Option<i32> {
        if is_fixnum(a) && is_fixnum(b) {
            return Some(unfix(a).cmp(&unfix(b)) as i32);
        }
        Some(self.to_big(a)?.cmp(&self.to_big(b)?) as i32)
    }

    pub fn bignum_string(&self, v: V) -> String {
        match self.to_big(v) {
            Some(n) => n.to_string(),
            None => "#<not a number>".to_string(),
        }
    }

    /// The limbs, least significant first.
    pub fn bignum_limbs(&self, v: V) -> Vec<u32> {
        (1..self.olen(v)).map(|i| self.slot(v, i).addr).collect()
    }

    // ---- symbols ----
    /// Symbols are chained through the obarray, a vector of buckets, and also
    /// threaded onto a flat list so the collector can walk every one of them.
    pub fn obarray(&mut self) -> V {
        let o = self.gv(LG_OBARRAY);
        if o != NIL {
            return o;
        }
        let v = self.alloc_obj(T_VECTOR, 1021);
        self.set_gv(LG_OBARRAY, v);
        v
    }

    /// djb2 over the package name, a colon, and the symbol name, masked to 30
    /// bits, so two packages can each have a `draw-char` without colliding.
    /// `qualified_hash` in Lisp computes the same value, which makes a symbol
    /// read at build time eq to one read by the machine.
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
        let mut p = self.gv(LG_PACKAGES);
        while p != NIL {
            let pkg = self.car(p);
            if self.package_name(pkg) == name {
                return pkg;
            }
            p = self.cdr(p);
        }
        let nm = self.string(name);
        let pkg = self.alloc_obj(T_RECORD, PKG_SLOTS);
        self.set_slot(pkg, PKG_NAME, nm);
        let all = self.gv(LG_PACKAGES);
        let cell = self.cons(pkg, all);
        self.set_gv(LG_PACKAGES, cell);
        let tag = self.intern("package");
        self.set_slot(pkg, PKG_TAG, tag);
        pkg
    }

    /// The package a bare name lands in: `lm`.
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
        let s = self.new_symbol(name, pkg);
        // The index for the name alone, which the build's tables use.
        let idx = self.sym_index(s);
        let next = self.m.name_ids.len() as u32;
        let nid = *self.m.name_ids.entry(name.to_string()).or_insert(next);
        if idx >= self.m.sym_name_id.len() {
            self.m.sym_name_id.resize(idx + 1, u32::MAX);
        }
        self.m.sym_name_id[idx] = nid;
        let head = self.slot(ob, b);
        let cell = self.cons(s, head);
        self.set_slot(ob, b, cell);
        let all = self.gv(LG_SYMLIST);
        let cell2 = self.cons(s, all);
        self.set_gv(LG_SYMLIST, cell2);
        s
    }

    /// A symbol with nothing in it. Flags are in the low eight bits and the
    /// symbol's identity above them: every symbol takes its number from the
    /// counter in low memory, on either side of the bootstrap, so no two
    /// symbols share one.
    fn new_symbol(&mut self, name: &str, pkg: V) -> V {
        let nm = self.string(name);
        let s = self.alloc_obj(T_SYMBOL, SYM_SLOTS);
        self.set_slot(s, SYM_NAME, nm);
        self.set_slot(s, SYM_VALUE, UNBOUND);
        let idx = self.g(LG_SYMCOUNT);
        self.set_g(LG_SYMCOUNT, idx + 1);
        self.set_slot(s, SYM_FLAGS, fix((idx << 8) as i32));
        self.set_slot(s, SYM_PACKAGE, pkg);
        s
    }

    pub fn intern(&mut self, name: &str) -> V {
        let p = self.base_package();
        self.intern_in(p, name)
    }

    /// A symbol in no package and on no list: what `gensym` makes. Nothing
    /// reaches it but the code that mentions it, so the collector frees it
    /// when that code goes. It takes an identity from the counter like any
    /// other symbol, so tables can hash it.
    pub fn make_symbol(&mut self, name: &str) -> V {
        self.new_symbol(name, NIL)
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
    /// A symbol's identity: a dense index from the symbol counter, above the
    /// eight flag bits. `intern_in` and `make_symbol` both take the next
    /// number, so indices run 0, 1, 2, ... with no gaps.
    pub fn sym_index(&self, s: V) -> usize {
        (unfix(self.slot(s, SYM_FLAGS)) as u32 >> 8) as usize
    }

    /// A dense index for a symbol's name, ignoring its package: every symbol
    /// spelled `car` shares one, whichever package it belongs to.
    ///
    /// The build's global and macro tables are indexed by this. It has to be
    /// the name rather than the symbol: the sources read before packages.lisp
    /// go through a flat reader with one namespace, and they call things that
    /// are defined later inside a package. Those two spell the same name and
    /// mean the same function, and a table keyed by symbol would give them
    /// separate cells.
    ///
    /// Filled on demand: `intern_in` here records it, but the machine's own
    /// `intern-in` in runtime.lisp also makes symbols while it runs
    /// interpreted during the build, and those arrive without one.
    pub fn name_id(&mut self, s: V) -> usize {
        let i = self.sym_index(s);
        if let Some(&id) = self.m.sym_name_id.get(i) {
            if id != u32::MAX {
                return id as usize;
            }
        }
        let name = self.str_of(self.slot(s, SYM_NAME));
        let next = self.m.name_ids.len() as u32;
        let nid = *self.m.name_ids.entry(name).or_insert(next);
        if i >= self.m.sym_name_id.len() {
            self.m.sym_name_id.resize(i + 1, u32::MAX);
        }
        self.m.sym_name_id[i] = nid;
        nid as usize
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

    // ---- code and closures ----
    /// The name a code object or a closure goes by, if it has one.
    pub fn fn_name(&self, f: V) -> Option<String> {
        let code = if self.is_type(f, T_CLOSURE) { self.slot(f, CLO_CODE) } else { f };
        if !self.is_type(code, T_CODE) {
            return None;
        }
        let nm = self.slot(code, CODE_NAME);
        if self.is_symbol(nm) {
            Some(self.sym_name(nm))
        } else if nm != NIL {
            Some(self.write(nm))
        } else {
            None
        }
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
                IMM_DEFAULT => out.push_str("#<default>"),
                k => out.push_str(&format!("#<immediate {k} {:#x}>", v.addr)),
            }
            return;
        }
        if is_cons(v) {
            // (quote x) prints as 'x, which keeps compiler dumps readable.
            let h = self.car(v);
            if self.is_symbol(h) && is_cons(self.cdr(v)) && self.cddr(v) == NIL {
                let pre = match self.sym_name(h).as_str() {
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
        if !is_obj(v) {
            out.push_str(&format!(
                "#<cap {:#x} [{:#x},{:#x}) perms {:#x} otype {}>",
                v.addr,
                v.base(),
                v.top(),
                v.perms(),
                v.otype()
            ));
            return;
        }
        match self.obj_type(v) {
            T_SYMBOL => {
                // Printed as a bare name, without its package. An uninterned
                // symbol is marked `#:` as the machine marks one.
                if self.slot(v, SYM_PACKAGE) == NIL {
                    out.push_str("#:");
                }
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
            T_BYTES => out.push_str(&format!("#<bytes {} @{:#x}>", self.olen(v), v.addr)),
            T_CODE => {
                let entry = self.slot(v, CODE_ENTRY);
                out.push_str(&format!(
                    "#<code {} {:#x} {} bytes, {} literals>",
                    self.fn_name(v).unwrap_or_else(|| "anonymous".into()),
                    entry.addr,
                    if entry.tag { entry.len() } else { 0 },
                    self.olen(v).saturating_sub(CODE_LITS)
                ));
            }
            T_CLOSURE => {
                if !self.slot(v, CLO_ENTRY).tag {
                    let nm = self.slot(v, CLO_NAME);
                    if self.is_symbol(nm) {
                        out.push_str(&format!("#<interpreted {}>", self.sym_name(nm)));
                    } else {
                        out.push_str("#<interpreted>");
                    }
                } else {
                    // A compiled closure knows its own name, through the code
                    // object it shares with every frame that runs it.
                    match self.fn_name(v) {
                        Some(n) => out.push_str(&format!("#<function {n}>")),
                        None => out.push_str(&format!(
                            "#<function {:#x}>",
                            self.slot(v, CLO_ENTRY).addr
                        )),
                    }
                }
            }
            T_FLOAT => out.push_str(&format!("{}", self.float_of(v))),
            T_BIGNUM => out.push_str(&self.bignum_string(v)),
            T_RECORD => {
                out.push_str("#[");
                self.write_into(self.slot(v, 0), out, quoted, depth + 1);
                for i in 1..self.olen(v).min(64) {
                    out.push(' ');
                    self.write_into(self.slot(v, i), out, quoted, depth + 1);
                }
                out.push(']');
            }
            t => out.push_str(&format!("#<type{t} {:#x}>", v.addr)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn heap() -> Box<Machine> {
        let mut m = Machine::new();
        Heap::new(&mut m).format();
        m
    }

    #[test]
    fn values_are_told_apart() {
        let mut m = heap();
        let mut h = Heap::new(&mut m);
        let p = h.cons(fix(1), NIL);
        let s = h.string("abc");
        let v = h.vector(&[p, s]);
        assert!(is_cons(p) && !is_obj(p));
        assert!(!is_cons(NIL) && !is_obj(NIL));
        assert!(is_obj(s) && is_obj(v) && !is_cons(v));
        assert!(is_fixnum(fix(-1)) && is_fixnum(fix(i32::MAX)));
        assert!(is_char(chr(65)) && !is_fixnum(chr(65)));
        assert_ne!(fix(65), chr(65));
        assert_eq!(h.car(NIL), NIL);
        assert_eq!(h.cdr(NIL), NIL);
        assert_eq!(vkind(&h, fix(3)), IMM_FIXNUM);
        assert_eq!(vkind(&h, UNBOUND), IMM_UNBOUND);
        assert_eq!(vkind(&h, NIL), VK_NIL);
        assert_eq!(vkind(&h, p), VK_PAIR);
        assert_eq!(vkind(&h, s), VK_OBJECT + T_STRING);
        assert_eq!(vkind(&h, Cap::root()), VK_CAP);
        assert_eq!(h.write(v), "#((1) \"abc\")");
    }

    /// Every object's capability has its payload as bounds, rounded only
    /// where a long payload has to be, and HD; a byte object cannot hold a
    /// capability. Neighbours never overlap, and what alignment skips is a
    /// hole the walk steps over.
    #[test]
    fn objects_have_their_payload_as_bounds() {
        let mut m = heap();
        let mut h = Heap::new(&mut m);
        let mut last_top = 0u64;
        for (ty, len) in [(T_VECTOR, 3), (T_STRING, 5), (T_VECTOR, 300), (T_BYTES, 5000), (T_VECTOR, 0), (T_BYTES, 70000)] {
            let o = h.alloc_obj(ty, len);
            let want = payload_bytes(header(len, ty));
            assert_eq!(h.hdr(o), header(len, ty));
            assert_eq!(o.addr, o.base());
            assert_eq!(o.len(), cap::rrl(want) as u64);
            if want < 256 {
                assert_eq!(o.len(), want as u64);
            }
            assert!(o.has(P_HD | P_LD | P_SD));
            assert_eq!(o.has(P_SC), !is_byte_type(ty));
            assert!(o.base() as u64 - HEADER_BYTES as u64 >= last_top);
            last_top = o.top();
        }
        let mut p = OBJ_BASE;
        while p < h.g(LG_OBJ_PTR) {
            let sz = block_size(h.ld(p));
            assert!(sz > 0);
            p += sz;
        }
        assert_eq!(p, h.g(LG_OBJ_PTR));
    }

    #[test]
    fn numbers_are_32_bits_and_widen_past_them() {
        let mut m = heap();
        let mut h = Heap::new(&mut m);
        let big = h.num_add(fix(i32::MAX), fix(1)).unwrap();
        assert!(h.is_type(big, T_BIGNUM));
        assert_eq!(h.bignum_string(big), "2147483648");
        assert_eq!(h.num_sub(big, fix(1)).unwrap(), fix(i32::MAX));
        assert_eq!(h.num_mul(fix(-65536), fix(32768)).unwrap(), fix(i32::MIN));
    }
}
