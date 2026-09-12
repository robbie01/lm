//! `lmforge`: build an image for the machine to boot.
//!
//! A small interpreter in Rust brings up the Lisp sources. The compiler, one
//! of those sources and written in Lisp, then compiles the whole system,
//! itself included, into the heap the interpreter has been building. What is
//! left in memory at the end is the image.

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

    /// Build a fresh image by having a previous image build it
    ///
    /// The sources are typed at the machine's console twice: once to make the
    /// running machine the new system, once to compile a fresh image with it.
    /// The machine writes that image out. Nothing the old image held comes
    /// with it, and the bootstrap interpreter is not involved.
    Rebuild {
        /// The image to build with
        #[arg(short, long, default_value = "kick.img")]
        from: String,

        /// Where to write the new image
        #[arg(short, long, default_value = "next.img")]
        out: String,

        /// Report what is being fed in and how long it took
        #[arg(short, long)]
        verbose: bool,

        /// Compile everything, twice, and collect, but write nothing
        #[arg(short, long)]
        check: bool,
    },

    /// Slide object space down in a saved image, and write it out again
    ///
    /// `build` does this on the way out. This is for an image written by the
    /// machine itself, by a rebuild or a `(save-image)`, which carries every
    /// hole the collector left.
    Compact {
        /// The image to compact
        #[arg(short, long, default_value = "next.img")]
        from: String,

        /// Where to write the result
        #[arg(short, long)]
        out: Option<String>,

        /// Report what moved and what was pinned
        #[arg(short, long)]
        verbose: bool,

        /// Slide code space down too, and blank the pool's scratch. Only for
        /// an image that boots through its kickstart, as `rebuild` makes; not
        /// one from `(save-image)`, which resumes with return addresses on
        /// its stacks
        #[arg(long)]
        fresh: bool,
    },

    /// Regenerate lisp/layout.lisp from the Rust definitions
    ///
    /// The memory map and object layout are defined once, in Rust, and emitted
    /// as Lisp constants so the two sides agree. `build` does this itself.
    Layout,
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let code = match cli.command {
        Cmd::Build { out, verbose } => lm::forge::build(&out, verbose),
        Cmd::Rebuild { from, out, verbose, check } => lm::forge::rebuild(&from, &out, verbose, check),
        Cmd::Compact { from, out, verbose, fresh } => {
            let out = out.unwrap_or_else(|| from.clone());
            lm::forge::compact::compact_image(&from, &out, verbose, fresh)
        }
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
