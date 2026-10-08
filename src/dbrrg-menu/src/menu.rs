//! The menu's state machine, apart from any drawing: which tile may be
//! activated, what activating it starts, and what it writes to the log. One action at a time, enforced here by refusing activation, not
//! by blocking the event loop.
//!
//! Log out saves the home directory here, behind the dialog, before the
//! menu exits (decided 2026-10-02). dbrrg-session no longer saves after a
//! logout: by the time the menu exits 0 the save has been done, or it
//! failed and the person at the machine chose to log out anyway.

use crate::jobs::{JobResult, SaveOutcome};
use crate::log::{Kind, Log};
use crate::tiles::{Action, Grid, Tile};
use std::time::{Duration, Instant};

/// How long "Home directory saved. Logging out." stays on screen.
pub const LOGOUT_PAUSE: Duration = Duration::from_millis(1500);

/// Why a save is running: a backup returns to the grid, a logout exits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveFor {
    Backup,
    Logout,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Busy {
    Idle,
    Running {
        name: String,
    },
    Saving {
        since: Instant,
        purpose: SaveFor,
    },
    /// The logout save did not happen. The dialog shows `message` and asks.
    LogoutFailed {
        message: String,
    },
    /// Saved; the menu exits 0 at `until`.
    LoggingOut {
        until: Instant,
    },
}

impl Busy {
    /// Whether the dialog is up, so the grid behind it is frozen and dimmed.
    pub fn dialog(&self) -> bool {
        matches!(
            self,
            Busy::Saving { .. } | Busy::LogoutFailed { .. } | Busy::LoggingOut { .. }
        )
    }

    /// Whether input is dropped before egui sees it. The failed-logout
    /// dialog has buttons, so it takes input; the others have none.
    pub fn refuses_input(&self) -> bool {
        matches!(self, Busy::Saving { .. } | Busy::LoggingOut { .. })
    }
}

/// The two answers to a failed logout save.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    LogOutAnyway,
    Stay,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Job {
    Save,
    Run {
        name: String,
        argv: Vec<String>,
        save_on_exit: bool,
    },
}

/// What the event loop must do after a state change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Start(Job),
    Exit(i32),
}

pub const RESTORE_FAILED_REASON: &str = "this boot's home restore failed, so saving would overwrite the stored home";

pub struct Menu {
    pub tiles: Vec<Tile>,
    pub banner: Vec<String>,
    pub busy: Busy,
    /// What happened, for the log under the grid.
    pub log: Log,
    restore_failed: bool,
}

const SAVING: &str = "Saving the home directory…";

fn run_message(name: &str, status: &Result<Option<i32>, String>) -> (Kind, String) {
    match status {
        Ok(Some(0)) => (Kind::Event, format!("{name} exited.")),
        Ok(Some(n)) => (Kind::Warn, format!("{name} exited with status {n}.")),
        Ok(None) => (Kind::Warn, format!("{name} was killed by a signal.")),
        Err(e) => (Kind::Warn, format!("{e}.")),
    }
}

fn save_message(outcome: &SaveOutcome) -> (Kind, String) {
    let kind = if outcome.saved() { Kind::Event } else { Kind::Warn };
    (kind, outcome.message())
}

impl Menu {
    /// `restore_failed` greys the save tile out with the reason, before
    /// anyone waits a minute for dbrrg-save-home to refuse.
    pub fn new(grid: Grid, restore_failed: bool) -> Menu {
        let mut tiles = grid.tiles;
        if restore_failed {
            for t in tiles.iter_mut().filter(|t| t.usable() && t.action == Action::SaveHome) {
                t.problem = Some(RESTORE_FAILED_REASON.to_string());
            }
        }
        let mut log = Log::default();
        for line in &grid.banner {
            log.note(Kind::Warn, line.clone());
        }
        Menu {
            tiles,
            banner: grid.banner,
            busy: Busy::Idle,
            log,
            restore_failed,
        }
    }

    pub fn activate(&mut self, index: usize, now: Instant) -> Option<Effect> {
        if self.busy != Busy::Idle {
            return None;
        }
        let tile = self.tiles.get(index).filter(|t| t.usable())?.clone();
        match tile.action {
            Action::Run => {
                self.log.note(Kind::Event, format!("{} started.", tile.name));
                self.busy = Busy::Running {
                    name: tile.name.clone(),
                };
                Some(Effect::Start(Job::Run {
                    name: tile.name.clone(),
                    argv: crate::tiles::command_line(&tile),
                    save_on_exit: tile.save_on_exit,
                }))
            }
            Action::SaveHome => {
                self.log.note(Kind::Event, SAVING);
                self.busy = Busy::Saving {
                    since: now,
                    purpose: SaveFor::Backup,
                };
                Some(Effect::Start(Job::Save))
            }
            Action::Logout => {
                // A save that is refused anyway is not attempted: the person
                // is asked straight away.
                if self.restore_failed {
                    let message = SaveOutcome::RestoreFailed.message();
                    self.log.note(Kind::Warn, message.clone());
                    self.busy = Busy::LogoutFailed { message };
                    return None;
                }
                self.log.note(Kind::Event, SAVING);
                self.busy = Busy::Saving {
                    since: now,
                    purpose: SaveFor::Logout,
                };
                Some(Effect::Start(Job::Save))
            }
        }
    }

    pub fn finished(&mut self, result: JobResult, now: Instant) -> Option<Effect> {
        match result {
            JobResult::Saved(outcome) => {
                let purpose = match self.busy {
                    Busy::Saving { purpose, .. } => purpose,
                    _ => SaveFor::Backup,
                };
                let (kind, text) = save_message(&outcome);
                self.log.note(kind, text);
                if purpose == SaveFor::Logout {
                    self.busy = if outcome.saved() {
                        Busy::LoggingOut {
                            until: now + LOGOUT_PAUSE,
                        }
                    } else {
                        Busy::LogoutFailed {
                            message: outcome.message(),
                        }
                    };
                    return None;
                }
                self.busy = Busy::Idle;
                None
            }
            JobResult::Ran {
                name,
                status,
                save_on_exit,
            } => {
                let (kind, text) = run_message(&name, &status);
                self.log.note(kind, text);
                if !save_on_exit {
                    self.busy = Busy::Idle;
                    return None;
                }
                if self.restore_failed {
                    self.log.note(Kind::Warn, SaveOutcome::RestoreFailed.message());
                    self.busy = Busy::Idle;
                    return None;
                }
                self.log.note(Kind::Event, SAVING);
                self.busy = Busy::Saving {
                    since: now,
                    purpose: SaveFor::Backup,
                };
                Some(Effect::Start(Job::Save))
            }
        }
    }

    /// The answer to a failed logout save. Ignored in any other state.
    pub fn choose(&mut self, choice: Choice) -> Option<Effect> {
        // The failure is in the log already, from when it happened.
        let Busy::LogoutFailed { .. } = &self.busy else {
            return None;
        };
        match choice {
            Choice::LogOutAnyway => Action::Logout.exit_code().map(Effect::Exit),
            Choice::Stay => {
                self.busy = Busy::Idle;
                None
            }
        }
    }

    /// Called on every frame: ends the menu once the "saved" message has
    /// been shown for `LOGOUT_PAUSE`.
    pub fn tick(&mut self, now: Instant) -> Option<Effect> {
        match self.busy {
            Busy::LoggingOut { until } if now >= until => Action::Logout.exit_code().map(Effect::Exit),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop;
    use crate::log::Kind;
    use crate::tiles::{SourceFile, merge};

    /// The log as (kind, text), oldest first.
    fn log(m: &Menu) -> Vec<(Kind, String)> {
        m.log.lines().map(|l| (l.kind, l.text.clone())).collect()
    }

    fn ev(t: &str) -> (Kind, String) {
        (Kind::Event, t.to_string())
    }

    fn warn(t: &str) -> (Kind, String) {
        (Kind::Warn, t.to_string())
    }

    fn grid() -> Grid {
        let f = |n: &str, t: &str| SourceFile {
            name: n.into(),
            entry: desktop::parse(t),
        };
        Grid {
            tiles: merge(
                &[
                    f(
                        "10-thinlinc.desktop",
                        "[Desktop Entry]\nName=ThinLinc\nExec=tlclient\nX-DBRRG-Save-On-Exit=true\n",
                    ),
                    f("30-terminal.desktop", "[Desktop Entry]\nName=Terminal\nExec=foot\n"),
                    f(
                        "40-save-home.desktop",
                        "[Desktop Entry]\nName=Back up home\nX-DBRRG-Action=save-home\n",
                    ),
                    f(
                        "80-logout.desktop",
                        "[Desktop Entry]\nName=Log out\nX-DBRRG-Action=logout\n",
                    ),
                ],
                &[],
            ),
            banner: Vec::new(),
        }
    }

    #[test]
    fn logout_saves_first_then_exits_zero_after_the_pause() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.activate(3, now), Some(Effect::Start(Job::Save)));
        assert_eq!(
            m.busy,
            Busy::Saving {
                since: now,
                purpose: SaveFor::Logout
            }
        );
        assert_eq!(m.finished(JobResult::Saved(SaveOutcome::Saved), now), None);
        assert_eq!(log(&m), [ev("Saving the home directory…"), ev("Home directory saved.")]);
        assert_eq!(m.tick(now), None, "the result is shown first");
        assert_eq!(m.tick(now + LOGOUT_PAUSE), Some(Effect::Exit(0)));
    }

    #[test]
    fn failed_logout_save_asks_and_stay_returns_to_the_grid() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(3, now);
        m.finished(JobResult::Saved(SaveOutcome::ServerUnreachable), now);
        assert_eq!(
            m.busy,
            Busy::LogoutFailed {
                message: SaveOutcome::ServerUnreachable.message()
            }
        );
        assert_eq!(m.tick(now + LOGOUT_PAUSE * 10), None, "never exits by itself");
        assert_eq!(m.activate(1, now), None, "the grid is refused while asking");
        assert_eq!(m.choose(Choice::Stay), None);
        assert_eq!(m.busy, Busy::Idle);
        assert_eq!(
            log(&m),
            [
                ev("Saving the home directory…"),
                warn("Not saved: the boot server cannot be reached.")
            ]
        );
    }

    #[test]
    fn failed_logout_save_can_log_out_anyway() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(3, now);
        m.finished(JobResult::Saved(SaveOutcome::Failed), now);
        assert_eq!(m.choose(Choice::LogOutAnyway), Some(Effect::Exit(0)));
    }

    #[test]
    fn logout_after_a_failed_restore_asks_without_saving() {
        let mut m = Menu::new(grid(), true);
        assert_eq!(m.activate(3, Instant::now()), None, "no save job started");
        assert!(matches!(m.busy, Busy::LogoutFailed { .. }));
        assert_eq!(log(&m), [warn(&SaveOutcome::RestoreFailed.message())]);
        assert_eq!(m.choose(Choice::LogOutAnyway), Some(Effect::Exit(0)));
    }

    #[test]
    fn choice_outside_the_question_is_ignored() {
        let mut m = Menu::new(grid(), false);
        assert_eq!(m.choose(Choice::LogOutAnyway), None);
        assert_eq!(m.busy, Busy::Idle);
    }

    #[test]
    fn one_action_at_a_time() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert!(matches!(m.activate(1, now), Some(Effect::Start(Job::Run { .. }))));
        assert_eq!(m.activate(2, now), None, "save refused while the terminal runs");
        assert_eq!(m.activate(3, now), None, "logout refused while the terminal runs");
        m.finished(
            JobResult::Ran {
                name: "Terminal".into(),
                status: Ok(Some(0)),
                save_on_exit: false,
            },
            now,
        );
        assert_eq!(m.busy, Busy::Idle);
        assert_eq!(log(&m), [ev("Terminal started."), ev("Terminal exited.")]);
        assert_eq!(m.activate(3, now), Some(Effect::Start(Job::Save)));
    }

    #[test]
    fn save_on_exit_opens_the_save_dialog_after_the_program() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(0, now);
        let e = m.finished(
            JobResult::Ran {
                name: "ThinLinc".into(),
                status: Ok(Some(1)),
                save_on_exit: true,
            },
            now,
        );
        assert_eq!(e, Some(Effect::Start(Job::Save)));
        assert_eq!(
            m.busy,
            Busy::Saving {
                since: now,
                purpose: SaveFor::Backup
            }
        );
        m.finished(JobResult::Saved(SaveOutcome::ServerUnreachable), now);
        assert_eq!(m.busy, Busy::Idle);
        assert_eq!(
            log(&m),
            [
                ev("ThinLinc started."),
                warn("ThinLinc exited with status 1."),
                ev("Saving the home directory…"),
                warn("Not saved: the boot server cannot be reached."),
            ]
        );
    }

    #[test]
    fn failed_restore_greys_save_and_skips_save_on_exit() {
        let mut m = Menu::new(grid(), true);
        assert_eq!(m.tiles[2].problem.as_deref(), Some(RESTORE_FAILED_REASON));
        let now = Instant::now();
        assert_eq!(m.activate(2, now), None);
        m.activate(0, now);
        assert_eq!(
            m.finished(
                JobResult::Ran {
                    name: "ThinLinc".into(),
                    status: Ok(Some(0)),
                    save_on_exit: true
                },
                now
            ),
            None
        );
        assert_eq!(m.busy, Busy::Idle);
        assert_eq!(
            log(&m),
            [
                ev("ThinLinc started."),
                ev("ThinLinc exited."),
                warn(&SaveOutcome::RestoreFailed.message())
            ]
        );
    }

    #[test]
    fn save_tile_reports_refusal_not_success() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.activate(2, now), Some(Effect::Start(Job::Save)));
        m.finished(JobResult::Saved(SaveOutcome::RestoreFailed), now);
        assert_eq!(
            log(&m),
            [
                ev("Saving the home directory…"),
                warn(&SaveOutcome::RestoreFailed.message())
            ]
        );
    }

    #[test]
    fn unstartable_program_is_reported() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(1, now);
        m.finished(
            JobResult::Ran {
                name: "Terminal".into(),
                status: Err("foot could not be started: x".into()),
                save_on_exit: false,
            },
            now,
        );
        assert_eq!(log(&m)[1], warn("foot could not be started: x."));
    }

    #[test]
    fn a_signal_is_a_warning() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(1, now);
        m.finished(
            JobResult::Ran {
                name: "Terminal".into(),
                status: Ok(None),
                save_on_exit: false,
            },
            now,
        );
        assert_eq!(log(&m)[1], warn("Terminal was killed by a signal."));
    }

    #[test]
    fn the_banner_opens_the_log_as_warnings() {
        let mut g = grid();
        g.banner = vec!["Your own tiles could not be read.".into()];
        let m = Menu::new(g, false);
        assert_eq!(log(&m), [warn("Your own tiles could not be read.")]);
        assert_eq!(m.banner.len(), 1, "--check still prints it");
    }
}
