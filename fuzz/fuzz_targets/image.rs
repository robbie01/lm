#![no_main]
use libfuzzer_sys::fuzz_target;

// Random bytes as an image file, run if they load. See `lm::fuzz::image`.
fuzz_target!(|data: &[u8]| {
    lm::fuzz::image(data);
});
