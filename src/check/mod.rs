//! The bench: everything that checks the machine rather than being part of it.
//!
//! `cpu` checks the processor against the manual. `asm` checks that the Lisp
//! assembler and an independent Rust encoder produce the same bytes.
//! `compiler` checks that source compiled and run on the machine gives the
//! expected answer, through the reader, macro expander, compiler, assembler,
//! object memory and processor. `readers` checks name resolution. `inspect`
//! reports what is in an image, and `reach` reports what each package can
//! reach in one.

pub mod asm;
pub mod compiler;
pub mod cpu;
pub mod inspect;
pub mod reach;
pub mod readers;
