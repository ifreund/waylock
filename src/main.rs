mod color;
mod config;
mod lock;
mod logger;
mod options;

use crate::lock::lock_screen;
use crate::options::Options;

fn main() -> std::io::Result<()> {
    let options = Options::new();
    lock_screen(&options)
}
