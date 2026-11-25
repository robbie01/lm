//! Capabilities: a 32-bit address, 32 bits of metadata, and a tag.
//!
//! The metadata of a capability:
//!
//! ```text
//! 31  LD   load data                 27  LM   load mutable
//! 30  SD   store data                26  EX   execute
//! 29  LC   load capabilities         25  SR   system registers
//! 28  SC   store capabilities        24  SE   seal and unseal
//!                                    23  HD   headed: a Lisp object
//! 22..19  otype   0 unsealed, 1 sentry, 2 closure, 3..15 by an SE authority
//! 18      IE      internal exponent
//! 17..10  T[7:0]  top mantissa
//! 9..0    B[9:0]  base mantissa
//! ```
//!
//! Bounds are CHERI Concentrate with a mantissa of MW = 10 bits, as ISAv9
//! defines it. With IE clear the exponent is 0 and B and T are the low bits
//! of the base and the top, so every length below 256 is exact. With IE set
//! the exponent E is `{T[2:0], B[2:0]}`, those six bits read as zero in the
//! mantissas, and base and top are multiples of 2^(E+3). The two top bits of
//! T are not stored: they are B's, plus a carry when T's low bits are below
//! B's, plus one with IE because the length's leading one sits there.
//!
//! Base and top are B and T shifted up by E with the address's bits above
//! them, corrected by one either way. The representable region runs from
//! R = B[9:7] - 1 (in its top three bits) a full 2^(E+MW) around, so an
//! address whose top three mantissa bits are below R lies in the region's
//! upper half, as does a B or T below it; the correction is the difference
//! of those two answers. A top computed as more than one step of 2^31 past
//! the base has wrapped at 2^32 and is folded back, except near the largest
//! exponent, where the region covers the whole space. E is at most 24, for
//! which T = 0x100 is a top of 2^32; a larger one is malformed, and its
//! bounds are empty.
//!
//! Every value in the machine is one of these: a pointer is a tagged
//! capability, a number an untagged one with metadata 0. The processor, the
//! forge and the bench all build and read capabilities through this module.

/// The mantissa width.
pub const MW: u32 = 10;
/// The largest exponent: a top of 2^32 is T = 0x100 shifted by it.
pub const MAX_E: u32 = 24;

/// The permissions, in the positions `cgetperm` returns them and `candperm`
/// takes them. In the metadata they sit 23 bits higher.
pub const P_LD: u32 = 1 << 8;
pub const P_SD: u32 = 1 << 7;
pub const P_LC: u32 = 1 << 6;
pub const P_SC: u32 = 1 << 5;
pub const P_LM: u32 = 1 << 4;
pub const P_EX: u32 = 1 << 3;
pub const P_SR: u32 = 1 << 2;
pub const P_SE: u32 = 1 << 1;
pub const P_HD: u32 = 1 << 0;
pub const P_ALL: u32 = 0x1ff;

/// Where the fields sit in the metadata word.
pub const PERM_SHIFT: u32 = 23;
pub const OTYPE_SHIFT: u32 = 19;
pub const OTYPE_MASK: u32 = 0xf << OTYPE_SHIFT;
pub const IE_BIT: u32 = 1 << 18;
pub const BOUNDS_MASK: u32 = (1 << 19) - 1;

pub const OT_UNSEALED: u32 = 0;
pub const OT_SENTRY: u32 = 1;
pub const OT_CLOSURE: u32 = 2;

/// The kinds of untagged value, as the metadata of an untagged capability.
pub const IMM_FIXNUM: u32 = 0;
pub const IMM_CHAR: u32 = 1;
pub const IMM_UNBOUND: u32 = 2;
pub const IMM_EOF: u32 = 3;
pub const IMM_VOID: u32 = 4;
pub const IMM_DEFAULT: u32 = 5;

const MASK33: u64 = (1 << 33) - 1;

#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug, Default)]
pub struct Cap {
    pub addr: u32,
    pub meta: u32,
    pub tag: bool,
}

/// The exponent and the full ten-bit B and T of a metadata word. The
/// exponent is as stored, up to 63; one above `MAX_E` is malformed.
#[inline(always)]
fn fields(meta: u32) -> (u32, u32, u32) {
    let b = meta & 0x3ff;
    let t = (meta >> 10) & 0xff;
    let (e, b, t, lmsb) = if meta & IE_BIT != 0 {
        let e = ((t & 7) << 3) | (b & 7);
        (e, b & !7, t & !7, 1)
    } else {
        (0, b, t, 0)
    };
    let carry = (t < (b & 0xff)) as u32;
    let t = ((((b >> 8) + carry + lmsb) & 3) << 8) | t;
    (e, b, t)
}

/// Base and top of the bounds `meta` gives at address `addr`. Bounds with
/// a malformed exponent are empty, base and top 0, as RVY decodes them.
#[inline(always)]
pub fn decode(meta: u32, addr: u32) -> (u32, u64) {
    let (e, b, t) = fields(meta);
    if e > MAX_E {
        return (0, 0);
    }
    let a = addr as u64;
    let a3 = ((a >> (e + MW - 3)) & 7) as u32;
    let r3 = ((b >> 7).wrapping_sub(1)) & 7;
    let ahi = (a3 < r3) as i64;
    let bhi = ((b >> 7) < r3) as i64;
    let thi = ((t >> 7) < r3) as i64;
    let atop = (a >> (e + MW)) as i64;
    let base = ((((atop + bhi - ahi) as u64) << (e + MW)) | ((b as u64) << e)) & MASK33;
    let mut top = ((((atop + thi - ahi) as u64) << (e + MW)) | ((t as u64) << e)) & MASK33;
    if e < MAX_E - 1 {
        let base2 = (base >> 31) & 1;
        let top2 = (top >> 31) & 3;
        if top2.wrapping_sub(base2) & 3 > 1 {
            top ^= 1 << 32;
        }
    }
    (base as u32, top)
}

/// The bounds field for `[base, top)`, rounded outward, and whether it is
/// exact. `top` is at most 2^32 and not below `base`.
pub fn encode(base: u32, top: u64) -> (u32, bool) {
    let len = top - base as u64;
    // The exponent that puts the length's leading one at bit E + MW - 2.
    let hi = len >> (MW - 1);
    let e = if hi == 0 { 0 } else { 64 - hi.leading_zeros() };
    let ie = e != 0 || len & (1 << (MW - 2)) != 0;
    if !ie {
        let b = base & 0x3ff;
        let t = (top as u32) & 0xff;
        return ((t << 10) | b, true);
    }
    let base = base as u64;
    let mut bie = (base >> (e + 3)) & 0x7f;
    let mut tie = (top >> (e + 3)) & 0x7f;
    let lo = (1u64 << (e + 3)) - 1;
    let mut lost_b = base & lo != 0;
    let mut lost_t = top & lo != 0;
    if lost_t {
        tie = (tie + 1) & 0x7f;
    }
    let mut e = e;
    if (tie.wrapping_sub(bie) & 0x7f) & (1 << (MW - 4)) != 0 {
        // Rounding grew the length past the mantissa: one more exponent.
        lost_b |= bie & 1 != 0;
        lost_t |= tie & 1 != 0;
        bie = (base >> (e + 4)) & 0x7f;
        tie = ((top >> (e + 4)) + lost_t as u64) & 0x7f;
        e += 1;
    }
    let b = ((bie as u32) << 3) | (e & 7);
    let t = (((tie as u32) & 0x1f) << 3) | (e >> 3);
    (IE_BIT | (t << 10) | b, !(lost_b || lost_t))
}

/// The alignment mask `CRAM`: what a base must be a multiple of for a
/// region of `len` bytes to be exact.
pub fn ram(len: u32) -> u32 {
    let (bounds, _) = encode(0, len as u64);
    if bounds & IE_BIT == 0 {
        return u32::MAX;
    }
    u32::MAX << (fields(bounds).0 + 3)
}

/// `CRRL`: `len` rounded up to the next length that can be exact.
pub fn rrl(len: u32) -> u32 {
    let m = ram(len);
    len.wrapping_add(!m) & m
}

impl Cap {
    pub const NULL: Cap = Cap { addr: 0, meta: 0, tag: false };

    /// Every permission over the whole address space: what PCC, DDC and
    /// MTCC hold at reset.
    pub const ROOT: Cap = Cap { addr: 0, meta: (P_ALL << PERM_SHIFT) | IE_BIT | (3 << 10), tag: true };

    /// nil: the 16-byte cell at 0, readable as a pair of nils and nothing
    /// else.
    pub const NIL: Cap = Cap { addr: 0, meta: ((P_LD | P_LC) << PERM_SHIFT) | (16 << 10), tag: true };

    pub const fn root() -> Cap {
        Cap::ROOT
    }

    /// The fixnum `v`.
    pub const fn int(v: u32) -> Cap {
        Cap { addr: v, meta: IMM_FIXNUM, tag: false }
    }

    /// An untagged value of kind `kind` (`IMM_CHAR`, ...) with `payload` in
    /// its address.
    pub const fn imm(kind: u32, payload: u32) -> Cap {
        Cap { addr: payload, meta: kind, tag: false }
    }

    #[inline(always)]
    pub fn bounds(&self) -> (u32, u64) {
        decode(self.meta, self.addr)
    }
    #[inline]
    pub fn base(&self) -> u32 {
        self.bounds().0
    }
    #[inline]
    pub fn top(&self) -> u64 {
        self.bounds().1
    }
    #[inline]
    pub fn len(&self) -> u64 {
        let (b, t) = self.bounds();
        t.saturating_sub(b as u64)
    }
    #[inline(always)]
    pub fn perms(&self) -> u32 {
        self.meta >> PERM_SHIFT
    }
    #[inline(always)]
    pub fn has(&self, p: u32) -> bool {
        self.perms() & p == p
    }
    #[inline(always)]
    pub fn otype(&self) -> u32 {
        (self.meta & OTYPE_MASK) >> OTYPE_SHIFT
    }
    #[inline(always)]
    pub fn is_sealed(&self) -> bool {
        self.meta & OTYPE_MASK != 0
    }
    /// Whether a jump through this capability with offset `off` may go
    /// where it says, as far as its seal goes: an unsealed capability
    /// anywhere, and a sentry only at its own address, with no offset and
    /// at an even address, since a jump clears bit 0 of its target.
    #[inline]
    pub fn enterable(&self, off: u32) -> bool {
        match self.otype() {
            OT_UNSEALED => true,
            OT_SENTRY => off == 0 && self.addr & 1 == 0,
            _ => false,
        }
    }

    /// Whether `[a, a + n)` lies inside the bounds.
    #[inline]
    pub fn covers(&self, a: u32, n: u32) -> bool {
        let (b, t) = self.bounds();
        a >= b && a as u64 + n as u64 <= t
    }

    /// The same capability at address `a`. The tag survives only if the
    /// capability is unsealed and its bounds read the same from `a`.
    #[inline]
    pub fn with_addr(self, a: u32) -> Cap {
        let tag = self.tag && !self.is_sealed() && decode(self.meta, a) == self.bounds();
        Cap { addr: a, meta: self.meta, tag }
    }

    #[inline]
    pub fn inc(self, d: u32) -> Cap {
        self.with_addr(self.addr.wrapping_add(d))
    }

    /// Bounds from the address for `len` bytes, rounded outward. None if
    /// the capability is untagged or sealed, or the region is not inside it.
    pub fn with_bounds(self, len: u32) -> Option<Cap> {
        self.set_bounds(len).map(|(c, _)| c)
    }

    /// The same, refusing a region that would need rounding.
    pub fn with_bounds_exact(self, len: u32) -> Option<Cap> {
        self.set_bounds(len).and_then(|(c, exact)| exact.then_some(c))
    }

    /// Bounds from the address for `len` bytes, rounded outward, and whether
    /// they are exact; None as `with_bounds` says.
    pub fn set_bounds(self, len: u32) -> Option<(Cap, bool)> {
        let top = self.addr as u64 + len as u64;
        if !self.tag || self.is_sealed() || !self.covers(self.addr, len) {
            return None;
        }
        let (bounds, exact) = encode(self.addr, top);
        let meta = if self.heads_at(self.addr) { self.meta } else { self.meta & !(P_HD << PERM_SHIFT) };
        Some((Cap { addr: self.addr, meta: (meta & !BOUNDS_MASK) | bounds, tag: true }, exact))
    }

    /// Whether a capability derived from this one with its base at `base`
    /// may keep HD. HD says the base is an object's payload with its header
    /// below it, so it survives at this capability's own base, and from one
    /// that spans the whole address space, which is how the root mints it;
    /// a new base anywhere else has left the object. `csetbounds` drops HD
    /// where this says no, and `cbuildcap` refuses it.
    #[inline]
    pub fn heads_at(&self, base: u32) -> bool {
        let (b, t) = self.bounds();
        b == base || (b == 0 && t == 1 << 32)
    }

    /// Keep only the permissions in `mask`. A sealed capability whose
    /// permissions this changes loses its tag; one the mask leaves as it
    /// was keeps it, as RVY's `YPERMC` does.
    #[inline]
    pub fn and_perms(self, mask: u32) -> Cap {
        let meta = self.meta & !(((!mask) & P_ALL) << PERM_SHIFT);
        Cap { addr: self.addr, meta, tag: self.tag && (!self.is_sealed() || meta == self.meta) }
    }

    /// Clear permissions, sealed or not; the tag is kept. This is what a
    /// load through an authority without LM does to what it loads.
    #[inline(always)]
    pub fn strip(self, mask: u32) -> Cap {
        Cap { addr: self.addr, meta: self.meta & !(mask << PERM_SHIFT), tag: self.tag }
    }

    /// The same capability with otype `ot`. The caller checks the authority.
    #[inline]
    pub fn seal(self, ot: u32) -> Cap {
        Cap { addr: self.addr, meta: (self.meta & !OTYPE_MASK) | (ot << OTYPE_SHIFT), tag: self.tag }
    }

    #[inline]
    pub fn unseal(self) -> Cap {
        self.seal(OT_UNSEALED)
    }

    pub fn without_tag(self) -> Cap {
        Cap { tag: false, ..self }
    }

    /// The 64 bits as memory holds them: metadata above, address below.
    #[inline(always)]
    pub fn to_bits(self) -> u64 {
        ((self.meta as u64) << 32) | self.addr as u64
    }
    #[inline(always)]
    pub fn from_bits(bits: u64, tag: bool) -> Cap {
        Cap { addr: bits as u32, meta: (bits >> 32) as u32, tag }
    }

    /// Whether the bounds field is exactly the one `encode` makes for the
    /// bounds it decodes to. Every capability `csetbounds` makes is one;
    /// metadata written by hand need not be, with a malformed exponent or
    /// mantissas that put the top past the end of the space or below the
    /// base, and `cbuildcap` refuses it, so that a capability with given
    /// bounds and permissions has one spelling.
    pub fn canonical(&self) -> bool {
        let (b, t) = self.bounds();
        t >= b as u64 && t <= 1 << 32 && encode(b, t) == (self.meta & BOUNDS_MASK, true)
    }

    /// Whether every permission and every byte of `self` is in `other`.
    pub fn is_subset_of(&self, other: &Cap) -> bool {
        let (b, t) = self.bounds();
        let (ob, ot) = other.bounds();
        self.tag == other.tag && b >= ob && t <= ot && self.perms() & !other.perms() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A small deterministic generator, so a failure reproduces.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u32 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            (self.0 >> 16) as u32
        }
    }

    fn region(base: u32, len: u32) -> Cap {
        Cap::ROOT.with_addr(base).with_bounds(len).unwrap()
    }

    #[test]
    fn root_covers_everything() {
        let r = Cap::root();
        assert_eq!(r.bounds(), (0, 1 << 32));
        assert_eq!(r.perms(), P_ALL);
        for a in [0u32, 1, 0x7fff_ffff, 0x8000_0000, 0xf000_0000, u32::MAX] {
            let c = r.with_addr(a);
            assert!(c.tag, "root at {a:#x}");
            assert_eq!(c.bounds(), (0, 1 << 32));
        }
        assert_eq!(encode(0, 1 << 32), (Cap::ROOT.meta & BOUNDS_MASK, true));
    }

    #[test]
    fn nil_is_a_pair_at_zero() {
        assert_eq!(Cap::NIL.bounds(), (0, 16));
        assert_eq!(Cap::NIL.perms(), P_LD | P_LC);
        assert_eq!(Cap::ROOT.with_bounds(16).unwrap().and_perms(P_LD | P_LC), Cap::NIL);
    }

    #[test]
    fn short_lengths_are_exact() {
        let mut g = Rng(1);
        for _ in 0..20_000 {
            let base = g.next();
            // Every length below 256, at any base.
            let len = g.next() % 256;
            if base as u64 + len as u64 <= 1 << 32 {
                let c = Cap::ROOT.with_addr(base).with_bounds_exact(len).unwrap();
                assert_eq!(c.bounds(), (base, base as u64 + len as u64));
            }
            // Every multiple of eight below 512, at any multiple of eight.
            let base = base & !7;
            let len = g.next() % 512 & !7;
            if base as u64 + len as u64 <= 1 << 32 {
                let c = Cap::ROOT.with_addr(base).with_bounds_exact(len).unwrap();
                assert_eq!(c.bounds(), (base, base as u64 + len as u64));
            }
        }
        for len in 0..256u32 {
            for base in [0u32, 1, 0x3ff, 0x400, 0x0200_0000, 0xffff_ff00, 0xffff_ffff - len] {
                let c = Cap::ROOT.with_addr(base).with_bounds_exact(len).unwrap();
                assert_eq!(c.bounds(), (base, base as u64 + len as u64));
            }
        }
    }

    #[test]
    fn decode_of_encode_contains_the_request() {
        let mut g = Rng(2);
        for _ in 0..200_000 {
            let base = g.next();
            let len = match g.next() % 4 {
                0 => g.next() % 512,
                1 => g.next() % 65536,
                2 => g.next() >> (g.next() % 32),
                _ => g.next(),
            };
            if base as u64 + len as u64 > 1 << 32 {
                continue;
            }
            let (bounds, exact) = encode(base, base as u64 + len as u64);
            let (b, t) = decode(bounds, base);
            assert!(b <= base && t >= base as u64 + len as u64, "{base:#x}+{len:#x} -> {b:#x}..{t:#x}");
            assert_eq!(exact, b == base && t == base as u64 + len as u64, "{base:#x}+{len:#x}");
            // What CRRL and CRAM promise is exact.
            let a = base & ram(len);
            let l = rrl(len);
            if l >= len && a as u64 + l as u64 <= 1 << 32 {
                assert!(encode(a, a as u64 + l as u64).1, "rrl/ram {a:#x}+{l:#x}");
            }
        }
    }

    #[test]
    fn round_trip_through_bits() {
        let mut g = Rng(3);
        for _ in 0..100_000 {
            let c = Cap { addr: g.next(), meta: g.next(), tag: g.next() & 1 != 0 };
            assert_eq!(Cap::from_bits(c.to_bits(), c.tag), c);
            let base = g.next() & !15;
            let len = g.next() >> (g.next() % 32);
            if let Some(d) = Cap::ROOT.with_addr(base).with_bounds(len) {
                let e = Cap::from_bits(d.to_bits(), true);
                assert_eq!(e.bounds(), d.bounds());
                assert_eq!(e.perms(), P_ALL);
            }
        }
    }

    #[test]
    fn malformed_exponents_decode_as_empty() {
        for e in MAX_E + 1..64 {
            let meta = (Cap::ROOT.meta & !BOUNDS_MASK) | IE_BIT | ((e >> 3) << 10) | (e & 7);
            for a in [0u32, 0x1234_5678, u32::MAX] {
                assert_eq!(decode(meta, a), (0, 0), "E = {e} at {a:#x}");
            }
            assert!(!Cap { addr: 0, meta, tag: false }.canonical(), "E = {e}");
        }
    }

    #[test]
    fn what_set_bounds_makes_is_canonical() {
        let mut g = Rng(6);
        for _ in 0..200_000 {
            let base = g.next();
            let len = match g.next() % 3 {
                0 => g.next() % 4096,
                1 => g.next() >> (g.next() % 32),
                _ => g.next(),
            };
            if let Some(c) = Cap::ROOT.with_addr(base).with_bounds(len) {
                assert!(c.canonical(), "{base:#x}+{len:#x}: {:#x}", c.meta);
                let (b, t) = c.bounds();
                let mid = c.with_addr((b as u64 + (t - b as u64) / 2) as u32);
                assert!(mid.canonical(), "{base:#x}+{len:#x} moved");
            }
        }
        assert!(Cap::ROOT.canonical() && Cap::NIL.canonical() && Cap::NULL.canonical());
        // Bits no bounds encode to: the largest exponent with a base
        // mantissa that puts the top past the end of the space.
        assert!(!Cap { addr: 0, meta: IE_BIT | (3 << 10) | 8, tag: false }.canonical());
    }

    #[test]
    fn moving_the_base_drops_hd() {
        let obj = Cap::ROOT.with_addr(0x0A00_0008).with_bounds_exact(64).unwrap();
        assert!(obj.perms() & P_HD != 0);
        assert!(obj.with_bounds_exact(16).unwrap().perms() & P_HD != 0);
        let inner = obj.with_addr(0x0A00_0018).with_bounds_exact(16).unwrap();
        assert_eq!(inner.perms() & P_HD, 0);
    }

    #[test]
    fn set_bounds_never_grows_authority() {
        let mut g = Rng(4);
        for _ in 0..100_000 {
            let outer = {
                let base = g.next();
                let len = g.next() >> (g.next() % 32);
                match Cap::ROOT.with_addr(base).with_bounds(len) {
                    Some(c) => c,
                    None => continue,
                }
            };
            let (ob, ot) = outer.bounds();
            let span = (ot - ob as u64) as u32;
            if span == 0 {
                continue;
            }
            let at = ob.wrapping_add(g.next() % span);
            let room = ot - at as u64;
            if room > u32::MAX as u64 {
                continue;
            }
            let room = room as u32;
            let len = if room == u32::MAX { g.next() } else { g.next() % (room + 1) };
            let inner = outer.with_addr(at);
            if !inner.tag {
                continue;
            }
            let c = inner.with_bounds(len).unwrap();
            let (b, t) = c.bounds();
            assert!(b >= ob && t <= ot, "{ob:#x}..{ot:#x} narrowed to {at:#x}+{len:#x} gave {b:#x}..{t:#x}");
            assert!(c.is_subset_of(&outer));
            // Asking for more than there is fails.
            if room < u32::MAX {
                assert!(inner.with_bounds(room + 1).is_none());
            }
        }
    }

    #[test]
    fn address_moves_keep_the_tag_while_representable() {
        let mut g = Rng(5);
        for _ in 0..50_000 {
            let base = g.next() & !7;
            let len = g.next() >> (g.next() % 32);
            let c = match Cap::ROOT.with_addr(base).with_bounds(len) {
                Some(c) => c,
                None => continue,
            };
            let (b, t) = c.bounds();
            // Anywhere inside the bounds, and one past the end, is fine.
            for a in [b, (b as u64 + (t - b as u64) / 2) as u32, (t - 1).max(b as u64) as u32] {
                let d = c.with_addr(a);
                assert!(d.tag && d.bounds() == (b, t), "{b:#x}..{t:#x} at {a:#x}");
            }
            if t < 1 << 32 {
                assert!(c.with_addr(t as u32).tag);
            }
            // Far away is not, unless the region is most of the space.
            let far = b.wrapping_add(0x8000_0000);
            let d = c.with_addr(far);
            if d.tag {
                assert_eq!(d.bounds(), (b, t));
            } else {
                assert!(t - b as u64 <= 1 << 31);
            }
            // A sealed capability never survives a move.
            let s = c.seal(OT_SENTRY);
            assert!(!s.with_addr(b).tag);
        }
        // An untagged value takes any address.
        assert_eq!(Cap::int(5).with_addr(7), Cap::int(7));
    }

    #[test]
    fn top_saturates_at_the_end_of_the_space() {
        let c = region(0xffff_ff00, 0x100);
        assert_eq!(c.top(), 1 << 32);
        let c = region(0xf000_0000, 0x1000_0000);
        assert_eq!(c.bounds(), (0xf000_0000, 1 << 32));
        let c = Cap::ROOT.with_addr(0x8000_0000).with_bounds(0x8000_0000).unwrap();
        assert_eq!(c.bounds(), (0x8000_0000, 1 << 32));
        assert_eq!(Cap::ROOT.len(), 1 << 32);
    }

    #[test]
    fn rrl_and_ram_agree_with_set_bounds() {
        for len in (0..1u64 << 32).step_by(65521).chain([0, 1, 255, 256, 257, 511, 512, 4095, 4096, 0xffff_ffff]) {
            let len = len as u32;
            let l = rrl(len);
            let m = ram(len);
            assert!(l >= len || l == 0, "rrl {len:#x} = {l:#x}");
            assert_eq!(!m & l, 0);
            if l == 0 && len != 0 {
                continue; // rounds to the whole space
            }
            let base = 0x1234_5678 & m;
            if base as u64 + l as u64 <= 1 << 32 {
                let c = Cap::ROOT.with_addr(base).with_bounds_exact(l);
                assert!(c.is_some(), "len {len:#x}: rrl {l:#x} at {base:#x} not exact");
            }
        }
        assert_eq!(rrl(100), 100);
        assert_eq!(ram(100), u32::MAX);
    }

    #[test]
    fn permissions_and_seals() {
        let c = region(0x1000, 64);
        let d = c.and_perms(P_LD | P_LC);
        assert_eq!(d.perms(), P_LD | P_LC);
        assert!(d.tag);
        let s = c.seal(OT_CLOSURE);
        assert_eq!(s.otype(), OT_CLOSURE);
        assert!(s.is_sealed());
        assert!(!s.and_perms(P_LD).tag);
        assert_eq!(s.and_perms(P_ALL), s);
        assert!(s.with_bounds(8).is_none());
        assert_eq!(s.unseal(), c);
        assert!(Cap::int(3).with_bounds(1).is_none());
    }
}
