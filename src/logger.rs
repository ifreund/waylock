use humantime::format_rfc3339_seconds;

use std::boxed::Box;
use std::time::SystemTime;

pub struct Logger {
    level_filter: log::LevelFilter,
}

impl Logger {
    fn new(level_filter: log::LevelFilter) -> Self {
        Self { level_filter }
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

            let text = match record.level() {
                log::Level::Error => "ERROR",
                log::Level::Warn => "WARNING",
                log::Level::Info => "INFO",
                log::Level::Debug => "DEBUG",
                log::Level::Trace => "TRACE",
            };

            eprintln!(
                "[{}][{}] {}: {}",
                timestamp,
                record.module_path().unwrap_or("<unknown>"),
                text,
                record.args()
            );
        }
    }

    fn flush(&self) {}
}
