mod color;
mod lock;

use crate::color::Color;
use crate::lock::lock_screen;

fn main() -> std::io::Result<()> {
    // Solarized base03
    let color = Color::new_from_hex_str("002b36").unwrap();
    // Solarized red
    let fail_color = Color::new_from_hex_str("dc322f").unwrap();
    lock_screen(color, fail_color)
}
