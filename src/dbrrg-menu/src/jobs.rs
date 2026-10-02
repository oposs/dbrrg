//! The work a tile starts: running a program, saving the home directory.
//! Both run on a worker thread; the event loop keeps answering the
//! compositor while they do. dbrrg-save-home on a netbooted machine can
//! spend 60 seconds pinging before it starts, and a window that stops
//! answering frame callbacks for that long looks dead.

use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

/// What dbrrg-save-home reported, by its exit code. The codes are its
/// contract, documented at the top of overlay/usr/bin/dbrrg-save-home.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveOutcome {
    Saved,
    HomeMissing,
    RestoreFailed,
    ServerUnreachable,
    NowhereToStore,
    Failed,
    /// Any other status, a signal, or the program not starting at all.
    Broken(String),
}

impl SaveOutcome {
    pub fn from_status(status: Option<i32>) -> SaveOutcome {
        match status {
            Some(0) => SaveOutcome::Saved,
            Some(1) => SaveOutcome::HomeMissing,
            Some(2) => SaveOutcome::RestoreFailed,
            Some(3) => SaveOutcome::ServerUnreachable,
            Some(4) => SaveOutcome::NowhereToStore,
            Some(5) => SaveOutcome::Failed,
            Some(n) => SaveOutcome::Broken(format!("dbrrg-save-home exited with status {n}")),
            None => SaveOutcome::Broken("dbrrg-save-home was killed by a signal".to_string()),
        }
    }

    pub fn saved(&self) -> bool {
        *self == SaveOutcome::Saved
    }

    /// The sentence the grid shows.
    pub fn message(&self) -> String {
        match self {
            SaveOutcome::Saved => "Home directory saved.".to_string(),
            SaveOutcome::HomeMissing => "Not saved: the home directory is missing.".to_string(),
            SaveOutcome::RestoreFailed => {
                "Not saved: this boot's home restore failed, and saving would overwrite the stored home with a default one."
                    .to_string()
            }
            SaveOutcome::ServerUnreachable => "Not saved: the boot server cannot be reached.".to_string(),
            SaveOutcome::NowhereToStore => "Not saved: this machine has no place to store a home directory.".to_string(),
            SaveOutcome::Failed => "The save failed. The previously stored home is unchanged.".to_string(),
            SaveOutcome::Broken(why) => format!("Not saved: {why}."),
        }
    }
}

/// Whether this boot's home restore failed, as the initramfs recorded it.
/// dbrrg-save-home refuses to save in that case; the grid greys the save
/// tile out before anyone waits a minute for the refusal. "absent" and a
/// missing file are not failures.
pub fn restore_failed(state_dir: &Path) -> bool {
    std::fs::read_to_string(state_dir.join("home-restore")).is_ok_and(|s| s.trim() == "failed")
}

/// What finished, handed back to the event loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobResult {
    Saved(SaveOutcome),
    /// `status` is the exit code, `Ok(None)` for a signal, `Err` when the
    /// program could not be started.
    Ran {
        name: String,
        status: Result<Option<i32>, String>,
        save_on_exit: bool,
    },
}

pub struct Paths {
    pub save_home: PathBuf,
    pub state_dir: PathBuf,
}

/// Run dbrrg-save-home. Its stdout and stderr go where ours go: the session
/// log.
pub fn save(paths: &Paths) -> SaveOutcome {
    match Command::new(&paths.save_home).stdin(Stdio::null()).status() {
        Ok(st) => SaveOutcome::from_status(st.code()),
        Err(e) => SaveOutcome::Broken(format!("{} could not be started: {e}", paths.save_home.display())),
    }
}

/// Run a tile's program and wait for it. The save that may follow is a
/// separate job, so the grid can show the save dialog for it.
pub fn run(name: &str, argv: &[String], save_on_exit: bool) -> JobResult {
    let status = Command::new(&argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .status()
        .map(|st: ExitStatus| st.code())
        .map_err(|e| format!("{} could not be started: {e}", argv[0]));
    JobResult::Ran {
        name: name.to_string(),
        status,
        save_on_exit,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("dbrrg-menu-jobs-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    // No test here writes a script and then executes it. Another test thread
    // forking in between inherits the still-open write descriptor, and the
    // exec fails with "Text file busy". System binaries avoid that race.

    #[test]
    fn every_save_exit_code_has_its_own_outcome() {
        let all: Vec<SaveOutcome> = (0..=5).map(|c| SaveOutcome::from_status(Some(c))).collect();
        assert_eq!(
            all,
            [
                SaveOutcome::Saved,
                SaveOutcome::HomeMissing,
                SaveOutcome::RestoreFailed,
                SaveOutcome::ServerUnreachable,
                SaveOutcome::NowhereToStore,
                SaveOutcome::Failed
            ]
        );
        assert!(matches!(SaveOutcome::from_status(Some(127)), SaveOutcome::Broken(_)));
        assert!(matches!(SaveOutcome::from_status(None), SaveOutcome::Broken(_)));
        assert!(!SaveOutcome::NowhereToStore.saved());
    }

    #[test]
    fn restore_state_is_read_tolerantly() {
        let d = dir("state");
        assert!(!restore_failed(&d), "missing file is not a failure");
        fs::write(d.join("home-restore"), "absent\n").unwrap();
        assert!(!restore_failed(&d));
        fs::write(d.join("home-restore"), "failed\n").unwrap();
        assert!(restore_failed(&d));
        fs::write(d.join("home-restore"), "failed").unwrap();
        assert!(restore_failed(&d), "no trailing newline");
        fs::write(d.join("home-restore"), "failed\r\n").unwrap();
        assert!(restore_failed(&d), "CRLF");
    }

    #[test]
    fn save_runs_the_command_and_maps_its_status() {
        let d = dir("save");
        let ok = Paths {
            save_home: "/bin/true".into(),
            state_dir: d.clone(),
        };
        assert_eq!(save(&ok), SaveOutcome::Saved);
        let one = Paths {
            save_home: "/bin/false".into(),
            state_dir: d.clone(),
        };
        assert_eq!(save(&one), SaveOutcome::HomeMissing);
        let missing = Paths {
            save_home: d.join("nope"),
            state_dir: d.clone(),
        };
        assert!(matches!(save(&missing), SaveOutcome::Broken(_)));
    }

    #[test]
    fn run_reports_the_exit_status() {
        let argv: Vec<String> = ["/bin/sh", "-c", "exit 7"].map(String::from).to_vec();
        assert_eq!(
            run("P", &argv, true),
            JobResult::Ran {
                name: "P".into(),
                status: Ok(Some(7)),
                save_on_exit: true
            }
        );
    }

    #[test]
    fn run_reports_a_program_that_cannot_start() {
        let JobResult::Ran { status, .. } = run("X", &["/nonexistent/prog".into()], false) else {
            panic!()
        };
        assert!(status.unwrap_err().contains("could not be started"));
    }
}
