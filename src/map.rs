//! Physical memory map of the LM machine.
//!
//! ```text
//!   0000_0000  ..  0000_000F   the nil cell: a pair whose car and cdr are nil.
//!                              nil is a capability to these 16 bytes that may
//!                              read them and nothing else.
//!   0000_0100  ..              the low-memory globals, one 8-byte slot each
//!   0000_0400  ..  0000_05FF   the free bins of object space
//!   0000_2000  ..  00FF_FFFF   the pool: stacks, contexts, descriptors, the
//!                              code registry
//!   0100_0000  ..  01FF_FFFF   code space; the reset stub at its base
//!   0200_0000  ..  09FF_FFFF   cons space, eight million pairs
//!   0A00_0000  ..  0DFF_FFFF   object space
//!   0E00_0000  ..  0FFF_FFFF   the mark bitmap, the mark stack, scratch
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

/// The end of the low block, the nil cell, the globals and the bins, which
/// an image saves whole.
pub const LOW_END: u32 = 0x0000_1000;

pub const POOL_BASE: u32 = 0x0000_2000;
pub const POOL_END: u32 = 0x0100_0000;

/// The base of code space, which is also the reset vector.
pub const CODE_BASE: u32 = 0x0100_0000;
pub const KICK_BASE: u32 = CODE_BASE;
/// The reset stub's room at the base of code space. It is the one piece of
/// code with no block header; code blocks start after it.
pub const RESET_RESERVE: u32 = 256;
pub const CODE_END: u32 = 0x0200_0000; // 16 MiB

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
    LG_CODE_PTR   = 4,  "code-ptr";     // bump pointer, code space
    LG_CODE_END   = 5,  "code-end";
    LG_CONS_FREE  = 6,  "cons-free";    // free list head, cons space
    LG_OBARRAY    = 7,  "obarray";      // vector of symbol buckets
    LG_GCCOUNT    = 8,  "gccount";
    LG_STACKTOP   = 9,  "stacktop";     // top of the boot stack
    LG_STACKBOT   = 10, "stackbot";
    LG_TOPLEVEL   = 11, "toplevel";     // closure the kickstart enters
    LG_POOLPTR    = 12, "poolptr";      // Exec pool bump pointer
    LG_POOLEND    = 13, "poolend";
    LG_ROOTS      = 14, "roots";        // vector of extra gc roots
    LG_ERRHANDLER = 15, "errhandler";   // closure called on a lisp error
    LG_TRAPSAVE   = 16, "trapsave";     // the boot context the trap stub saves into
    LG_SYMLIST    = 17, "symlist";      // every interned symbol, for the gc
    LG_IMGENTRY   = 18, "imgentry";     // entry point recorded in the image
    LG_CONSFREEN  = 19, "cons-free-n";  // cells on the cons free list
    LG_OBJFREEN   = 20, "obj-free-n";
    LG_TRAPHOOK   = 21, "traphook";     // closure called from the trap stub
    LG_BOOTLIST   = 22, "bootlist";     // thunks the kickstart runs in order
    LG_CONS_RUN   = 23, "cons-run";     // the running task's cons run
    LG_STARTUP    = 24, "startup";      // closure run before the repl
    LG_TASKEXIT   = 25, "task-exit";    // the closure a task returns into
    LG_TRAPENTRY  = 26, "trap-entry";   // the trap stub's block in code space
    LG_BOOTARG    = 27, "boot-arg";     // the forge's trampoline argument
    LG_CODEFREE   = 28, "code-free";    // free blocks in code space
    LG_CODEREG    = 29, "code-reg";     // registry of every code object
    LG_CODEREGN   = 30, "code-reg-n";
    LG_CODEFREEN  = 31, "code-free-n";
    LG_SYMCOUNT   = 32, "symcount";     // symbols interned so far: the next
                                        // symbol's identity, and its hash
    LG_POOLFREE   = 33, "pool-free";    // free list head, exec pool
    LG_PACKAGES   = 34, "packages";     // every package, as a list
    LG_PACKAGE    = 35, "package";      // the one a bare name is read in
    LG_TRAPDEPTH  = 36, "trapdepth";    // traps in progress; 0 outside one
    LG_TRAPTMP    = 37, "traptmp";      // the stub has no free register at
    LG_TRAPTMP2   = 38, "traptmp2";     // entry, so two go here for a moment
}

// The globals must stay below the free bins, and the bins in the low block.
const _: () = assert!(LG_BASE + 8 * 39 <= OBJ_BINS);
const _: () = assert!(OBJ_BINS + 8 * OBJ_BIN_COUNT <= LOW_END);
