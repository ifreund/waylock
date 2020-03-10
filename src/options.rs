use crate::color::Color;
use crate::config::{Config, ConfigError};

use clap::{crate_authors, crate_description, crate_name, crate_version, App, Arg};

pub struct Options {
    pub init_color: Color,
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
                Arg::with_name("init-color")
                    .long("init-color")
                    .help("Specify the initial color of the lock screen.")
                    .value_name("COLOR")
                    .default_value("ffffff")
                    .validator(Color::is_valid),
            )
            .arg(
                Arg::with_name("input-color")
                    .long("input-color")
                    .help("Specify the color of the lock screen after input is recieved.")
                    .value_name("COLOR")
                    .default_value("0000ff")
                    .validator(Color::is_valid),
            )
            .arg(
                Arg::with_name("fail-color")
                    .long("fail-color")
                    .help("Specify the color of the lock screen on authentication failure.")
                    .value_name("COLOR")
                    .default_value("ff0000")
                    .validator(Color::is_valid),
            )
            .get_matches();

        let mut options = Self {
            init_color: Color::from_hex_str(matches.value_of("init-color").unwrap()).unwrap(),
            input_color: Color::from_hex_str(matches.value_of("input-color").unwrap()).unwrap(),
            fail_color: Color::from_hex_str(matches.value_of("fail-color").unwrap()).unwrap(),
        };

        // It's fine if there's no config file, but if we encountered an error report it.
        match Config::new() {
            Ok(config) => {
                if let Some(color) = config.colors.init_color {
                    options.init_color = color.into();
                }
                if let Some(color) = config.colors.input_color {
                    options.input_color = color.into();
                }
                if let Some(color) = config.colors.fail_color {
                    options.fail_color = color.into();
                }
            }
            Err(ConfigError::NotFound) => {}
            Err(err) => eprintln!("{}", err),
        };

        options
    }
}
