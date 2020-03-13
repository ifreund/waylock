use ansi_term::Color;
use humantime::format_rfc3339_seconds;

use std::boxed::Box;
use std::time::SystemTime;

pub struct Logger {
    level_filter: log::LevelFilter,
    use_color: bool,
}

impl Logger {
    fn new(level_filter: log::LevelFilter) -> Self {
        Self {
            level_filter,
            use_color: atty::is(atty::Stream::Stderr),
        }
    }

    pub fn init(level_filter: log::LevelFilter) -> Result<(), log::SetLoggerError> {
        log::set_boxed_logger(Box::new(Self::new(level_filter)))
            .map(|()| log::set_max_level(level_filter))
    }
}

impl log::Log for Logger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= self.level_filter
    }

    fn log(&self, record: &log::Record) {
        // enabled is not necessarily called first, so we must check manually
        if self.enabled(record.metadata()) {
            let timestamp = format_rfc3339_seconds(SystemTime::now());

            let (color, text) = match record.level() {
                log::Level::Error => (Color::Red, "ERROR"),
                log::Level::Warn => (Color::Yellow, "WARNING"),
                log::Level::Info => (Color::Green, "INFO"),
                log::Level::Debug => (Color::Blue, "DEBUG"),
                log::Level::Trace => (Color::Cyan, "TRACE"),
            };

            eprintln!(
                "[{}][{}] {}: {}",
                timestamp,
                record.module_path().unwrap_or("<unknown>"),
                // TODO: get rid of these allocations
                if self.use_color {
                    color.paint(text).to_string()
                } else {
                    text.to_owned()
                },
                record.args()
            );
        }
    }

    fn flush(&self) {}
}
