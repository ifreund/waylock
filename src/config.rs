use serde::Deserialize;
use xdg::BaseDirectories;

use std::fmt;
use std::fs;
use std::io;
use std::result::Result;

#[derive(Debug)]
pub enum ConfigError {
    NotFound,
    Io(io::Error),
    Toml(toml::de::Error),
}

// Special case for NotFound since if there is no config file we simply use the defaults
impl From<io::Error> for ConfigError {
    fn from(err: io::Error) -> Self {
        if err.kind() == io::ErrorKind::NotFound {
            ConfigError::NotFound
        } else {
            ConfigError::Io(err)
        }
    }
}

impl From<toml::de::Error> for ConfigError {
    fn from(err: toml::de::Error) -> Self {
        ConfigError::Toml(err)
    }
}

impl std::error::Error for ConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ConfigError::NotFound => None,
            ConfigError::Io(err) => err.source(),
            ConfigError::Toml(err) => err.source(),
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::NotFound => write!(f, "Couldn't find the config file"),
            ConfigError::Io(err) => write!(f, "I/O error reading the config file: {}", err),
            ConfigError::Toml(err) => write!(f, "TOML error reading the config file: {}", err),
        }
    }
}

#[derive(Deserialize)]
pub struct Config {
    pub colors: Colors,
}

#[derive(Deserialize)]
pub struct Colors {
    pub init_color: Option<u32>,
    pub input_color: Option<u32>,
    pub fail_color: Option<u32>,
}

impl Config {
    /// Find and read the config file if it exists. If $XDG_CONFIG_HOME is not set, the xdg crate will
    /// properly default to $HOME/.config
    pub fn new() -> Result<Self, ConfigError> {
        if let Some(config_file) = BaseDirectories::with_prefix("waylock")
            .ok()
            .and_then(|base_dirs| base_dirs.find_config_file("waylock.toml"))
        {
            let config = fs::read_to_string(config_file)?;
            Ok(toml::from_str(&config)?)
        } else {
            Err(ConfigError::NotFound)
        }
    }
}
