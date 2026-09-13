#![feature(explicit_tail_calls)]
#![allow(incomplete_features)]
#![allow(clippy::needless_range_loop)]

//! LM, a Lisp machine.
//!
//! The crate has three separable parts:
//!
//!   - the machine: the RV32IMC core, its memory, its custom chips, and the
//!     image format. This is everything a booted system needs.
//!   - the forge ([`forge`]): a bootstrap Lisp interpreter that runs the
//!     compiler, which is written in Lisp, so that the compiler can compile
//!     itself into an image. Needed to build a machine, not to run one.
//!   - the bench ([`check`]): conformance tests, a differential test for the
//!     assembler, end-to-end compiler tests, and tools for inspecting an
//!     image.
//!
//! The three binaries follow the same split: `lm` boots, `lmforge` builds,
//! `lmdev` checks.

// ---- the machine ----
pub mod boot;
pub mod cpu;
pub mod dev;
pub mod heap;
pub mod image;
pub mod mach;
pub mod map;
pub mod prof;
pub mod run;
pub mod rvenc;

// ---- building one ----
pub mod forge;

// ---- checking one ----
pub mod check;
pub mod fuzz;
