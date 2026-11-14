//! Where the log goes.
//!
//! The app logs to stdout, which is useless when it was started from a shortcut
//! or an installer: the window is detached from any console and there is nothing
//! to attach to a bug report. This adds the second destination — a file next to
//! the rest of the app data, rotated so it cannot grow without bound.
//!
//! Deliberately no new dependency: the writer is a `std::fs::File` behind a
//! mutex, and `MakeWriter` is the only trait the subscriber needs.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Rotate once the log passes this size. Two files of this size is the ceiling.
pub const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;

/// `%APPDATA%\warust` (or the platform equivalent) — the folder the session
/// database lives in, so a log and the data it describes stay together.
pub fn log_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .join("warust")
}

/// `warust.log` in the app data folder, next to the session database.
pub fn log_path() -> PathBuf {
    log_dir().join("warust.log")
}

/// Move a log that outgrew [`MAX_LOG_BYTES`] aside, keeping one older file.
///
/// Rotation happens once at startup, not per write: the point is a bounded file
/// to attach to a bug report, and rewriting a log file mid-session can lose the
/// lines that explain what went wrong.
pub fn rotate_if_needed(path: &Path, max_bytes: u64) -> io::Result<bool> {
    let size = match std::fs::metadata(path) {
        Ok(meta) => meta.len(),
        Err(_) => return Ok(false),
    };
    if size < max_bytes {
        return Ok(false);
    }
    let old = path.with_extension("1.log");
    let _ = std::fs::remove_file(&old);
    std::fs::rename(path, &old)?;
    Ok(true)
}

/// Appends to one log file; tracing asks for a writer per event.
#[derive(Clone)]
struct FileAppender {
    file: Arc<Mutex<File>>,
}

impl FileAppender {
    fn open(path: &Path) -> io::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            file: Arc::new(Mutex::new(file)),
        })
    }
}

impl Write for FileAppender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        // A poisoned mutex must not take the app down: losing log lines is
        // survivable, a panic in the logging path is not.
        let mut file = self.file.lock().unwrap_or_else(|err| err.into_inner());
        file.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut file = self.file.lock().unwrap_or_else(|err| err.into_inner());
        file.flush()
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for FileAppender {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

/// Installs the subscriber: stdout as before, plus the log file.
///
/// If the file cannot be opened (read-only folder, full disk) the app still runs
/// with stdout logging — a diagnostic aid must never be the reason a build fails
/// to start.
pub fn init() {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    let filter = tracing_subscriber::EnvFilter::from_default_env()
        .add_directive("warust=debug".parse().expect("statická direktiva"))
        .add_directive("whatsapp_rust=info".parse().expect("statická direktiva"));

    let stdout_layer = tracing_subscriber::fmt::layer()
        .with_target(false)
        .with_thread_ids(true)
        .with_file(true)
        .with_line_number(true);

    let path = log_path();
    match FileAppender::open(&path) {
        Ok(appender) => {
            let rotated = rotate_if_needed(&path, MAX_LOG_BYTES).unwrap_or(false);
            let file_layer = tracing_subscriber::fmt::layer()
                .with_target(false)
                .with_thread_ids(true)
                .with_file(true)
                .with_line_number(true)
                .with_ansi(false)
                .with_writer(appender);
            tracing_subscriber::registry()
                .with(filter)
                .with(stdout_layer)
                .with(file_layer)
                .init();
            tracing::info!(
                "Log: {} ({}rotováno)",
                path.display(),
                if rotated { "" } else { "ne" }
            );
        }
        Err(err) => {
            tracing_subscriber::registry()
                .with(filter)
                .with(stdout_layer)
                .init();
            tracing::warn!("Log do souboru nejde otevřít ({}): {err}", path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_log_lives_beside_the_app_data() {
        let path = log_path();
        assert_eq!(path.file_name().unwrap(), "warust.log");
        assert_eq!(path.parent().unwrap().file_name().unwrap(), "warust");
    }

    /// A log that outgrew the limit is kept as `warust.1.log`, not deleted, and a
    /// small one is left alone.
    #[test]
    fn rotation_keeps_one_old_file_and_only_when_needed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("warust.log");
        std::fs::write(&path, b"kratky").unwrap();
        assert!(!rotate_if_needed(&path, MAX_LOG_BYTES).unwrap());
        assert!(path.exists());

        std::fs::write(&path, vec![b'x'; 64]).unwrap();
        assert!(rotate_if_needed(&path, 32).unwrap());
        let old = dir.path().join("warust.1.log");
        assert_eq!(std::fs::metadata(&old).unwrap().len(), 64);
        // The live log starts empty again, so the next run does not append to a
        // rotated file.
        assert!(!path.exists());

        // A second rotation replaces the older file instead of piling up.
        std::fs::write(&path, vec![b'y'; 64]).unwrap();
        assert!(rotate_if_needed(&path, 32).unwrap());
        assert_eq!(std::fs::metadata(&old).unwrap().len(), 64);
        assert_eq!(
            std::fs::read(dir.path().join("warust.1.log")).unwrap()[0],
            b'y'
        );
    }

    #[test]
    fn the_appender_creates_the_folder_and_appends() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("warust.log");
        let mut first = FileAppender::open(&path).unwrap();
        first.write_all(b"prvni\n").unwrap();
        let mut second = FileAppender::open(&path).unwrap();
        second.write_all(b"druhy\n").unwrap();
        second.flush().unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "prvni\ndruhy\n",
            "druhý běh musí přidávat, ne přepisovat"
        );
    }
}
