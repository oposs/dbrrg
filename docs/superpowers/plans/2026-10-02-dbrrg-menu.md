# dbrrg-menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The session shows a grid of tiles instead of starting ThinLinc
directly. The grid offers `run`, `save-home` and `logout`, reads its tiles
from `/etc/dbrrg/menu` and `~/.config/dbrrg/menu`, and no file in a restored
home can make the machine unusable.

**Architecture:** A new Rust crate `src/dbrrg-menu/` builds the program
`dbrrg-menu`. It drives egui by hand through egui-winit and draws egui's
meshes with its own CPU rasteriser into a softbuffer surface, so it needs no
GPU, GL or Vulkan. All decisions (tile parsing, the reword rules, icon lookup,
the one-action-at-a-time state machine, save exit codes) live in modules
with no window, and are unit tested on the host. `dbrrg-session` runs the
menu where it ran `tlclient` and acts on its exit status: `0` saves the home
and logs out, anything else is a failure that is shown and not saved. The
login script stops restarting the session after three consecutive menu
failures.

**Tech Stack:** Rust 1.96.0 (edition 2024), egui / egui-winit 0.36.2,
winit 0.30.13 (Wayland only, dlopen), softbuffer 0.4.8, resvg 0.48.1, a
vendored copy of the `egui_shadcn` registry 0.2.1 (theme and fonts). POSIX
shell for the session scripts, bash for the integration tests. The image
build gains a `menu-build` stage that installs the pinned toolchain with
`rustup`.

**Spec:** `docs/superpowers/specs/2026-10-01-tile-menu-design.md`, delivery
item 2 ("The menu with `run`, `save-home` and `logout` only"). Item 3 (reboot
and poweroff) is out of scope; this plan leaves the two places it extends
named in code (`Action` in `tiles.rs`, the `case` in `dbrrg-session`).

**Every line of Rust in this plan was compiled and its tests run** against
the versions above on 2026-10-02 (48 unit tests green, `cargo clippy
--all-targets -- -D warnings` clean, `cargo fmt --check` clean). The release
binary was run under headless labwc inside `localhost/dbrrg-ubuntu:3.0.0`:
it mapped at 1280x720, rastered its first frame in 21 ms, and `--check`
resolved every shipped tile's icon. The shell scripts and the new
integration test were run offline and pass. Copy the code as given; where it
does not compile on your toolchain, fix the drift, do not redesign.

## Spec deltas

The spec predates the field-report work and the egui 0.36 release. Where it
and the current code disagree, this plan does the following:

1. **"Decisions taken" still says the initramfs records the EFI device node
   for the save.** The corrected section ("Corrected 2026-10-02") and the
   shipped `dbrrg-save-home` write to `/run/dbrrg/storage/efi` instead, with
   no `boot-efi-dev`. This plan touches neither; Task 10 corrects the stale
   bullet in the spec.
2. **`dbrrg-save-home` has six exit codes, not "distinct codes for its
   refusals".** Item 1 added `5` (attempted and failed). The menu maps all
   six (`jobs::SaveOutcome`), and any other status or a signal is reported
   as broken, never as saved.
3. **Six shipped tiles, not eight.** `90-reboot.desktop` and
   `95-poweroff.desktop` belong to item 3 together with exit codes 10 and
   11. Until then `X-DBRRG-Action=reboot` and `poweroff` are unknown actions
   and draw a disabled tile. Only the three Lucide icons item 2 uses ship
   (`hard-drive-download`, `usb`, `log-out`); item 3 adds `rotate-cw` and
   `power`.
4. **The mockup draws `Name` only.** The approved wording is `ThinLinc`,
   `oxulnk`, `Terminal`, `Back up home`, `Upgrade image`, `Log out`. The
   shipped files carry no `Comment`; a `Comment` a user sets is drawn as a
   muted second line.
5. **"Full screen grid" is a maximized, undecorated window, not an xdg
   fullscreen surface.** Fullscreen would cover waybar, which is the only way
   back to a minimized window, and would put the grid above the `foot` or
   ThinLinc window a tile has just opened. On a machine without waybar the
   two are the same size; the runtime test asserts the full output size.
6. **The pointer routing predicate has no consumer and is not built.** The
   menu has no floating UI apart from the save dialog, and while the dialog
   is up input is dropped before egui sees it. `is_pointer_over_egui()` is
   still banned (Global Constraints). The loop calls egui 0.36's
   `Context::run_ui`, which is the hand-driven `begin_pass`/`end_pass` pair
   plus a root `Ui`; there is still no eframe.
7. **The build stage uses `rustup`, pinned to 1.96.0.** Ubuntu 26.04's
   archive `rustc` is 1.93.1 and `egui-winit` 0.36.2 declares
   `rust-version = 1.95`.
8. **"Counts restarts and falls through after several fast failures"** is
   three *consecutive* failed sessions, recorded through a status file,
   because labwc's own exit status carries nothing. No time window: stopping
   a loop needs no clock.
9. **"Prints the diagnostic and holds"** is a `foot` window naming the status
   and the tail of the session log. Closing it ends the session, which then
   counts as one failure.
10. **The binary is 9 MB**, not the 15 to 25 MB the spec estimated.

## Open questions for the user

1. **A save that fails at logout is reported only in the session log.**
   On exit 0 `dbrrg-session` runs `dbrrg-save-home` and the session ends at
   once, as it does today after `tlclient`. The plan keeps that contract.
   The alternative is for the Log out tile to run the save behind the dialog
   first, show the result, and only then exit, which changes the exit-code
   contract the spec fixed. Not decided here.

## Global Constraints

Every task's reviewer gets this section verbatim.

- **Host rules.** At most 4 cores: `CARGO_BUILD_JOBS=4` and `-j 4` on every
  cargo call. No data under `/tmp`: export
  `TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test` (create it) before any
  `cargo test` or integration test. Container builds run as
  `flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make …` and use
  podman, never docker. Pass `timeout: 600000` on long Bash calls and never
  end a turn while a background shell is still running.
- **Every `cargo test` runs under a memory cap:**
  `systemd-run --user --scope -q -p MemoryMax=2G -- cargo test …`. The
  icon and tile-file tests feed deliberately oversized input; a broken
  bound must fail the test, not exhaust the shared 25 GiB slice.
- **Crate versions are the ones in Task 1's `Cargo.toml`**, the latest
  stable on 2026-10-02 (checked with `cargo search`). `Cargo.lock` is
  committed and every build after Task 1 uses `--locked`.
- `[profile.dev]` keeps `debug = "line-tables-only"` and
  `split-debuginfo = "unpacked"`.
- **No GPU API.** No `wgpu`, `glow`, `eframe`, `egui_glow`, `egui-wgpu` or
  `egui_kittest` in any dependency table. The binary must not link or
  dlopen `libvulkan`, `libGL`, `libEGL` or `libGLESv2` (Task 8 asserts it).
- **No `smithay-clipboard`.** `egui-winit` stays at
  `default-features = false, features = ["links", "wayland"]`; check with
  `cargo tree -i smithay-clipboard` (must report no match).
- **Never `ctx.is_pointer_over_egui()`** or `wants_pointer_input()` for
  routing: both are always true under a hand-driven loop.
- **Rendering rules from the spec:** feathering off; tessellate with the
  `pixels_per_point` egui laid out with; `animation_time = 0`; honour
  `repaint_delay`; skip raster and present when the primitive fingerprints
  are unchanged; dim the grid once when the save dialog opens; rasterise
  icons once at startup.
- **Exit-status contract**, `dbrrg-menu` to `dbrrg-session`: `0` = log out
  (save, then return). Any other status = the menu failed: do **not** save,
  show why, hold. Failure is the default branch. Item 3 adds `10` reboot
  and `11` poweroff; nothing in this plan may give those numbers a meaning.
- **`dbrrg-save-home` exit codes** (shipped, `overlay/usr/bin/dbrrg-save-home:21-31`):
  `0` saved, `1` home missing, `2` this boot's restore failed, `3` boot
  server unreachable, `4` nowhere to store, `5` attempted and failed.
- **User tile rules** (spec, "Tile sources" and "Tile file format"): at most
  32 user files, regular files in a real directory only; one parse failure
  disables one tile; a user file named like a shipped file takes only
  `Name`, `Comment`, `Icon` from the user and names the ignored keys
  (`Exec`, `Terminal`, `X-DBRRG-Action`, `X-DBRRG-Save-On-Exit`); a
  standalone user tile may only `run`; `X-DBRRG-Save-On-Exit` counts only
  for `run`; name matching is case sensitive; if the merge leaves fewer
  usable shipped tiles than the shipped set alone, show the shipped set and
  say why.
- **Icon lookup order:** absolute path; `/usr/share/dbrrg/icons/<n>.svg`;
  hicolor `scalable/apps/<n>.svg`, then the largest `NxN/apps/<n>.png`;
  Adwaita `symbolic/*/<n>.svg`, then `scalable/*/<n>.svg`; else the first
  letter of `Name`.
- Shipped tiles live in `/etc/dbrrg/menu`, never under `$HOME`; icons in
  `/usr/share/dbrrg/icons/` with Lucide's `LICENSE` beside them.
- **Standing constraints stay:** zero labwc keybindings, no keybinding to
  reach the terminal (the tile is the launch path), `tluser` keeps
  passwordless sudo, no restore call in `dbrrg-session` or
  `10-dbrrg-session.sh`.
- Shell: `/bin/sh`, no bashisms, in `overlay/`. Tests: bash, offline,
  unprivileged, in `test/integration/`, printing `ok   - …` / `FAIL - …`
  and exiting non-zero on any failure.
- English for code, comments and docs. Comments say why, in the density of
  the surrounding file.
- Commit after each task with a conventional subject and the trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. The repo has no
  CHANGES file; `CLAUDE.md` is the project memory (Task 10).

## Review Focus

Five conditions the spec implies but does not spell out, most likely first.
Each has a test in the task named.

- **A user tile whose `Name` or `Comment` is one 60 KB line.** It is laid
  out and rasterised on every frame and can push every other tile off
  screen. Expected: text cut to 120 characters. → Task 2,
  `overlong_text_is_cut`.
- **The menu dies by a signal** (OOM killer, labwc tearing down). The shell
  reports 137, not 0. Expected: no save, a failure window, status recorded.
  → Task 7, "menu killed".
- **`Icon=` names `/dev/zero`, or a PNG whose header claims 100000x100000.**
  Reading the first never ends; decoding the second allocates 40 GB.
  Expected: refused before reading or decoding, letter fallback. → Task 3,
  `absolute_and_fallback`, `refuses_png_bombs_before_decoding`.
- **`home-restore` holds `failed` without a newline, or with CRLF.**
  Expected: the save tile is still greyed out. → Task 5,
  `restore_state_is_read_tolerantly`.
- **ThinLinc exits non-zero straight away** (bad config, no server).
  Expected: the grid says so, and the save on exit still runs behind the
  dialog. → Task 5, `save_on_exit_opens_the_save_dialog_after_the_program`.

---

## File Structure

| file | responsibility | change |
| --- | --- | --- |
| `src/dbrrg-menu/Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `rustfmt.toml` | crate manifest, pinned toolchain | new |
| `src/dbrrg-menu/egui_shadcn/` | vendored theme, fonts and components (registry 0.2.1) | new |
| `src/dbrrg-menu/src/desktop.rs` | desktop entry and `Exec` parsing | new |
| `src/dbrrg-menu/src/tiles.rs` | tile model, bounded directory reading, reword and merge rules, fallback, missing programs | new |
| `src/dbrrg-menu/src/icons.rs` | icon lookup order, bounded SVG/PNG rasterising | new |
| `src/dbrrg-menu/icons/` | three Lucide SVGs and `LICENSE` | new |
| `src/dbrrg-menu/src/raster.rs` | CPU rasteriser, textures, frozen background | new |
| `src/dbrrg-menu/src/damage.rs` | primitive fingerprints, damage rectangle | new |
| `src/dbrrg-menu/src/jobs.rs` | save and run on a worker, save exit codes | new |
| `src/dbrrg-menu/src/menu.rs` | state machine: one action at a time, exit codes | new |
| `src/dbrrg-menu/src/ui.rs` | painting the grid and the save dialog | new |
| `src/dbrrg-menu/src/app.rs` | winit / egui-winit / softbuffer event loop | new |
| `src/dbrrg-menu/src/main.rs`, `lib.rs` | entry point, `--check` | new |
| `overlay/usr/bin/dbrrg-session` | runs the menu, acts on its status | modify |
| `overlay/usr/libexec/dbrrg/session-verdict` | restart or stop after a failed session | new |
| `overlay/etc/profile.d/10-dbrrg-session.sh` | status file, failure count | modify |
| `overlay/etc/dbrrg/menu/*.desktop` | the six shipped tiles | new |
| `containers/ubuntu/Dockerfile` | `menu-build` stage, install binary and icons | modify |
| `Makefile` | `MENU_FILES`, `test-unit` runs cargo, new tests wired | modify |
| `.dockerignore`, `.gitignore` | let the crate into the build context, keep `target/` out | modify |
| `test/integration/test-session-lifecycle.sh` | exit-status contract, restart limit (offline) | new |
| `test/integration/test-session-packages.sh` | image assertions | modify |
| `test/runtime/test-labwc-runtime.sh` | the grid maps full size under labwc | modify |
| `CLAUDE.md`, `README.md`, the spec | project memory, user docs, stale bullet | modify |

---

### Task 1: Crate scaffold, vendored theme, desktop entry parser

**Files:**
- Create: `src/dbrrg-menu/Cargo.toml`, `src/dbrrg-menu/rust-toolchain.toml`,
  `src/dbrrg-menu/rustfmt.toml`, `src/dbrrg-menu/src/lib.rs`,
  `src/dbrrg-menu/src/main.rs`, `src/dbrrg-menu/src/desktop.rs`,
  `src/dbrrg-menu/egui_shadcn/` (vendored), `src/dbrrg-menu/Cargo.lock`
- Modify: `Makefile` (`test-unit`), `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `desktop::Entry { keys: BTreeMap<String, String> }` with
  `Entry::get(&self, key: &str) -> Option<&str>`;
  `desktop::parse(text: &str) -> Result<Entry, String>` (errors name the
  line: `"line 3 is not a desktop entry line"`);
  `desktop::split_exec(exec: &str) -> Result<Vec<String>, String>`. The
  `egui_shadcn` crate with `egui_shadcn::Theme::{dark, current, apply}` and
  `Theme.palette.{background, foreground, card, accent, border, ring, muted,
  muted_foreground}`, `radius_sm()`, `radius_md()`, `radius_lg()`.
  `make test-unit` runs the crate's tests.

- [ ] **Step 1: Write the manifest and toolchain files**

`src/dbrrg-menu/Cargo.toml`:

```toml
[package]
name = "dbrrg-menu"
version = "0.1.0"
edition = "2024"
rust-version = "1.96"
publish = false

[dependencies]
egui_shadcn = { path = "egui_shadcn" }
egui = { version = "0.36.2", default-features = false, features = ["default_fonts"] }
egui-winit = { version = "0.36.2", default-features = false, features = ["links", "wayland"] }
winit = { version = "0.30.13", default-features = false, features = ["wayland", "wayland-dlopen", "rwh_06"] }
softbuffer = { version = "0.4.8", default-features = false, features = ["wayland", "wayland-dlopen"] }
resvg = { version = "0.48.1", default-features = false }

[profile.dev]
debug = "line-tables-only"
split-debuginfo = "unpacked"

[profile.release]
lto = "thin"
strip = true
```

`src/dbrrg-menu/rust-toolchain.toml`:

```toml
[toolchain]
channel = "1.96.0"
profile = "minimal"
components = ["clippy", "rustfmt"]
```

`src/dbrrg-menu/rustfmt.toml`:

```toml
max_width = 120
```

- [ ] **Step 2: Vendor the egui_shadcn registry**

The registry is shipped with the `egui-shadcn` skill. Copy it unchanged,
minus `reference.rs` (a demo screen that warns under egui 0.36 and is not
used):

```bash
R=/home/oetiker/.claude/plugins/cache/oposs-plugins/egui-shadcn/0.2.1
D=/home/oetiker/checkouts/dbrrg/src/dbrrg-menu/egui_shadcn
mkdir -p "$D"
cp -r "$R/skills/egui-shadcn/registry/src" "$R/skills/egui-shadcn/registry/assets" "$D/"
cp "$R/LICENSE" "$D/LICENSE"
rm "$D/src/reference.rs"
sed -i '/^pub mod reference;$/d' "$D/src/lib.rs"
```

Then write `src/dbrrg-menu/egui_shadcn/Cargo.toml`:

```toml
[package]
name = "egui_shadcn"
version = "0.2.1"
edition = "2021"
publish = false

[dependencies]
egui = { version = "0.36.2", default-features = false, features = ["default_fonts"] }
egui_extras = { version = "0.36.2", default-features = false }
```

If that cache path is missing, clone `https://github.com/oetiker/egui-shadcn`
at tag `v0.2.1` and copy the same two directories from
`skills/egui-shadcn/registry/`.

- [ ] **Step 3: Write the failing parser tests**

`src/dbrrg-menu/src/lib.rs`:

```rust
//! dbrrg-menu: the tile grid that is the body of the dbrrg session.

pub mod desktop;
```

`src/dbrrg-menu/src/main.rs` (replaced in Task 6):

```rust
fn main() {}
```

`src/dbrrg-menu/src/desktop.rs`, tests only for now:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_main_group_and_skips_others() {
        let e = parse(
            "# c\n[Desktop Entry]\nName=ThinLinc\nName[de]=Dünn\nExec=/opt/thinlinc/bin/tlclient\n\
             [Desktop Action x]\nName=other\n",
        )
        .unwrap();
        assert_eq!(e.get("Name"), Some("ThinLinc"));
        assert_eq!(e.get("Exec"), Some("/opt/thinlinc/bin/tlclient"));
        assert_eq!(e.keys.len(), 2);
    }

    #[test]
    fn names_the_bad_line() {
        assert_eq!(
            parse("[Desktop Entry]\nName=x\nthis is junk\n").unwrap_err(),
            "line 3 is not a desktop entry line"
        );
        assert_eq!(parse("Name=x\n").unwrap_err(), "line 1 comes before [Desktop Entry]");
        assert_eq!(parse("").unwrap_err(), "no [Desktop Entry] group");
    }

    #[test]
    fn unescapes_values() {
        let e = parse("[Desktop Entry]\nComment=a\\sb\\\\c\n").unwrap();
        assert_eq!(e.get("Comment"), Some("a b\\c"));
    }

    #[test]
    fn splits_exec() {
        assert_eq!(split_exec("sudo upgrade-image").unwrap(), ["sudo", "upgrade-image"]);
        assert_eq!(split_exec("foo %U --x").unwrap(), ["foo", "--x"]);
        assert_eq!(
            split_exec(r#""/a b/c" "q\"x" 100%%"#).unwrap(),
            ["/a b/c", "q\"x", "100%"]
        );
        assert_eq!(split_exec(r#"x """#).unwrap(), ["x", ""]);
        assert!(split_exec("\"open").is_err());
        assert!(split_exec("   ").is_err());
        assert!(split_exec("%U").is_err());
    }
}
```

- [ ] **Step 4: Run them to see them fail**

```bash
mkdir -p /scratch/oetiker/claude-tmp/dbrrg-test
cd /home/oetiker/checkouts/dbrrg/src/dbrrg-menu
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test CARGO_BUILD_JOBS=4 \
  systemd-run --user --scope -q -p MemoryMax=2G -- cargo test -j 4
```

Expected: compile errors `cannot find function \`parse\`` and
`cannot find function \`split_exec\``. This first run also resolves the
dependencies and writes `Cargo.lock`.

- [ ] **Step 5: Implement the parser**

Insert above the `#[cfg(test)]` line of `src/dbrrg-menu/src/desktop.rs`:

```rust
//! A desktop entry reader that knows exactly as much of the freedesktop
//! format as a tile needs: the `[Desktop Entry]` group, `key=value` lines,
//! comments, value escapes, and the `Exec` quoting rules.

use std::collections::BTreeMap;

/// The keys of one `[Desktop Entry]` group. Localised keys (`Name[de]`) and
/// other groups are skipped, not rejected.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Entry {
    pub keys: BTreeMap<String, String>,
}

impl Entry {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.keys.get(key).map(String::as_str)
    }
}

/// Parse a desktop entry. The error names the line, because the grid shows
/// it on the tile and that is the only place a person at the machine sees it.
pub fn parse(text: &str) -> Result<Entry, String> {
    let mut entry = Entry::default();
    let mut in_main = false;
    let mut seen_main = false;
    for (idx, raw) in text.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            if !line.ends_with(']') {
                return Err(format!("line {line_no} is not a group header"));
            }
            in_main = line == "[Desktop Entry]";
            seen_main |= in_main;
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!("line {line_no} is not a desktop entry line"));
        };
        if !seen_main {
            return Err(format!("line {line_no} comes before [Desktop Entry]"));
        }
        if !in_main {
            continue;
        }
        let key = key.trim();
        if key.is_empty() {
            return Err(format!("line {line_no} has no key"));
        }
        if key.contains('[') {
            continue;
        }
        entry.keys.insert(key.to_string(), unescape(value.trim()));
    }
    if !seen_main {
        return Err("no [Desktop Entry] group".to_string());
    }
    Ok(entry)
}

fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Split an `Exec` value into argv. Double quotes group, a backslash inside
/// quotes escapes the next character, field codes (`%f`, `%U`, ...) are
/// dropped because a tile is never started with files, and `%%` is a `%`.
pub fn split_exec(exec: &str) -> Result<Vec<String>, String> {
    let mut args = Vec::new();
    let mut cur = String::new();
    let mut have = false;
    let mut quoted = false;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                quoted = !quoted;
                have = true;
            }
            '\\' if quoted => match chars.next() {
                Some(n) => cur.push(n),
                None => return Err("Exec ends in a backslash".to_string()),
            },
            '%' => match chars.next() {
                Some('%') => {
                    cur.push('%');
                    have = true;
                }
                Some(_) => {}
                None => return Err("Exec ends in a lone %".to_string()),
            },
            c if c.is_whitespace() && !quoted => {
                if have || !cur.is_empty() {
                    args.push(std::mem::take(&mut cur));
                    have = false;
                }
            }
            c => {
                cur.push(c);
                have = true;
            }
        }
    }
    if quoted {
        return Err("Exec has an unterminated quote".to_string());
    }
    if have || !cur.is_empty() {
        args.push(cur);
    }
    if args.is_empty() {
        return Err("Exec is empty".to_string());
    }
    Ok(args)
}
```

- [ ] **Step 6: Run the tests**

Same command as Step 4, now with `--locked`. Expected:
`test result: ok. 4 passed`. Then:

```bash
CARGO_BUILD_JOBS=4 cargo clippy --locked -j 4 --all-targets -- -D warnings
cargo fmt --check
cargo tree -i smithay-clipboard
```

Expected: clippy prints no warning, fmt prints nothing, `cargo tree` says
the package ID specification did not match any packages.

- [ ] **Step 7: Wire `make test-unit` and ignore the target directory**

In `Makefile`, replace the `test-unit` rule (currently `Makefile:303-307`):

```make
# Host-side tests. No image, no container, no network: the fast feedback
# loop for the scripts in overlay/usr/bin and for dbrrg-menu's rules.
# Deliberately not dependent on 'rootfs'.
#
# MEMCAP bounds the cargo tests: the tile-file and icon tests feed
# deliberately oversized input, and a broken bound must fail the test rather
# than take the machine's memory. Set MEMCAP= where systemd-run is missing.
MENU_DIR := src/dbrrg-menu
MEMCAP ?= systemd-run --user --scope -q -p MemoryMax=2G --
test-unit:
	@python3 -m unittest discover -s test/unit -v
	cd $(MENU_DIR) && CARGO_BUILD_JOBS=$(BUILD_JOBS) $(MEMCAP) cargo test --locked -j $(BUILD_JOBS)
```

Append to `.gitignore`:

```
# dbrrg-menu build output, when CARGO_TARGET_DIR is not set
/src/dbrrg-menu/target/
```

Run: `TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test make test-unit`.
Expected: the Python suite passes, then `test result: ok. 4 passed`.

- [ ] **Step 8: Commit**

```bash
cd /home/oetiker/checkouts/dbrrg
git add src/dbrrg-menu Makefile .gitignore
git commit -m "feat(menu): scaffold the dbrrg-menu crate and its desktop entry parser

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Tiles, their sources, and the rules that protect the machine

**Files:**
- Create: `src/dbrrg-menu/src/tiles.rs`
- Modify: `src/dbrrg-menu/src/lib.rs` (add `pub mod tiles;`)

**Interfaces:**
- Consumes: `desktop::{parse, split_exec, Entry}` (Task 1).
- Produces:
  - `enum Action { Run, SaveHome, Logout }`,
    `Action::parse(Option<&str>) -> Result<Action, String>`,
    `Action::exit_code(self) -> Option<i32>` (`Logout` → `Some(0)`).
  - `enum Origin { Shipped, Reworded { ignored: Vec<String> }, User }`
  - `struct Tile { file, name: String, comment, icon: Option<String>,
    action: Action, argv: Vec<String>, terminal, save_on_exit: bool,
    origin: Origin, problem: Option<String>, note: Option<String> }`,
    `Tile::usable(&self) -> bool`.
  - `struct SourceFile { name: String, entry: Result<Entry, String> }`,
    `struct SourceDir { files: Vec<SourceFile>, notes: Vec<String> }`,
    `read_dir_bounded(dir: &Path, cap: usize, label: &str) -> SourceDir`.
  - `merge(shipped: &[SourceFile], user: &[SourceFile]) -> Vec<Tile>`,
    `struct Grid { tiles: Vec<Tile>, banner: Vec<String> }`,
    `choose(shipped_only, merged, banner) -> Grid`,
    `load(shipped_dir: &Path, user_dir: &Path) -> Grid`.
  - `find_program(&str, path: &OsStr) -> Option<PathBuf>`,
    `mark_missing_programs(&mut [Tile], path: &OsStr)`,
    `command_line(&Tile) -> Vec<String>` (`Terminal=true` → `foot -- …`).
  - Constants `MAX_USER_FILES = 32`, `MAX_SHIPPED_FILES = 64`,
    `MAX_DIR_ENTRIES = 4096`, `MAX_FILE_BYTES = 64 KiB`,
    `MAX_TEXT_CHARS = 120`.

**Why:** a restored home is restored again on every boot, so one bad file
in `~/.config/dbrrg/menu` must cost at most its own tile. The test the spec
calls easy to leave out is here:
`reword_with_broken_exec_still_launches_shipped_tlclient`.

- [ ] **Step 1: Write the failing tests**

Add `pub mod tiles;` to `src/dbrrg-menu/src/lib.rs` and create
`src/dbrrg-menu/src/tiles.rs` with:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("dbrrg-menu-tiles-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn src(name: &str, text: &str) -> SourceFile {
        SourceFile {
            name: name.to_string(),
            entry: desktop::parse(text),
        }
    }

    fn thinlinc() -> SourceFile {
        src(
            "10-thinlinc.desktop",
            "[Desktop Entry]\nName=ThinLinc\nIcon=/opt/thinlinc/lib/tlclient/thinlinc_128.png\n\
             Exec=/opt/thinlinc/bin/tlclient\nX-DBRRG-Save-On-Exit=true\n",
        )
    }

    fn save_home() -> SourceFile {
        src(
            "40-save-home.desktop",
            "[Desktop Entry]\nName=Back up home\nIcon=hard-drive-download\nX-DBRRG-Action=save-home\n",
        )
    }

    #[test]
    fn sorts_both_directories_together_by_file_name() {
        let tiles = merge(
            &[thinlinc(), save_home()],
            &[src(
                "25-browser.desktop",
                "[Desktop Entry]\nName=Browser\nExec=firefox\n",
            )],
        );
        let files: Vec<&str> = tiles.iter().map(|t| t.file.as_str()).collect();
        assert_eq!(
            files,
            ["10-thinlinc.desktop", "25-browser.desktop", "40-save-home.desktop"]
        );
        assert_eq!(tiles[1].origin, Origin::User);
    }

    #[test]
    fn user_file_rewords_name_comment_icon_only() {
        let tiles = merge(
            &[thinlinc()],
            &[src(
                "10-thinlinc.desktop",
                "[Desktop Entry]\nName=Firmen-Desktop\nComment=Anmelden\nIcon=foot\n\
                 Exec=/bin/false\nTerminal=true\nX-DBRRG-Action=logout\nX-DBRRG-Save-On-Exit=false\n",
            )],
        );
        assert_eq!(tiles.len(), 1);
        let t = &tiles[0];
        assert_eq!(t.name, "Firmen-Desktop");
        assert_eq!(t.comment.as_deref(), Some("Anmelden"));
        assert_eq!(t.icon.as_deref(), Some("foot"));
        assert_eq!(t.argv, ["/opt/thinlinc/bin/tlclient"]);
        assert!(!t.terminal);
        assert_eq!(t.action, Action::Run);
        assert!(t.save_on_exit);
        assert_eq!(
            t.origin,
            Origin::Reworded {
                ignored: vec![
                    "Exec".into(),
                    "Terminal".into(),
                    "X-DBRRG-Action".into(),
                    "X-DBRRG-Save-On-Exit".into()
                ]
            }
        );
        assert!(t.usable());
    }

    // The test the spec calls easy to leave out and the whole point of the
    // rule: a reword with a broken Exec still launches the shipped tlclient.
    #[test]
    fn reword_with_broken_exec_still_launches_shipped_tlclient() {
        let tiles = merge(
            &[thinlinc()],
            &[src(
                "10-thinlinc.desktop",
                "[Desktop Entry]\nName=TL\nExec=\"unterminated\n",
            )],
        );
        assert_eq!(tiles[0].argv, ["/opt/thinlinc/bin/tlclient"]);
        assert!(tiles[0].usable());
        assert_eq!(command_line(&tiles[0]), ["/opt/thinlinc/bin/tlclient"]);
    }

    #[test]
    fn unreadable_reword_keeps_shipped_text_and_says_so() {
        let tiles = merge(&[thinlinc()], &[src("10-thinlinc.desktop", "garbage\n")]);
        assert_eq!(tiles[0].name, "ThinLinc");
        assert!(tiles[0].usable());
        assert!(tiles[0].note.as_deref().unwrap().contains("could not be read"));
    }

    #[test]
    fn name_match_is_case_sensitive() {
        let tiles = merge(
            &[thinlinc()],
            &[src(
                "10-ThinLinc.desktop",
                "[Desktop Entry]\nName=Mine\nExec=tlclient\n",
            )],
        );
        assert_eq!(tiles.len(), 2);
        assert_eq!(tiles[0].origin, Origin::User, "uppercase T sorts first");
        assert_eq!(tiles[1].name, "ThinLinc");
    }

    #[test]
    fn user_tile_may_only_run() {
        let tiles = merge(
            &[],
            &[
                src("60-x.desktop", "[Desktop Entry]\nName=X\nX-DBRRG-Action=logout\n"),
                src(
                    "61-y.desktop",
                    "[Desktop Entry]\nName=Y\nX-DBRRG-Action=reboot\nExec=y\n",
                ),
                src("62-z.desktop", "[Desktop Entry]\nName=Z\nX-DBRRG-Action=run\nExec=z\n"),
            ],
        );
        assert!(
            tiles[0]
                .problem
                .as_deref()
                .unwrap()
                .contains("may only use the run action")
        );
        assert!(tiles[1].problem.is_some());
        assert!(tiles[2].usable());
    }

    #[test]
    fn save_on_exit_ignored_outside_run() {
        let tiles = merge(
            &[src(
                "40-save-home.desktop",
                "[Desktop Entry]\nName=B\nX-DBRRG-Action=save-home\nX-DBRRG-Save-On-Exit=true\nTerminal=true\n",
            )],
            &[src(
                "70-u.desktop",
                "[Desktop Entry]\nName=U\nExec=u\nX-DBRRG-Save-On-Exit=true\n",
            )],
        );
        assert!(!tiles[0].save_on_exit);
        assert!(!tiles[0].terminal);
        assert!(tiles[1].save_on_exit, "valid on a user run tile");
    }

    #[test]
    fn reboot_and_poweroff_are_not_actions_yet() {
        assert!(Action::parse(Some("reboot")).is_err());
        assert!(Action::parse(Some("poweroff")).is_err());
        assert_eq!(Action::Logout.exit_code(), Some(0));
        assert_eq!(Action::Run.exit_code(), None);
        assert_eq!(Action::SaveHome.exit_code(), None);
    }

    #[test]
    fn one_malformed_file_disables_one_tile() {
        let tiles = merge(
            &[thinlinc()],
            &[
                src("60-bad.desktop", "[Desktop Entry]\nName=Bad\nnot a line\n"),
                src("61-good.desktop", "[Desktop Entry]\nName=Good\nExec=good\n"),
            ],
        );
        assert_eq!(tiles.len(), 3);
        assert!(tiles[0].usable());
        assert_eq!(
            tiles[1].problem.as_deref(),
            Some("60-bad.desktop: line 3 is not a desktop entry line")
        );
        assert!(tiles[2].usable());
    }

    #[test]
    fn falls_back_to_shipped_set_when_merge_loses_a_shipped_tile() {
        let shipped_only = merge(&[thinlinc()], &[]);
        let mut merged = shipped_only.clone();
        merged[0].problem = Some("broken".into());
        let grid = choose(shipped_only, merged, Vec::new());
        assert!(grid.tiles[0].usable());
        assert_eq!(grid.banner.len(), 1);
    }

    #[test]
    fn reads_at_most_32_user_files_in_name_order() {
        let d = tmpdir("cap");
        for i in 0..40 {
            fs::write(
                d.join(format!("{i:02}.desktop")),
                format!("[Desktop Entry]\nName=T{i}\nExec=x\n"),
            )
            .unwrap();
        }
        let got = read_dir_bounded(&d, MAX_USER_FILES, "~/.config/dbrrg/menu");
        assert_eq!(got.files.len(), 32);
        assert_eq!(got.files[0].name, "00.desktop");
        assert_eq!(got.files[31].name, "31.desktop");
        assert!(got.notes[0].contains("only the first 32"));
    }

    #[test]
    fn refuses_symlinked_or_file_directory() {
        let d = tmpdir("dirkind");
        let real = d.join("real");
        fs::create_dir(&real).unwrap();
        fs::write(real.join("a.desktop"), "[Desktop Entry]\nName=A\nExec=a\n").unwrap();
        symlink(&real, d.join("link")).unwrap();
        fs::write(d.join("file"), "x").unwrap();
        let link = read_dir_bounded(&d.join("link"), 32, "L");
        assert!(link.files.is_empty());
        assert_eq!(link.notes, ["L is not a directory, so it was ignored"]);
        assert!(read_dir_bounded(&d.join("file"), 32, "F").files.is_empty());
        let missing = read_dir_bounded(&d.join("nope"), 32, "N");
        assert!(missing.files.is_empty() && missing.notes.is_empty());
    }

    #[test]
    fn refuses_fifo_symlink_and_oversized_files() {
        let d = tmpdir("files");
        symlink("/dev/zero", d.join("a.desktop")).unwrap();
        let st = std::process::Command::new("mkfifo")
            .arg(d.join("b.desktop"))
            .status()
            .unwrap();
        assert!(st.success());
        fs::write(d.join("c.desktop"), vec![b'x'; (MAX_FILE_BYTES + 1) as usize]).unwrap();
        fs::write(d.join("d.desktop"), [0xff, 0xfe]).unwrap();
        let got = read_dir_bounded(&d, 32, "D");
        let errs: Vec<String> = got.files.iter().map(|f| f.entry.clone().unwrap_err()).collect();
        assert_eq!(
            errs,
            [
                "not a regular file",
                "not a regular file",
                "larger than 64 KiB",
                "not UTF-8 text"
            ]
        );
    }

    #[test]
    fn huge_directory_is_bounded() {
        let d = tmpdir("huge");
        for i in 0..(MAX_DIR_ENTRIES + 10) {
            fs::write(d.join(format!("f{i}")), "").unwrap();
        }
        let got = read_dir_bounded(&d, 32, "H");
        assert!(got.files.is_empty());
        assert!(got.notes[0].contains("more than 4096 entries"));
    }

    #[test]
    fn missing_program_disables_tile() {
        let d = tmpdir("path");
        let bin = d.join("bin");
        fs::create_dir(&bin).unwrap();
        fs::write(bin.join("present"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(bin.join("present"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(bin.join("noexec"), "").unwrap();
        let mut tiles = merge(
            &[],
            &[
                src("1.desktop", "[Desktop Entry]\nName=P\nExec=present\n"),
                src("2.desktop", "[Desktop Entry]\nName=Q\nExec=absent --x\n"),
                src("3.desktop", "[Desktop Entry]\nName=R\nExec=noexec\n"),
                src("4.desktop", "[Desktop Entry]\nName=S\nExec=present\nTerminal=true\n"),
            ],
        );
        mark_missing_programs(&mut tiles, bin.as_os_str());
        assert!(tiles[0].usable());
        assert_eq!(tiles[1].problem.as_deref(), Some("absent is not installed"));
        assert_eq!(tiles[2].problem.as_deref(), Some("noexec is not installed"));
        assert_eq!(tiles[3].problem.as_deref(), Some("foot is not installed"));
    }

    #[test]
    fn overlong_text_is_cut() {
        let long = "x".repeat(60_000);
        let tiles = merge(
            &[],
            &[src(
                "1.desktop",
                &format!("[Desktop Entry]\nName={long}\nComment={long}\nExec=x\n"),
            )],
        );
        assert_eq!(tiles[0].name.chars().count(), MAX_TEXT_CHARS);
        assert_eq!(tiles[0].comment.as_ref().unwrap().chars().count(), MAX_TEXT_CHARS);
    }

    #[test]
    fn terminal_tile_runs_in_foot() {
        let tiles = merge(
            &[src(
                "50-u.desktop",
                "[Desktop Entry]\nName=U\nExec=sudo upgrade-image\nTerminal=true\n",
            )],
            &[],
        );
        assert_eq!(command_line(&tiles[0]), ["foot", "--", "sudo", "upgrade-image"]);
    }
}
```

- [ ] **Step 2: Run them to see them fail**

```bash
cd /home/oetiker/checkouts/dbrrg/src/dbrrg-menu
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test CARGO_BUILD_JOBS=4 \
  systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 tiles::
```

Expected: compile errors, `cannot find function \`merge\``,
`cannot find type \`SourceFile\`` and similar.

- [ ] **Step 3: Implement**

Insert above the `#[cfg(test)]` line:

```rust
//! Tiles: where they come from, how a user file may change them, and what
//! keeps one bad file in a restored home from making the machine unusable.

use crate::desktop::{self, Entry};
use std::ffi::OsStr;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// At most this many user files are read. The cap is in the spec.
pub const MAX_USER_FILES: usize = 32;
/// The shipped directory is ours, but it goes through the same reader.
pub const MAX_SHIPPED_FILES: usize = 64;
/// Directory entries looked at before giving up, so a directory holding
/// 200000 files cannot stall the grid.
pub const MAX_DIR_ENTRIES: usize = 4096;
/// A tile file larger than this is not a tile file.
pub const MAX_FILE_BYTES: u64 = 64 * 1024;
/// Name, Comment and Icon are cut to this many characters. A 60 KB Name
/// would otherwise be laid out and rasterised on every frame.
pub const MAX_TEXT_CHARS: usize = 120;

/// What a tile does. Item 3 of the spec adds `Reboot` (exit 10) and
/// `Poweroff` (exit 11) here and in `exit_code`; until then those names are
/// unknown actions and the tile is drawn disabled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Run,
    SaveHome,
    Logout,
}

impl Action {
    pub fn parse(value: Option<&str>) -> Result<Action, String> {
        match value {
            None | Some("run") => Ok(Action::Run),
            Some("save-home") => Ok(Action::SaveHome),
            Some("logout") => Ok(Action::Logout),
            Some(other) => Err(format!("unknown action '{other}'")),
        }
    }

    /// The exit status that hands this action to dbrrg-session, for the
    /// actions that end the menu. Anything else dbrrg-menu exits with is a
    /// failure, and dbrrg-session must not save on it.
    pub fn exit_code(self) -> Option<i32> {
        match self {
            Action::Logout => Some(0),
            Action::Run | Action::SaveHome => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    Shipped,
    /// A user file of the same name changed Name, Comment or Icon. `ignored`
    /// lists the keys it set that only the shipped file may set.
    Reworded {
        ignored: Vec<String>,
    },
    User,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tile {
    pub file: String,
    pub name: String,
    pub comment: Option<String>,
    pub icon: Option<String>,
    pub action: Action,
    pub argv: Vec<String>,
    pub terminal: bool,
    pub save_on_exit: bool,
    pub origin: Origin,
    /// Set when the tile cannot be used. The grid draws it disabled with
    /// this text on it.
    pub problem: Option<String>,
    /// Shown on the tile without disabling it.
    pub note: Option<String>,
}

impl Tile {
    fn broken(file: &str, origin: Origin, why: String) -> Tile {
        Tile {
            file: file.to_string(),
            name: file.trim_end_matches(".desktop").to_string(),
            comment: None,
            icon: None,
            action: Action::Run,
            argv: Vec::new(),
            terminal: false,
            save_on_exit: false,
            origin,
            problem: Some(why),
            note: None,
        }
    }

    pub fn usable(&self) -> bool {
        self.problem.is_none()
    }
}

/// One file as read from a tile directory.
#[derive(Debug, Clone)]
pub struct SourceFile {
    pub name: String,
    pub entry: Result<Entry, String>,
}

/// The files of one directory plus anything worth telling the user about
/// how it was read.
#[derive(Debug, Default)]
pub struct SourceDir {
    pub files: Vec<SourceFile>,
    pub notes: Vec<String>,
}

/// Read `*.desktop` files from `dir`, bounded in every direction: a missing
/// directory is empty, a symlink or regular file in its place is refused,
/// at most `MAX_DIR_ENTRIES` entries are looked at, at most `cap` files are
/// read, and only regular files no larger than `MAX_FILE_BYTES` are opened.
/// `label` is how the notes name the directory.
pub fn read_dir_bounded(dir: &Path, cap: usize, label: &str) -> SourceDir {
    let mut out = SourceDir::default();
    match fs::symlink_metadata(dir) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return out,
        Err(e) => {
            out.notes.push(format!("{label} cannot be read: {e}"));
            return out;
        }
        Ok(m) if !m.file_type().is_dir() => {
            out.notes.push(format!("{label} is not a directory, so it was ignored"));
            return out;
        }
        Ok(_) => {}
    }
    let iter = match fs::read_dir(dir) {
        Ok(i) => i,
        Err(e) => {
            out.notes.push(format!("{label} cannot be read: {e}"));
            return out;
        }
    };
    let mut names = Vec::new();
    let mut scanned = 0usize;
    for entry in iter {
        scanned += 1;
        if scanned > MAX_DIR_ENTRIES {
            out.notes.push(format!(
                "{label} holds more than {MAX_DIR_ENTRIES} entries; only the first {MAX_DIR_ENTRIES} were looked at"
            ));
            break;
        }
        let Ok(entry) = entry else { continue };
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        if name.ends_with(".desktop") && !name.starts_with('.') {
            names.push(name);
        }
    }
    names.sort();
    if names.len() > cap {
        out.notes.push(format!(
            "{label} has {} tile files; only the first {cap} are shown",
            names.len()
        ));
        names.truncate(cap);
    }
    for name in names {
        let entry = read_file_bounded(&dir.join(&name)).and_then(|t| desktop::parse(&t));
        out.files.push(SourceFile { name, entry });
    }
    out
}

fn read_file_bounded(path: &Path) -> Result<String, String> {
    // symlink_metadata, not metadata: a FIFO or a symlink to /dev/zero named
    // x.desktop must be refused before anything opens it.
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.file_type().is_file() {
        return Err("not a regular file".to_string());
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(format!("larger than {} KiB", MAX_FILE_BYTES / 1024));
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .and_then(|f| f.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes))
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("larger than {} KiB", MAX_FILE_BYTES / 1024));
    }
    String::from_utf8(bytes).map_err(|_| "not UTF-8 text".to_string())
}

fn flag(entry: &Entry, key: &str) -> bool {
    entry.get(key) == Some("true")
}

fn non_empty(entry: &Entry, key: &str) -> Option<String> {
    entry
        .get(key)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(|v| v.chars().take(MAX_TEXT_CHARS).collect())
}

/// Build a tile from one parsed file. `user` restricts the action to `run`.
fn tile_from(file: &str, entry: &Entry, origin: Origin) -> Tile {
    let user = origin == Origin::User;
    let Some(name) = non_empty(entry, "Name") else {
        return Tile::broken(file, origin, format!("{file} has no Name"));
    };
    let action = match Action::parse(entry.get("X-DBRRG-Action")) {
        Ok(a) => a,
        Err(e) => return Tile::broken(file, origin, format!("{file}: {e}")),
    };
    if user && action != Action::Run {
        let named = entry.get("X-DBRRG-Action").unwrap_or_default();
        return Tile::broken(
            file,
            origin,
            format!("{file}: a tile of your own may only use the run action, not '{named}'"),
        );
    }
    let mut argv = Vec::new();
    if action == Action::Run {
        match entry.get("Exec").map(desktop::split_exec) {
            Some(Ok(a)) => argv = a,
            Some(Err(e)) => return Tile::broken(file, origin, format!("{file}: {e}")),
            None => return Tile::broken(file, origin, format!("{file} has no Exec")),
        }
    }
    Tile {
        file: file.to_string(),
        name,
        comment: non_empty(entry, "Comment"),
        icon: non_empty(entry, "Icon"),
        action,
        argv,
        terminal: action == Action::Run && flag(entry, "Terminal"),
        // Ignored unless the action is run: the other actions have no
        // program, and save-home would save twice.
        save_on_exit: action == Action::Run && flag(entry, "X-DBRRG-Save-On-Exit"),
        origin,
        problem: None,
        note: None,
    }
}

/// Keys only a shipped file may set. A user file that rewords a shipped tile
/// and sets one of them still rewords it; the key is named on the tile.
const SHIPPED_ONLY_KEYS: [&str; 4] = ["Exec", "Terminal", "X-DBRRG-Action", "X-DBRRG-Save-On-Exit"];

fn reword(mut tile: Tile, user: &SourceFile) -> Tile {
    match &user.entry {
        Err(e) => {
            tile.note = Some(format!(
                "your {} could not be read ({e}); the shipped text is shown",
                user.name
            ));
            tile
        }
        Ok(entry) => {
            if let Some(name) = non_empty(entry, "Name") {
                tile.name = name;
            }
            if let Some(comment) = non_empty(entry, "Comment") {
                tile.comment = Some(comment);
            }
            if let Some(icon) = non_empty(entry, "Icon") {
                tile.icon = Some(icon);
            }
            let ignored: Vec<String> = SHIPPED_ONLY_KEYS
                .iter()
                .filter(|k| entry.get(k).is_some())
                .map(|k| k.to_string())
                .collect();
            tile.origin = Origin::Reworded { ignored };
            tile
        }
    }
}

/// Merge the two directories. Both are sorted together by file name; a user
/// file whose name equals a shipped one (case sensitive) rewords it.
pub fn merge(shipped: &[SourceFile], user: &[SourceFile]) -> Vec<Tile> {
    let mut tiles: Vec<Tile> = shipped
        .iter()
        .map(|f| match &f.entry {
            Ok(e) => tile_from(&f.name, e, Origin::Shipped),
            Err(e) => Tile::broken(&f.name, Origin::Shipped, format!("{}: {e}", f.name)),
        })
        .collect();
    for u in user {
        if let Some(pos) = tiles
            .iter()
            .position(|t| t.origin == Origin::Shipped && t.file == u.name)
        {
            let shipped = tiles[pos].clone();
            tiles[pos] = reword(shipped, u);
            continue;
        }
        tiles.push(match &u.entry {
            Ok(e) => tile_from(&u.name, e, Origin::User),
            Err(e) => Tile::broken(&u.name, Origin::User, format!("{}: {e}", u.name)),
        });
    }
    tiles.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| (a.origin == Origin::User).cmp(&(b.origin == Origin::User)))
    });
    tiles
}

/// How many tiles that come from shipped files can be used.
fn usable_shipped(tiles: &[Tile]) -> usize {
    tiles.iter().filter(|t| t.origin != Origin::User && t.usable()).count()
}

/// The tiles the grid shows, and a banner when something was left out.
#[derive(Debug)]
pub struct Grid {
    pub tiles: Vec<Tile>,
    pub banner: Vec<String>,
}

/// The fallback rule: if the user's files leave fewer usable shipped tiles
/// than the shipped set alone has, show the shipped set alone and say why.
pub fn choose(shipped_only: Vec<Tile>, merged: Vec<Tile>, mut banner: Vec<String>) -> Grid {
    if usable_shipped(&merged) < usable_shipped(&shipped_only) {
        banner.push("Your own tiles were left out because they disabled a shipped tile.".to_string());
        return Grid {
            tiles: shipped_only,
            banner,
        };
    }
    Grid { tiles: merged, banner }
}

/// Read both directories and build the grid. A panic while handling the
/// user's files falls back to the shipped set: a restored home is restored
/// again on every boot, so it must not be able to stop the grid appearing.
pub fn load(shipped_dir: &Path, user_dir: &Path) -> Grid {
    let shipped = read_dir_bounded(shipped_dir, MAX_SHIPPED_FILES, "the shipped tile directory");
    let shipped_only = merge(&shipped.files, &[]);
    let mut banner = shipped.notes.clone();
    let user = std::panic::catch_unwind(|| {
        let user = read_dir_bounded(user_dir, MAX_USER_FILES, "~/.config/dbrrg/menu");
        let merged = merge(&shipped.files, &user.files);
        (merged, user.notes)
    });
    match user {
        Ok((merged, notes)) => {
            banner.extend(notes);
            choose(shipped_only, merged, banner)
        }
        Err(_) => {
            banner.push("Your own tiles could not be read; only the shipped tiles are shown.".to_string());
            Grid {
                tiles: shipped_only,
                banner,
            }
        }
    }
}

/// Find `program` the way a shell would: as given when it contains a slash,
/// else in each directory of `path`. Only executable regular files count.
pub fn find_program(program: &str, path: &OsStr) -> Option<PathBuf> {
    let executable = |p: &Path| fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0);
    if program.contains('/') {
        let p = PathBuf::from(program);
        return executable(&p).then_some(p);
    }
    std::env::split_paths(path)
        .map(|d| d.join(program))
        .find(|p| executable(p))
}

/// Disable run tiles whose program is not installed. A terminal tile also
/// needs `foot`.
pub fn mark_missing_programs(tiles: &mut [Tile], path: &OsStr) {
    for t in tiles.iter_mut().filter(|t| t.usable() && t.action == Action::Run) {
        let mut needed: Vec<&str> = Vec::new();
        if t.terminal {
            needed.push("foot");
        }
        needed.push(&t.argv[0]);
        if let Some(missing) = needed.into_iter().find(|p| find_program(p, path).is_none()) {
            t.problem = Some(format!("{missing} is not installed"));
        }
    }
}

/// The argv a run tile is started with: `Terminal=true` wraps it in foot.
pub fn command_line(tile: &Tile) -> Vec<String> {
    let mut argv = Vec::new();
    if tile.terminal {
        argv.push("foot".to_string());
        argv.push("--".to_string());
    }
    argv.extend(tile.argv.iter().cloned());
    argv
}
```

- [ ] **Step 4: Run the tests**

Same command. Expected: `tiles::` 17 passed, whole suite green. Then clippy and fmt
as in Task 1 Step 6, both silent.

- [ ] **Step 5: Commit**

```bash
git add src/dbrrg-menu/src/tiles.rs src/dbrrg-menu/src/lib.rs
git commit -m "feat(menu): read tiles from both directories under the reword and cap rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Icons

**Files:**
- Create: `src/dbrrg-menu/src/icons.rs`, `src/dbrrg-menu/icons/hard-drive-download.svg`,
  `src/dbrrg-menu/icons/usb.svg`, `src/dbrrg-menu/icons/log-out.svg`,
  `src/dbrrg-menu/icons/LICENSE`
- Modify: `src/dbrrg-menu/src/lib.rs` (add `pub mod icons;`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct IconRoots { dbrrg, hicolor, adwaita: PathBuf }`,
  `IconRoots::system()`; `resolve(icon: &str, roots: &IconRoots) ->
  Option<PathBuf>` (`None` = letter fallback);
  `is_symbolic(path: &Path, roots: &IconRoots) -> bool`;
  `recolour_svg(source: &str, symbolic: bool, rgb: [u8; 3]) -> String`;
  `render(path: &Path, side: u32, rgb: [u8; 3], symbolic: bool) ->
  Result<egui::ColorImage, String>`; constants `MAX_ICON_BYTES = 1 MiB`,
  `MAX_PNG_SIDE = 4096`.

- [ ] **Step 1: Fetch the three Lucide icons and the licence**

```bash
W=/scratch/oetiker/claude-tmp/dbrrg-test/lucide
mkdir -p "$W" && cd "$W"
curl -fsSL -o l.tgz https://registry.npmjs.org/lucide-static/-/lucide-static-1.49.0.tgz
tar xzf l.tgz
sha256sum package/icons/hard-drive-download.svg package/icons/usb.svg \
          package/icons/log-out.svg package/LICENSE
```

Expected, exactly:

```
cb8b194e88469d3ec1cce0a00b7185cf231f3856d7cd5730fe21ffe3dc2528c8  package/icons/hard-drive-download.svg
8c8f8a53953f44687f8e3c70891a8bab49c4316572da3e8e91848c43d8a03a46  package/icons/usb.svg
61b2e34a195833ffe9b893e7562eb8dec14c58d30ef1574f5377e907ec7949cc  package/icons/log-out.svg
b495047bd93a9b06913511076f504daba17d5bbeb3e0650f3bb53a4220329c57  package/LICENSE
```

Then copy them unchanged:

```bash
D=/home/oetiker/checkouts/dbrrg/src/dbrrg-menu/icons
mkdir -p "$D"
cp package/icons/hard-drive-download.svg package/icons/usb.svg package/icons/log-out.svg package/LICENSE "$D/"
```

- [ ] **Step 2: Write the failing tests**

Add `pub mod icons;` to `lib.rs`; create `src/dbrrg-menu/src/icons.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn roots(tag: &str) -> IconRoots {
        let base = std::env::temp_dir().join(format!("dbrrg-menu-icons-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let r = IconRoots {
            dbrrg: base.join("dbrrg"),
            hicolor: base.join("hicolor"),
            adwaita: base.join("Adwaita"),
        };
        for d in [
            "dbrrg",
            "hicolor/scalable/apps",
            "hicolor/48x48/apps",
            "hicolor/256x256/apps",
            "hicolor/1024x1024@2/apps",
            "Adwaita/symbolic/actions",
            "Adwaita/scalable/devices",
        ] {
            fs::create_dir_all(base.join(d)).unwrap();
        }
        r
    }

    fn touch(p: &Path) {
        fs::write(p, "x").unwrap();
    }

    #[test]
    fn resolution_order() {
        let r = roots("order");
        touch(&r.dbrrg.join("usb.svg"));
        touch(&r.hicolor.join("scalable/apps/usb.svg"));
        assert_eq!(
            resolve("usb", &r),
            Some(r.dbrrg.join("usb.svg")),
            "shipped Lucide first"
        );

        touch(&r.hicolor.join("scalable/apps/foot.svg"));
        touch(&r.hicolor.join("48x48/apps/foot.png"));
        assert_eq!(
            resolve("foot", &r),
            Some(r.hicolor.join("scalable/apps/foot.svg")),
            "scalable before pixels"
        );

        touch(&r.hicolor.join("48x48/apps/ox.png"));
        touch(&r.hicolor.join("256x256/apps/ox.png"));
        touch(&r.hicolor.join("1024x1024@2/apps/ox.png"));
        assert_eq!(
            resolve("ox", &r),
            Some(r.hicolor.join("256x256/apps/ox.png")),
            "largest NxN, @2 ignored"
        );

        touch(&r.adwaita.join("symbolic/actions/edit-symbolic.svg"));
        assert_eq!(
            resolve("edit-symbolic", &r),
            Some(r.adwaita.join("symbolic/actions/edit-symbolic.svg"))
        );
        touch(&r.adwaita.join("scalable/devices/drive-harddisk.svg"));
        assert_eq!(
            resolve("drive-harddisk", &r),
            Some(r.adwaita.join("scalable/devices/drive-harddisk.svg"))
        );
    }

    #[test]
    fn absolute_and_fallback() {
        let r = roots("abs");
        let p = r.dbrrg.join("logo.png");
        touch(&p);
        assert_eq!(resolve(p.to_str().unwrap(), &r), Some(p));
        assert_eq!(resolve("/dev/zero", &r), None, "a device is not an icon");
        assert_eq!(resolve("/nonexistent/x.png", &r), None);
        assert_eq!(resolve("no-such-icon", &r), None);
        assert_eq!(resolve("../../etc/passwd", &r), None);
        assert_eq!(resolve("", &r), None);
    }

    #[test]
    fn recolours_lucide_and_symbolic_only() {
        let rgb = [0x12, 0x34, 0x56];
        assert_eq!(
            recolour_svg(r#"stroke="currentColor""#, false, rgb),
            r##"stroke="#123456""##
        );
        assert_eq!(recolour_svg(r##"fill="#2e3436""##, true, rgb), r##"fill="#123456""##);
        assert_eq!(recolour_svg(r##"fill="#2e3436""##, false, rgb), r##"fill="#2e3436""##);
    }

    #[test]
    fn renders_lucide_svg_in_the_given_colour() {
        let r = roots("render");
        let p = r.dbrrg.join("power.svg");
        fs::write(
            &p,
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2v10"/></svg>"#,
        )
        .unwrap();
        assert!(is_symbolic(&p, &r));
        let img = render(&p, 48, [255, 0, 0], true).unwrap();
        assert_eq!(img.size, [48, 48]);
        assert!(
            img.pixels.iter().any(|c| c.r() > 200 && c.g() == 0 && c.a() > 200),
            "red stroke drawn"
        );
    }

    #[test]
    fn refuses_png_bombs_before_decoding() {
        let r = roots("bomb");
        let p = r.dbrrg.join("big.png");
        let mut b = b"\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".to_vec();
        b.extend_from_slice(&100_000u32.to_be_bytes());
        b.extend_from_slice(&100_000u32.to_be_bytes());
        b.extend_from_slice(&[8, 6, 0, 0, 0]);
        fs::write(&p, b).unwrap();
        assert_eq!(
            render(&p, 64, [0; 3], false).unwrap_err(),
            "PNG is 100000x100000, larger than 4096x4096"
        );
        assert!(render(Path::new("/dev/zero"), 64, [0; 3], false).is_err());
    }
}
```

- [ ] **Step 3: Run them to see them fail**

`… cargo test --locked -j 4 icons::` (command as in Task 2 Step 2).
Expected: compile errors, `cannot find function \`resolve\``.

- [ ] **Step 4: Implement**

Insert above `#[cfg(test)]`:

```rust
//! Icon lookup and rasterisation. Icons are drawn once at startup into
//! pixmaps; nothing here runs per frame.

use resvg::tiny_skia::{FilterQuality, Pixmap, PixmapPaint, Transform};
use resvg::usvg;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

/// Icon files larger than this are not read.
pub const MAX_ICON_BYTES: u64 = 1024 * 1024;
/// A PNG declaring a larger side is refused before it is decoded, so a small
/// file cannot ask for gigabytes.
pub const MAX_PNG_SIDE: u32 = 4096;

/// Where `Icon=` names are looked up.
#[derive(Debug, Clone)]
pub struct IconRoots {
    pub dbrrg: PathBuf,
    pub hicolor: PathBuf,
    pub adwaita: PathBuf,
}

impl IconRoots {
    pub fn system() -> IconRoots {
        IconRoots {
            dbrrg: PathBuf::from("/usr/share/dbrrg/icons"),
            hicolor: PathBuf::from("/usr/share/icons/hicolor"),
            adwaita: PathBuf::from("/usr/share/icons/Adwaita"),
        }
    }
}

fn is_file(p: &Path) -> bool {
    // metadata follows symlinks: icon themes are full of them. A device node
    // or FIFO is not a file and is refused here.
    fs::metadata(p).is_ok_and(|m| m.is_file())
}

fn sorted_subdirs(dir: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    dirs
}

/// `NxN` with equal sides, as hicolor names its pixel directories. `128x128@2`
/// and `scalable` are not pixel directories.
fn pixel_size(dir_name: &str) -> Option<u32> {
    let (w, h) = dir_name.split_once('x')?;
    let w: u32 = w.parse().ok()?;
    (h.parse::<u32>().ok()? == w).then_some(w)
}

/// Resolve an `Icon=` value, in the order the spec fixes. `None` means the
/// tile draws the first letter of its name instead.
pub fn resolve(icon: &str, roots: &IconRoots) -> Option<PathBuf> {
    if icon.is_empty() {
        return None;
    }
    if icon.starts_with('/') {
        let p = PathBuf::from(icon);
        return is_file(&p).then_some(p);
    }
    if icon.contains('/') || icon.starts_with('.') {
        return None;
    }
    let svg = format!("{icon}.svg");
    let png = format!("{icon}.png");
    let ours = roots.dbrrg.join(&svg);
    if is_file(&ours) {
        return Some(ours);
    }
    let scalable = roots.hicolor.join("scalable/apps").join(&svg);
    if is_file(&scalable) {
        return Some(scalable);
    }
    let mut sizes: Vec<(u32, PathBuf)> = fs::read_dir(&roots.hicolor)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let size = pixel_size(e.file_name().to_str()?)?;
            Some((size, e.path()))
        })
        .collect();
    sizes.sort_by_key(|s| std::cmp::Reverse(s.0));
    if let Some(p) = sizes
        .iter()
        .map(|(_, d)| d.join("apps").join(&png))
        .find(|p| is_file(p))
    {
        return Some(p);
    }
    for sub in ["symbolic", "scalable"] {
        if let Some(p) = sorted_subdirs(&roots.adwaita.join(sub))
            .into_iter()
            .map(|d| d.join(&svg))
            .find(|p| is_file(p))
        {
            return Some(p);
        }
    }
    None
}

fn read_bounded(path: &Path) -> Result<Vec<u8>, String> {
    let meta = fs::metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_file() {
        return Err("not a regular file".to_string());
    }
    if meta.len() > MAX_ICON_BYTES {
        return Err("larger than 1 MiB".to_string());
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .and_then(|f| f.take(MAX_ICON_BYTES + 1).read_to_end(&mut bytes))
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_ICON_BYTES {
        return Err("larger than 1 MiB".to_string());
    }
    Ok(bytes)
}

/// Lucide draws with `stroke="currentColor"`, which resvg resolves to black,
/// and Adwaita's symbolic icons hardcode `#2e3436` for GTK to recolour. Both
/// are replaced with `rgb` in the source before parsing. A full-colour SVG is
/// left alone unless it says `currentColor`.
pub fn recolour_svg(source: &str, symbolic: bool, rgb: [u8; 3]) -> String {
    let hex = format!("#{:02x}{:02x}{:02x}", rgb[0], rgb[1], rgb[2]);
    let s = source.replace("currentColor", &hex);
    if symbolic { s.replace("#2e3436", &hex) } else { s }
}

fn png_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 24 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" || &bytes[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    Some((w, h))
}

/// Whether an icon is a one-colour glyph to be drawn in the tile's text
/// colour: the shipped Lucide set and Adwaita's `-symbolic` icons.
pub fn is_symbolic(path: &Path, roots: &IconRoots) -> bool {
    path.starts_with(&roots.dbrrg)
        || path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with("-symbolic.svg"))
}

/// Rasterise the icon at `path` into a `side` x `side` premultiplied RGBA
/// image, keeping its aspect ratio and centring it.
pub fn render(path: &Path, side: u32, rgb: [u8; 3], symbolic: bool) -> Result<egui::ColorImage, String> {
    let bytes = read_bounded(path)?;
    let mut out = Pixmap::new(side, side).ok_or("bad icon size")?;
    let is_svg = path.extension().is_some_and(|e| e == "svg");
    if is_svg {
        let text = String::from_utf8(bytes).map_err(|_| "SVG is not UTF-8".to_string())?;
        let text = recolour_svg(&text, symbolic, rgb);
        let tree = usvg::Tree::from_str(&text, &usvg::Options::default()).map_err(|e| e.to_string())?;
        let size = tree.size();
        let scale = side as f32 / size.width().max(size.height());
        let dx = (side as f32 - size.width() * scale) / 2.0;
        let dy = (side as f32 - size.height() * scale) / 2.0;
        resvg::render(
            &tree,
            Transform::from_scale(scale, scale).post_translate(dx, dy),
            &mut out.as_mut(),
        );
    } else {
        let (w, h) = png_dimensions(&bytes).ok_or("not a PNG file")?;
        if w == 0 || h == 0 || w > MAX_PNG_SIDE || h > MAX_PNG_SIDE {
            return Err(format!("PNG is {w}x{h}, larger than {MAX_PNG_SIDE}x{MAX_PNG_SIDE}"));
        }
        let src = Pixmap::decode_png(&bytes).map_err(|e| e.to_string())?;
        let scale = side as f32 / w.max(h) as f32;
        let dx = (side as f32 - w as f32 * scale) / 2.0;
        let dy = (side as f32 - h as f32 * scale) / 2.0;
        let paint = PixmapPaint {
            quality: FilterQuality::Bicubic,
            ..Default::default()
        };
        out.draw_pixmap(
            0,
            0,
            src.as_ref(),
            &paint,
            Transform::from_scale(scale, scale).post_translate(dx, dy),
            None,
        );
    }
    Ok(egui::ColorImage::from_rgba_premultiplied(
        [side as usize, side as usize],
        out.data(),
    ))
}
```

- [ ] **Step 5: Run the tests**

Expected: `test result: ok. 5 passed` for `icons::`, the whole suite green,
clippy and fmt silent. The PNG bomb test must finish in milliseconds; if
it is killed by the memory cap, the dimension guard is broken.

- [ ] **Step 6: Commit**

```bash
git add src/dbrrg-menu/src/icons.rs src/dbrrg-menu/src/lib.rs src/dbrrg-menu/icons
git commit -m "feat(menu): resolve and rasterise tile icons, with the Lucide action set

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: CPU rasteriser and damage tracking

**Files:**
- Create: `src/dbrrg-menu/src/raster.rs`, `src/dbrrg-menu/src/damage.rs`
- Modify: `src/dbrrg-menu/src/lib.rs` (add `pub mod damage;` and `pub mod raster;`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `raster::IRect { x0, y0, x1, y1: i32 }` with `EMPTY`, `is_empty`,
    `intersect`, `union`, `from_points(egui::Rect, ppp: f32)`.
  - `raster::Textures` with `apply_set(&TexturesDelta)` (before a frame)
    and `apply_free(&TexturesDelta)` (after).
  - `raster::Background::{Solid(Color32), Frozen(Vec<u32>)}`.
  - `raster::Canvas { width, height: usize, pixels: Vec<u32>, background }`
    with `new(w, h, Color32)`, `bounds()`, `restore_background(IRect)`,
    `freeze_dimmed(keep: u32)`, `draw(&[ClippedPrimitive], &Textures,
    ppp: f32, damage: IRect)`. Pixels are `0x00RRGGBB`, softbuffer's format.
  - `damage::Tracker` with `reset()` and `damage(&[ClippedPrimitive],
    ppp) -> Option<IRect>` (`None` = nothing changed, skip raster and
    present).

**Why:** the spec's whole "Rendering without a GPU" section lands here. The
solid fast path keys on `egui::epaint::WHITE_UV`, which is `(0, 0)` in
epaint 0.36, never a literal `(0.5, 0.5)`. The top-left fill rule keeps a
translucent quad from being blended twice along its diagonal.

- [ ] **Step 1: Write the failing tests**

Add both modules to `lib.rs`. `src/dbrrg-menu/src/raster.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use egui::epaint::Mesh;
    use egui::{Rect, pos2};

    fn prim(mesh: Mesh, clip: Rect) -> ClippedPrimitive {
        ClippedPrimitive {
            clip_rect: clip,
            primitive: Primitive::Mesh(mesh),
        }
    }

    fn rect_mesh(r: Rect, c: Color32) -> Mesh {
        let mut m = Mesh::default();
        m.add_colored_rect(r, c);
        m
    }

    const FULL: Rect = Rect {
        min: pos2(0.0, 0.0),
        max: pos2(100.0, 100.0),
    };

    #[test]
    fn opaque_rect_fills_exactly() {
        let mut c = Canvas::new(10, 10, Color32::BLACK);
        let m = rect_mesh(
            Rect::from_min_max(pos2(2.0, 3.0), pos2(5.0, 6.0)),
            Color32::from_rgb(255, 0, 0),
        );
        c.draw(&[prim(m, FULL)], &Textures::default(), 1.0, c.bounds());
        let red = (0..10)
            .flat_map(|y| (0..10).map(move |x| (x, y)))
            .filter(|&(x, y)| c.pixels[y * 10 + x] == 0xff0000)
            .count();
        assert_eq!(red, 9);
        assert_eq!(c.pixels[3 * 10 + 2], 0xff0000);
        assert_eq!(c.pixels[6 * 10 + 5], 0);
    }

    #[test]
    fn translucent_quad_is_not_blended_twice_on_its_diagonal() {
        let mut c = Canvas::new(8, 8, Color32::BLACK);
        let half = Color32::from_rgba_premultiplied(100, 100, 100, 128);
        let m = rect_mesh(Rect::from_min_max(pos2(0.0, 0.0), pos2(8.0, 8.0)), half);
        c.draw(&[prim(m, FULL)], &Textures::default(), 1.0, c.bounds());
        assert!(c.pixels.iter().all(|&p| p == 0x646464), "{:x?}", c.pixels);
    }

    #[test]
    fn clip_and_damage_are_respected() {
        let mut c = Canvas::new(10, 10, Color32::BLACK);
        let m = rect_mesh(Rect::from_min_max(pos2(0.0, 0.0), pos2(10.0, 10.0)), Color32::WHITE);
        let clip = Rect::from_min_max(pos2(0.0, 0.0), pos2(5.0, 10.0));
        c.draw(
            &[prim(m, clip)],
            &Textures::default(),
            1.0,
            IRect {
                x0: 0,
                y0: 0,
                x1: 10,
                y1: 2,
            },
        );
        assert_eq!(c.pixels[4], 0xffffff);
        assert_eq!(c.pixels[5], 0, "outside clip");
        assert_eq!(c.pixels[2 * 10], 0, "outside damage");
    }

    #[test]
    fn pixels_per_point_scales_geometry() {
        let mut c = Canvas::new(10, 10, Color32::BLACK);
        let m = rect_mesh(Rect::from_min_max(pos2(0.0, 0.0), pos2(2.0, 2.0)), Color32::WHITE);
        c.draw(&[prim(m, FULL)], &Textures::default(), 2.0, c.bounds());
        assert_eq!(c.pixels.iter().filter(|&&p| p == 0xffffff).count(), 16);
    }

    #[test]
    fn texture_is_sampled_and_tinted() {
        let mut tex = Textures::default();
        let id = TextureId::Managed(7);
        tex.map.insert(
            id,
            Texture {
                width: 1,
                height: 1,
                pixels: vec![Color32::from_rgb(255, 255, 255)],
            },
        );
        let mut m = Mesh::with_texture(id);
        m.add_rect_with_uv(
            Rect::from_min_max(pos2(0.0, 0.0), pos2(4.0, 4.0)),
            Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)),
            Color32::from_rgb(0, 128, 0),
        );
        let mut c = Canvas::new(4, 4, Color32::BLACK);
        c.draw(&[prim(m, FULL)], &tex, 1.0, c.bounds());
        assert!(c.pixels.iter().all(|&p| p == 0x008000));
    }

    #[test]
    fn frozen_background_is_dimmed_once() {
        let mut c = Canvas::new(2, 1, Color32::from_rgb(200, 100, 50));
        c.freeze_dimmed(128);
        c.pixels.fill(0);
        c.restore_background(c.bounds());
        assert_eq!(c.pixels[0], pack([200 * 128 / 255, 100 * 128 / 255, 50 * 128 / 255]));
    }
}
```

`src/dbrrg-menu/src/damage.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use egui::epaint::Mesh;
    use egui::{Color32, Rect, pos2};

    fn quad(x: f32, c: Color32) -> ClippedPrimitive {
        let mut m = Mesh::default();
        m.add_colored_rect(Rect::from_min_max(pos2(x, 0.0), pos2(x + 10.0, 10.0)), c);
        ClippedPrimitive {
            clip_rect: Rect::from_min_max(pos2(0.0, 0.0), pos2(100.0, 100.0)),
            primitive: Primitive::Mesh(m),
        }
    }

    #[test]
    fn identical_frame_needs_nothing() {
        let mut t = Tracker::default();
        let f = vec![quad(0.0, Color32::RED), quad(20.0, Color32::BLUE)];
        assert!(t.damage(&f, 1.0).is_some(), "first frame draws");
        assert_eq!(t.damage(&f, 1.0), None, "a mouse move over a static grid draws nothing");
    }

    #[test]
    fn damage_covers_old_and_new_place_of_what_changed() {
        let mut t = Tracker::default();
        t.damage(&[quad(0.0, Color32::RED), quad(50.0, Color32::BLUE)], 1.0);
        let d = t
            .damage(&[quad(0.0, Color32::RED), quad(60.0, Color32::BLUE)], 1.0)
            .unwrap();
        assert_eq!(
            d,
            IRect {
                x0: 50,
                y0: 0,
                x1: 70,
                y1: 10
            }
        );
    }

    #[test]
    fn reorder_redraws_both() {
        let mut t = Tracker::default();
        let a = quad(0.0, Color32::RED);
        let b = quad(5.0, Color32::BLUE);
        t.damage(&[a.clone(), b.clone()], 1.0);
        let d = t.damage(&[b, a], 1.0).unwrap();
        assert_eq!(
            d,
            IRect {
                x0: 0,
                y0: 0,
                x1: 15,
                y1: 10
            }
        );
    }

    #[test]
    fn reset_forces_full_damage() {
        let mut t = Tracker::default();
        let f = vec![quad(0.0, Color32::RED)];
        t.damage(&f, 1.0);
        t.reset();
        assert_eq!(
            t.damage(&f, 1.0),
            Some(IRect {
                x0: 0,
                y0: 0,
                x1: 10,
                y1: 10
            })
        );
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run the whole suite (command as in Task 2 Step 2, without a filter). Expected:
compile errors, `cannot find type \`Canvas\``, `cannot find type
\`Tracker\``.

- [ ] **Step 3: Implement the rasteriser**

Insert above `#[cfg(test)]` in `raster.rs`:

```rust
//! A CPU rasteriser for egui's tessellated meshes, writing into a 0RGB
//! canvas that is copied to a softbuffer surface. No GPU, no GL, no Vulkan.
//!
//! It assumes feathering is off (see app.rs): every edge is hard, so a
//! pixel is either inside a triangle or not, and solid fills can take the
//! fast paths below.

use egui::epaint::{ClippedPrimitive, Primitive, Vertex, WHITE_UV};
use egui::{Color32, TextureId, TexturesDelta};
use std::collections::HashMap;

/// An integer pixel rectangle, `x0..x1` by `y0..y1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IRect {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
}

impl IRect {
    pub const EMPTY: IRect = IRect {
        x0: 0,
        y0: 0,
        x1: 0,
        y1: 0,
    };

    pub fn is_empty(&self) -> bool {
        self.x1 <= self.x0 || self.y1 <= self.y0
    }
    pub fn intersect(&self, o: &IRect) -> IRect {
        IRect {
            x0: self.x0.max(o.x0),
            y0: self.y0.max(o.y0),
            x1: self.x1.min(o.x1),
            y1: self.y1.min(o.y1),
        }
    }
    pub fn union(&self, o: &IRect) -> IRect {
        if self.is_empty() {
            return *o;
        }
        if o.is_empty() {
            return *self;
        }
        IRect {
            x0: self.x0.min(o.x0),
            y0: self.y0.min(o.y0),
            x1: self.x1.max(o.x1),
            y1: self.y1.max(o.y1),
        }
    }
    /// The pixels an egui rect in points covers, rounded outwards.
    pub fn from_points(r: egui::Rect, ppp: f32) -> IRect {
        IRect {
            x0: (r.min.x * ppp).floor() as i32,
            y0: (r.min.y * ppp).floor() as i32,
            x1: (r.max.x * ppp).ceil() as i32,
            y1: (r.max.y * ppp).ceil() as i32,
        }
    }
}

struct Texture {
    width: usize,
    height: usize,
    pixels: Vec<Color32>,
}

/// The textures egui has asked for, kept in sync from `TexturesDelta`.
#[derive(Default)]
pub struct Textures {
    map: HashMap<TextureId, Texture>,
}

impl Textures {
    /// Apply `delta.set` before rasterising a frame.
    pub fn apply_set(&mut self, delta: &TexturesDelta) {
        // A texture's deltas arrive in order: a full image, then patches.
        for (id, deltas) in &delta.set {
            for d in deltas {
                let egui::ImageData::Color(img) = &d.image;
                match d.pos {
                    None => {
                        let t = Texture {
                            width: img.size[0],
                            height: img.size[1],
                            pixels: img.pixels.clone(),
                        };
                        self.map.insert(*id, t);
                    }
                    Some([px, py]) => {
                        let Some(t) = self.map.get_mut(id) else { continue };
                        for row in 0..img.size[1] {
                            let dst = (py + row) * t.width + px;
                            let src = row * img.size[0];
                            t.pixels[dst..dst + img.size[0]].copy_from_slice(&img.pixels[src..src + img.size[0]]);
                        }
                    }
                }
            }
        }
    }

    /// Apply `delta.free` after the frame, so a skipped raster never drops an
    /// update.
    pub fn apply_free(&mut self, delta: &TexturesDelta) {
        for id in &delta.free {
            self.map.remove(id);
        }
    }
}

/// What lies under egui: a solid colour, or a frozen, dimmed copy of the grid
/// while the save dialog is open.
pub enum Background {
    Solid(Color32),
    Frozen(Vec<u32>),
}

pub struct Canvas {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u32>,
    pub background: Background,
}

fn pack(c: [u32; 3]) -> u32 {
    (c[0] << 16) | (c[1] << 8) | c[2]
}

fn unpack(p: u32) -> [u32; 3] {
    [(p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff]
}

/// Premultiplied `src` over opaque `dst`.
fn blend(dst: u32, src: [u32; 4]) -> u32 {
    if src[3] == 255 {
        return pack([src[0], src[1], src[2]]);
    }
    let d = unpack(dst);
    let inv = 255 - src[3];
    pack([
        (src[0] + (d[0] * inv + 127) / 255).min(255),
        (src[1] + (d[1] * inv + 127) / 255).min(255),
        (src[2] + (d[2] * inv + 127) / 255).min(255),
    ])
}

fn rgba(c: Color32) -> [u32; 4] {
    [c.r() as u32, c.g() as u32, c.b() as u32, c.a() as u32]
}

fn is_white_uv(v: &Vertex) -> bool {
    (v.uv.x - WHITE_UV.x).abs() < 1e-3 && (v.uv.y - WHITE_UV.y).abs() < 1e-3
}

impl Canvas {
    pub fn new(width: usize, height: usize, background: Color32) -> Canvas {
        let mut c = Canvas {
            width,
            height,
            pixels: vec![0; width * height],
            background: Background::Solid(background),
        };
        c.restore_background(c.bounds());
        c
    }

    pub fn bounds(&self) -> IRect {
        IRect {
            x0: 0,
            y0: 0,
            x1: self.width as i32,
            y1: self.height as i32,
        }
    }

    /// Copy what lies under egui back into `rect`.
    pub fn restore_background(&mut self, rect: IRect) {
        let r = rect.intersect(&self.bounds());
        if r.is_empty() {
            return;
        }
        for y in r.y0 as usize..r.y1 as usize {
            let row = y * self.width;
            let span = row + r.x0 as usize..row + r.x1 as usize;
            match &self.background {
                Background::Solid(c) => {
                    let p = pack([c.r() as u32, c.g() as u32, c.b() as u32]);
                    self.pixels[span].fill(p);
                }
                Background::Frozen(f) => self.pixels[span.clone()].copy_from_slice(&f[span]),
            }
        }
    }

    /// Freeze the current picture, darkened, as the background. Done once
    /// when the dialog opens; blending a full-window scrim every frame while
    /// a tar runs is the most expensive thing this program could do.
    pub fn freeze_dimmed(&mut self, keep: u32) {
        let frozen = self
            .pixels
            .iter()
            .map(|&p| {
                let c = unpack(p);
                pack([c[0] * keep / 255, c[1] * keep / 255, c[2] * keep / 255])
            })
            .collect();
        self.background = Background::Frozen(frozen);
    }

    /// Rasterise `prims` into the canvas, touching only pixels inside `damage`.
    pub fn draw(&mut self, prims: &[ClippedPrimitive], textures: &Textures, ppp: f32, damage: IRect) {
        let damage = damage.intersect(&self.bounds());
        for p in prims {
            let Primitive::Mesh(mesh) = &p.primitive else { continue };
            let clip = IRect::from_points(p.clip_rect, ppp).intersect(&damage);
            if clip.is_empty() {
                continue;
            }
            let tex = textures.map.get(&mesh.texture_id);
            if self.try_fill_rect(&mesh.vertices, &mesh.indices, ppp, clip) {
                continue;
            }
            for tri in mesh.indices.chunks_exact(3) {
                let v = [
                    &mesh.vertices[tri[0] as usize],
                    &mesh.vertices[tri[1] as usize],
                    &mesh.vertices[tri[2] as usize],
                ];
                self.triangle(v, tex, ppp, clip);
            }
        }
    }

    /// The fast path for opaque axis-aligned solid rectangles, which is most
    /// of the pixels on screen: fill rows instead of testing each pixel.
    fn try_fill_rect(&mut self, verts: &[Vertex], idx: &[u32], ppp: f32, clip: IRect) -> bool {
        if verts.len() != 4 || idx.len() != 6 {
            return false;
        }
        let c = verts[0].color;
        if c.a() != 255 || !verts.iter().all(|v| v.color == c && is_white_uv(v)) {
            return false;
        }
        let xs: Vec<f32> = verts.iter().map(|v| v.pos.x).collect();
        let ys: Vec<f32> = verts.iter().map(|v| v.pos.y).collect();
        let (minx, maxx) = (
            xs.iter().cloned().fold(f32::MAX, f32::min),
            xs.iter().cloned().fold(f32::MIN, f32::max),
        );
        let (miny, maxy) = (
            ys.iter().cloned().fold(f32::MAX, f32::min),
            ys.iter().cloned().fold(f32::MIN, f32::max),
        );
        let axis_aligned = verts
            .iter()
            .all(|v| (v.pos.x == minx || v.pos.x == maxx) && (v.pos.y == miny || v.pos.y == maxy));
        if !axis_aligned {
            return false;
        }
        let r = IRect {
            x0: (minx * ppp).round() as i32,
            y0: (miny * ppp).round() as i32,
            x1: (maxx * ppp).round() as i32,
            y1: (maxy * ppp).round() as i32,
        }
        .intersect(&clip);
        let p = pack([c.r() as u32, c.g() as u32, c.b() as u32]);
        if !r.is_empty() {
            for y in r.y0 as usize..r.y1 as usize {
                let row = y * self.width;
                self.pixels[row + r.x0 as usize..row + r.x1 as usize].fill(p);
            }
        }
        true
    }

    fn triangle(&mut self, v: [&Vertex; 3], tex: Option<&Texture>, ppp: f32, clip: IRect) {
        let p: [(f32, f32); 3] = [
            (v[0].pos.x * ppp, v[0].pos.y * ppp),
            (v[1].pos.x * ppp, v[1].pos.y * ppp),
            (v[2].pos.x * ppp, v[2].pos.y * ppp),
        ];
        let area = (p[1].0 - p[0].0) * (p[2].1 - p[0].1) - (p[1].1 - p[0].1) * (p[2].0 - p[0].0);
        if area.abs() < 1e-6 {
            return;
        }
        let bb = IRect {
            x0: p.iter().map(|q| q.0).fold(f32::MAX, f32::min).floor() as i32,
            y0: p.iter().map(|q| q.1).fold(f32::MAX, f32::min).floor() as i32,
            x1: p.iter().map(|q| q.0).fold(f32::MIN, f32::max).ceil() as i32,
            y1: p.iter().map(|q| q.1).fold(f32::MIN, f32::max).ceil() as i32,
        }
        .intersect(&clip);
        if bb.is_empty() {
            return;
        }
        let solid = v.iter().all(|x| is_white_uv(x)) && v[0].color == v[1].color && v[1].color == v[2].color;
        // Edge function of edge a->b at point (x, y), positive inside for a
        // triangle with positive area.
        let sign = area.signum();
        let edge =
            |a: (f32, f32), b: (f32, f32), x: f32, y: f32| sign * ((b.0 - a.0) * (y - a.1) - (b.1 - a.1) * (x - a.0));
        // Top-left rule: a pixel centre exactly on a shared edge belongs to
        // one of the two triangles only, so translucent fills are not blended
        // twice along the diagonal of a quad.
        let owns = |a: (f32, f32), b: (f32, f32)| {
            let (dx, dy) = (sign * (b.0 - a.0), sign * (b.1 - a.1));
            (dy == 0.0 && dx < 0.0) || dy > 0.0
        };
        let tl = [owns(p[1], p[2]), owns(p[2], p[0]), owns(p[0], p[1])];
        let inv_area = 1.0 / (area * sign);
        for y in bb.y0..bb.y1 {
            let cy = y as f32 + 0.5;
            let row = y as usize * self.width;
            for x in bb.x0..bb.x1 {
                let cx = x as f32 + 0.5;
                let w = [
                    edge(p[1], p[2], cx, cy),
                    edge(p[2], p[0], cx, cy),
                    edge(p[0], p[1], cx, cy),
                ];
                if (0..3).any(|i| w[i] < 0.0 || (w[i] == 0.0 && !tl[i])) {
                    continue;
                }
                let src = if solid {
                    rgba(v[0].color)
                } else {
                    let b = [w[0] * inv_area, w[1] * inv_area, w[2] * inv_area];
                    let col: [f32; 4] = std::array::from_fn(|k| {
                        b[0] * rgba(v[0].color)[k] as f32
                            + b[1] * rgba(v[1].color)[k] as f32
                            + b[2] * rgba(v[2].color)[k] as f32
                    });
                    let texel = match tex {
                        Some(t) => {
                            let u = b[0] * v[0].uv.x + b[1] * v[1].uv.x + b[2] * v[2].uv.x;
                            let vv = b[0] * v[0].uv.y + b[1] * v[1].uv.y + b[2] * v[2].uv.y;
                            let tx = ((u * t.width as f32) as usize).min(t.width - 1);
                            let ty = ((vv * t.height as f32) as usize).min(t.height - 1);
                            rgba(t.pixels[ty * t.width + tx])
                        }
                        None => [255; 4],
                    };
                    std::array::from_fn(|k| ((col[k] * texel[k] as f32 / 255.0).round() as u32).min(255))
                };
                if src[3] == 0 && src[0] == 0 && src[1] == 0 && src[2] == 0 {
                    continue;
                }
                let i = row + x as usize;
                self.pixels[i] = blend(self.pixels[i], src);
            }
        }
    }
}
```

- [ ] **Step 4: Implement damage tracking**

Insert above `#[cfg(test)]` in `damage.rs`:

```rust
//! Raster less. egui-winit asks for a repaint on every CursorMoved, so the
//! loop fingerprints each clipped primitive and rasters only where the set
//! changed. Moving the mouse across a static grid must not re-raster it.

use crate::raster::IRect;
use egui::epaint::{ClippedPrimitive, Primitive};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};

fn fingerprint(p: &ClippedPrimitive) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for f in [
        p.clip_rect.min.x,
        p.clip_rect.min.y,
        p.clip_rect.max.x,
        p.clip_rect.max.y,
    ] {
        f.to_bits().hash(&mut h);
    }
    if let Primitive::Mesh(m) = &p.primitive {
        m.texture_id.hash(&mut h);
        m.indices.hash(&mut h);
        for v in &m.vertices {
            v.pos.x.to_bits().hash(&mut h);
            v.pos.y.to_bits().hash(&mut h);
            v.uv.x.to_bits().hash(&mut h);
            v.uv.y.to_bits().hash(&mut h);
            v.color.to_array().hash(&mut h);
        }
    }
    h.finish()
}

fn bounds(p: &ClippedPrimitive, ppp: f32) -> IRect {
    let clip = IRect::from_points(p.clip_rect, ppp);
    let Primitive::Mesh(m) = &p.primitive else { return clip };
    let mut r = egui::Rect::NOTHING;
    for v in &m.vertices {
        r.extend_with(v.pos);
    }
    if !r.is_positive() {
        return IRect::EMPTY;
    }
    IRect::from_points(r, ppp).intersect(&clip)
}

/// The previous frame's primitives, as fingerprints and pixel bounds.
#[derive(Default)]
pub struct Tracker {
    prev: Vec<(u64, IRect)>,
}

impl Tracker {
    /// Forget the previous frame, so the next `damage` covers everything
    /// drawn. Used after a resize and when the background changes.
    pub fn reset(&mut self) {
        self.prev.clear();
    }

    /// The pixels that must be redrawn to turn the previous frame into this
    /// one, or `None` when the two are identical and neither raster nor
    /// present is needed.
    pub fn damage(&mut self, prims: &[ClippedPrimitive], ppp: f32) -> Option<IRect> {
        let now: Vec<(u64, IRect)> = prims.iter().map(|p| (fingerprint(p), bounds(p, ppp))).collect();
        if now.iter().map(|x| x.0).eq(self.prev.iter().map(|x| x.0)) {
            return None;
        }
        let mut counts: HashMap<u64, i32> = HashMap::new();
        for (f, _) in &self.prev {
            *counts.entry(*f).or_default() += 1;
        }
        for (f, _) in &now {
            *counts.entry(*f).or_default() -= 1;
        }
        let changed = |list: &[(u64, IRect)]| {
            list.iter()
                .filter(|(f, _)| counts.get(f).copied().unwrap_or(0) != 0)
                .fold(IRect::EMPTY, |acc, (_, r)| acc.union(r))
        };
        let mut dmg = changed(&self.prev).union(&changed(&now));
        if dmg.is_empty() {
            // Same primitives in a new order: the stacking changed.
            dmg = now
                .iter()
                .chain(self.prev.iter())
                .fold(IRect::EMPTY, |acc, (_, r)| acc.union(r));
        }
        self.prev = now;
        Some(dmg)
    }
}
```

- [ ] **Step 5: Run the tests**

Expected: `raster::` 6 passed, `damage::` 4 passed, whole suite green,
clippy and fmt silent.

- [ ] **Step 6: Commit**

```bash
git add src/dbrrg-menu/src/raster.rs src/dbrrg-menu/src/damage.rs src/dbrrg-menu/src/lib.rs
git commit -m "feat(menu): rasterise egui meshes on the CPU and redraw only what changed

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Jobs and the menu state machine

**Files:**
- Create: `src/dbrrg-menu/src/jobs.rs`, `src/dbrrg-menu/src/menu.rs`
- Modify: `src/dbrrg-menu/src/lib.rs` (add `pub mod jobs;`, `pub mod menu;`)

**Interfaces:**
- Consumes: `tiles::{Action, Grid, Tile, command_line, merge, SourceFile}`,
  `desktop::parse` (tests).
- Produces:
  - `jobs::SaveOutcome::{Saved, HomeMissing, RestoreFailed,
    ServerUnreachable, NowhereToStore, Failed, Broken(String)}` with
    `from_status(Option<i32>)`, `saved()`, `message() -> String`.
  - `jobs::restore_failed(state_dir: &Path) -> bool`.
  - `jobs::JobResult::{Saved(SaveOutcome), Ran { name: String, status:
    Result<Option<i32>, String>, save_on_exit: bool }}`.
  - `jobs::Paths { save_home, state_dir: PathBuf }`,
    `jobs::save(&Paths) -> SaveOutcome`,
    `jobs::run(name: &str, argv: &[String], save_on_exit: bool) -> JobResult`.
  - `menu::Busy::{Idle, Running { name }, Saving { since: Instant }}`,
    `menu::Job::{Save, Run { name, argv, save_on_exit }}`,
    `menu::Effect::{Start(Job), Exit(i32)}`,
    `menu::Menu { tiles, banner, busy, notice }` with
    `new(Grid, restore_failed: bool)`,
    `activate(&mut self, index: usize, now: Instant) -> Option<Effect>`,
    `finished(&mut self, JobResult, now: Instant) -> Option<Effect>`;
    `menu::RESTORE_FAILED_REASON`.

**Why:** "one action at a time, enforced by the menu refusing input, not by
blocking the loop". `activate` refuses while busy; the work itself runs on
a worker thread (Task 6). No test writes a script and then executes it:
another test thread forking in between holds the write descriptor and the
exec fails with "Text file busy", which made an earlier draft flaky.

- [ ] **Step 1: Write the failing tests**

Add both modules to `lib.rs`. `src/dbrrg-menu/src/jobs.rs`:

```rust
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
```

`src/dbrrg-menu/src/menu.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop;
    use crate::tiles::{SourceFile, merge};

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
    fn logout_exits_zero() {
        let mut m = Menu::new(grid(), false);
        assert_eq!(m.activate(3, Instant::now()), Some(Effect::Exit(0)));
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
        assert_eq!(m.notice, None);
        assert_eq!(m.activate(3, now), Some(Effect::Exit(0)));
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
        assert_eq!(m.busy, Busy::Saving { since: now });
        m.finished(JobResult::Saved(SaveOutcome::ServerUnreachable), now);
        assert_eq!(m.busy, Busy::Idle);
        assert_eq!(
            m.notice.as_deref(),
            Some("ThinLinc exited with status 1. Not saved: the boot server cannot be reached.")
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
        assert!(m.notice.as_deref().unwrap().contains("home restore failed"));
    }

    #[test]
    fn save_tile_reports_refusal_not_success() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.activate(2, now), Some(Effect::Start(Job::Save)));
        m.finished(JobResult::Saved(SaveOutcome::RestoreFailed), now);
        assert!(m.notice.as_deref().unwrap().starts_with("Not saved"));
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
        assert_eq!(m.notice.as_deref(), Some("foot could not be started: x."));
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Whole suite. Expected: compile errors, `cannot find type \`SaveOutcome\``,
`cannot find type \`Menu\``.

- [ ] **Step 3: Implement the jobs**

Above `#[cfg(test)]` in `jobs.rs`:

```rust
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
```

- [ ] **Step 4: Implement the state machine**

Above `#[cfg(test)]` in `menu.rs`:

```rust
//! The menu's state machine, apart from any drawing: which tile may be
//! activated, what activating it starts, and what a finished job leaves on
//! screen. One action at a time, enforced here by refusing activation, not
//! by blocking the event loop.

use crate::jobs::{JobResult, SaveOutcome};
use crate::tiles::{Action, Grid, Tile};
use std::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Busy {
    Idle,
    Running { name: String },
    Saving { since: Instant },
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
    pub notice: Option<String>,
    restore_failed: bool,
}

fn run_message(name: &str, status: &Result<Option<i32>, String>) -> Option<String> {
    match status {
        Ok(Some(0)) => None,
        Ok(Some(n)) => Some(format!("{name} exited with status {n}.")),
        Ok(None) => Some(format!("{name} was killed by a signal.")),
        Err(e) => Some(format!("{e}.")),
    }
}

fn join(a: Option<String>, b: String) -> String {
    match a {
        Some(a) => format!("{a} {b}"),
        None => b,
    }
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
        Menu {
            tiles,
            banner: grid.banner,
            busy: Busy::Idle,
            notice: None,
            restore_failed,
        }
    }

    pub fn activate(&mut self, index: usize, now: Instant) -> Option<Effect> {
        if self.busy != Busy::Idle {
            return None;
        }
        let tile = self.tiles.get(index).filter(|t| t.usable())?.clone();
        self.notice = None;
        if let Some(code) = tile.action.exit_code() {
            return Some(Effect::Exit(code));
        }
        match tile.action {
            Action::Run => {
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
                self.busy = Busy::Saving { since: now };
                Some(Effect::Start(Job::Save))
            }
            Action::Logout => unreachable!("handled by exit_code"),
        }
    }

    pub fn finished(&mut self, result: JobResult, now: Instant) -> Option<Effect> {
        match result {
            JobResult::Saved(outcome) => {
                let prior = self.notice.take();
                self.notice = Some(join(prior, outcome.message()));
                self.busy = Busy::Idle;
                None
            }
            JobResult::Ran {
                name,
                status,
                save_on_exit,
            } => {
                self.notice = run_message(&name, &status);
                if !save_on_exit {
                    self.busy = Busy::Idle;
                    return None;
                }
                if self.restore_failed {
                    let prior = self.notice.take();
                    self.notice = Some(join(prior, SaveOutcome::RestoreFailed.message()));
                    self.busy = Busy::Idle;
                    return None;
                }
                self.busy = Busy::Saving { since: now };
                Some(Effect::Start(Job::Save))
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Expected: `jobs::` 5 passed, `menu::` 6 passed, whole suite green. Run it
five times in a row; it must be green every time (the "Text file busy"
race shows up about one run in six when it is present). Clippy and fmt
silent.

- [ ] **Step 6: Commit**

```bash
git add src/dbrrg-menu/src/jobs.rs src/dbrrg-menu/src/menu.rs src/dbrrg-menu/src/lib.rs
git commit -m "feat(menu): one action at a time, save exit codes mapped to messages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Drawing, the event loop, and the binary

**Files:**
- Create: `src/dbrrg-menu/src/ui.rs`, `src/dbrrg-menu/src/app.rs`
- Modify: `src/dbrrg-menu/src/main.rs` (replace), `src/dbrrg-menu/src/lib.rs`

**Interfaces:**
- Consumes: everything from Tasks 1 to 5.
- Produces: the `dbrrg-menu` binary.
  - `dbrrg-menu` draws the grid; exit `0` = Log out; `1` = it could not
    start (no Wayland, no surface); a panic is `101`.
  - `dbrrg-menu --check` prints one line per tile
    (`file<TAB>name<TAB>action<TAB>ok|DISABLED (why)<TAB>icon: path|letter fallback`)
    and exits `1` when a shipped tile is unusable or has no icon.
  - Environment: `DBRRG_MENU_SHIPPED_DIR` (default `/etc/dbrrg/menu`),
    `DBRRG_MENU_USER_DIR` (default `$HOME/.config/dbrrg/menu`),
    `DBRRG_SAVE_HOME` (default `/usr/bin/dbrrg-save-home`),
    `DBRRG_STATE_DIR` (default `/run/dbrrg/state`), `DBRRG_MENU_DEBUG`
    (prints `dbrrg-menu: N tiles`, `dbrrg-menu: configure WxH` on each
    configure, and `dbrrg-menu: raster IRect {…} in …` per raster, to
    stderr).

**Why:** this is the only code that needs a compositor, so it holds no
decisions. `CloseRequested` is ignored on purpose: ending there would be
exit 0, which `dbrrg-session` reads as logout.

- [ ] **Step 1: Write the failing test**

Create `src/dbrrg-menu/src/ui.rs` with its test only:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn elapsed_is_minutes_and_seconds() {
        assert_eq!(elapsed(Duration::from_secs(0)), "0:00");
        assert_eq!(elapsed(Duration::from_secs(65)), "1:05");
    }
}
```

and add `pub mod ui;` to `lib.rs`. Run the suite. Expected: compile error,
`cannot find function \`elapsed\``.

- [ ] **Step 2: Implement the drawing**

Above `#[cfg(test)]` in `ui.rs`:

```rust
//! Drawing the grid and the save dialog. Everything that decides something
//! lives in menu.rs; this file only paints it and reports clicks.

use crate::icons::{self, IconRoots};
use crate::menu::{Busy, Menu};
use crate::tiles::{Origin, Tile};
use egui::{Align2, Color32, FontId, Rect, Sense, Stroke, StrokeKind, TextureHandle, Ui, Vec2, pos2, vec2};
use egui_shadcn::Theme;
use std::time::{Duration, Instant};

pub const COLUMNS: usize = 3;
pub const GAP: f32 = 16.0;
pub const ICON_SIDE: u32 = 96;
/// A warning amber, for reasons drawn on a disabled tile.
pub const WARN: Color32 = Color32::from_rgb(0xc7, 0x9a, 0x4a);

/// Rasterise every tile's icon once, at startup. `None` draws the letter.
pub fn load_icons(ctx: &egui::Context, tiles: &[Tile], roots: &IconRoots) -> Vec<Option<TextureHandle>> {
    let fg = Theme::dark().palette.foreground;
    tiles
        .iter()
        .map(|t| {
            let path = icons::resolve(t.icon.as_deref()?, roots)?;
            let symbolic = icons::is_symbolic(&path, roots);
            match icons::render(&path, ICON_SIDE, [fg.r(), fg.g(), fg.b()], symbolic) {
                Ok(img) => Some(ctx.load_texture(t.file.clone(), img, egui::TextureOptions::LINEAR)),
                Err(e) => {
                    eprintln!("dbrrg-menu: icon {} for {}: {e}", path.display(), t.file);
                    None
                }
            }
        })
        .collect()
}

fn elapsed(d: Duration) -> String {
    let s = d.as_secs();
    format!("{}:{:02}", s / 60, s % 60)
}

/// Draw one frame. Returns the index of a clicked tile.
pub fn show(ui: &mut Ui, menu: &Menu, icons: &[Option<TextureHandle>], now: Instant) -> Option<usize> {
    // No background fill here: the canvas restores the page colour itself,
    // and while saving it holds the frozen grid, which a fill would erase.
    if let Busy::Saving { since } = menu.busy {
        // Only the dialog is drawn. The grid behind it is the frozen,
        // dimmed copy in the canvas background.
        save_dialog(ui, now.duration_since(since));
        ui.ctx().request_repaint_after(Duration::from_secs(1));
        return None;
    }
    let mut clicked = None;
    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
        ui.add_space(GAP);
        for line in menu.banner.iter().chain(menu.notice.iter()) {
            ui.horizontal(|ui| {
                ui.add_space(GAP);
                ui.label(egui::RichText::new(line).color(WARN).size(16.0));
            });
        }
        if let Busy::Running { name } = &menu.busy {
            ui.horizontal(|ui| {
                ui.add_space(GAP);
                ui.label(egui::RichText::new(format!("{name} is running.")).size(16.0));
            });
        }
        let width = ui.available_width() - 2.0 * GAP;
        let tile_w = (width - GAP * (COLUMNS as f32 - 1.0)) / COLUMNS as f32;
        let tile_h = (tile_w * 0.5).clamp(160.0, 260.0);
        for (row, chunk) in menu.tiles.chunks(COLUMNS).enumerate() {
            ui.horizontal(|ui| {
                ui.add_space(GAP);
                ui.spacing_mut().item_spacing.x = GAP;
                for (col, tile) in chunk.iter().enumerate() {
                    let index = row * COLUMNS + col;
                    let enabled = tile.usable() && menu.busy == Busy::Idle;
                    let sense = if enabled { Sense::click() } else { Sense::hover() };
                    let (rect, resp) = ui.allocate_exact_size(vec2(tile_w, tile_h), sense);
                    paint_tile(
                        ui,
                        rect,
                        tile,
                        icons[index].as_ref(),
                        resp.hovered() && enabled,
                        resp.has_focus(),
                    );
                    if resp.clicked() {
                        clicked = Some(index);
                    }
                }
            });
            ui.add_space(GAP - ui.spacing().item_spacing.y);
        }
    });
    clicked
}

fn paint_tile(ui: &Ui, rect: Rect, tile: &Tile, icon: Option<&TextureHandle>, hovered: bool, focused: bool) {
    let t = Theme::current(ui.ctx());
    let p = ui.painter();
    let usable = tile.usable();
    let fill = if hovered { t.palette.accent } else { t.palette.card };
    p.rect_filled(rect, t.radius_md(), fill);
    let border = if usable { t.palette.border } else { WARN };
    p.rect_stroke(rect, t.radius_md(), Stroke::new(1.0, border), StrokeKind::Inside);
    if focused {
        p.rect_stroke(
            rect.expand(2.0),
            t.radius_md(),
            Stroke::new(3.0, t.palette.ring),
            StrokeKind::Outside,
        );
    }
    let fg = if usable {
        t.palette.foreground
    } else {
        t.palette.muted_foreground
    };
    let icon_px = ICON_SIDE as f32 / ui.ctx().pixels_per_point();
    let icon_rect = Rect::from_center_size(
        pos2(rect.center().x, rect.top() + 16.0 + icon_px / 2.0),
        Vec2::splat(icon_px),
    );
    match icon {
        Some(tex) => {
            let tint = if usable {
                Color32::WHITE
            } else {
                Color32::from_gray(128)
            };
            p.image(
                tex.id(),
                icon_rect,
                Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)),
                tint,
            );
        }
        None => {
            p.rect_filled(icon_rect, t.radius_sm(), t.palette.muted);
            let letter: String = tile
                .name
                .chars()
                .next()
                .map(|c| c.to_uppercase().collect())
                .unwrap_or_default();
            p.text(
                icon_rect.center(),
                Align2::CENTER_CENTER,
                letter,
                FontId::proportional(icon_px * 0.5),
                fg,
            );
        }
    }
    let mut y = icon_rect.bottom() + 12.0;
    let text_w = rect.width() - 24.0;
    let mut line = |text: &str, font: FontId, color: Color32| {
        let galley = p.layout(text.to_string(), font, color, text_w);
        p.galley(pos2(rect.center().x - galley.size().x / 2.0, y), galley.clone(), color);
        y += galley.size().y + 4.0;
    };
    line(&tile.name, FontId::proportional(20.0), fg);
    if let Some(c) = &tile.comment {
        line(c, FontId::proportional(14.0), t.palette.muted_foreground);
    }
    if let Some(why) = &tile.problem {
        line(why, FontId::monospace(13.0), WARN);
    }
    if let Some(note) = &tile.note {
        line(note, FontId::monospace(12.0), t.palette.muted_foreground);
    }
    if let Origin::Reworded { ignored } = &tile.origin {
        let text = if ignored.is_empty() {
            "reworded".to_string()
        } else {
            format!("reworded; ignored: {}", ignored.join(", "))
        };
        line(&text, FontId::monospace(12.0), t.palette.muted_foreground);
    }
    if tile.origin == Origin::User {
        p.text(
            rect.right_top() + vec2(-8.0, 6.0),
            Align2::RIGHT_TOP,
            "user",
            FontId::monospace(11.0),
            t.palette.muted_foreground,
        );
    }
}

fn save_dialog(ui: &Ui, took: Duration) {
    let t = Theme::current(ui.ctx());
    egui::Area::new(egui::Id::new("save-dialog"))
        .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ui.ctx(), |ui| {
            egui::Frame::new()
                .fill(t.palette.card)
                .stroke(Stroke::new(1.0, t.palette.border))
                .corner_radius(t.radius_lg())
                .inner_margin(24.0)
                .show(ui, |ui| {
                    ui.set_width(420.0);
                    ui.label(egui::RichText::new("Backing up your home directory").size(18.0));
                    ui.label(
                        egui::RichText::new(elapsed(took))
                            .size(28.0)
                            .monospace()
                            .color(t.palette.ring),
                    );
                    ui.label(
                        egui::RichText::new("On a network-booted machine this can take a minute.")
                            .color(t.palette.muted_foreground),
                    );
                });
        });
}
```

Run the suite: `ui::tests::elapsed_is_minutes_and_seconds ... ok`.

- [ ] **Step 3: Write the event loop**

`src/dbrrg-menu/src/app.rs`:

```rust
//! The event loop: winit for the Wayland window, egui-winit for input,
//! egui for layout, raster.rs for pixels, softbuffer to put them on screen.
//! Driven by hand rather than through eframe so that nothing here needs a
//! GPU. The rules this file follows are in the spec under "Rendering
//! without a GPU".

use crate::damage::Tracker;
use crate::icons::IconRoots;
use crate::jobs::{self, JobResult, Paths};
use crate::menu::{Busy, Effect, Job, Menu};
use crate::raster::{Background, Canvas, Textures};
use crate::ui;
use egui::{TextureHandle, ViewportId};
use std::num::NonZeroU32;
use std::rc::Rc;
use std::time::Instant;
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

/// How much of the grid's brightness survives behind the save dialog.
const DIM_KEEP: u32 = 90;

pub struct Config {
    pub menu: Menu,
    pub paths: Paths,
    pub icon_roots: IconRoots,
    pub debug: bool,
}

struct Live {
    window: Rc<Window>,
    surface: softbuffer::Surface<Rc<Window>, Rc<Window>>,
    egui: egui_winit::State,
    canvas: Canvas,
    textures: Textures,
    tracker: Tracker,
    icons: Vec<Option<TextureHandle>>,
}

pub struct App {
    cfg: Config,
    ctx: egui::Context,
    proxy: EventLoopProxy<JobResult>,
    live: Option<Live>,
    /// Set when the menu must end; `run` returns it as the process status.
    exit: Option<i32>,
    /// Whether the canvas background is the frozen grid.
    frozen: bool,
}

/// Run the menu until it exits. Returns the exit status for dbrrg-session.
pub fn run(cfg: Config) -> Result<i32, String> {
    let event_loop = EventLoop::<JobResult>::with_user_event()
        .build()
        .map_err(|e| e.to_string())?;
    event_loop.set_control_flow(ControlFlow::Wait);
    let ctx = egui::Context::default();
    // Feathering assumes coverage blending, which an integer rasteriser does
    // not do: it shows up as fringes on rounded corners.
    ctx.options_mut(|o| o.tessellation_options.feathering = false);
    // An animated widget on a CPU rasteriser arrives as visibly staged full
    // frames.
    ctx.global_style_mut(|s| s.animation_time = 0.0);
    let mut app = App {
        cfg,
        ctx,
        proxy: event_loop.create_proxy(),
        live: None,
        exit: None,
        frozen: false,
    };
    event_loop.run_app(&mut app).map_err(|e| e.to_string())?;
    app.exit
        .ok_or_else(|| "the event loop ended without an exit request".to_string())
}

impl App {
    fn start(&self, job: Job) {
        let proxy = self.proxy.clone();
        let paths = Paths {
            save_home: self.cfg.paths.save_home.clone(),
            state_dir: self.cfg.paths.state_dir.clone(),
        };
        std::thread::spawn(move || {
            let result = match job {
                Job::Save => JobResult::Saved(jobs::save(&paths)),
                Job::Run {
                    name,
                    argv,
                    save_on_exit,
                } => jobs::run(&name, &argv, save_on_exit),
            };
            // The loop is gone only when the menu is exiting; nothing to tell.
            let _ = proxy.send_event(result);
        });
    }

    fn apply(&mut self, effect: Option<Effect>, event_loop: &ActiveEventLoop) {
        match effect {
            Some(Effect::Start(job)) => self.start(job),
            Some(Effect::Exit(code)) => {
                self.exit = Some(code);
                event_loop.exit();
            }
            None => {}
        }
    }

    fn redraw(&mut self, event_loop: &ActiveEventLoop) {
        let Some(live) = self.live.as_mut() else { return };
        egui_shadcn::Theme::dark().apply(&self.ctx);
        let input = live.egui.take_egui_input(&live.window);
        let now = Instant::now();
        let mut clicked = None;
        let out = self.ctx.run_ui(input, |ui| {
            clicked = ui::show(ui, &self.cfg.menu, &live.icons, now);
        });
        live.egui.handle_platform_output(&live.window, out.platform_output);

        // The dialog dims the grid once, when it opens, and un-freezes it
        // when it closes. Either way every pixel must be redrawn once.
        let saving = matches!(self.cfg.menu.busy, Busy::Saving { .. });
        let mut force_full = false;
        if saving != self.frozen {
            if saving {
                live.canvas.freeze_dimmed(DIM_KEEP);
            } else {
                let bg = egui_shadcn::Theme::dark().palette.background;
                live.canvas.background = Background::Solid(bg);
            }
            self.frozen = saving;
            live.tracker.reset();
            force_full = true;
        }

        live.textures.apply_set(&out.textures_delta);
        let ppp = out.pixels_per_point;
        let prims = self.ctx.tessellate(out.shapes, ppp);
        let mut damage = live.tracker.damage(&prims, ppp);
        if force_full || !out.textures_delta.set.is_empty() {
            damage = Some(live.canvas.bounds());
        }
        if let Some(rect) = damage {
            let t0 = Instant::now();
            live.canvas.restore_background(rect);
            live.canvas.draw(&prims, &live.textures, ppp, rect);
            if let Err(e) = present(&mut live.surface, &live.canvas) {
                eprintln!("dbrrg-menu: present failed: {e}");
            }
            if self.cfg.debug {
                eprintln!("dbrrg-menu: raster {:?} in {:?}", rect, t0.elapsed());
            }
        }
        live.textures.apply_free(&out.textures_delta);

        // Honour egui's own repaint requests. Ignoring them leaves the first
        // screen in fallback fonts until the mouse moves, because the font
        // atlas lands one frame late.
        let delay = out.viewport_output.get(&ViewportId::ROOT).map(|v| v.repaint_delay);
        match delay {
            Some(d) if d.is_zero() => live.window.request_redraw(),
            Some(d) if d < std::time::Duration::from_secs(3600) => {
                event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + d))
            }
            _ => event_loop.set_control_flow(ControlFlow::Wait),
        }

        if let Some(i) = clicked {
            let effect = self.cfg.menu.activate(i, now);
            self.apply(effect, event_loop);
            if let Some(live) = self.live.as_ref() {
                live.window.request_redraw();
            }
        }
    }
}

fn present(surface: &mut softbuffer::Surface<Rc<Window>, Rc<Window>>, canvas: &Canvas) -> Result<(), String> {
    let mut buf = surface.buffer_mut().map_err(|e| e.to_string())?;
    if buf.len() != canvas.pixels.len() {
        return Err(format!(
            "buffer is {} pixels, canvas {}",
            buf.len(),
            canvas.pixels.len()
        ));
    }
    buf.copy_from_slice(&canvas.pixels);
    buf.present().map_err(|e| e.to_string())
}

impl ApplicationHandler<JobResult> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.live.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("dbrrg-menu")
            .with_decorations(false)
            .with_maximized(true);
        let window = match event_loop.create_window(attrs) {
            Ok(w) => Rc::new(w),
            Err(e) => {
                eprintln!("dbrrg-menu: cannot create a window: {e}");
                self.exit = Some(1);
                event_loop.exit();
                return;
            }
        };
        let surface =
            softbuffer::Context::new(window.clone()).and_then(|c| softbuffer::Surface::new(&c, window.clone()));
        let surface = match surface {
            Ok(s) => s,
            Err(e) => {
                eprintln!("dbrrg-menu: cannot create a drawing surface: {e}");
                self.exit = Some(1);
                event_loop.exit();
                return;
            }
        };
        let egui = egui_winit::State::new(
            self.ctx.clone(),
            ViewportId::ROOT,
            &window,
            Some(window.scale_factor() as f32),
            None,
            None,
        );
        let icons = ui::load_icons(&self.ctx, &self.cfg.menu.tiles, &self.cfg.icon_roots);
        let bg = egui_shadcn::Theme::dark().palette.background;
        self.live = Some(Live {
            window: window.clone(),
            surface,
            egui,
            canvas: Canvas::new(1, 1, bg),
            textures: Textures::default(),
            tracker: Tracker::default(),
            icons,
        });
        window.request_redraw();
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, result: JobResult) {
        let effect = self.cfg.menu.finished(result, Instant::now());
        self.apply(effect, event_loop);
        if let Some(live) = self.live.as_ref() {
            live.window.request_redraw();
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        let Some(live) = self.live.as_mut() else { return };
        match &event {
            WindowEvent::RedrawRequested => {
                self.redraw(event_loop);
                return;
            }
            WindowEvent::Resized(size) => {
                if self.cfg.debug {
                    eprintln!("dbrrg-menu: configure {}x{}", size.width, size.height);
                }
                if let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) {
                    if let Err(e) = live.surface.resize(w, h) {
                        eprintln!("dbrrg-menu: resize failed: {e}");
                    }
                    let bg = egui_shadcn::Theme::dark().palette.background;
                    live.canvas = Canvas::new(size.width as usize, size.height as usize, bg);
                    self.frozen = false;
                    live.tracker.reset();
                }
            }
            // labwc draws no close button and has no keybindings, so this
            // only comes from a client asking. Ending here would be exit 0,
            // which dbrrg-session reads as logout.
            WindowEvent::CloseRequested => return,
            _ => {}
        }
        // While the dialog is up, input is refused rather than handled.
        if matches!(self.cfg.menu.busy, Busy::Saving { .. }) && is_input(&event) {
            return;
        }
        let resp = live.egui.on_window_event(&live.window, &event);
        if resp.repaint {
            live.window.request_redraw();
        }
    }
}

fn is_input(e: &WindowEvent) -> bool {
    matches!(
        e,
        WindowEvent::KeyboardInput { .. }
            | WindowEvent::MouseInput { .. }
            | WindowEvent::MouseWheel { .. }
            | WindowEvent::CursorMoved { .. }
            | WindowEvent::Touch(_)
    )
}
```

Final `src/dbrrg-menu/src/lib.rs`:

```rust
//! dbrrg-menu: the tile grid that is the body of the dbrrg session.

pub mod app;
pub mod damage;
pub mod desktop;
pub mod icons;
pub mod jobs;
pub mod menu;
pub mod raster;
pub mod tiles;
pub mod ui;
```

- [ ] **Step 4: Write the entry point**

Replace `src/dbrrg-menu/src/main.rs`:

```rust
//! Entry point. The exit status is the contract with dbrrg-session:
//! 0 means log out (save the home, then return), anything else means the
//! menu failed and dbrrg-session must not save.

use dbrrg_menu::app::{self, Config};
use dbrrg_menu::icons::{self, IconRoots};
use dbrrg_menu::jobs::{self, Paths};
use dbrrg_menu::menu::Menu;
use dbrrg_menu::tiles;
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

/// `dbrrg-menu --check`: print every tile and how its icon resolves, and
/// fail if a shipped tile is unusable or has no icon. For the image tests,
/// and for an operator at a VT asking why a tile is grey.
fn check() -> ExitCode {
    let (menu, _, roots) = build_menu();
    let mut bad = false;
    for line in &menu.banner {
        println!("banner: {line}");
    }
    for t in &menu.tiles {
        let icon = t.icon.as_deref().and_then(|i| icons::resolve(i, &roots));
        let shipped = t.origin != tiles::Origin::User;
        let state = match &t.problem {
            Some(p) => format!("DISABLED ({p})"),
            None => "ok".to_string(),
        };
        let icon_text = icon
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "letter fallback".into());
        println!("{}\t{}\t{:?}\t{}\ticon: {}", t.file, t.name, t.action, state, icon_text);
        if shipped && (t.problem.is_some() || icon.is_none()) {
            bad = true;
        }
    }
    if bad { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn main() -> ExitCode {
    if std::env::args().nth(1).as_deref() == Some("--check") {
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
        Ok(code) => ExitCode::from(code as u8),
        Err(e) => {
            eprintln!("dbrrg-menu: {e}");
            ExitCode::from(1)
        }
    }
}
```

- [ ] **Step 5: Build, lint, test**

```bash
cd /home/oetiker/checkouts/dbrrg/src/dbrrg-menu
CARGO_BUILD_JOBS=4 cargo build --locked --release -j 4
CARGO_BUILD_JOBS=4 cargo clippy --locked -j 4 --all-targets -- -D warnings
cargo fmt --check
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test CARGO_BUILD_JOBS=4 \
  systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4
B=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')/release/dbrrg-menu
readelf -d "$B" | grep NEEDED
grep -acE 'libvulkan\.so|libEGL\.so|libGL\.so|libGLESv2' "$B"
```

Expected: `test result: ok. 48 passed`; `NEEDED` lists only `libgcc_s`,
`libm`, `libc`, `ld-linux-x86-64`; the `grep -c` prints `0`.

- [ ] **Step 6: `--check` against a fixture**

```bash
F=/scratch/oetiker/claude-tmp/dbrrg-test/check
rm -rf "$F" && mkdir -p "$F/shipped" "$F/user" "$F/state"
printf '[Desktop Entry]\nName=Log out\nIcon=log-out\nX-DBRRG-Action=logout\n' >"$F/shipped/80-logout.desktop"
printf '[Desktop Entry]\nName=Mine\nX-DBRRG-Action=logout\n' >"$F/user/60-mine.desktop"
DBRRG_MENU_SHIPPED_DIR="$F/shipped" DBRRG_MENU_USER_DIR="$F/user" DBRRG_STATE_DIR="$F/state" "$B" --check; echo "rc=$?"
```

Expected: `60-mine.desktop … DISABLED (60-mine.desktop: a tile of your own
may only use the run action, not 'logout')`, then `80-logout.desktop …
icon: letter fallback` (the host has no `/usr/share/dbrrg/icons`) and
`rc=1`, because a shipped tile has no icon.

- [ ] **Step 7: Smoke test under headless labwc**

The last built image has labwc but no menu; bind the binary, the Task 3
icons and a fixture tile set into it. The host's glibc is older than the
image's, so a host build runs there.

```bash
F=/scratch/oetiker/claude-tmp/dbrrg-test/smoke
rm -rf "$F" && mkdir -p "$F/menu"
printf '[Desktop Entry]\nName=Terminal\nIcon=foot\nExec=foot\n' >"$F/menu/30-terminal.desktop"
printf '[Desktop Entry]\nName=Log out\nIcon=log-out\nX-DBRRG-Action=logout\n' >"$F/menu/80-logout.desktop"
timeout --kill-after=10 120 podman run --rm --network=none \
  -v "$B:/usr/bin/dbrrg-menu:ro" -v "$F/menu:/etc/dbrrg/menu:ro" \
  -v /home/oetiker/checkouts/dbrrg/src/dbrrg-menu/icons:/usr/share/dbrrg/icons:ro \
  -e WLR_BACKENDS=headless -e WLR_HEADLESS_OUTPUTS=1 -e WLR_RENDERER=pixman -e XDG_RUNTIME_DIR=/tmp/xdg \
  localhost/dbrrg-ubuntu:3.0.0 sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
    labwc -C /etc/dbrrg/labwc -S "sh -c \"DBRRG_MENU_DEBUG=1 timeout 8 dbrrg-menu; echo menu-rc=\$?\""' 2>&1 | grep -E 'dbrrg-menu|menu-rc'
```

Expected:

```
dbrrg-menu: 2 tiles
dbrrg-menu: configure 1280x720
dbrrg-menu: raster IRect { x0: 0, y0: 0, x1: 1280, y1: 720 } in …
menu-rc=124
```

`124` means `timeout` ended a menu that was still running. If the image
does not exist yet, skip this step and say so in the report; Task 9 covers
the same ground against the real image.

- [ ] **Step 8: Commit**

```bash
git add src/dbrrg-menu/src
git commit -m "feat(menu): draw the grid and the save dialog in a GPU-free event loop

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The session runs the menu and acts on its exit status

**Files:**
- Create: `test/integration/test-session-lifecycle.sh`,
  `overlay/usr/libexec/dbrrg/session-verdict`
- Modify: `overlay/usr/bin/dbrrg-session`,
  `overlay/etc/profile.d/10-dbrrg-session.sh`, `Makefile` (`test` target)

**Interfaces:**
- Consumes: the exit-status contract (Global Constraints). Not the binary:
  everything here is tested with stubs.
- Produces:
  - `dbrrg-session` runs `$DBRRG_MENU` (default `/usr/bin/dbrrg-menu`),
    writes its status to `$DBRRG_SESSION_STATUS` (default
    `${XDG_RUNTIME_DIR:-/tmp}/dbrrg-session.status`), runs
    `$DBRRG_SAVE_HOME` only on `0`, otherwise opens a `foot` window with
    the status and exits with it.
  - `/usr/libexec/dbrrg/session-verdict STATUS_FILE COUNTER_FILE`: exit `0`
    = start a fresh session; exit `1` = stop, and it prints the menu's
    status. Limit `DBRRG_SESSION_FAILURE_LIMIT`, default `3`.
  - `10-dbrrg-session.sh` exports `DBRRG_SESSION_LOG` and
    `DBRRG_SESSION_STATUS`; `DBRRG_SESSION_FAILURES` and
    `DBRRG_SESSION_VERDICT` are overridable for the tests.

**Why:** labwc exits 0 whatever its `-S` command returned (CLAUDE.md,
"A session body that fails to start does so silently"), so today a failing
session body respawns in a loop with nothing on screen. With a menu that
loop would also archive the home once per pass. The status file is how the
login shell learns what labwc does not tell it.

- [ ] **Step 1: Write the failing test**

`test/integration/test-session-lifecycle.sh` (mode 755):

```bash
#!/bin/bash
# Offline: the exit-status contract between dbrrg-menu and dbrrg-session,
# and the restart limit in session-verdict. No image, no compositor; the
# menu, dbrrg-save-home and foot are stubs on PATH.
#
# Usage: test/integration/test-session-lifecycle.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SESSION="$ROOT/overlay/usr/bin/dbrrg-session"
VERDICT="$ROOT/overlay/usr/libexec/dbrrg/session-verdict"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
ok()   { echo "ok   - $1"; }
bad()  { echo "FAIL - $1"; fail=1; }

mkdir -p "$WORK/bin" "$WORK/home"
# foot records its arguments instead of opening a window.
cat >"$WORK/bin/foot" <<STUB
#!/bin/sh
echo "\$@" >"$WORK/foot.args"
STUB
cat >"$WORK/bin/save" <<STUB
#!/bin/sh
touch "$WORK/saved"
STUB
chmod 755 "$WORK/bin/foot" "$WORK/bin/save"
# The session also starts these helpers when they exist; on a dev host they
# might, so stub them rather than launch the real ones.
for h in waybar swayidle wlopm; do
    printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$h"
    chmod 755 "$WORK/bin/$h"
done

# Run dbrrg-session with a menu stub that runs $1 as shell code.
run_session() {
    rm -f "$WORK/saved" "$WORK/foot.args" "$WORK/status" "$WORK/dbrrg-session.status"
    printf '#!/bin/sh\n%s\n' "$1" >"$WORK/bin/menu"
    chmod 755 "$WORK/bin/menu"
    env -i PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" \
        XDG_RUNTIME_DIR="$WORK" \
        DBRRG_MENU="$WORK/bin/menu" DBRRG_SAVE_HOME="$WORK/bin/save" \
        DBRRG_SESSION_LOG="$WORK/log" \
        sh "$SESSION" >/dev/null 2>&1
}

run_session 'exit 0'
rc=$?
[[ $rc -eq 0 ]] && ok "logout: session exits 0" || bad "logout: session exited $rc"
[[ -e "$WORK/saved" ]] && ok "logout: home saved" || bad "logout: home not saved"
[[ "$(cat "$WORK/dbrrg-session.status" 2>/dev/null)" == 0 ]] && ok "logout: status 0 recorded" || bad "logout: status file wrong"
[[ ! -e "$WORK/foot.args" ]] && ok "logout: no failure window" || bad "logout: failure window shown"

for code in 1 101 127; do
    run_session "exit $code"
    rc=$?
    [[ $rc -eq $code ]] && ok "menu exit $code: session exits $code" || bad "menu exit $code: session exited $rc"
    [[ ! -e "$WORK/saved" ]] && ok "menu exit $code: home NOT saved" || bad "menu exit $code: home was saved"
    [[ "$(cat "$WORK/dbrrg-session.status" 2>/dev/null)" == "$code" ]] && ok "menu exit $code: status recorded" \
        || bad "menu exit $code: status file wrong"
    grep -q -- "-- sh -c" "$WORK/foot.args" 2>/dev/null && grep -q " $code " "$WORK/foot.args" \
        && ok "menu exit $code: failure window names the status" || bad "menu exit $code: no failure window"
done

# Killed by a signal: the shell reports 128+N. Still a failure, still no save.
run_session 'kill -9 $$'
rc=$?
[[ $rc -eq 137 && ! -e "$WORK/saved" ]] && ok "menu killed: no save, status 137" \
    || bad "menu killed: rc=$rc saved=$([[ -e $WORK/saved ]] && echo yes || echo no)"

# --- session-verdict ---------------------------------------------------
S="$WORK/vstatus"
C="$WORK/vcount"
rm -f "$S" "$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 ]] && ok "verdict: no status file restarts" || bad "verdict: no status file gave $rc"
echo 0 >"$S"; echo 2 >"$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 && ! -e "$C" ]] && ok "verdict: clean logout resets the count" || bad "verdict: clean logout rc=$rc"
echo 101 >"$S"; rm -f "$C"
"$VERDICT" "$S" "$C" >/dev/null; r1=$?
"$VERDICT" "$S" "$C" >/dev/null; r2=$?
out=$("$VERDICT" "$S" "$C"); r3=$?
[[ $r1 -eq 0 && $r2 -eq 0 && $r3 -eq 1 && "$out" == 101 ]] \
    && ok "verdict: third consecutive failure stops the restarts and names 101" \
    || bad "verdict: got $r1 $r2 $r3 '$out'"
[[ ! -e "$C" ]] && ok "verdict: count cleared after stopping" || bad "verdict: count left behind"
echo garbage >"$C"
"$VERDICT" "$S" "$C" >/dev/null; rc=$?
[[ $rc -eq 0 && "$(cat "$C")" == 1 ]] && ok "verdict: a corrupt count starts again at 1" || bad "verdict: corrupt count rc=$rc"

# --- 10-dbrrg-session.sh stops restarting after repeated failures ----
PROFILE="$ROOT/overlay/etc/profile.d/10-dbrrg-session.sh"
mkdir -p "$WORK/ps/bin" "$WORK/ps/home" "$WORK/ps/run"
printf '#!/bin/sh\necho /dev/tty1\n' >"$WORK/ps/bin/tty"
# labwc runs the session, which records the menu's status, and exits 0 as
# the real one always does.
printf '#!/bin/sh\necho "$STUB_MENU_RC" >"$DBRRG_SESSION_STATUS"\nexit 0\n' >"$WORK/ps/bin/labwc"
chmod 755 "$WORK/ps/bin/tty" "$WORK/ps/bin/labwc"
run_profile() {
    env -i PATH="$WORK/ps/bin:/usr/bin:/bin" HOME="$WORK/ps/home" \
        XDG_RUNTIME_DIR="$WORK/ps/run" STUB_MENU_RC="$1" \
        DBRRG_SESSION_VERDICT="$VERDICT" DBRRG_SESSION_FAILURES="$WORK/ps/failures" \
        sh "$PROFILE" >"$WORK/ps/out" 2>&1
    ps_rc=$?
}
run_profile 101
r1=$ps_rc; o1=$(cat "$WORK/ps/out")
run_profile 101
r2=$ps_rc
run_profile 101
if [[ $r1 -eq 0 && $r2 -eq 0 && "$o1" != *"graphical session exited"* ]] &&
   grep -q 'graphical session exited with status 101' "$WORK/ps/out"; then
    ok "profile: two failed menus restart, the third shows the failure screen"
else
    bad "profile: r1=$r1 r2=$r2 out=$(cat "$WORK/ps/out")"
fi
run_profile 0
if [[ $ps_rc -eq 0 && ! -e "$WORK/ps/failures" ]] && ! grep -q 'graphical session exited' "$WORK/ps/out"; then
    ok "profile: a clean logout ends the session and clears the count"
else
    bad "profile: clean logout rc=$ps_rc out=$(cat "$WORK/ps/out")"
fi

exit $fail
```

- [ ] **Step 2: Run it to see it fail**

```bash
cd /home/oetiker/checkouts/dbrrg
chmod 755 test/integration/test-session-lifecycle.sh
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test test/integration/test-session-lifecycle.sh; echo "rc=$?"
```

Expected: `FAIL` lines (the current script runs `/opt/thinlinc/bin/tlclient`
and ignores `DBRRG_MENU`; `session-verdict` does not exist) and `rc=1`.

- [ ] **Step 3: Add the verdict helper**

`overlay/usr/libexec/dbrrg/session-verdict` (mode 755):

```sh
#!/bin/sh
# Decide, after labwc has returned 0, whether the session that just ended
# failed often enough to stop restarting it.
#
# Usage: session-verdict STATUS_FILE COUNTER_FILE
#
# STATUS_FILE holds dbrrg-menu's exit status, written by dbrrg-session.
# labwc exits 0 whatever its -S command returned, so this file is the only
# record of a failed menu. COUNTER_FILE counts consecutive failed sessions
# and must survive the logout, so it does not live in XDG_RUNTIME_DIR.
#
# Exit 0: start a fresh session (a clean logout, or a failure below the
#         limit).
# Exit 1: stop and show the failure screen. Prints the menu's status.
#
# A missing or empty STATUS_FILE is a clean session: dbrrg-session writes it
# only once the menu has returned, and an older dbrrg-session never writes it.

DBRRG_SESSION_FAILURE_LIMIT="${DBRRG_SESSION_FAILURE_LIMIT:-3}"

status=$(cat "$1" 2>/dev/null || true)
case "$status" in
    ''|0)
        rm -f "$2"
        exit 0
        ;;
esac

count=$(cat "$2" 2>/dev/null || true)
case "$count" in
    ''|*[!0-9]*) count=0 ;;
esac
count=$((count + 1))
if [ "$count" -lt "$DBRRG_SESSION_FAILURE_LIMIT" ]; then
    echo "$count" >"$2" 2>/dev/null || true
    exit 0
fi
rm -f "$2"
echo "$status"
exit 1
```

- [ ] **Step 4: Rewrite `dbrrg-session`**

The full new file. Compared with today's it changes the header comment,
the comment above the `.dbrrg-sessionrc` source, and replaces the last two
lines (`tlclient`, then `dbrrg-save-home`) with the menu and the status
`case`; the sessionrc, helper, waybar and swayidle blocks are unchanged.

```sh
#!/bin/sh
# Body of the graphical session, run by labwc via 'labwc -S'.
#
# The body of the session is dbrrg-menu, the tile grid. ThinLinc is one of
# its tiles. The menu never ends the session itself: it exits with a status
# and this script carries that out, because dbrrg-save-home needs a live
# session (see the end of this file).
#
# When this script returns, labwc terminates and the tty1 login starts a
# fresh session. Leaving the compositor running would strand the user on a
# bare desktop with no keybindings and no way to recover.
# NOTE: the home directory has ALREADY been restored, by restore_home() in
# the initramfs before the pivot - not by this script or its caller. It has
# to happen there so a user's ~/.dbrrg-environment (keyboard layout, cursor)
# is on disk before labwc reads XKB_DEFAULT_* at startup, and so the SSH host
# keys inside it are available before sshd starts. Do not add a restore call
# here - it would overwrite the running session's home with the on-disk copy
# midway through.

# Per-device session customisation, sourced after the home restore so the
# user's own saved copy wins.
#
# This is the Wayland replacement for ~/.xsessionrc, which the move off X11
# removed. That file was how people configured individual machines - display
# layout with xrandr, keyboard, netplan/WiFi - and because it lives in $HOME
# it is captured by save-home and restored on every boot, so edits persist
# without rebuilding an image.
#
# Displays: wlr-randr is the xrandr equivalent for this compositor, e.g.
#   wlr-randr --output DP-1 --transform 90 --pos 1920,0
# For layouts that must survive a monitor being switched on late or waking
# from DPMS, run kanshi from here instead - it reapplies on hotplug, which a
# one-shot wlr-randr does not.
#
# Sourced rather than executed, matching ~/.xsessionrc semantics: no execute
# bit needed, and it can export variables into the session.
#
# It runs BEFORE the menu, and so before any tile starts tlclient, because
# the ThinLinc client reads the monitor layout once at startup - a rotation
# applied afterwards would leave the client believing a portrait screen is
# still landscape.
if [ -r "$HOME/.dbrrg-sessionrc" ]; then
    . "$HOME/.dbrrg-sessionrc"
fi

# Background helpers. Every one of them must die with the session: labwc
# terminates when this script returns, and an orphan would linger against the
# next session's compositor. One trap covers all of them, so adding a helper
# means appending its PID here and nothing else.
HELPER_PIDS=""
kill_helpers() {
    for _p in $HELPER_PIDS; do
        kill "$_p" 2>/dev/null
    done
}
trap kill_helpers EXIT INT TERM

# The taskbar. Without it a window minimized via labwc's iconify button is
# gone for the rest of the session - there are no keybindings and no menu to
# get it back. See /etc/dbrrg/waybar/config.jsonc.
if command -v waybar >/dev/null 2>&1; then
    waybar -c /etc/dbrrg/waybar/config.jsonc \
           -s /etc/dbrrg/waybar/style.css &
    HELPER_PIDS="$HELPER_PIDS $!"
fi

# Screen blanking. Wayland splits this in two: labwc reports idleness via
# ext_idle_notifier_v1 but has no timeout of its own, so without a policy
# daemon listening nothing ever blanks. That is what was lost moving off X11,
# where the X server did it internally (xset s / server-side DPMS).
#
# wlopm - not wlr-randr - is the right tool. wlr-randr --off speaks the output
# *management* protocol and disables the output outright, changing the monitor
# layout and resizing the fullscreen ThinLinc client. wlopm speaks output
# *power* management, which is true DPMS: the panel sleeps, the layout is
# untouched, any input wakes it.
#
# No locking. ext_session_lock_manager_v1 is available, but tluser has no
# password, so a lock screen would have nothing to authenticate against -
# session security is ThinLinc's job, not the local compositor's.
#
# Note the ThinLinc client is an X11 app under Xwayland and cannot send an
# idle inhibit, so a long video inside the remote session with no input will
# blank the local screen. Any keypress restores it.
#
# Per-machine override from ~/.dbrrg-sessionrc, sourced above:
#   DBRRG_IDLE_TIMEOUT=900   longer grace period
#   DBRRG_IDLE_TIMEOUT=0     disable blanking entirely
: "${DBRRG_IDLE_TIMEOUT:=300}"
if [ "$DBRRG_IDLE_TIMEOUT" -gt 0 ] 2>/dev/null &&
   command -v swayidle >/dev/null 2>&1 &&
   command -v wlopm >/dev/null 2>&1; then
    swayidle -w \
        timeout "$DBRRG_IDLE_TIMEOUT" 'wlopm --off \*' \
        resume 'wlopm --on \*' &
    HELPER_PIDS="$HELPER_PIDS $!"
fi

# The programs this script runs, overridable so
# test/integration/test-session-lifecycle.sh can run it unprivileged.
DBRRG_MENU="${DBRRG_MENU:-/usr/bin/dbrrg-menu}"
DBRRG_SAVE_HOME="${DBRRG_SAVE_HOME:-/usr/bin/dbrrg-save-home}"
# Where the menu's exit status is left for 10-dbrrg-session.sh. labwc always
# exits 0 whatever this script returns, so this file is the only way the
# login shell learns that the menu failed.
DBRRG_SESSION_STATUS="${DBRRG_SESSION_STATUS:-${XDG_RUNTIME_DIR:-/tmp}/dbrrg-session.status}"

# Show why the menu failed, in a window, and keep the compositor alive while
# it is open. Returning straight away would let getty restart the session
# and the reason would never be on screen.
dbrrg_hold() {
    foot --title "dbrrg: the menu failed" -- sh -c '
        echo "dbrrg-menu exited with status $1, so the session stopped."
        echo "Your home directory was NOT saved."
        echo ""
        echo "Last lines of the session log ($2):"
        tail -n 20 "$2" 2>/dev/null
        echo ""
        echo "Close this window to start a new session."
        exec sh' dbrrg-hold "$1" "${DBRRG_SESSION_LOG:-unknown}"
}

# The menu's exit status is a request:
#
#   0          log out: save the home directory, then return
#   any other  the menu failed: do NOT save, show why, hold
#
# Failure is the default branch on purpose. A Rust panic exits 101, a
# segfault 139, a failed exec 126 or 127; reading those as logout would make
# a crash silent and archive the home once per respawn. Item 3 of the tile
# menu spec adds 10 (reboot) and 11 (poweroff) as further cases here.
"$DBRRG_MENU"
menu_rc=$?
echo "$menu_rc" >"$DBRRG_SESSION_STATUS" 2>/dev/null || true
case "$menu_rc" in
    0)
        "$DBRRG_SAVE_HOME"
        exit 0
        ;;
    *)
        echo "dbrrg: dbrrg-menu exited with status $menu_rc - the home directory was not saved" >&2
        dbrrg_hold "$menu_rc"
        exit "$menu_rc"
        ;;
esac
```

- [ ] **Step 5: Teach the login script the status file**

Three edits to `overlay/etc/profile.d/10-dbrrg-session.sh`.

After the block that picks `DBRRG_SESSION_LOG` (ends with
`DBRRG_SESSION_LOG=/tmp/dbrrg-session.log` / `fi`), insert:

```sh

    # dbrrg-session leaves dbrrg-menu's exit status in DBRRG_SESSION_STATUS.
    # labwc always exits 0 whatever its -S command returned, so without this
    # file a failing menu restarts in a loop with nothing on screen.
    # session-verdict counts consecutive failures in DBRRG_SESSION_FAILURES,
    # which must outlive this login; XDG_RUNTIME_DIR does not, /tmp is per
    # boot. dbrrg-session reads both exported names.
    DBRRG_SESSION_STATUS="${XDG_RUNTIME_DIR:-/tmp}/dbrrg-session.status"
    DBRRG_SESSION_FAILURES="${DBRRG_SESSION_FAILURES:-/tmp/dbrrg-session-failures.$(id -u)}"
    DBRRG_SESSION_VERDICT="${DBRRG_SESSION_VERDICT:-/usr/libexec/dbrrg/session-verdict}"
    export DBRRG_SESSION_LOG DBRRG_SESSION_STATUS
```

In `dbrrg_run_labwc()`, make the first line of the body:

```sh
        rm -f "$DBRRG_SESSION_STATUS"
```

Replace

```sh
    if [ "$DBRRG_SESSION_RC" -eq 0 ]; then
        # Normal logout: exit so getty starts a fresh session.
        exit 0
    fi
```

with

```sh
    if [ "$DBRRG_SESSION_RC" -eq 0 ]; then
        # labwc came up and went away again. Whether the session inside it
        # ended cleanly is in the status file, not in labwc's status. A
        # logout, or a menu failure below the limit, exits so getty starts
        # a fresh session. A missing helper keeps the old behaviour.
        if [ ! -x "$DBRRG_SESSION_VERDICT" ] ||
           DBRRG_MENU_RC=$("$DBRRG_SESSION_VERDICT" \
                "$DBRRG_SESSION_STATUS" "$DBRRG_SESSION_FAILURES"); then
            exit 0
        fi
        echo "dbrrg: the menu failed several sessions in a row."
        DBRRG_SESSION_RC=$DBRRG_MENU_RC
    fi
```

The failure screen below it then prints `graphical session exited with
status <menu status>`.

- [ ] **Step 6: Run the new test and the existing profile test**

```bash
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test test/integration/test-session-lifecycle.sh; echo "rc=$?"
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test test/integration/test-field-report.sh | grep -E 'FAIL|labwc'
sh -n overlay/usr/bin/dbrrg-session overlay/usr/libexec/dbrrg/session-verdict overlay/etc/profile.d/10-dbrrg-session.sh
```

Expected: 24 `ok` lines and `rc=0`; the three existing labwc retry checks
in `test-field-report.sh` still `ok` (the verdict helper is absent on the
host's `/usr/libexec`, and the missing-helper branch keeps the old
behaviour); `sh -n` silent.

- [ ] **Step 7: Wire the test into `make test`**

In `Makefile`, add to the `test:` recipe after
`@test/integration/test-field-report.sh`:

```make
	@test/integration/test-session-lifecycle.sh
```

- [ ] **Step 8: Commit**

```bash
git add test/integration/test-session-lifecycle.sh overlay/usr/libexec/dbrrg/session-verdict \
        overlay/usr/bin/dbrrg-session overlay/etc/profile.d/10-dbrrg-session.sh Makefile
git commit -m "feat(session): run dbrrg-menu and save only on its logout status

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Shipped tiles and the image build

**Files:**
- Create: `overlay/etc/dbrrg/menu/10-thinlinc.desktop`,
  `20-oxulnk.desktop`, `30-terminal.desktop`, `40-save-home.desktop`,
  `50-upgrade-image.desktop`, `80-logout.desktop`
- Modify: `containers/ubuntu/Dockerfile`, `Makefile`, `.dockerignore`,
  `test/integration/test-session-packages.sh`

**Interfaces:**
- Consumes: the crate (Tasks 1 to 6), the session scripts (Task 7).
- Produces: an image with `/usr/bin/dbrrg-menu`,
  `/usr/share/dbrrg/icons/{hard-drive-download,usb,log-out}.svg` and
  `LICENSE`, `/usr/share/dbrrg/fonts/Oxanium-OFL.txt`, and the six tiles in
  `/etc/dbrrg/menu`. `test-session-packages.sh` reads the image name from
  `DBRRG_UBUNTU_IMAGE` (default `localhost/dbrrg-ubuntu:3.0.0`).

- [ ] **Step 1: Write the failing image assertions**

In `test/integration/test-session-packages.sh`, after the line
`absent  "old regenerate unit" 'regenerate_ssh_host_keys\.service$'`, add:

```bash
present "dbrrg-menu"          'usr/bin/dbrrg-menu$'
present "session verdict"     'usr/libexec/dbrrg/session-verdict$'
for t in 10-thinlinc 20-oxulnk 30-terminal 40-save-home 50-upgrade-image 80-logout; do
    present "tile $t" "etc/dbrrg/menu/$t\.desktop$"
done
for i in hard-drive-download usb log-out; do
    present "Lucide icon $i" "usr/share/dbrrg/icons/$i\.svg$"
done
present "Lucide licence"      'usr/share/dbrrg/icons/LICENSE$'
present "Oxanium licence"     'usr/share/dbrrg/fonts/Oxanium-OFL\.txt$'
```

Before the final `exit $fail`, add:

```bash
# dbrrg-menu rasterises on the CPU. The images this is built for have no
# Vulkan driver at all, and a GL path would make the menu's start depend on
# EGL context creation. A later switch to a GPU backend must fail here, not
# on a client. Both linking and dlopen are checked: winit and wgpu load
# their libraries at runtime.
MENU_TMP=$(mktemp -d)
if unsquashfs -no-xattrs -d "$MENU_TMP/x" "$SQSH" usr/bin/dbrrg-menu >/dev/null 2>&1 &&
   [[ -f "$MENU_TMP/x/usr/bin/dbrrg-menu" ]]; then
    MB="$MENU_TMP/x/usr/bin/dbrrg-menu"
    if readelf -d "$MB" | grep NEEDED | grep -qiE 'vulkan|libGL|libEGL|GLES'; then
        echo "FAIL - dbrrg-menu links a GPU library"
        fail=1
    elif grep -aqE 'libvulkan\.so|libEGL\.so|libGLESv2\.so|libGL\.so' "$MB"; then
        echo "FAIL - dbrrg-menu names a GPU library it may dlopen"
        fail=1
    else
        echo "ok   - dbrrg-menu uses no GPU library"
    fi
else
    echo "FAIL - cannot extract usr/bin/dbrrg-menu from $SQSH"
    fail=1
fi
rm -rf "$MENU_TMP"

# The session body is the menu now; tlclient is one of its tiles.
if [[ -n "${SESS:-}" && -f "$SESS" ]] &&
   grep -q 'DBRRG_MENU:-/usr/bin/dbrrg-menu' "$SESS" &&
   ! grep -v '^[[:space:]]*#' "$SESS" | grep -q '/opt/thinlinc/bin/tlclient'; then
    echo "ok   - dbrrg-session launches dbrrg-menu, not tlclient"
else
    echo "FAIL - dbrrg-session does not launch dbrrg-menu"
    fail=1
fi

# Cargo.lock is committed, so the image builds what was tested, and it
# carries no smithay-clipboard, which segfaults on Wayland.
LOCK=src/dbrrg-menu/Cargo.lock
if git ls-files --error-unmatch "$LOCK" >/dev/null 2>&1 &&
   ! grep -q '^name = "smithay-clipboard"$' "$LOCK"; then
    echo "ok   - $LOCK is committed and has no smithay-clipboard"
else
    echo "FAIL - $LOCK missing from git or pulls smithay-clipboard"
    fail=1
fi

# Every shipped tile is usable and its Icon= resolves to a file in the
# image, checked by the menu's own resolver. thinlinc_128.png is an absolute
# path into /opt/thinlinc, which has moved across client versions before.
IMAGE="${DBRRG_UBUNTU_IMAGE:-localhost/dbrrg-ubuntu:3.0.0}"
if check_out=$(podman run --rm --network=none "$IMAGE" /usr/bin/dbrrg-menu --check 2>&1); then
    echo "ok   - every shipped tile is usable and its icon resolves"
else
    echo "FAIL - dbrrg-menu --check in $IMAGE:"
    echo "$check_out"
    fail=1
fi
```

`SESS` is set by the existing swayidle block (it extracts
`usr/bin/dbrrg-session`); keep the new block after it. Run the script
against the current image: `test/integration/test-session-packages.sh`.
Expected: `FAIL - dbrrg-menu missing`, the tile and icon `FAIL`s, and
`FAIL - cannot extract usr/bin/dbrrg-menu`.

- [ ] **Step 2: Write the six tiles**

`overlay/etc/dbrrg/menu/10-thinlinc.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=ThinLinc
Icon=/opt/thinlinc/lib/tlclient/thinlinc_128.png
Exec=/opt/thinlinc/bin/tlclient
X-DBRRG-Save-On-Exit=true
```

`overlay/etc/dbrrg/menu/20-oxulnk.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=oxulnk
Icon=oxulnk-desktop
Exec=oxulnk-desktop
X-DBRRG-Save-On-Exit=true
```

`overlay/etc/dbrrg/menu/30-terminal.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Terminal
Icon=foot
Exec=foot
```

`overlay/etc/dbrrg/menu/40-save-home.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Back up home
Icon=hard-drive-download
X-DBRRG-Action=save-home
```

`overlay/etc/dbrrg/menu/50-upgrade-image.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Upgrade image
Icon=usb
Exec=sudo upgrade-image
Terminal=true
```

`overlay/etc/dbrrg/menu/80-logout.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Log out
Icon=log-out
X-DBRRG-Action=logout
```

The names leave gaps (`60`, `70`, `90`) for user tiles and for item 3's
`90-reboot` and `95-poweroff`.

- [ ] **Step 3: Add the build stage**

In `containers/ubuntu/Dockerfile`, insert between the end of the
`labwc-build` stage (the `cp /build/labwc_*.deb /out/` line) and
`FROM ubuntu:26.04`:

```dockerfile

# dbrrg-menu, the tile grid that is the body of the session. See
# docs/superpowers/specs/2026-10-01-tile-menu-design.md.
#
# The toolchain comes from rustup, pinned by the crate's rust-toolchain.toml:
# egui 0.36 needs Rust 1.95 and Ubuntu 26.04's archive rustc is 1.93.
# Cargo.lock is committed and --locked makes a drifted lock fail the build
# instead of silently resolving something untested.
FROM ubuntu:26.04 AS menu-build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -yq --no-install-recommends rustup ca-certificates gcc libc6-dev
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
COPY src/dbrrg-menu/ /build/dbrrg-menu/
WORKDIR /build/dbrrg-menu
RUN set -eu; \
    toolchain=$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml); \
    rustup toolchain install "$toolchain" --profile minimal; \
    CARGO_BUILD_JOBS=4 rustup run "$toolchain" cargo build --release --locked -j 4; \
    install -D -m 0755 target/release/dbrrg-menu /out/usr/bin/dbrrg-menu; \
    install -D -m 0644 -t /out/usr/share/dbrrg/icons icons/*.svg icons/LICENSE; \
    install -D -m 0644 egui_shadcn/assets/Oxanium-OFL.txt /out/usr/share/dbrrg/fonts/Oxanium-OFL.txt
```

And after the labwc install block in the final stage (the `rm -rf
/tmp/labwc-deb` line), add:

```dockerfile

# dbrrg-menu and its icons, from the menu-build stage above. The tiles
# themselves are plain files in overlay/etc/dbrrg/menu.
COPY --from=menu-build /out/ /
```

- [ ] **Step 4: Let the crate into the build context**

`.dockerignore` excludes everything not re-included. Append:

```
!src/dbrrg-menu
src/dbrrg-menu/target
```

- [ ] **Step 5: Make the crate a build input**

In `Makefile`, after the `PATCH_FILES` definition, add:

```make

# dbrrg-menu is built from source in the ubuntu container's menu-build stage.
# Like PATCH_FILES, its sources must be prerequisites of .ubuntu-container:
# OVERLAY_FILES only finds files under overlay/, and the crate cannot live
# there because overlay/ is copied into the shipped rootfs. Without this,
# editing main.rs leaves the stamp valid, 'make rootfs' reports nothing to
# do, and 'make test' validates a stale binary while printing green. The
# directories are listed as well, so deleting a file still changes a
# prerequisite's mtime.
MENU_FILES := $(shell find src/dbrrg-menu -path src/dbrrg-menu/target -prune -o -type f ! -name '*~' -print 2>/dev/null)
MENU_DIRS := $(shell find src/dbrrg-menu -path src/dbrrg-menu/target -prune -o -type d -print 2>/dev/null)
```

Extend the `.ubuntu-container` prerequisites with
`$(MENU_FILES) $(MENU_DIRS)`, and pass the image name to the packages test
in the `test:` recipe:

```make
	@DBRRG_UBUNTU_IMAGE=$(UBUNTU_IMAGE) test/integration/test-session-packages.sh
```

Check the prerequisite works before building: `make -n rootfs | head -3`
must show the `podman build` (the crate is newer than the stamp).

- [ ] **Step 6: Build and run the image suite**

```bash
cd /home/oetiker/checkouts/dbrrg
flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make rootfs
TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make test
```

Expected: the build log shows `menu-build` compiling `dbrrg-menu`; every
line of `make test` is `ok`, including the new ones, and `dbrrg-menu
--check` lists the six tiles as `ok` with icons
`/opt/thinlinc/lib/tlclient/thinlinc_128.png`,
`/usr/share/icons/hicolor/256x256/apps/oxulnk-desktop.png`,
`/usr/share/icons/hicolor/scalable/apps/foot.svg` and the three
`/usr/share/dbrrg/icons/*.svg`. Then touch `src/dbrrg-menu/src/main.rs`
and confirm `make -n rootfs` wants to rebuild.

- [ ] **Step 7: Commit**

```bash
git add overlay/etc/dbrrg/menu containers/ubuntu/Dockerfile Makefile .dockerignore \
        test/integration/test-session-packages.sh
git commit -m "feat(image): build dbrrg-menu into the image with its six shipped tiles

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Runtime proof under labwc

**Files:**
- Modify: `test/runtime/test-labwc-runtime.sh`

**Interfaces:**
- Consumes: the image from Task 8; `DBRRG_MENU_DEBUG` output (Task 6).
- Produces: three new runtime assertions.

**Why:** a native Wayland client has no X connection, so `x11-probe.py`
cannot measure it. The menu prints its own configure size. The rig has no
input devices, so clicking a tile cannot be tested here; Known limits in
CLAUDE.md say so (Task 10).

- [ ] **Step 1: Add the menu check**

In `test/runtime/test-labwc-runtime.sh`, before the final `exit $fail`:

```bash
# dbrrg-menu is a native Wayland client, so x11-probe cannot see it; it
# prints its own configure size under DBRRG_MENU_DEBUG. One output, so the
# maximized grid must get all of it. timeout ends the menu after 10s: exit
# 124 means it was still running, i.e. it neither crashed nor exited on its
# own, and an exit 0 here would be a logout nobody asked for.
MENU_CONTAINER_NAME="dbrrg-runtime-test-menu-$$"

menu_out=$(timeout --kill-after=10 "$RUNTIME_TIMEOUT" podman run --rm --name "$MENU_CONTAINER_NAME" \
    -e WLR_BACKENDS=headless \
    -e WLR_HEADLESS_OUTPUTS=1 \
    -e WLR_RENDERER=pixman \
    -e XDG_RUNTIME_DIR=/tmp/xdg \
    "$IMAGE" \
    sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
           labwc -C /etc/dbrrg/labwc -S "sh -c \"DBRRG_MENU_DEBUG=1 timeout 10 dbrrg-menu; echo menu-rc=\$?\""' 2>&1)
menu_rc=$?

if [[ $menu_rc -eq 124 || $menu_rc -eq 137 ]]; then
    echo "FAIL - podman run timed out after ${RUNTIME_TIMEOUT}s (labwc hang during menu startup)"
    echo "$menu_out"
    podman rm -f "$MENU_CONTAINER_NAME" >/dev/null 2>&1
    exit 1
fi

if echo "$menu_out" | grep -q 'dbrrg-menu: configure 1280x720'; then
    echo "ok   - dbrrg-menu maps at the full output size (1280x720)"
else
    echo "FAIL - dbrrg-menu did not configure at 1280x720"
    echo "$menu_out"
    fail=1
fi
if echo "$menu_out" | grep -q 'dbrrg-menu: raster'; then
    echo "ok   - dbrrg-menu rasterised a frame on the CPU"
else
    echo "FAIL - dbrrg-menu never rasterised a frame"
    echo "$menu_out"
    fail=1
fi
if echo "$menu_out" | grep -q 'menu-rc=124'; then
    echo "ok   - dbrrg-menu kept running until stopped"
else
    echo "FAIL - dbrrg-menu exited on its own: $(echo "$menu_out" | grep menu-rc)"
    fail=1
fi
```

Update the script's header comment to mention the menu check.

- [ ] **Step 2: Run it**

```bash
flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make test-runtime
```

Expected: the three existing `ok` lines and the three new ones.

- [ ] **Step 3: Commit**

```bash
git add test/runtime/test-labwc-runtime.sh
git commit -m "test(runtime): assert dbrrg-menu maps full size and keeps running under labwc

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Project memory and user documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`,
  `docs/superpowers/specs/2026-10-01-tile-menu-design.md`

**Interfaces:**
- Consumes: everything above.
- Produces: documentation only.

- [ ] **Step 1: Update CLAUDE.md**

Make these changes, in the file's existing voice:

1. **Build System Architecture:** add the `menu-build` stage of
   `containers/ubuntu/Dockerfile` (Rust 1.96.0 via rustup, `--locked`) and
   the crate at `src/dbrrg-menu/`, and that `MENU_FILES`/`MENU_DIRS` make it
   a prerequisite of `.ubuntu-container`.
2. **Boot Flow, step 5 (Home Persistence)** and **Persistent Home
   Directory, "On logout"**: the home is saved when the Log out tile ends
   the menu with status 0 (by `dbrrg-session`), after a tile with
   `X-DBRRG-Save-On-Exit=true` (ThinLinc, oxulnk) exits (by the menu,
   behind its dialog), and from the Back up home tile. The menu greys the
   save tile out when `/run/dbrrg/state/home-restore` says `failed`.
3. **Customizing the System:** a bullet for tiles: shipped in
   `overlay/etc/dbrrg/menu/` (outside `$HOME`, for the reason `rc.xml` is);
   per-machine tiles in `~/.config/dbrrg/menu/*.desktop`, at most 32, `run`
   only; a user file named like a shipped one may reword `Name`, `Comment`,
   `Icon` only. Fix the `.dbrrg-sessionrc` bullet: it runs before the menu,
   and so before `tlclient`.
4. **Standing Constraints:** add two rules and change "Eleven" to
   "Thirteen" in the intro:
   - *dbrrg-menu draws on the CPU.* No wgpu/glow/eframe; the target images
     have no Vulkan ICD (`/usr/share/vulkan/icd.d` does not exist), and GL
     would make the menu's start depend on EGL. `test-session-packages.sh`
     fails on a GPU library linked or named.
   - *dbrrg-session saves only on menu status 0.* Failure is the default
     branch; a panic (101), segfault (139) or failed exec (126/127) read as
     logout would be silent and would archive the home on every respawn.
     `test-session-lifecycle.sh` guards it.
5. **Debugging, "A session body that fails to start does so silently":**
   rewrite for the new mechanism: `dbrrg-session` writes the menu's status
   to `$XDG_RUNTIME_DIR/dbrrg-session.status`, shows a `foot` window on
   failure, and `session-verdict` stops the restarts after three
   consecutive failed sessions, counted in
   `/tmp/dbrrg-session-failures.<uid>`. `dbrrg-menu --check` from a VT lists
   every tile and why one is grey.
6. **Debugging, "Reaching a terminal":** the Terminal tile is now the
   in-session path; VT and SSH remain for when the session is down.
7. **Known Limitations:** the grid is on one monitor (the span patch is
   Xwayland-only); a tile whose program never exits and opens no window
   keeps the menu busy with no way to cancel; clicking a tile is not
   covered by the headless runtime test (no input devices); a failed save
   at logout is visible only in the session log.

- [ ] **Step 2: README**

Add a short section for administrators, after the section that documents
`sudo upgrade-image`: the session opens a grid of tiles; ThinLinc is one
click; per-machine tiles go in `~/.config/dbrrg/menu/` as `.desktop` files
(`Name`, `Icon`, `Exec`, optional `Terminal=true`,
`X-DBRRG-Save-On-Exit=true`), are saved with the home directory, and may
reword a shipped tile by using its file name; `dbrrg-menu --check` explains
a grey tile.

- [ ] **Step 3: Correct the spec's stale decision**

In `docs/superpowers/specs/2026-10-01-tile-menu-design.md`, under "Decisions
taken", replace the bullet that begins "**`dbrrg-save-home` stops trusting
`by-partlabel`.**" with:

```markdown
- **`dbrrg-save-home` stops trusting `by-partlabel`.** It writes to the ESP
  the initramfs already mounted at `/run/dbrrg/storage/efi`, which is by
  construction the partition this boot read; the by-partlabel symlink stays
  only as the fallback for a boot that left nothing mounted. (The first
  version of this bullet said the initramfs records the device node; see
  "Corrected 2026-10-02" under Copying a home onto a new stick.)
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md docs/superpowers/specs/2026-10-01-tile-menu-design.md
git commit -m "docs: record the tile menu in CLAUDE.md, README and the spec

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Verification

After Task 10, on the branch head, re-derive every gate rather than trusting
a task report:

```bash
cd /home/oetiker/checkouts/dbrrg
export TMPDIR=/scratch/oetiker/claude-tmp/dbrrg-test
make test-unit                                   # Python suite + 48 cargo tests
(cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 cargo clippy --locked -j 4 --all-targets -- -D warnings && cargo fmt --check)
flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make test          # image suite incl. --check
flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make test-runtime  # labwc headless
```

Then on hardware, which no test here reaches: boot, see the grid, open
ThinLinc, quit it and watch the save dialog, open the Terminal tile, log
out and see the grid come back. Record the result in CLAUDE.md the way
"Confirmed on hardware" entries are recorded there.
