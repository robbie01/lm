//! `lmdev` — the test bench and the tools for looking inside things.
//!
//! Nothing here is needed to run a machine or to build one. It is here to
//! answer questions about whether either of them is right.

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
    /// Two independent readings of the RISC-V manual agreeing is evidence.
    /// One encoding agreeing with itself is not.
    Asm,

    /// End-to-end compiler tests: source in, machine code out, run, compare
    Compiler {
        /// Report heap usage before each case
        #[arg(short, long)]
        verbose: bool,
    },

    /// Run every suite
    All,

    /// Measure the interpreter
    Bench,

    /// Compile and run one expression, and print what it evaluated to
    ///
    /// Builds the standard library first, so this is slow to start and exact
    /// about what the compiler actually does with a form.
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

    /// A prompt on the bootstrap interpreter, for poking at the compiler
    ///
    /// This is the build-time Lisp, not the machine's own: it runs on the host
    /// and evaluates over the target heap.
    Repl {
        /// Extra files to load before the prompt appears
        files: Vec<String>,
    },
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let ok = match cli.command {
        Cmd::Cpu => lm::check::cpu::run_all(),
        Cmd::Asm => lm::check::asm::run(),
        Cmd::Compiler { verbose } => lm::check::compiler::run_all(verbose),
        Cmd::All => {
            let a = lm::check::cpu::run_all();
            let b = lm::check::asm::run();
            let c = lm::check::compiler::run_all(false);
            a && b && c
        }
        Cmd::Bench => {
            lm::check::cpu::bench();
            true
        }
        Cmd::Eval { exprs } => lm::check::compiler::eval_one(&exprs) == 0,
        Cmd::Inspect { image, names } => lm::check::inspect::run(&image, &names) == 0,
        Cmd::Repl { files } => lm::forge::host_repl(&files) == 0,
    };
    if ok {
        std::process::ExitCode::SUCCESS
    } else {
        std::process::ExitCode::FAILURE
    }
}
