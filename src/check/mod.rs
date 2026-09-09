//! The bench: everything that checks the machine rather than being part of it.
//!
//! Each of these answers a different question. `cpu` asks whether the
//! processor matches the manual. `asm` asks whether the Lisp assembler and an
//! independent Rust encoder agree — two readings of the same specification
//! agreeing is evidence, one reading agreeing with itself is not. `compiler`
//! asks whether source goes in and the right answer comes out the far end,
//! having been through the reader, the macro expander, the compiler, the
//! assembler, the object memory and the processor. `inspect` does not ask
//! anything; it shows you what is in an image.

pub mod asm;
pub mod compiler;
pub mod cpu;
pub mod inspect;
pub mod reach;
pub mod readers;
