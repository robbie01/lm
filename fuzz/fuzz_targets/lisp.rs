#![no_main]
use libfuzzer_sys::fuzz_target;

// Random text to the bootstrap reader and evaluator, prelude loaded. The
// interpreter recurses on the host stack, so the target runs on a thread
// with room for the depth its guards allow. See `lm::fuzz::lisp`.
fuzz_target!(|data: &[u8]| {
    let data = data.to_vec();
    std::thread::Builder::new()
        .stack_size(256 << 20)
        .spawn(move || lm::fuzz::lisp(&data))
        .expect("fuzz thread")
        .join()
        .expect("lisp target panicked");
});
