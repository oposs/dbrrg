//! Entry point. The exit status is the contract with dbrrg-session:
//! 0 means log out, and only after this program's own logout save or the
//! person's choice of "Log out anyway" following a failed save.
//! dbrrg-session saves on no status at all; any other status means the menu
//! failed.

use dbrrg_menu::app::{self, Config};
use dbrrg_menu::icons::{self, IconRoots};
use dbrrg_menu::jobs::{self, Paths};
use dbrrg_menu::menu::Menu;
use dbrrg_menu::{tiles, ui};
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;

fn env_path(name: &str, default: &str) -> PathBuf {
    std::env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn user_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("DBRRG_MENU_USER_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/home/tluser"));
    home.join(".config/dbrrg/menu")
}

fn build_menu() -> (Menu, Paths, IconRoots) {
    let shipped = env_path("DBRRG_MENU_SHIPPED_DIR", "/etc/dbrrg/menu");
    let paths = Paths {
        save_home: env_path("DBRRG_SAVE_HOME", "/usr/bin/dbrrg-save-home"),
        state_dir: env_path("DBRRG_STATE_DIR", "/run/dbrrg/state"),
    };
    let mut grid = tiles::load(&shipped, &user_dir());
    let path = std::env::var_os("PATH").unwrap_or_else(|| "/usr/local/bin:/usr/bin:/bin".into());
    tiles::mark_missing_programs(&mut grid.tiles, &path);
    let menu = Menu::new(grid, jobs::restore_failed(&paths.state_dir));
    (menu, paths, IconRoots::system())
}

/// `dbrrg-menu --check`: print every tile and how its icon draws, and fail
/// if a shipped tile is unusable or draws its letter. For the image tests,
/// and for an operator at a VT asking why a tile is grey.
fn check() -> ExitCode {
    let (menu, _, roots) = build_menu();
    let mut bad = false;
    for line in &menu.banner {
        println!("banner: {line}");
    }
    let icons = ui::render_icons(&menu.tiles, &roots);
    for (t, icon) in menu.tiles.iter().zip(icons) {
        let shipped = t.origin != tiles::Origin::User;
        let state = match &t.problem {
            Some(p) => format!("DISABLED ({p})"),
            None => "ok".to_string(),
        };
        let (icon_text, drawn) = match icon {
            None => ("letter fallback".to_string(), false),
            Some((path, Ok(_))) => (path.display().to_string(), true),
            Some((path, Err(e))) => (format!("letter fallback ({}: {e})", path.display()), false),
        };
        println!("{}\t{}\t{:?}\t{}\ticon: {}", t.file, t.name, t.action, state, icon_text);
        if shipped && (t.problem.is_some() || !drawn) {
            bad = true;
        }
    }
    if bad { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().collect();
    if args.get(1).is_some_and(|a| a == icons::RENDER_ICON_ARG) {
        return icons::render_icon_main(&args[2..]);
    }
    if args.get(1).is_some_and(|a| a == "--check") {
        return check();
    }
    let (menu, paths, icon_roots) = build_menu();
    let debug = std::env::var_os("DBRRG_MENU_DEBUG").is_some();
    if debug {
        eprintln!("dbrrg-menu: {} tiles", menu.tiles.len());
    }
    match app::run(Config {
        menu,
        paths,
        icon_roots,
        debug,
    }) {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(e) => {
            eprintln!("dbrrg-menu: {e}");
            ExitCode::from(1)
        }
    }
}
