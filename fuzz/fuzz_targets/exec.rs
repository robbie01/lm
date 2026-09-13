#![no_main]
use libfuzzer_sys::fuzz_target;

// Random registers and random code on a fresh machine. See `lm::fuzz::exec`.
fuzz_target!(|data: &[u8]| {
    lm::fuzz::exec(data);
});
