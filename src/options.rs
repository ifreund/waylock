use crate::color::Color;

use clap::{crate_authors, crate_description, crate_name, crate_version, App, Arg};

pub struct Options {
    pub color: Color,
    pub input_color: Color,
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
                    .help("Specify the initial color of the lock screen.")
                    .value_name("COLOR")
                    .default_value("ffffff")
                    .validator(Options::validate_color),
            )
            .arg(
                Arg::with_name("input-color")
                    .long("input-color")
                    .help("Specify the color of the lock screen after input is recieved.")
                    .value_name("COLOR")
                    .default_value("0000ff")
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
            input_color: Color::new_from_hex_str(matches.value_of("input-color").unwrap()).unwrap(),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_6_digit_color_valid() {
        assert!(Options::validate_color("01abEF".to_owned()).is_ok());
    }

    #[test]
    fn short_color_invalid() {
        assert!(Options::validate_color("12345".to_owned()).is_err());
    }

    #[test]
    fn long_color_invalid() {
        assert!(Options::validate_color("1234567".to_owned()).is_err());
    }

    #[test]
    fn non_hex_color_invalid() {
        assert!(Options::validate_color("12z456".to_owned()).is_err());
    }
}
