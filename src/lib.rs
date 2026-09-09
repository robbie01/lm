#![feature(explicit_tail_calls)]
#![allow(incomplete_features)]
#![allow(clippy::needless_range_loop)]

//! LM — a Lisp machine.
//!
//! Three things live here, and they are deliberately separable:
//!
//!   - **the machine** — the RV32IMC core, its memory, its custom chips, and
//!     the image format. This is what a booted system needs and nothing more.
//!   - **the forge** ([`forge`]) — a bootstrap Lisp interpreter that exists
//!     only to run the compiler, which is written in Lisp, so that it can
//!     compile itself into an image. Needed to *build* a machine, never to
//!     *run* one.
//!   - **the bench** ([`check`]) — conformance tests, a differential test for
//!     the assembler, end-to-end compiler tests, and tools for looking inside
//!     an image.
//!
//! The three binaries follow the same seam: `lm` boots, `lmforge` builds,
//! `lmdev` checks.

// ---- the machine ----
pub mod boot;
pub mod cpu;
pub mod dev;
pub mod heap;
pub mod image;
pub mod mach;
pub mod map;
#[cfg(feature = "isaprof")]
pub mod prof;
pub mod run;
pub mod rvenc;

// ---- building one ----
pub mod forge;

// ---- checking one ----
pub mod check;
