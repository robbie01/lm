//! Physical memory map of the LM machine.
//!
//!   0000_0000  ..  0000_0007   the nil cell. nil is the word 0, which is also
//!                              a valid cons whose car and cdr are nil, so car
//!                              and cdr need no null check and `null?` is one
//!                              `beqz`. This is why AbsSysBase sits at 8 and
//!                              not at 4 the way a real Amiga has it.
//!   0000_0008                  AbsSysBase -> ExecBase
//!   0000_0100  ..  0000_01FF   Lisp global block, reachable as `lw t,0x100(x0)`
//!   0000_1000  ..              trap vectors and the exception stub
//!   0000_2000  ..  00FF_FFFF   Exec memory pool: tasks, ports, bitmaps
//!   0100_0000  ..  01FF_FFFF   code space (also the reset vector)
//!   0200_0000  ..  09FF_FFFF   cons space
//!   0A00_0000  ..  0DFF_FFFF   object space
//!   0E00_0000  ..  0FFF_FFFF   unclaimed: mark bitmap, mark stack, buffers
//!   F000_0000  ..              custom chips
//!
//! One flat shared address space, no MMU: every task can see every byte, which
//! is what makes Exec-style message passing by pointer legal.

pub const RAM_BASE: u32 = 0x0000_0000;
pub const CHIP_SIZE: u32 = 128 << 20;
pub const FAST_SIZE: u32 = 128 << 20;
pub const RAM_SIZE: u32 = CHIP_SIZE + FAST_SIZE;
pub const CHIP_END: u32 = RAM_BASE + CHIP_SIZE;

pub const NIL_CELL: u32 = 0x0000_0000;

/// Lisp global block. Every slot is reachable with a single `lw`/`sw` off x0
/// because the whole block sits inside the 12-bit immediate range.
pub const LG_BASE: u32 = 0x0000_0100;

/// Exact-fit free lists for object space, one word per granule count, in
/// reserved low memory above the Lisp global block. Entry 0 holds everything
/// too big to have a list of its own.
pub const OBJ_BINS: u32 = 0x0000_0200;
pub const OBJ_BIN_COUNT: u32 = 64;

pub const TRAP_BASE: u32 = 0x0000_1000;
pub const POOL_BASE: u32 = 0x0000_2000;
pub const POOL_END: u32 = 0x0100_0000;

/// Reset vector, and the base of code space.
pub const KICK_BASE: u32 = 0x0100_0000;
pub const CODE_BASE: u32 = 0x0100_0000;
pub const CODE_END: u32 = 0x0200_0000; // 16 MiB

pub const CONS_BASE: u32 = 0x0200_0000;
pub const CONS_END: u32 = 0x0A00_0000; // 128 MiB, sixteen million pairs

pub const OBJ_BASE: u32 = 0x0A00_0000;
pub const OBJ_END: u32 = 0x0E00_0000; // 64 MiB

/// Everything above this is unclaimed: the mark bitmap, the mark stack, and
/// whatever a program wants a bitmap plane for.
pub const FAST_BASE: u32 = 0x0E00_0000;

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
// Offsets within LG_BASE. Kept in one place and emitted into a generated
// Lisp file at build time so the two sides cannot drift apart.

macro_rules! globals {
    ($($name:ident = $off:expr, $lisp:expr;)*) => {
        $(pub const $name: u32 = LG_BASE + $off;)*
        pub const GLOBAL_NAMES: &[(&str, u32)] = &[$(($lisp, LG_BASE + $off)),*];
    };
}

globals! {
    LG_CONS_PTR   = 0x00, "cons-ptr";    // bump pointer, cons space
    LG_CONS_END   = 0x04, "cons-end";
    LG_OBJ_PTR    = 0x08, "obj-ptr";     // bump pointer, object space
    LG_OBJ_END    = 0x0c, "obj-end";
    LG_CODE_PTR   = 0x10, "code-ptr";    // bump pointer, code space
    LG_CODE_END   = 0x14, "code-end";
    LG_CONS_FREE  = 0x18, "cons-free";   // free list head, cons space
    LG_OBJ_FREE   = 0x1c, "obj-free";    // free list head, object space
    LG_OBARRAY    = 0x20, "obarray";     // vector of symbol buckets
    LG_MARKBASE   = 0x24, "markbase";    // mark bitmap, 1 bit per 8 heap bytes
    LG_GCCOUNT    = 0x28, "gccount";
    LG_GCTHRESH   = 0x2c, "gcthresh";    // free words below which a gc is due
    LG_STACKTOP   = 0x34, "stacktop";    // top of the boot stack
    LG_STACKBOT   = 0x38, "stackbot";
    LG_TOPLEVEL   = 0x3c, "toplevel";    // closure the kickstart enters
    LG_POOLPTR    = 0x40, "poolptr";     // Exec pool bump pointer
    LG_POOLEND    = 0x44, "poolend";
    LG_ROOTS      = 0x48, "roots";       // vector of extra gc roots
    LG_NROOTS     = 0x4c, "nroots";
    LG_ERRHANDLER = 0x50, "errhandler";  // closure called on a lisp error
    LG_TRAPSAVE   = 0x54, "trapsave";    // scratch for the exception stub
    LG_FEATURES   = 0x58, "features";
    LG_SYMLIST    = 0x5c, "symlist";     // every interned symbol, for the gc
    LG_GCLOCK     = 0x60, "gclock";      // non-zero: collection is forbidden
    LG_ALLOCED    = 0x64, "alloced";     // bytes handed out since the last gc
    LG_IMGENTRY   = 0x68, "imgentry";    // entry point recorded in the image
    LG_IMGVERSION = 0x6c, "imgversion";
    LG_CONSFREEN  = 0x70, "cons-free-n"; // cells on the cons free list
    LG_OBJFREEN   = 0x74, "obj-free-n";
    LG_TRACE      = 0x78, "trace";
    LG_GCHOOK     = 0x7c, "gchook";      // raw code address: replenish cons space
    LG_OBJHOOK    = 0x80, "objhook";     // raw code address: allocate an object
    LG_TRAPHOOK   = 0x84, "traphook";    // closure called from the trap stub
    LG_BOOTLIST   = 0x88, "bootlist";    // thunks the kickstart runs in order
    LG_CONS_RUN   = 0x8c, "cons-run";     // start of the run being bumped
    LG_CONSRUNEND = 0x90, "cons-run-end"; // and its end
    LG_REFILL     = 0x94, "refill";      // closure: take the next cons run
    LG_CODEFREE   = 0xb4, "code-free";   // free blocks in code space
    LG_CODEREG    = 0xb8, "code-reg";    // registry of every code object
    LG_CODEREGN   = 0xbc, "code-reg-n";
    LG_CODEFREEN  = 0xc0, "code-free-n";
    LG_STUBLO     = 0xac, "stub-lo";     // extent of the cons refill stub,
    LG_STUBHI     = 0xb0, "stub-hi";     // which is not a lisp frame
    LG_STARTUP    = 0x98, "startup";     // closure run before the repl
    LG_SCRATCH0   = 0x9c, "scratch0";
    LG_SCRATCH1   = 0xa0, "scratch1";
    LG_SCRATCH2   = 0xa4, "scratch2";
    LG_SCRATCH3   = 0xa8, "scratch3";
    LG_SYMCOUNT   = 0xc4, "symcount";    // symbols interned so far: the next
                                         // symbol's identity, and its hash
    LG_POOLFREE   = 0xc8, "pool-free";   // free list head, exec pool
    LG_PACKAGES   = 0xcc, "packages";    // every package, as a list
    LG_PACKAGE    = 0xd0, "package";     // the one a bare name is read in
    LG_TRAPDEPTH  = 0xd4, "trapdepth";   // traps in progress; 0 outside one
    LG_TRAPTMP    = 0xd8, "traptmp";     // the stub has no free register at
    LG_TRAPTMP2   = 0xdc, "traptmp2";    // entry, so two go here for a moment
}
