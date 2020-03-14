use crate::color::Color;
use crate::config::{Config, ConfigError};
use crate::logger::Logger;

use clap::{crate_authors, crate_description, crate_name, crate_version, App, Arg};

use std::str::FromStr;

pub struct Options {
    pub init_color: Color,
    pub input_color: Color,
    pub fail_color: Color,
}

impl Options {
    pub fn new() -> Self {
        let valid_color = |s: String| match Color::from_str(&s) {
            Ok(_) => Ok(()),
            Err(err) => Err(err.to_string()),
        };

        let matches = App::new(crate_name!())
            .version(crate_version!())
            .author(crate_authors!())
            .about(crate_description!())
            .arg(
                Arg::with_name("init-color")
                    .long("init-color")
                    .help("Specify the initial color of the lock screen.")
                    .value_name("COLOR")
                    .default_value("#ffffff")
                    .validator(valid_color),
            )
            .arg(
                Arg::with_name("input-color")
                    .long("input-color")
                    .help("Specify the color of the lock screen after input is received.")
                    .value_name("COLOR")
                    .default_value("#0000ff")
                    .validator(valid_color),
            )
            .arg(
                Arg::with_name("fail-color")
                    .long("fail-color")
                    .help("Specify the color of the lock screen on authentication failure.")
                    .value_name("COLOR")
                    .default_value("#ff0000")
                    .validator(valid_color),
            )
            .arg(
                Arg::with_name("config")
                    .long("config")
                    // Manually document the default path here since this should stay unset by default
                    .help("Specify an alternative config file. [default: $XDG_CONFIG_HOME/waylock/waylock.toml]")
                    .value_name("FILE")
            )
            .arg(
                Arg::with_name("v")
                    .short("verbosity")
                    .multiple(true)
                    .help("Set the verbosity level of logging. Can be repeated for greater effect (e.g. -vvv).")
            )
            .get_matches();

        // This is fine to unwrap, as it only fails when called more than once, and this is the
        // only call site
        Logger::init(match matches.occurrences_of("v") {
            0 => log::LevelFilter::Error,
            1 => log::LevelFilter::Warn,
            2 => log::LevelFilter::Info,
            3 => log::LevelFilter::Debug,
            _ => log::LevelFilter::Trace,
        })
        .unwrap();

        let mut options = Self {
            init_color: Color::from_str(matches.value_of("init-color").unwrap()).unwrap(),
            input_color: Color::from_str(matches.value_of("input-color").unwrap()).unwrap(),
            fail_color: Color::from_str(matches.value_of("fail-color").unwrap()).unwrap(),
        };

        // It's fine if there's no config file, but if we encountered an error report it.
        match Config::new(matches.value_of("config")) {
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
            Err(err) => log::error!("{}", err),
        };

        options
    }
}
