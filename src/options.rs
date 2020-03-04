use crate::color::Color;

use clap::{crate_authors, crate_description, crate_name, crate_version, App, Arg};

pub struct Options {
    pub color: Color,
    pub fail_color: Color,
}

impl Options {
    pub fn new() -> Self {
        let matches = App::new(crate_name!())
            .version(crate_version!())
            .author(crate_authors!("\n"))
            .about(crate_description!())
            .arg(
                Arg::with_name("color")
                    .long("color")
                    .short("c")
                    .help("Specify the color of the lock screen.")
                    .value_name("COLOR")
                    .default_value("ffffff")
                    .validator(Options::validate_color),
            )
            .arg(
                Arg::with_name("fail-color")
                    .long("fail-color")
                    .help("Specify the color of the lock screen on authentication failure.")
                    .value_name("COLOR")
                    .default_value("ff0000")
                    .validator(Options::validate_color),
            )
            .get_matches();

        Self {
            color: Color::new_from_hex_str(matches.value_of("color").unwrap()).unwrap(),
            fail_color: Color::new_from_hex_str(matches.value_of("fail-color").unwrap()).unwrap(),
        }
    }

    fn validate_color(color: String) -> Result<(), String> {
        if color.len() != 6 {
            Err("COLOR arg must be exactly 6 digits".to_owned())
        } else if let Err(e) = u32::from_str_radix(&color, 16) {
            Err(format!("{}", e))
        } else {
            Ok(())
        }
    }
}
