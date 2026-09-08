#![feature(explicit_tail_calls)]
#![allow(incomplete_features)]
#![allow(clippy::needless_range_loop)]

//! LM - a Lisp machine.
//!
//!   lm build [out]        build the kickstart image from lisp/
//!   lm run [image] [..]   boot an image
//!                         --no-window --scale N --script TEXT --batch
//!                         --disk FILE --stats --budget N
//!   lm test               processor conformance tests
//!   lm asmdiff            assembler differential test
//!   lm ctest              compiler end to end tests
//!   lm bench              measure the interpreter
//!   lm host [files]       a repl on the bootstrap interpreter

mod asmdiff;
mod boot;
mod cpu;
mod ctest;
mod dev;
mod forge;
mod heap;
mod image;
mod inspect;
mod hostlisp;
mod mach;
mod map;
mod read;
mod run;
mod rvenc;
mod tests;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("run");
    match cmd {
        "test" => {
            if tests::run_all() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        "bench" => {
            tests::bench();
            ExitCode::SUCCESS
        }
        "asmdiff" => {
            forge::write_layout();
            if asmdiff::run() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "ctest" => {
            if ctest::run_all() { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "build" => {
            let out = args.get(1).map(|s| s.as_str()).unwrap_or("kick.img");
            if forge::build(out) == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "layout" => {
            forge::write_layout();
            ExitCode::SUCCESS
        }
        "host" => {
            forge::write_layout();
            let code = forge::host_repl(&args[1..]);
            if code == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "hostrun" => {
            forge::write_layout();
            let code = forge::host_run(&args[1..]);
            if code == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "eval" => {
            let code = ctest::eval_one(&args[1..]);
            if code == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "inspect" => {
            let code = inspect::run(&args[1..]);
            if code == 0 { ExitCode::SUCCESS } else { ExitCode::FAILURE }
        }
        "run" => {
            let mut o = boot::Options::default();
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--no-window" => o.window = false,
                    "--scale" => { i += 1; o.scale = args[i].parse().unwrap_or(1); }
                    "--script" => { i += 1; o.script = Some(args[i].replace("\n", "
")); }
                    "--batch" => o.interactive = false,
                    "--disk" => { i += 1; o.disk = Some(args[i].clone()); }
                    "--stats" => o.trace_exit = true,
                    "--shot" => { i += 1; o.screenshot = Some(args[i].clone()); }
                    "--budget" => { i += 1; o.budget = args[i].parse().unwrap_or(u64::MAX); }
                    other => o.image = other.to_string(),
                }
                i += 1;
            }
            let code = boot::boot(&o);
            if code == 0 { ExitCode::SUCCESS } else { ExitCode::from(code as u8) }
        }
        other => {
            eprintln!("lm: unknown command {other:?}");
            ExitCode::FAILURE
        }
    }
}
