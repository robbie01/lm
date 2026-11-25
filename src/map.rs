//! Physical memory map of the LM machine.
//!
//! ```text
//!   0000_0000  ..  0000_000F   the nil cell: a pair whose car and cdr are nil.
//!                              nil is a capability to these 16 bytes that may
//!                              read them and nothing else.
//!   0000_0800  ..  0000_0FFF   the reset stub, where the processor starts
//!   0100_0000  ..  08FF_FFFF   cons space, eight million pairs
//!   0900_0000  ..  0CFF_FFFF   object space: every object, the kernel block,
//!                              machine code, stacks and register contexts
//!                              among them
//!   0D00_0000  ..  0FFF_FFFF   the mark bitmap, the object-start map, and
//!                              the collector's scratch
//!   F000_0000  ..              device pages, 4 KiB each, 32-bit registers
//! ```
//!
//! One flat address space, and the machine reaches none of it by number.
//! The reset stub turns this map into capabilities, once, each time the
//! machine starts: nil, the kernel block, each region and each device page,
//! from the root. Everything after that holds capabilities and works by
//! offsets into them. Tags exist for RAM only: a device page holds no
//! capabilities. Cons space starts at 16 MiB so that its runs fall on round
//! boundaries.

/// RAM: chip RAM, the first 128 MiB, which a display bitmap must lie in,
/// and fast RAM above it.
pub const CHIP_SIZE: u32 = 128 << 20;
pub const FAST_SIZE: u32 = 128 << 20;
pub const RAM_SIZE: u32 = CHIP_SIZE + FAST_SIZE;

/// The 16-byte cell nil names. Its car and cdr hold nil.
pub const NIL_CELL: u32 = 0x0000_0000;

/// Exact-fit free lists for object space, one per granule count, in a
/// vector the kernel block holds. Entry 0 holds everything too big to have a
/// list of its own.
pub const OBJ_BIN_COUNT: u32 = 64;

/// The reset vector, where PCC starts, and the room the reset stub has
/// there. The stub is the one piece of code at a fixed address and the one
/// that is not an object: every function's machine code is an object in
/// object space (`T_TEXT`), reached through its entry capability.
pub const RESET_VECTOR: u32 = 0x0000_0800;
pub const RESET_RESERVE: u32 = 1024;

/// The end of the low block, the nil cell and the reset stub, which an
/// image saves whole.
pub const LOW_END: u32 = 0x0000_1000;

pub const CONS_BASE: u32 = 0x0100_0000;
pub const CONS_END: u32 = 0x0900_0000; // 128 MiB, eight million pairs

pub const OBJ_BASE: u32 = 0x0900_0000;
pub const OBJ_END: u32 = 0x0D00_0000; // 64 MiB

/// Everything above this is the collector's: the mark bitmap, the
/// object-start map, and scratch.
pub const FAST_BASE: u32 = 0x0D00_0000;

/// The collector's mark bitmap: one bit per eight bytes of heap from
/// `CONS_BASE`, bit i of the word at index i/32. The write barrier reads it
/// through the capability in `mach::CSR_GCMARKS`, so how a map is laid out
/// is the machine's; where it lies is whatever that capability says, and
/// the reset stub says this.
pub const GC_BITMAP: u32 = FAST_BASE;
pub const GC_BITMAP_BYTES: u32 = (OBJ_END - CONS_BASE) >> 6;

/// The object-start map: one bit per eight bytes of object space from
/// `OBJ_BASE`, set at the header of every block the allocator has handed out
/// and not yet seen swept. A capability whose base lies inside an object's
/// payload finds the object by the nearest set bit at or below the granule
/// before its base. The write barrier reads it too, through the capability
/// in `mach::CSR_GCSTARTS`.
pub const OBJ_STARTS: u32 = GC_BITMAP + GC_BITMAP_BYTES;
pub const OBJ_STARTS_BYTES: u32 = (OBJ_END - OBJ_BASE) >> 6;

/// The collector's scratch, the rest of RAM: the mark stack, the
/// compactor's table and the image writer's tag maps, laid out by gc.lisp.
/// Its first word holds `OBJ_STARTS_MAGIC` once the start map describes
/// object space: scratch memory starts zero, so a machine fresh from an
/// image builds the map before its first collection marks anything.
pub const SCRATCH: u32 = OBJ_STARTS + OBJ_STARTS_BYTES;
pub const SCRATCH_BYTES: u32 = RAM_SIZE - SCRATCH;
pub const OBJ_STARTS_READY: u32 = SCRATCH;
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

/// How many device pages there are, the reserved one included.
pub const DEV_COUNT: u32 = 8;

// ======================================================== the kernel block
// The kernel's own state, one object: the first in object space, where the
// forge makes it and nothing moves it, so that the reset stub can mint it
// from the root and put it in `mscratch`. Everything after reaches it
// through `mscratch`, which takes SR to read. Its slots are kept in one place
// and emitted into the generated layout, so the two sides cannot drift
// apart. The Rust names are the slots' addresses, which only the forge and
// the tools outside the machine use.

/// Where the kernel block's payload starts: its header is the first granule
/// of object space.
pub const KB_BASE: u32 = OBJ_BASE + 8;

macro_rules! kernel {
    ($($name:ident = $slot:expr, $lisp:expr;)*) => {
        $(pub const $name: u32 = KB_BASE + 8 * $slot;)*
        pub const KERNEL_SLOTS: &[(&str, u32)] = &[$(($lisp, $slot)),*];
    };
}

kernel! {
    // What the collector's roots scan, values every one.
    KB_FRAME      = 0,  "frame";      // the frame the next trap saves into
    KB_DEPTH      = 1,  "depth";      // traps in progress; 0 outside one
    KB_TRAPSTACK  = 2,  "trap-stack"; // the trap handler's stack, at its top
    KB_TRAPHOOK   = 3,  "trap-hook";  // the closure the trap stub calls
    KB_TRAPNEST   = 4,  "trap-nest";  // a vector of frames for nested traps
    KB_TRAPENTRY  = 5,  "trap-entry"; // the trap stub's entry, for `mtvec`
    KB_BOOTSTACK  = 6,  "boot-stack"; // the boot stack, at its top
    KB_BOOTFRAME  = 7,  "boot-frame"; // the boot context
    KB_TOPLEVEL   = 8,  "toplevel";   // the closure the reset stub enters
    KB_TASKEXIT   = 9,  "task-exit";  // the closure a finished task calls
    KB_OBARRAY    = 10, "obarray";    // a vector of symbol buckets
    KB_SYMBOLS    = 11, "symbols";    // every interned symbol, as a list
    KB_PACKAGES   = 12, "packages";   // every package, as a list
    KB_PACKAGE    = 13, "package";    // the one a bare name is read in
    KB_SYMCOUNT   = 14, "symcount";   // symbols interned so far: the next
                                      // symbol's identity, and its hash
    KB_ROOTS      = 15, "roots";      // whatever else is to be kept
    KB_CONS_PTR   = 16, "cons-ptr";   // cons space's frontier
    KB_OBJ_PTR    = 17, "obj-ptr";    // object space's frontier
    KB_OBJ_FREE   = 18, "obj-free";   // the bytes in its free blocks
    KB_BINS       = 19, "bins";       // object space's free lists, a vector
    KB_DEVICES    = 20, "devices";    // a vector of the device pages
    // What they do not: the trap stub's two parked registers, which the
    // frame it saves holds too, and the capabilities the reset stub mints
    // from the memory map, which name regions rather than objects.
    KB_PARK       = 21, "park";
    KB_PARK2      = 22, "park2";
    KB_LOW        = 23, "low";        // the low block, to be read
    KB_CONS       = 24, "cons";       // cons space
    KB_OBJECTS    = 25, "objects";    // object space, the allocator's
    KB_MARKS      = 26, "marks";      // the mark bitmap
    KB_STARTS     = 27, "starts";     // the object-start map
    KB_SCRATCH    = 28, "scratch";    // the collector's scratch
    KB_SEALS      = 29, "seals";      // every otype, to mint keys from
}

/// How many slots the kernel block has, and the first one the roots do not
/// scan.
pub const KB_SLOTS: u32 = 30;
pub const KB_UNSCANNED: u32 = 21;

// The kernel block's bounds are exact wherever it is, the reset stub fits
// the low block, and the maps and the scratch fill fast RAM.
const _: () = assert!(KB_SLOTS * 8 < 256);
const _: () = assert!(RESET_VECTOR + RESET_RESERVE <= LOW_END);
const _: () = assert!(SCRATCH + SCRATCH_BYTES == RAM_SIZE);

