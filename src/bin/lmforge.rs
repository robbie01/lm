//! `lmforge` — build an image for the machine to boot.
//!
//! The build is the interesting half of this system. A small interpreter in
//! Rust brings up the Lisp sources, and then the compiler — which is one of
//! those sources, written in Lisp — compiles the whole system including
//! itself, into the same heap the interpreter has been building all along.
//! What is left in memory at the end is the image.

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "lmforge",
    version,
    about = "Build Lisp machine images",
    long_about = "Compiles lisp/*.lisp into a bootable image.\n\n\
                  There is one compiler and it is written in Lisp. A bootstrap \
                  interpreter runs it just long enough for it to compile \
                  itself, after which the image carries a native copy."
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Compile the Lisp sources into a bootable image
    Build {
        /// Where to write the image
        #[arg(short, long, default_value = "kick.img")]
        out: String,

        /// Report progress, file by file and form by form
        #[arg(short, long)]
        verbose: bool,
    },

    /// Regenerate lisp/layout.lisp from the Rust definitions
    ///
    /// The memory map and object layout are defined once, in Rust, and emitted
    /// as Lisp constants so the two sides cannot drift apart. `build` does this
    /// for you; this is here for when you want to look at the result.
    Layout,
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let code = match cli.command {
        Cmd::Build { out, verbose } => lm::forge::build(&out, verbose),
        Cmd::Layout => {
            lm::forge::write_layout();
            println!("wrote lisp/layout.lisp");
            0
        }
    };
    if code == 0 {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}
