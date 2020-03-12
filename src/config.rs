use serde::Deserialize;

use std::env;
use std::error;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
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
            Self::NotFound
        } else {
            Self::Io(err)
        }
    }
}

impl From<toml::de::Error> for ConfigError {
    fn from(err: toml::de::Error) -> Self {
        Self::Toml(err)
    }
}

impl error::Error for ConfigError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            Self::NotFound => None,
            Self::Io(err) => err.source(),
            Self::Toml(err) => err.source(),
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => write!(f, "Couldn't find the config file"),
            Self::Io(err) => write!(f, "I/O error reading the config file: {}", err),
            Self::Toml(err) => write!(f, "TOML error reading the config file: {}", err),
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
    /// Find and read the config file if it exists. The following fallback order is used:
    /// 1. manually specified config path using the --config flag
    /// 2. $XDG_CONFIG_HOME/waylock/waylock.toml
    /// 3. $HOME/.config/waylock/waylock.toml
    pub fn new(path_override: Option<&str>) -> Result<Self, ConfigError> {
        if let Some(config_file) = path_override.map(PathBuf::from).or_else(|| {
            env::var("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|_| match env::var("HOME") {
                    Ok(home) => Ok(Path::new(&home).join(".config")),
                    Err(err) => Err(err),
                })
                .map(|config_home| config_home.join("waylock/waylock.toml"))
                .ok()
        }) {
            let config = fs::read_to_string(config_file)?;
            Ok(toml::from_str(&config)?)
        } else {
            Err(ConfigError::NotFound)
        }
    }
}
