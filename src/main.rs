mod lock;

use crate::lock::lock_screen;

// Solarized base03
const COLOR_NORMAL: (f64, f64, f64) = (
    0x00 as f64 / 255.0,
    0x2B as f64 / 255.0,
    0x36 as f64 / 255.0,
);

// Solarized red
const COLOR_INVALID: (f64, f64, f64) = (
    0xDC as f64 / 255.0,
    0x32 as f64 / 255.0,
    0x2F as f64 / 255.0,
);

fn main() -> std::io::Result<()> {
    lock_screen(COLOR_NORMAL, COLOR_INVALID)
}
