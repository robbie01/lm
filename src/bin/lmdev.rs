//! `lmdev`: the test bench and the tools for looking inside images.
//!
//! Nothing here is needed to run a machine or to build one. These commands
//! check and inspect both.

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "lmdev",
    version,
    about = "Test and inspect the Lisp machine",
    long_about = "The test bench.\n\n\
                  `cpu` checks the processor against the manual. `asm` checks \
                  the Lisp assembler against an independent Rust encoder. \
                  `compiler` puts source in one end and compares what comes \
                  out of the far end, having been through everything."
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Processor conformance tests
    Cpu,

    /// Assemble the same program in Lisp and in Rust, and compare byte for byte
    ///
    /// The Rust encoders are an independent reading of the RISC-V manual.
    Asm,

    /// End-to-end compiler tests: source in, machine code out, run, compare
    Compiler {
        /// Report heap usage before each case
        #[arg(short, long)]
        verbose: bool,
    },

    /// Name resolution: what a package can see, and what pkg:name reaches
    Readers,

    /// Run every suite
    All,

    /// Measure the interpreter
    Bench,

    /// Compile and run one expression, and print what it evaluated to
    ///
    /// Builds the standard library first, so it is slow to start.
    Eval {
        /// Expressions to compile and run
        #[arg(required = true)]
        exprs: Vec<String>,
    },

    /// Look inside an image without running it
    Inspect {
        /// Image to examine
        #[arg(default_value = "kick.img")]
        image: String,

        /// Report these symbols in full
        names: Vec<String>,
    },

    /// What each package's symbols can reach, and what only they can reach
    Reach {
        /// Image to examine
        #[arg(default_value = "kick.img")]
        image: String,

        /// Print the regions as JSON rather than a table
        #[arg(long)]
        json: bool,
    },

    /// A prompt on the bootstrap interpreter
    ///
    /// This is the build-time Lisp, not the machine's own: it runs on the host
    /// and evaluates over the target heap.
    Repl {
        /// Extra files to load before the prompt appears
        files: Vec<String>,
    },

    /// Throw random input at the machine, the image loader and the bootstrap interpreter
    ///
    /// `exec` runs random code with random registers on a fresh machine;
    /// `image` loads random bytes as an image and runs what came out; `lisp`
    /// feeds random text to the bootstrap reader and evaluator with the
    /// prelude loaded. Every input is written to target/fuzz/last-TARGET.bin
    /// before it runs, so a crash leaves its input behind. This driver has no
    /// coverage feedback; the cargo-fuzz targets under fuzz/ run the same
    /// functions with it.
    Fuzz {
        /// exec, image, lisp, or all
        #[arg(long, default_value = "all")]
        target: String,

        /// How long to run
        #[arg(long, default_value_t = 60)]
        seconds: u64,

        /// Seed for the input generator; the same seed gives the same inputs
        #[arg(long, default_value_t = 1)]
        seed: u64,

        /// Run this one saved input and stop
        #[arg(long, value_name = "FILE")]
        replay: Option<String>,
    },
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let ok = match cli.command {
        Cmd::Cpu => lm::check::cpu::run_all(),
        Cmd::Asm => lm::check::asm::run(),
        Cmd::Compiler { verbose } => lm::check::compiler::run_all(verbose),
        Cmd::Readers => lm::check::readers::run(),
        Cmd::All => {
            let a = lm::check::cpu::run_all();
            let b = lm::check::asm::run();
            let c = lm::check::compiler::run_all(false);
            let d = lm::check::readers::run();
            a && b && c && d
        }
        Cmd::Bench => {
            lm::check::cpu::bench();
            true
        }
        Cmd::Eval { exprs } => lm::check::compiler::eval_one(&exprs) == 0,
        Cmd::Inspect { image, names } => lm::check::inspect::run(&image, &names) == 0,
        Cmd::Reach { image, json } => lm::check::reach::run(&image, json) == 0,
        Cmd::Repl { files } => lm::forge::host_repl(&files) == 0,
        Cmd::Fuzz { target, seconds, seed, replay } => {
            // On a thread with room for the depth the reader and evaluator
            // guard against, so that reaching the guard is what stops a deep
            // input, not the host's stack.
            std::thread::Builder::new()
                .stack_size(256 << 20)
                .spawn(move || lm::fuzz::run(&target, seconds, seed, replay.as_deref()))
                .expect("fuzz thread")
                .join()
                .unwrap_or(false)
        }
    };
    if ok {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}
