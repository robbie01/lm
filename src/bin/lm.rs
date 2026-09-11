//! `lm` — boot a Lisp machine image.
//!
//! This is the runtime, and only the runtime. It knows how to load an image
//! and let it run; it does not know how to build one, and does not carry the
//! bootstrap interpreter or the test bench around with it.

use clap::Parser;
use lm::boot;

#[derive(Parser)]
#[command(
    name = "lm",
    version,
    about = "Boot a Lisp machine image",
    long_about = "Loads an image and runs it.\n\n\
                  The image contains its own compiler, so the prompt it gives \
                  you compiles whatever you type to native RISC-V before \
                  running it. Type (help) once it is up."
)]
struct Cli {
    /// Image to boot
    #[arg(default_value = "kick.img")]
    image: String,

    /// Run headless, with no display window
    #[arg(long)]
    no_window: bool,

    /// Scale the display window: 1, 2 or 4
    #[arg(long, value_name = "N", default_value_t = 1,
          value_parser = clap::value_parser!(u32).range(1..=4))]
    scale: u32,

    /// Type this at the console, as though it had been entered by hand
    #[arg(long, value_name = "TEXT")]
    script: Option<String>,

    /// Do not read the host's keyboard; useful with --script
    #[arg(long)]
    batch: bool,

    /// Attach a file as block storage, which is where (save-image) writes
    #[arg(long, value_name = "FILE")]
    disk: Option<String>,

    /// Stop after this many instructions
    #[arg(long, value_name = "N")]
    budget: Option<u64>,

    /// Report instructions retired and speed on exit
    #[arg(long)]
    stats: bool,

    /// Count what the machine executes, and print the histogram on exit
    ///
    /// One counter per dispatch slot, the custom opcodes broken down by form,
    /// memory traffic by base register, a census of which functions never call
    /// anything, and how many instructions exist only because values are
    /// tagged. Implies --stats.
    #[arg(long)]
    isaprof: bool,

    /// Report which functions the instructions were spent in, on exit
    ///
    /// Charges every thousand or so instructions to the function the machine
    /// is in and to each function on the frame chain above it. Implies
    /// --stats.
    #[arg(long)]
    fnprof: bool,

    /// Write the final display contents as a PPM
    #[arg(long, value_name = "FILE")]
    shot: Option<String>,

    /// Report every trap the machine takes
    #[arg(long)]
    trace_traps: bool,
}

/// `\n` in a script is a newline, so that a script can be typed on one line -
/// except inside a character literal. `#\n` is the character n and
/// `#\newline` is the newline character, and both used to arrive cut in two:
/// a `#`, a line break, and the rest of the name as a symbol.
fn unescape_script(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            // `#\` and the character after it, whatever it is, as they are.
            '#' if it.peek() == Some(&'\\') => {
                out.push('#');
                out.extend(it.next());
                out.extend(it.next());
            }
            '\\' if it.peek() == Some(&'n') => {
                it.next();
                out.push('\n');
            }
            _ => out.push(c),
        }
    }
    out
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();
    let o = boot::Options {
        image: cli.image,
        window: !cli.no_window,
        scale: cli.scale,
        script: cli.script.map(|s| unescape_script(&s)),
        interactive: !cli.batch,
        budget: cli.budget.unwrap_or(u64::MAX),
        disk: cli.disk,
        trace_exit: cli.stats || cli.isaprof || cli.fnprof,
        isaprof: cli.isaprof,
        fnprof: cli.fnprof,
        screenshot: cli.shot,
        trace_traps: cli.trace_traps,
    };
    match boot::boot(&o) {
        0 => std::process::ExitCode::SUCCESS,
        n => std::process::ExitCode::from(n as u8),
    }
}
