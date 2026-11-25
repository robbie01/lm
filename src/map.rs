//! Physical memory map of the LM machine.
//!
//! ```text
//!   0000_0000  ..  0000_000F   the nil cell: a pair whose car and cdr are nil.
//!                              nil is a capability to these 16 bytes that may
//!                              read them and nothing else.
//!   0000_0100  ..              the low-memory globals, one 8-byte slot each
//!   0000_0400  ..  0000_05FF   the free bins of object space
//!   0000_0800  ..  0000_08FF   the reset stub, where the processor starts
//!   0000_2000  ..  00FF_FFFF   the pool: stacks, contexts, descriptors
//!   0100_0000  ..  01FF_FFFF   unused
//!   0200_0000  ..  09FF_FFFF   cons space, eight million pairs
//!   0A00_0000  ..  0DFF_FFFF   object space, machine code among the objects
//!   0E00_0000  ..  0FFF_FFFF   the mark bitmap, the object-start map, the
//!                              mark stack, scratch
//!   F000_0000  ..              device pages, 4 KiB each, 32-bit registers
//! ```
//!
//! One flat address space. Tags exist for RAM only: a device page holds no
//! capabilities. Every slot below 0x800 is reachable with one load or store
//! off x0, which addresses memory through DDC.

/// RAM: chip RAM, the first 128 MiB, which a display bitmap must lie in,
/// and fast RAM above it.
pub const CHIP_SIZE: u32 = 128 << 20;
pub const FAST_SIZE: u32 = 128 << 20;
pub const RAM_SIZE: u32 = CHIP_SIZE + FAST_SIZE;

/// The 16-byte cell nil names. Its car and cdr hold nil.
pub const NIL_CELL: u32 = 0x0000_0000;

/// The low-memory globals. A global that holds an address holds it as a
/// fixnum, and authority to what it names comes from DDC; one that holds a
/// value holds the value.
pub const LG_BASE: u32 = 0x0000_0100;

/// Exact-fit free lists for object space, one 8-byte slot per granule count.
/// Entry 0 holds everything too big to have a list of its own.
pub const OBJ_BINS: u32 = 0x0000_0400;
pub const OBJ_BIN_COUNT: u32 = 64;

/// The reset vector, where PCC starts, and the room the reset stub has
/// there. The stub is the one piece of code at a fixed address and the one
/// that is not an object: every function's machine code is an object in
/// object space (`T_TEXT`), reached through its entry capability.
pub const RESET_VECTOR: u32 = 0x0000_0800;
pub const RESET_RESERVE: u32 = 256;

/// The end of the low block, the nil cell, the globals, the bins and the
/// reset stub, which an image saves whole.
pub const LOW_END: u32 = 0x0000_1000;

pub const POOL_BASE: u32 = 0x0000_2000;
pub const POOL_END: u32 = 0x0100_0000;

pub const CONS_BASE: u32 = 0x0200_0000;
pub const CONS_END: u32 = 0x0A00_0000; // 128 MiB, eight million pairs

pub const OBJ_BASE: u32 = 0x0A00_0000;
pub const OBJ_END: u32 = 0x0E00_0000; // 64 MiB

/// Everything above this is unclaimed: the mark bitmap, the mark stack, and
/// whatever a program wants a bitmap plane for.
pub const FAST_BASE: u32 = 0x0E00_0000;

/// The collector's mark bitmap: one bit per eight bytes of heap from
/// `CONS_BASE`, bit i of the word at index i/32. The write barrier reads it
/// (see `mach::CSR_GCMODE`), so the address is the machine's, not the
/// collector's to choose: gc.lisp's `gc-bitmap` is this.
pub const GC_BITMAP: u32 = FAST_BASE;
pub const GC_BITMAP_BYTES: u32 = (OBJ_END - CONS_BASE) >> 6;

/// The object-start map: one bit per eight bytes of object space from
/// `OBJ_BASE`, set at the header of every block the allocator has handed out
/// and not yet seen swept. A capability whose base lies inside an object's
/// payload finds the object by the nearest set bit at or below the granule
/// before its base. The write barrier reads it too.
pub const OBJ_STARTS: u32 = GC_BITMAP + GC_BITMAP_BYTES;
pub const OBJ_STARTS_BYTES: u32 = (OBJ_END - OBJ_BASE) >> 6;
/// A word that holds `OBJ_STARTS_MAGIC` once the map describes object space:
/// scratch memory starts zero, so a machine fresh from an image builds the
/// map before its first collection marks anything.
pub const OBJ_STARTS_READY: u32 = OBJ_STARTS + OBJ_STARTS_BYTES;
pub const OBJ_STARTS_MAGIC: u32 = 0x0b57_a275;

pub const MMIO_BASE: u32 = 0xF000_0000;
pub const MMIO_END: u32 = 0xF010_0000;

pub const DEV_SHIFT: u32 = 12; // 4 KiB per device page
pub const fn dev_of(addr: u32) -> u32 {
    (addr - MMIO_BASE) >> DEV_SHIFT
}

pub const DEV_SYS: u32 = 0x00; // F000_0000 halt / debug / interrupt control
pub const DEV_UART: u32 = 0x01; // F000_1000 serial console
pub const DEV_TIMER: u32 = 0x02; // F000_2000 mtime / mtimecmp
pub const DEV_GFX: u32 = 0x03; // F000_3000 display
pub const DEV_INPUT: u32 = 0x04; // F000_4000 keyboard + mouse
pub const DEV_BLIT: u32 = 0x05; // F000_5000 blitter
pub const DEV_DISK: u32 = 0x06; // F000_6000 block storage
pub const DEV_AUDIO: u32 = 0x07; // F000_7000 (reserved)

// ---- interrupt lines, as bit numbers in INTREQ/INTENA --------------------
pub const INT_UART: u32 = 0;
pub const INT_VBLANK: u32 = 1;
pub const INT_INPUT: u32 = 2;
pub const INT_BLIT: u32 = 3;
pub const INT_DISK: u32 = 4;
pub const INT_SOFT: u32 = 5; // software interrupt, for Exec's Cause()

// ============================================================ Lisp globals
// Slot numbers within LG_BASE, eight bytes apart. Kept in one place and
// emitted into a generated Lisp file at build time so the two sides cannot
// drift apart.

macro_rules! globals {
    ($($name:ident = $slot:expr, $lisp:expr;)*) => {
        $(pub const $name: u32 = LG_BASE + 8 * $slot;)*
        pub const GLOBAL_NAMES: &[(&str, u32)] = &[$(($lisp, LG_BASE + 8 * $slot)),*];
    };
}

globals! {
    LG_CONS_PTR   = 0,  "cons-ptr";     // bump pointer, cons space
    LG_CONS_END   = 1,  "cons-end";
    LG_OBJ_PTR    = 2,  "obj-ptr";      // bump pointer, object space
    LG_OBJ_END    = 3,  "obj-end";
    LG_CONS_FREE  = 4,  "cons-free";    // free list head, cons space
    LG_OBARRAY    = 5,  "obarray";      // vector of symbol buckets
    LG_GCCOUNT    = 6,  "gccount";
    LG_STACKTOP   = 7,  "stacktop";     // top of the boot stack
    LG_STACKBOT   = 8,  "stackbot";
    LG_TOPLEVEL   = 9,  "toplevel";     // closure the kickstart enters
    LG_POOLPTR    = 10, "poolptr";      // Exec pool bump pointer
    LG_POOLEND    = 11, "poolend";
    LG_ROOTS      = 12, "roots";        // vector of extra gc roots
    LG_ERRHANDLER = 13, "errhandler";   // closure called on a lisp error
    LG_TRAPSAVE   = 14, "trapsave";     // the boot context the trap stub saves into
    LG_SYMLIST    = 15, "symlist";      // every interned symbol, for the gc
    LG_CONSFREEN  = 16, "cons-free-n";  // cells on the cons free list
    LG_OBJFREEN   = 17, "obj-free-n";
    LG_TRAPHOOK   = 18, "traphook";     // closure called from the trap stub
    LG_BOOTLIST   = 19, "bootlist";     // thunks the kickstart runs in order
    LG_CONS_RUN   = 20, "cons-run";     // the running task's cons run
    LG_STARTUP    = 21, "startup";      // closure run before the repl
    LG_TASKEXIT   = 22, "task-exit";    // the closure a task returns into
    LG_TRAPENTRY  = 23, "trap-entry";   // the trap stub's entry, for MTCC
    LG_SYMCOUNT   = 24, "symcount";     // symbols interned so far: the next
                                        // symbol's identity, and its hash
    LG_POOLFREE   = 25, "pool-free";    // free list head, exec pool
    LG_PACKAGES   = 26, "packages";     // every package, as a list
    LG_PACKAGE    = 27, "package";      // the one a bare name is read in
    LG_TRAPDEPTH  = 28, "trapdepth";    // traps in progress; 0 outside one
    LG_TRAPTMP    = 29, "traptmp";      // the stub has no free register at
    LG_TRAPTMP2   = 30, "traptmp2";     // entry, so two go here for a moment
}

// The globals must stay below the free bins, the bins below the reset stub,
// and the stub in the low block.
const _: () = assert!(LG_BASE + 8 * 31 <= OBJ_BINS);
const _: () = assert!(OBJ_BINS + 8 * OBJ_BIN_COUNT <= RESET_VECTOR);
const _: () = assert!(RESET_VECTOR + RESET_RESERVE <= LOW_END);
