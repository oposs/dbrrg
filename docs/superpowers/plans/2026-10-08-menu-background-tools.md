# Menu: background programs, coloured log, menu always behind — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tile menu runs several programs at once, shows their ANSI colours in its log, and always stays the bottom window.

**Architecture:** `menu.rs` replaces the single `Busy` state with three parts (running jobs, a save with a one-deep queue, logout steps). `jobs.rs` starts each program in its own process group, reports its process group id, and can signal the group. `log.rs` parses SGR escapes into coloured runs that `ui.rs` draws. A labwc window rule keeps the window with app_id `dbrrg-menu` at the bottom.

**Tech Stack:** Rust 1.96 (edition 2024), egui 0.36 / egui-winit / winit 0.30 (Wayland), softbuffer, libc; labwc 0.9.3 `rc.xml`; bash integration tests; podman image build via `make`.

**Spec:** `docs/superpowers/specs/2026-10-08-menu-background-tools-design.md`

## Global Constraints

- Branch `menu-bg`; work lands on `main` by fast-forward after review. Ask before pushing and before `scripts/publish.sh`.
- Max 4 cores: `CARGO_BUILD_JOBS=4 ... cargo test --locked -j 4`.
- Every cargo test run under `systemd-run --user --scope -q -p MemoryMax=2G --`.
- Image builds under `flock /scratch/oetiker/claude-tmp/dbrrg-build.lock make …`; logs in `/scratch/oetiker/claude-tmp/dbrrg-build/`. Long Bash calls pass `timeout: 600000`.
- `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings` must pass (crate has `rustfmt.toml` with `max_width = 120`).
- CPU-only rendering: no GPU crates (`wgpu`, `glow`, `eframe`).
- labwc `rc.xml` keeps zero keybindings (no `<keybind`, no `<default />`).
- Menu saves before it exits 0; `dbrrg-session` never saves. `dbrrg-save-home` exit codes 0-5 are a contract.
- Program output is untrusted: lines cut at `LINE_BYTES` (1024), log and feed capped at `LOG_LINES` (500), output wakes at most every `OUTPUT_PACE` (100 ms). Add: at most `MAX_RUNS` (64) colour runs per line.
- `STOP_GRACE` = 5 s between SIGTERM and SIGKILL at logout.
- English for code, comments, identifiers. No CHANGES file in this repo; `CLAUDE.md` is the project memory.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. `stop()` with a process group id of 0 or 1 → must send nothing. `kill(-0, …)` signals the menu's own group and `kill(-1, …)` every process the user owns; a pgid not yet known must never become 0. Pinned in Task 4 (`stop_target_refuses_0_and_1`).
2. A program whose `Started` arrives after *Stop them and log out* was clicked → it must still get SIGTERM (or SIGKILL if the deadline passed), else logout hangs. Pinned in Task 4 (`a_program_started_late_is_stopped_when_its_group_is_known`).
3. A program that ignores SIGTERM → SIGKILL at `kill_at`, and the deadline fires without input. Pinned in Task 4 (`a_program_ignoring_term_is_killed_at_the_deadline`, plus the repaint request in `ui.rs`).
4. Program output made only of escape sequences, or cut in the middle of one at 1 KiB → an empty or plain line, never `[33m` text and never a panic. Pinned in Task 2 (`escapes_only_give_an_empty_line`, `a_sequence_cut_at_the_end_is_removed`).
5. Save requests arriving during a save (two Save-On-Exit programs ending, plus Back up home) → exactly one more save, and a logout during a background save waits for it and then saves once more. Pinned in Task 4 (`requests_during_a_save_give_exactly_one_more`, `logout_waits_for_a_background_save_then_saves`).

---

### Task 1: The menu is always the bottom window

**Files:**
- Modify: `src/dbrrg-menu/src/app.rs` (window attributes in `resumed`, ~line 241)
- Modify: `overlay/etc/dbrrg/labwc/rc.xml`
- Modify: `test/integration/test-session-packages.sh:93-101`

**Interfaces:**
- Consumes: nothing.
- Produces: Wayland app_id `dbrrg-menu`; labwc rule matching it.

- [ ] **Step 1: Write the failing check** in `test/integration/test-session-packages.sh`, directly after the `fi` that ends the keybinding check (line 101):

```bash
# The menu is the bottom window: a program clicked away must not go behind
# it, and the taskbar must not offer to minimise it. Matched by app_id.
if [[ -f "$RC/etc/dbrrg/labwc/rc.xml" ]] &&
   tr -d '\n' < "$RC/etc/dbrrg/labwc/rc.xml" |
   grep -qE '<windowRule[^>]*identifier="dbrrg-menu"[^>]*skipTaskbar="yes"[^>]*>[[:space:]]*<action name="ToggleAlwaysOnBottom"'; then
    echo "ok   - rc.xml keeps dbrrg-menu at the bottom and off the taskbar"
else
    echo "FAIL - rc.xml has no ToggleAlwaysOnBottom/skipTaskbar rule for dbrrg-menu"
    fail=1
fi
```

- [ ] **Step 2: Add the rule** to `overlay/etc/dbrrg/labwc/rc.xml`, after the `<!-- No <mouse> section … -->` comment, before `</labwc_config>`:

```xml
  <!--
    dbrrg-menu is the desktop: always the bottom window, so a program
    window can never go behind it, and never in the taskbar, where it could
    be minimised. The menu sets this app_id in src/dbrrg-menu/src/app.rs.
  -->
  <windowRules>
    <windowRule identifier="dbrrg-menu" skipTaskbar="yes">
      <action name="ToggleAlwaysOnBottom" />
    </windowRule>
  </windowRules>
```

- [ ] **Step 3: Set the app_id** in `src/dbrrg-menu/src/app.rs`. Add to the imports:

```rust
use winit::platform::wayland::WindowAttributesExtWayland;
```

and change the attributes in `resumed`:

```rust
        // The app_id labwc's window rule in /etc/dbrrg/labwc/rc.xml matches
        // to keep the menu at the bottom and off the taskbar.
        let attrs = Window::default_attributes()
            .with_title("dbrrg-menu")
            .with_name("dbrrg-menu", "")
            .with_decorations(false)
            .with_maximized(true);
```

- [ ] **Step 4: Build and lint the crate**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo clippy --locked -j 4 --all-targets -- -D warnings && cargo fmt --check`
Expected: no warnings, no format diff.

- [ ] **Step 5: Commit**

```bash
git add src/dbrrg-menu/src/app.rs overlay/etc/dbrrg/labwc/rc.xml test/integration/test-session-packages.sh
git commit -m "feat(menu): the menu is always the bottom window and not in the taskbar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The image-level check (`make test`) and `make test-runtime` run in Task 5, after one image build for all tasks.

---

### Task 2: ANSI colours in the log

**Files:**
- Modify: `src/dbrrg-menu/src/log.rs` (Line, Log::push/note, `clean` → `parse`, Splitter, tests)
- Modify: `src/dbrrg-menu/src/jobs.rs` (`pump` builds `runs`; tests read `plain()`)
- Modify: `src/dbrrg-menu/src/menu.rs` (test helper `log()` reads `plain()`)
- Modify: `src/dbrrg-menu/src/ui.rs` (`log_job` draws runs; `ansi_color`; tests construct `runs`)

**Interfaces:**
- Consumes: nothing new.
- Produces (in `log.rs`):
  - `pub enum Ansi { Basic(u8), Indexed(u8), Rgb(u8, u8, u8) }` (derive `Debug, Clone, Copy, PartialEq, Eq`)
  - `pub struct Run { pub text: String, pub fg: Option<Ansi>, pub bold: bool }` with `Run::plain(text: impl Into<String>) -> Run`
  - `pub struct Line { pub time: String, pub source: Option<String>, pub runs: Vec<Run>, pub kind: Kind }` with `Line::plain(&self) -> String`
  - `pub fn parse(bytes: &[u8]) -> Vec<Run>` (never empty)
  - `pub fn plain(runs: &[Run]) -> String`
  - `pub const MAX_RUNS: usize = 64;`
  - `Splitter::feed(&mut self, chunk: &[u8], out: &mut impl FnMut(Vec<Run>))`, same for `finish`.
- Produces (in `ui.rs`): `pub fn ansi_color(a: Ansi) -> Color32`.

- [ ] **Step 1: Write the failing parser tests** in `log.rs` `mod tests`. Replace the test `control_characters_are_removed` with these, and change the `split` helper to return plain strings:

```rust
    fn split(chunks: &[&[u8]]) -> Vec<String> {
        let mut s = Splitter::default();
        let mut out = Vec::new();
        for c in chunks {
            s.feed(c, &mut |r| out.push(plain(&r)));
        }
        s.finish(&mut |r| out.push(plain(&r)));
        out
    }

    fn run(text: &str, fg: Option<Ansi>, bold: bool) -> Run {
        Run {
            text: text.into(),
            fg,
            bold,
        }
    }

    #[test]
    fn control_characters_are_removed() {
        assert_eq!(plain(&parse(b"a\tb\r")), "a b");
        assert_eq!(plain(&parse(b"bad \xff byte")), "bad \u{fffd} byte");
    }

    #[test]
    fn sgr_colours_become_runs() {
        // As oxulnk-desktop writes a log line.
        assert_eq!(
            parse(b"\x1b[2m2026-10-08\x1b[0m \x1b[33m WARN\x1b[0m \x1b[2moxulnk\x1b[0m: slow"),
            [
                run("2026-10-08 ", None, false),
                run(" WARN", Some(Ansi::Basic(3)), false),
                run(" oxulnk: slow", None, false),
            ]
        );
    }

    #[test]
    fn bold_bright_256_and_rgb() {
        assert_eq!(parse(b"\x1b[1;31mA"), [run("A", Some(Ansi::Basic(1)), true)]);
        assert_eq!(parse(b"\x1b[92mB"), [run("B", Some(Ansi::Basic(10)), false)]);
        assert_eq!(parse(b"\x1b[38;5;208mC"), [run("C", Some(Ansi::Indexed(208)), false)]);
        assert_eq!(parse(b"\x1b[38;2;1;2;3mD"), [run("D", Some(Ansi::Rgb(1, 2, 3)), false)]);
        assert_eq!(parse(b"\x1b[31mE\x1b[39mF"), [run("E", Some(Ansi::Basic(1)), false), run("F", None, false)]);
        assert_eq!(parse(b"\x1b[1mG\x1b[22mH"), [run("G", None, true), run("H", None, false)]);
        // A background colour is read and ignored, not taken for a foreground.
        assert_eq!(parse(b"\x1b[48;5;1;32mI"), [run("I", Some(Ansi::Basic(2)), false)]);
        assert_eq!(parse(b"\x1b[38;5;999mJ"), [run("J", None, false)], "out of range");
    }

    #[test]
    fn other_escapes_are_removed_whole() {
        assert_eq!(plain(&parse(b"\x1b]0;title\x07after")), "after");
        assert_eq!(plain(&parse(b"\x1b]0;title\x1b\\after")), "after");
        assert_eq!(plain(&parse(b"a\x1b[2Kb\x1b[10;20Hc")), "abc");
        assert_eq!(plain(&parse(b"\x1b(Bx\x1b=y")), "xy");
    }

    #[test]
    fn a_sequence_cut_at_the_end_is_removed() {
        assert_eq!(parse(b"ok\x1b[38;5"), [run("ok", None, false)]);
        assert_eq!(plain(&parse(b"ok\x1b]0;unterminated")), "ok");
        assert_eq!(plain(&parse(b"ok\x1b")), "ok");
    }

    #[test]
    fn escapes_only_give_an_empty_line() {
        assert_eq!(parse(b"\x1b[31m\x1b[0m"), [run("", None, false)]);
        assert_eq!(parse(b""), [run("", None, false)]);
    }

    #[test]
    fn colour_changes_past_the_limit_join_the_last_run() {
        let mut input = Vec::new();
        for i in 0..200 {
            input.extend_from_slice(format!("\x1b[3{}m{}", i % 8, i % 10).as_bytes());
        }
        let runs = parse(&input);
        assert_eq!(runs.len(), MAX_RUNS);
        assert_eq!(plain(&runs).len(), 200, "no text lost");
    }

    #[test]
    fn a_cut_line_ends_in_an_ellipsis_after_its_colours() {
        let mut input = b"\x1b[31m".to_vec();
        input.extend(std::iter::repeat_n(b'x', LINE_BYTES + 10));
        input.push(b'\n');
        let mut got = Vec::new();
        let mut s = Splitter::default();
        s.feed(&input, &mut |r| got.push(r));
        assert_eq!(got.len(), 1);
        let last = got[0].last().unwrap();
        assert!(last.text.ends_with('…'));
        assert_eq!(last.fg, Some(Ansi::Basic(1)));
    }
```

Also change the existing test helper `line(text)` in `log.rs` to build `runs: vec![Run::plain(text)]`, and in `the_log_keeps_the_newest_lines` / `the_feed_drops_its_oldest_lines_when_full` replace `.text` with `.plain()`.

- [ ] **Step 2: Run the tests, expect compile failure**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 --lib log::`
Expected: FAIL to compile (`parse`, `Run`, `Ansi`, `plain` not found).

- [ ] **Step 3: Implement the model and the parser** in `log.rs`. Replace `pub text: String` in `Line` by `pub runs: Vec<Run>`, and replace `clean()` by the following:

```rust
/// The most colour runs one line keeps. Past it, colour changes are ignored
/// and the text joins the last run: a program cannot make a line cost more
/// than this many sections to draw.
pub const MAX_RUNS: usize = 64;

/// A foreground colour a program asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ansi {
    /// 0-7 normal, 8-15 bright.
    Basic(u8),
    /// The 256-colour palette.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

/// A piece of a line in one colour.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    /// `None` draws in the line's own colour.
    pub fg: Option<Ansi>,
    pub bold: bool,
}

impl Run {
    pub fn plain(text: impl Into<String>) -> Run {
        Run {
            text: text.into(),
            fg: None,
            bold: false,
        }
    }
}

/// The text of runs without their colours.
pub fn plain(runs: &[Run]) -> String {
    runs.iter().map(|r| r.text.as_str()).collect()
}

impl Line {
    pub fn plain(&self) -> String {
        plain(&self.runs)
    }
}

/// Apply one SGR parameter list (the part between `ESC [` and `m`).
/// Only the foreground and bold are kept; everything else is read and
/// ignored, including background colours and their arguments.
fn sgr(params: &str, mut fg: Option<Ansi>, mut bold: bool) -> (Option<Ansi>, bool) {
    let p: Vec<Option<u16>> = params
        .split(';')
        .map(|x| if x.is_empty() { Some(0) } else { x.parse().ok() })
        .collect();
    let byte = |i: usize| p.get(i).copied().flatten().and_then(|n| u8::try_from(n).ok());
    let mut i = 0;
    while i < p.len() {
        match p[i] {
            Some(0) => {
                fg = None;
                bold = false;
            }
            Some(1) => bold = true,
            Some(22) => bold = false,
            Some(n @ 30..=37) => fg = Some(Ansi::Basic((n - 30) as u8)),
            Some(n @ 90..=97) => fg = Some(Ansi::Basic((n - 90 + 8) as u8)),
            Some(39) => fg = None,
            Some(c @ (38 | 48)) => match p.get(i + 1).copied().flatten() {
                Some(5) => {
                    if c == 38
                        && let Some(n) = byte(i + 2)
                    {
                        fg = Some(Ansi::Indexed(n));
                    }
                    i += 2;
                }
                Some(2) => {
                    if c == 38
                        && let (Some(r), Some(g), Some(b)) = (byte(i + 2), byte(i + 3), byte(i + 4))
                    {
                        fg = Some(Ansi::Rgb(r, g, b));
                    }
                    i += 4;
                }
                _ => {}
            },
            _ => {}
        }
        i += 1;
    }
    (fg, bold)
}

/// One line of program output as coloured runs: invalid UTF-8 replaced, a
/// tab as a space, SGR colours kept, every other escape sequence and
/// control character removed. A sequence cut off by the end of the line is
/// removed too. Never returns an empty list.
pub fn parse(bytes: &[u8]) -> Vec<Run> {
    let s = String::from_utf8_lossy(bytes);
    let mut chars = s.chars().peekable();
    let mut runs: Vec<Run> = Vec::new();
    let mut cur = Run::plain("");
    while let Some(c) = chars.next() {
        match c {
            '\x1b' => match chars.next() {
                Some('[') => {
                    let mut params = String::new();
                    let mut end = None;
                    for c in chars.by_ref() {
                        if ('\x40'..='\x7e').contains(&c) {
                            end = Some(c);
                            break;
                        }
                        // Bounded like the line: a parameter list longer
                        // than this is no colour anyone meant.
                        if params.len() < 64 {
                            params.push(c);
                        }
                    }
                    if end == Some('m') {
                        let (fg, bold) = sgr(&params, cur.fg, cur.bold);
                        if (fg, bold) != (cur.fg, cur.bold) {
                            if cur.text.is_empty() {
                                cur.fg = fg;
                                cur.bold = bold;
                            } else if runs.len() + 1 < MAX_RUNS {
                                let next = Run { text: String::new(), fg, bold };
                                runs.push(std::mem::replace(&mut cur, next));
                            }
                        }
                    }
                }
                Some(']') => {
                    while let Some(c) = chars.next() {
                        if c == '\x07' {
                            break;
                        }
                        if c == '\x1b' {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                    }
                }
                // ESC ( B and the like: one intermediate, one final byte.
                Some(c) if ('\x20'..='\x2f').contains(&c) => {
                    chars.next();
                }
                _ => {}
            },
            '\t' => cur.text.push(' '),
            c if c.is_control() => {}
            c => cur.text.push(c),
        }
    }
    if !cur.text.is_empty() || runs.is_empty() {
        runs.push(cur);
    }
    runs
}
```

In `Splitter`, change `out: &mut impl FnMut(String)` to `out: &mut impl FnMut(Vec<Run>)` in `feed` and `finish`, and replace the three `clean(...)` calls:

```rust
                if part.len() > room {
                    self.buf.extend_from_slice(&part[..room]);
                    let mut runs = parse(&self.buf);
                    // parse never returns an empty list.
                    if let Some(last) = runs.last_mut() {
                        last.text.push('…');
                    }
                    out(runs);
```

and `out(parse(&self.buf));` at the other two places.

In `Log::push`, print `line.plain()` instead of `line.text`. In `Log::note`, build `runs: vec![Run::plain(text)]`.

- [ ] **Step 4: Adapt the users.** In `jobs.rs` `pump`, change the closure to `let mut emit = |runs: Vec<Run>| feed.push(Line { time: local_time(), source: Some(source.clone()), runs, kind: Kind::Output })` and import `Run`. In `jobs.rs` tests replace each `l.text` with `l.plain()`. In `menu.rs` tests, `fn log` becomes `m.log.lines().map(|l| (l.kind, l.plain())).collect()`. In `ui.rs` test `a_log_line_is_drawn_below_the_tiles_with_its_time` build the line with `runs: vec![crate::log::Run::plain("hello-log")]`.

- [ ] **Step 5: Run the log tests, expect PASS**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 --lib log::`
Expected: PASS, including the 8 new tests.

- [ ] **Step 6: Write the failing UI test** in `ui.rs` `mod tests`:

```rust
    #[test]
    fn a_coloured_log_line_is_drawn_in_its_colours() {
        let mut menu = Menu::new(
            Grid {
                tiles: vec![plain_tile("T0")],
                banner: vec![],
            },
            false,
        );
        menu.log.push(crate::log::Line {
            time: "12:34:56".into(),
            source: Some("oxulnk".into()),
            runs: crate::log::parse(b"plain \x1b[33mYELLOWPART\x1b[0m end"),
            kind: crate::log::Kind::Output,
        });
        let ctx = egui::Context::default();
        Theme::dark().apply(&ctx);
        let input = egui::RawInput {
            screen_rect: Some(screen(1280.0, 720.0)),
            ..Default::default()
        };
        let mut out = None;
        for _ in 0..2 {
            let mut o = ctx.run_ui(input.clone(), |ui| {
                show(ui, &menu, &[None], Instant::now());
            });
            o.textures_delta.clear();
            out = Some(o);
        }
        let out = out.unwrap();
        let galley = out
            .shapes
            .iter()
            .find_map(|c| match &c.shape {
                egui::Shape::Text(t) if t.galley.text().contains("YELLOWPART") => Some(t.galley.clone()),
                _ => None,
            })
            .expect("log line drawn");
        let text = galley.text();
        let at = text.find("YELLOWPART").unwrap();
        let section = galley
            .job
            .sections
            .iter()
            .find(|s| s.byte_range.contains(&at))
            .unwrap();
        assert_eq!(section.format.color, ansi_color(Ansi::Basic(3)));
        assert!(!text.contains("[33m"), "{text}");
    }
```

Add `use crate::log::Ansi;` inside `mod tests` (or `use super::*` already covers it once Step 7 imports `Ansi` at file level).

- [ ] **Step 7: Implement the drawing** in `ui.rs`. Import `Ansi` and `Run` (`use crate::log::{Ansi, Kind, Line, Log, Run};`). Add:

```rust
/// The 16 basic terminal colours, picked to read on the dark log
/// background: black and blue are lightened, which a terminal's defaults
/// would leave nearly invisible here.
const ANSI16: [Color32; 16] = [
    Color32::from_rgb(0x6e, 0x6e, 0x6e),
    Color32::from_rgb(0xe0, 0x6c, 0x75),
    Color32::from_rgb(0x98, 0xc3, 0x79),
    Color32::from_rgb(0xe5, 0xc0, 0x7b),
    Color32::from_rgb(0x61, 0xaf, 0xef),
    Color32::from_rgb(0xc6, 0x78, 0xdd),
    Color32::from_rgb(0x56, 0xb6, 0xc2),
    Color32::from_rgb(0xd0, 0xd0, 0xd0),
    Color32::from_rgb(0x8a, 0x8a, 0x8a),
    Color32::from_rgb(0xff, 0x7b, 0x86),
    Color32::from_rgb(0xb5, 0xe8, 0x90),
    Color32::from_rgb(0xff, 0xd7, 0x87),
    Color32::from_rgb(0x82, 0xc4, 0xff),
    Color32::from_rgb(0xe0, 0x9c, 0xf5),
    Color32::from_rgb(0x7f, 0xd8, 0xe3),
    Color32::from_rgb(0xff, 0xff, 0xff),
];

pub fn ansi_color(a: Ansi) -> Color32 {
    match a {
        Ansi::Basic(n) => ANSI16[(n & 15) as usize],
        Ansi::Indexed(n @ 0..=15) => ANSI16[n as usize],
        Ansi::Indexed(n @ 16..=231) => {
            let level = [0u8, 95, 135, 175, 215, 255];
            let i = n - 16;
            Color32::from_rgb(level[(i / 36) as usize], level[(i / 6 % 6) as usize], level[(i % 6) as usize])
        }
        Ansi::Indexed(n) => {
            let g = 8 + 10 * (n - 232);
            Color32::from_rgb(g, g, g)
        }
        Ansi::Rgb(r, g, b) => Color32::from_rgb(r, g, b),
    }
}

/// A run's colour: its own, brightened when bold the way terminals do, or
/// the line's colour by kind; bold without a colour is the strong text.
fn run_color(run: &Run, line_color: Color32, t: &Theme) -> Color32 {
    match (run.fg, run.bold) {
        (Some(Ansi::Basic(n)), true) if n < 8 => ansi_color(Ansi::Basic(n + 8)),
        (Some(a), _) => ansi_color(a),
        (None, true) => t.palette.foreground,
        (None, false) => line_color,
    }
}
```

and change the end of `log_job` (after `job.append(&line.time, …)`):

```rust
    let mut lead = 16.0;
    if let Some(source) = &line.source {
        job.append(&format!("{source} | "), 16.0, muted);
        lead = 0.0;
    }
    for run in &line.runs {
        job.append(&run.text, lead, TextFormat::simple(font.clone(), run_color(run, text_color, t)));
        lead = 0.0;
    }
    job
```

(Keep whatever follows in `log_job` today that ends the function; the two old `job.append(&line.text, …)` calls go.)

- [ ] **Step 8: Run all crate tests, clippy, fmt**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo clippy --locked -j 4 --all-targets -- -D warnings && cargo fmt --check`
Expected: all PASS, no warnings, no diff.

- [ ] **Step 9: Commit**

```bash
git add src/dbrrg-menu/src
git commit -m "feat(menu): the log shows the colours programs write

Program output was cleaned of control characters only, so an SGR sequence
lost its ESC and showed as [33m. Lines are now parsed into coloured runs:
SGR foreground (16, 256, RGB) and bold are kept, every other escape
sequence is removed whole, one cut off at the end of the line too. At most
64 runs per line. The session log copy stays plain text.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `X-DBRRG-Multiple` tile key

**Files:**
- Modify: `src/dbrrg-menu/src/tiles.rs` (Tile field, `tile_from`, `Tile::broken`, `SHIPPED_ONLY_KEYS`, tests)
- Modify: `src/dbrrg-menu/src/ui.rs` (test `Tile { … }` literals get `multiple: false`)
- Modify: `overlay/etc/dbrrg/menu/10-thinlinc.desktop`, `20-oxulnk.desktop`, `30-terminal.desktop`

**Interfaces:**
- Consumes: nothing.
- Produces: `Tile.multiple: bool` — true only for `Action::Run` tiles whose file sets `X-DBRRG-Multiple=true`; a user file rewording a shipped tile cannot set it.

- [ ] **Step 1: Write the failing tests** in `tiles.rs` `mod tests`:

```rust
    #[test]
    fn multiple_only_on_run_tiles() {
        let tiles = merge(
            &[
                src("10-a.desktop", "[Desktop Entry]\nName=A\nExec=a\nX-DBRRG-Multiple=true\n"),
                src("20-b.desktop", "[Desktop Entry]\nName=B\nExec=b\n"),
                src(
                    "40-save-home.desktop",
                    "[Desktop Entry]\nName=S\nX-DBRRG-Action=save-home\nX-DBRRG-Multiple=true\n",
                ),
            ],
            &[src("70-u.desktop", "[Desktop Entry]\nName=U\nExec=u\nX-DBRRG-Multiple=true\n")],
        );
        assert!(tiles[0].multiple);
        assert!(!tiles[1].multiple, "default is one at a time");
        assert!(!tiles[2].multiple, "not on save-home");
        assert!(tiles[3].multiple, "a user's own run tile may set it");
    }

    #[test]
    fn the_shipped_program_tiles_allow_several_copies() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../overlay/etc/dbrrg/menu");
        let read = |f: &str| {
            let text = std::fs::read_to_string(dir.join(f)).unwrap();
            merge(&[src(f, &text)], &[]).remove(0)
        };
        for f in ["10-thinlinc.desktop", "20-oxulnk.desktop", "30-terminal.desktop"] {
            assert!(read(f).multiple, "{f}");
        }
        for f in ["40-save-home.desktop", "50-upgrade-image.desktop", "80-logout.desktop"] {
            assert!(!read(f).multiple, "{f}");
        }
    }
```

Extend `user_file_rewords_name_comment_icon_only`: add `\nX-DBRRG-Multiple=false` to the user file text, add `assert!(!t.multiple);` (the shipped `thinlinc()` helper has no Multiple key), and append `"X-DBRRG-Multiple".into()` to the expected `ignored` list.

- [ ] **Step 2: Run, expect compile failure**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 --lib tiles::`
Expected: FAIL to compile (`no field multiple`).

- [ ] **Step 3: Implement.** In `struct Tile` after `save_on_exit`:

```rust
    /// Whether the tile may run again while a copy of it still runs.
    pub multiple: bool,
```

In `Tile::broken` add `multiple: false,`. In `tile_from` after `save_on_exit`:

```rust
        // Only a program can run twice; the other actions are one at a time.
        multiple: action == Action::Run && flag(entry, "X-DBRRG-Multiple"),
```

Change the constant:

```rust
const SHIPPED_ONLY_KEYS: [&str; 5] = [
    "Exec",
    "Terminal",
    "X-DBRRG-Action",
    "X-DBRRG-Save-On-Exit",
    "X-DBRRG-Multiple",
];
```

In `ui.rs` tests add `multiple: false,` to every `Tile { … }` literal (three places: `tile_text_stays_on_one_line_inside_its_tile`, `a_log_line_is_drawn_below_the_tiles_with_its_time`, `plain_tile`).

Append `X-DBRRG-Multiple=true` as the last line of `overlay/etc/dbrrg/menu/10-thinlinc.desktop`, `20-oxulnk.desktop` and `30-terminal.desktop`.

- [ ] **Step 4: Run all crate tests, clippy, fmt**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo clippy --locked -j 4 --all-targets -- -D warnings && cargo fmt --check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/dbrrg-menu/src overlay/etc/dbrrg/menu
git commit -m "feat(menu): X-DBRRG-Multiple lets a tile run while a copy of it runs

ThinLinc, oxulnk and Terminal set it. Only run tiles honour it, and a user
file that rewords a shipped tile cannot set it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Programs run in the background

One task because `Busy` is used by `menu.rs`, `ui.rs` and `app.rs`; the crate does not compile with only part of the change.

**Files:**
- Modify: `src/dbrrg-menu/src/jobs.rs` (`JobId`, `JobResult`, `Signal`, `stop`, `stop_target`, process group, `on_spawn`)
- Modify: `src/dbrrg-menu/src/menu.rs` (state machine rewrite, tests rewritten)
- Modify: `src/dbrrg-menu/src/ui.rs` (dialogs, tile enable + status label)
- Modify: `src/dbrrg-menu/src/app.rs` (start/Started/Signal, `choose(c, now)`, `dialog()`, `refuses_input()`)

**Interfaces:**
- Consumes: `Tile.multiple`, `Tile.save_on_exit` (Task 3); `Line.plain()` (Task 2).
- Produces (`jobs.rs`):
  - `pub type JobId = u64;`
  - `pub enum JobResult { Saved(SaveOutcome), Started { id: JobId, pgid: i32 }, Ran { id: JobId, status: Result<Option<i32>, String> } }`
  - `#[derive(Debug, Clone, Copy, PartialEq, Eq)] pub enum Signal { Term, Kill }`
  - `pub fn stop_target(pgid: i32) -> Option<i32>` — `Some(-pgid)` for `pgid > 1`, else `None`.
  - `pub fn stop(pgid: i32, signal: Signal)`
  - `pub fn run(id: JobId, name: &str, argv: &[String], feed: &Arc<Feed>, on_spawn: impl FnOnce(i32)) -> JobResult`
- Produces (`menu.rs`):
  - `pub const STOP_GRACE: Duration = Duration::from_secs(5);`
  - `pub struct Running { pub id: JobId, pub tile: usize, pub name: String, pub pgid: Option<i32> }`
  - `pub struct SaveState { pub running: bool, pub again: bool }`
  - `pub enum Logout { Confirm, Stopping { kill_at: Instant, killed: bool }, WaitSave, Saving { since: Instant }, Failed { message: String }, Leaving { until: Instant } }`
  - `pub enum Choice { Stay, StopAndLogOut, LogOutAnyway }`
  - `pub enum Job { Save, Run { id: JobId, name: String, argv: Vec<String> } }`
  - `pub enum Effect { Start(Job), Signal(Vec<i32>, Signal), Exit(i32) }`
  - `Menu { pub tiles, pub banner, pub jobs: Vec<Running>, pub save: SaveState, pub logout: Option<Logout>, pub log, .. }`
  - `Menu::dialog(&self) -> bool`, `Menu::refuses_input(&self) -> bool`, `Menu::can_activate(&self, index: usize) -> bool`, `Menu::status(&self, index: usize) -> Option<String>`, `Menu::activate(&mut self, index, now) -> Option<Effect>`, `Menu::finished(&mut self, JobResult, now) -> Option<Effect>`, `Menu::choose(&mut self, Choice, now) -> Option<Effect>`, `Menu::tick(&mut self, now) -> Option<Effect>`.

- [ ] **Step 1: Write the failing `jobs.rs` tests.** Adapt every existing `run(...)` call in `jobs.rs` tests from `run("Tool", &argv, false, &feed)` to `run(1, "Tool", &argv, &feed, |_| {})`, and match `JobResult::Ran { status, .. }` as before. Add:

```rust
    #[test]
    fn stop_target_refuses_0_and_1() {
        // kill(-0) is the menu's own group, kill(-1) every process the user
        // owns. A pgid that is not known yet must never reach kill.
        assert_eq!(stop_target(0), None);
        assert_eq!(stop_target(1), None);
        assert_eq!(stop_target(-5), None);
        assert_eq!(stop_target(4242), Some(-4242));
    }

    #[test]
    fn stopping_the_group_ends_the_program_and_its_background_child() {
        let feed = Arc::new(Feed::default());
        let (tx, rx) = std::sync::mpsc::channel();
        let f = feed.clone();
        let worker = std::thread::spawn(move || {
            run(1, "Tool", &sh("sleep 30 & echo child $!; wait"), &f, move |pgid| {
                let _ = tx.send(pgid);
            })
        });
        let pgid = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // Wait for the child's pid in the output.
        let mut child = None;
        let t0 = Instant::now();
        while child.is_none() && t0.elapsed() < Duration::from_secs(5) {
            child = feed
                .drain()
                .into_iter()
                .find_map(|l| l.plain().strip_prefix("child ").and_then(|p| p.parse::<i32>().ok()));
            std::thread::sleep(Duration::from_millis(20));
        }
        let child = child.expect("child pid printed");
        stop(pgid, Signal::Term);
        let JobResult::Ran { status, .. } = worker.join().unwrap() else {
            panic!()
        };
        assert_eq!(status, Ok(None), "ended by the signal");
        let t0 = Instant::now();
        // SAFETY: signal 0 only checks that the process exists.
        while unsafe { libc::kill(child, 0) } == 0 && t0.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_ne!(unsafe { libc::kill(child, 0) }, 0, "the background child ended too");
    }

    #[test]
    fn stopping_a_finished_group_does_nothing() {
        let feed = Arc::new(Feed::default());
        let mut pgid = 0;
        run(1, "Tool", &sh("exit 0"), &feed, |p| pgid = p);
        assert!(pgid > 1);
        stop(pgid, Signal::Kill);
    }
```

- [ ] **Step 2: Implement `jobs.rs`.** Replace `JobResult` and `run`, add `JobId`, `Signal`, `stop_target`, `stop`, and give `run_logged` an `on_spawn` parameter:

```rust
/// Names one started program, so its start, its output and its end can be
/// matched while others run.
pub type JobId = u64;

/// What finished, handed back to the event loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobResult {
    Saved(SaveOutcome),
    /// The program runs, in a process group of its own with this id.
    Started { id: JobId, pgid: i32 },
    /// `status` is the exit code, `Ok(None)` for a signal, `Err` when the
    /// program could not be started.
    Ran {
        id: JobId,
        status: Result<Option<i32>, String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Term,
    Kill,
}

/// The `kill` target for a process group, or `None` when the id cannot be
/// one this menu started: 0 would signal the menu's own group and 1 (as -1)
/// every process of the user.
pub fn stop_target(pgid: i32) -> Option<i32> {
    (pgid > 1).then_some(-pgid)
}

/// Signal a program and everything it started. A group that is already
/// gone is not an error.
pub fn stop(pgid: i32, signal: Signal) {
    let Some(target) = stop_target(pgid) else { return };
    let sig = match signal {
        Signal::Term => libc::SIGTERM,
        Signal::Kill => libc::SIGKILL,
    };
    // SAFETY: kill has no memory preconditions; ESRCH is ignored.
    unsafe {
        libc::kill(target, sig);
    }
}
```

`run_logged` gains `on_spawn: impl FnOnce(u32)` as last parameter and calls `on_spawn(child.id());` right after `spawn()?`. `save` passes `|_| {}` (the save is not in a group of its own and is never stopped). Then:

```rust
/// Run a tile's program and wait for it; its output goes to the log under
/// the tile's name. The program gets a process group of its own, whose id
/// `on_spawn` receives before the wait, so a logout can stop it together
/// with everything it started.
pub fn run(id: JobId, name: &str, argv: &[String], feed: &Arc<Feed>, on_spawn: impl FnOnce(i32)) -> JobResult {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]).process_group(0);
    let status = run_logged(cmd, name, feed, |pid| on_spawn(pid as i32))
        .map(|st| st.code())
        .map_err(|e| format!("{} could not be started: {e}", argv[0]));
    JobResult::Ran { id, status }
}
```

Update the module doc comment: programs now run in the background, several at once.

- [ ] **Step 3: Write the failing `menu.rs` tests.** Replace the whole `mod tests` body after `grid()` with the tests below. In `grid()`, add `X-DBRRG-Multiple=true\n` to the Terminal entry (tiles: 0 ThinLinc Save-On-Exit, 1 Terminal Multiple, 2 Back up home, 3 Log out). Keep the helpers `log`, `ev`, `warn`.

```rust
    fn started(m: &mut Menu, index: usize, now: Instant) -> JobId {
        let Some(Effect::Start(Job::Run { id, .. })) = m.activate(index, now) else {
            panic!("tile {index} did not start")
        };
        m.finished(JobResult::Started { id, pgid: 1000 + id as i32 }, now);
        id
    }

    fn ran(m: &mut Menu, id: JobId, code: i32, now: Instant) -> Option<Effect> {
        m.finished(JobResult::Ran { id, status: Ok(Some(code)) }, now)
    }

    #[test]
    fn programs_run_side_by_side() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let a = started(&mut m, 0, now);
        let b = started(&mut m, 1, now);
        assert_eq!(m.jobs.len(), 2);
        assert!(m.can_activate(2), "save while programs run");
        assert!(!m.dialog());
        ran(&mut m, b, 0, now);
        assert_eq!(m.jobs.iter().map(|j| j.id).collect::<Vec<_>>(), [a]);
    }

    #[test]
    fn a_tile_without_multiple_runs_once() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        started(&mut m, 0, now);
        assert!(!m.can_activate(0));
        assert_eq!(m.activate(0, now), None);
        assert_eq!(m.status(0).as_deref(), Some("running"));
    }

    #[test]
    fn a_multiple_tile_runs_again_and_counts() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        started(&mut m, 1, now);
        started(&mut m, 1, now);
        assert!(m.can_activate(1));
        assert_eq!(m.status(1).as_deref(), Some("2 running"));
        assert_eq!(m.status(2), None);
    }

    #[test]
    fn save_on_exit_saves_in_the_background() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let a = started(&mut m, 0, now);
        assert_eq!(ran(&mut m, a, 1, now), Some(Effect::Start(Job::Save)));
        assert!(!m.dialog(), "no dialog for a background save");
        assert!(m.save.running);
        assert_eq!(m.status(2).as_deref(), Some("running"));
        assert!(!m.can_activate(2));
        assert_eq!(m.finished(JobResult::Saved(SaveOutcome::ServerUnreachable), now), None);
        assert!(!m.save.running);
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
    fn requests_during_a_save_give_exactly_one_more() {
        let mut g = grid();
        // A second Save-On-Exit tile that may run twice.
        g.tiles[0].multiple = true;
        let mut m = Menu::new(g, false);
        let now = Instant::now();
        let a = started(&mut m, 0, now);
        let b = started(&mut m, 0, now);
        let c = started(&mut m, 0, now);
        assert_eq!(ran(&mut m, a, 0, now), Some(Effect::Start(Job::Save)));
        assert_eq!(ran(&mut m, b, 0, now), None, "queued");
        assert_eq!(ran(&mut m, c, 0, now), None, "still one queued");
        assert_eq!(
            m.finished(JobResult::Saved(SaveOutcome::Saved), now),
            Some(Effect::Start(Job::Save)),
            "one more"
        );
        assert_eq!(m.finished(JobResult::Saved(SaveOutcome::Saved), now), None, "and no third");
        assert!(!m.save.running);
    }

    #[test]
    fn failed_restore_greys_save_and_skips_save_on_exit() {
        let mut m = Menu::new(grid(), true);
        assert_eq!(m.tiles[2].problem.as_deref(), Some(RESTORE_FAILED_REASON));
        let now = Instant::now();
        assert!(!m.can_activate(2));
        let a = started(&mut m, 0, now);
        assert_eq!(ran(&mut m, a, 0, now), None);
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
    fn logout_with_nothing_running_saves_then_exits_zero_after_the_pause() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.activate(3, now), Some(Effect::Start(Job::Save)));
        assert_eq!(m.logout, Some(Logout::Saving { since: now }));
        assert!(m.refuses_input());
        assert_eq!(m.finished(JobResult::Saved(SaveOutcome::Saved), now), None);
        assert_eq!(log(&m), [ev("Saving the home directory…"), ev("Home directory saved.")]);
        assert_eq!(m.tick(now), None, "the result is shown first");
        assert_eq!(m.tick(now + LOGOUT_PAUSE), Some(Effect::Exit(0)));
    }

    #[test]
    fn logout_with_programs_asks_and_stay_returns() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        started(&mut m, 1, now);
        assert_eq!(m.activate(3, now), None);
        assert_eq!(m.logout, Some(Logout::Confirm));
        assert!(m.dialog() && !m.refuses_input(), "the dialog has buttons");
        assert!(!m.can_activate(1), "the grid is frozen");
        assert_eq!(m.choose(Choice::Stay, now), None);
        assert_eq!(m.logout, None);
        assert_eq!(m.jobs.len(), 1, "nothing stopped");
    }

    #[test]
    fn stop_them_terms_each_group_then_saves() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let a = started(&mut m, 0, now);
        let b = started(&mut m, 1, now);
        m.activate(3, now);
        assert_eq!(
            m.choose(Choice::StopAndLogOut, now),
            Some(Effect::Signal(vec![1000 + a as i32, 1000 + b as i32], Signal::Term))
        );
        assert_eq!(m.logout, Some(Logout::Stopping { kill_at: now + STOP_GRACE, killed: false }));
        assert_eq!(ran(&mut m, a, 0, now), None, "Save-On-Exit is not acted on while stopping");
        assert!(!m.save.running);
        assert_eq!(
            m.finished(JobResult::Ran { id: b, status: Ok(None) }, now),
            Some(Effect::Start(Job::Save)),
            "the last one gone: the logout save"
        );
        assert_eq!(m.logout, Some(Logout::Saving { since: now }));
    }

    #[test]
    fn a_program_ignoring_term_is_killed_at_the_deadline() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let a = started(&mut m, 1, now);
        m.activate(3, now);
        m.choose(Choice::StopAndLogOut, now);
        assert_eq!(m.tick(now + STOP_GRACE / 2), None);
        assert_eq!(
            m.tick(now + STOP_GRACE),
            Some(Effect::Signal(vec![1000 + a as i32], Signal::Kill))
        );
        assert_eq!(m.tick(now + STOP_GRACE * 2), None, "killed once");
        assert_eq!(m.finished(JobResult::Ran { id: a, status: Ok(None) }, now), Some(Effect::Start(Job::Save)));
    }

    #[test]
    fn a_program_started_late_is_stopped_when_its_group_is_known() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let Some(Effect::Start(Job::Run { id, .. })) = m.activate(1, now) else {
            panic!()
        };
        m.activate(3, now);
        assert_eq!(m.choose(Choice::StopAndLogOut, now), Some(Effect::Signal(vec![], Signal::Term)));
        assert_eq!(
            m.finished(JobResult::Started { id, pgid: 77 }, now),
            Some(Effect::Signal(vec![77], Signal::Term))
        );
        m.tick(now + STOP_GRACE);
        let Some(Effect::Start(Job::Run { id: late, .. })) = ({
            m.logout = None;
            m.activate(1, now)
        }) else {
            panic!()
        };
        m.activate(3, now);
        m.choose(Choice::StopAndLogOut, now);
        m.tick(now + STOP_GRACE);
        assert_eq!(
            m.finished(JobResult::Started { id: late, pgid: 78 }, now),
            Some(Effect::Signal(vec![78], Signal::Kill)),
            "after the deadline, straight to SIGKILL"
        );
    }

    #[test]
    fn logout_waits_for_a_background_save_then_saves() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.activate(2, now), Some(Effect::Start(Job::Save)));
        assert_eq!(m.activate(3, now), None);
        assert_eq!(m.logout, Some(Logout::WaitSave));
        assert_eq!(
            m.finished(JobResult::Saved(SaveOutcome::Saved), now),
            Some(Effect::Start(Job::Save)),
            "the logout's own save"
        );
        assert_eq!(m.logout, Some(Logout::Saving { since: now }));
        m.finished(JobResult::Saved(SaveOutcome::Saved), now);
        assert!(matches!(m.logout, Some(Logout::Leaving { .. })));
    }

    #[test]
    fn failed_logout_save_asks_and_stay_returns_to_the_grid() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(3, now);
        m.finished(JobResult::Saved(SaveOutcome::ServerUnreachable), now);
        assert_eq!(
            m.logout,
            Some(Logout::Failed {
                message: SaveOutcome::ServerUnreachable.message()
            })
        );
        assert_eq!(m.tick(now + LOGOUT_PAUSE * 10), None, "never exits by itself");
        assert_eq!(m.activate(1, now), None, "the grid is refused while asking");
        assert_eq!(m.choose(Choice::Stay, now), None);
        assert_eq!(m.logout, None);
    }

    #[test]
    fn failed_logout_save_can_log_out_anyway() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        m.activate(3, now);
        m.finished(JobResult::Saved(SaveOutcome::Failed), now);
        assert_eq!(m.choose(Choice::LogOutAnyway, now), Some(Effect::Exit(0)));
    }

    #[test]
    fn logout_after_a_failed_restore_asks_without_saving() {
        let mut m = Menu::new(grid(), true);
        let now = Instant::now();
        assert_eq!(m.activate(3, now), None, "no save job started");
        assert!(matches!(m.logout, Some(Logout::Failed { .. })));
        assert_eq!(log(&m), [warn(&SaveOutcome::RestoreFailed.message())]);
        assert_eq!(m.choose(Choice::LogOutAnyway, now), Some(Effect::Exit(0)));
    }

    #[test]
    fn choice_outside_the_question_is_ignored() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.choose(Choice::LogOutAnyway, now), None);
        assert_eq!(m.choose(Choice::StopAndLogOut, now), None);
        assert_eq!(m.logout, None);
    }

    #[test]
    fn unstartable_program_is_reported_and_removed() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let Some(Effect::Start(Job::Run { id, .. })) = m.activate(1, now) else {
            panic!()
        };
        m.finished(JobResult::Ran { id, status: Err("foot could not be started: x".into()) }, now);
        assert_eq!(log(&m)[1], warn("foot could not be started: x."));
        assert!(m.jobs.is_empty());
    }

    #[test]
    fn a_signal_is_a_warning() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        let id = started(&mut m, 1, now);
        m.finished(JobResult::Ran { id, status: Ok(None) }, now);
        assert_eq!(log(&m)[1], warn("Terminal was killed by a signal."));
    }

    #[test]
    fn an_unknown_job_id_is_ignored() {
        let mut m = Menu::new(grid(), false);
        let now = Instant::now();
        assert_eq!(m.finished(JobResult::Ran { id: 99, status: Ok(Some(0)) }, now), None);
        assert_eq!(m.finished(JobResult::Started { id: 99, pgid: 5 }, now), None);
        assert!(log(&m).is_empty());
    }

    #[test]
    fn the_banner_opens_the_log_as_warnings() {
        let mut g = grid();
        g.banner = vec!["Your own tiles could not be read.".into()];
        let m = Menu::new(g, false);
        assert_eq!(log(&m), [warn("Your own tiles could not be read.")]);
        assert_eq!(m.banner.len(), 1, "--check still prints it");
    }
```

Add `use crate::jobs::{JobId, Signal};` to `mod tests` if not covered by `use super::*`.

- [ ] **Step 4: Implement `menu.rs`.** Replace everything from `pub enum SaveFor` down to the end of `impl Menu` (keep `LOGOUT_PAUSE`, `RESTORE_FAILED_REASON`, `SAVING`, `run_message`, `save_message`). Imports: `use crate::jobs::{JobId, JobResult, SaveOutcome, Signal};`. Update the module doc: several programs run at once; the dialog shows only during logout.

```rust
/// How long programs get to end after SIGTERM before SIGKILL, at logout.
pub const STOP_GRACE: Duration = Duration::from_secs(5);

/// A program a tile started that has not ended yet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Running {
    pub id: JobId,
    pub tile: usize,
    pub name: String,
    /// Known once the worker reports the start.
    pub pgid: Option<i32>,
}

/// The background save: one at a time, and one more at most queued.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SaveState {
    pub running: bool,
    pub again: bool,
}

/// The steps of a logout. While one is set the dialog is up and the grid
/// frozen behind it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Logout {
    /// Programs still run: Stay, or Stop them and log out.
    Confirm,
    /// SIGTERM sent; SIGKILL at `kill_at` to what is left.
    Stopping { kill_at: Instant, killed: bool },
    /// The programs are gone; a background save is still running.
    WaitSave,
    /// The logout save runs.
    Saving { since: Instant },
    /// The logout save did not happen: Stay, or Log out anyway.
    Failed { message: String },
    /// Saved; the menu exits 0 at `until`.
    Leaving { until: Instant },
}

impl Logout {
    /// The steps without buttons drop input before egui sees it.
    fn refuses_input(&self) -> bool {
        !matches!(self, Logout::Confirm | Logout::Failed { .. })
    }
}

/// The answers the logout dialog offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    Stay,
    StopAndLogOut,
    LogOutAnyway,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Job {
    Save,
    Run { id: JobId, name: String, argv: Vec<String> },
}

/// What the event loop must do after a state change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Start(Job),
    /// Send the signal to each of these process groups.
    Signal(Vec<i32>, Signal),
    Exit(i32),
}

pub struct Menu {
    pub tiles: Vec<Tile>,
    pub banner: Vec<String>,
    pub jobs: Vec<Running>,
    pub save: SaveState,
    pub logout: Option<Logout>,
    /// What happened, for the log under the grid.
    pub log: Log,
    restore_failed: bool,
    next_id: JobId,
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
            jobs: Vec::new(),
            save: SaveState::default(),
            logout: None,
            log,
            restore_failed,
            next_id: 1,
        }
    }

    /// Whether the dialog is up, so the grid behind it is frozen and dimmed.
    pub fn dialog(&self) -> bool {
        self.logout.is_some()
    }

    /// Whether input is dropped before egui sees it.
    pub fn refuses_input(&self) -> bool {
        self.logout.as_ref().is_some_and(Logout::refuses_input)
    }

    fn running(&self, tile: usize) -> usize {
        self.jobs.iter().filter(|j| j.tile == tile).count()
    }

    pub fn can_activate(&self, index: usize) -> bool {
        let Some(tile) = self.tiles.get(index) else { return false };
        if self.logout.is_some() || !tile.usable() {
            return false;
        }
        match tile.action {
            Action::Run => tile.multiple || self.running(index) == 0,
            Action::SaveHome => !self.save.running,
            Action::Logout => true,
        }
    }

    /// What the tile shows besides its text while it is at work.
    pub fn status(&self, index: usize) -> Option<String> {
        match self.running(index) {
            0 if self.tiles.get(index)?.action == Action::SaveHome && self.save.running => Some("running".into()),
            0 => None,
            1 => Some("running".into()),
            n => Some(format!("{n} running")),
        }
    }

    pub fn activate(&mut self, index: usize, now: Instant) -> Option<Effect> {
        if !self.can_activate(index) {
            return None;
        }
        let tile = self.tiles[index].clone();
        match tile.action {
            Action::Run => {
                let id = self.next_id;
                self.next_id += 1;
                self.log.note(Kind::Event, format!("{} started.", tile.name));
                self.jobs.push(Running {
                    id,
                    tile: index,
                    name: tile.name.clone(),
                    pgid: None,
                });
                Some(Effect::Start(Job::Run {
                    id,
                    name: tile.name.clone(),
                    argv: crate::tiles::command_line(&tile),
                }))
            }
            Action::SaveHome => self.request_save(),
            Action::Logout => {
                if self.jobs.is_empty() {
                    self.logout_after_jobs(now)
                } else {
                    self.logout = Some(Logout::Confirm);
                    None
                }
            }
        }
    }

    /// Start a background save, or queue one more behind the running one.
    fn request_save(&mut self) -> Option<Effect> {
        if self.save.running {
            self.save.again = true;
            return None;
        }
        self.save.running = true;
        self.log.note(Kind::Event, SAVING);
        Some(Effect::Start(Job::Save))
    }

    /// The programs are gone: wait for a background save, or save now.
    fn logout_after_jobs(&mut self, now: Instant) -> Option<Effect> {
        // A save that is refused anyway is not attempted: the person is
        // asked straight away.
        if self.restore_failed {
            let message = SaveOutcome::RestoreFailed.message();
            self.log.note(Kind::Warn, message.clone());
            self.logout = Some(Logout::Failed { message });
            return None;
        }
        if self.save.running {
            // The logout save follows; a queued one would only repeat it.
            self.save.again = false;
            self.logout = Some(Logout::WaitSave);
            return None;
        }
        self.save.running = true;
        self.log.note(Kind::Event, SAVING);
        self.logout = Some(Logout::Saving { since: now });
        Some(Effect::Start(Job::Save))
    }

    fn pgids(&self) -> Vec<i32> {
        self.jobs.iter().filter_map(|j| j.pgid).collect()
    }

    pub fn finished(&mut self, result: JobResult, now: Instant) -> Option<Effect> {
        match result {
            JobResult::Started { id, pgid } => {
                let job = self.jobs.iter_mut().find(|j| j.id == id)?;
                job.pgid = Some(pgid);
                // Stop was asked before this program's group was known.
                match self.logout {
                    Some(Logout::Stopping { killed, .. }) => {
                        let sig = if killed { Signal::Kill } else { Signal::Term };
                        Some(Effect::Signal(vec![pgid], sig))
                    }
                    _ => None,
                }
            }
            JobResult::Ran { id, status } => {
                let pos = self.jobs.iter().position(|j| j.id == id)?;
                let job = self.jobs.remove(pos);
                let (kind, text) = run_message(&job.name, &status);
                self.log.note(kind, text);
                if let Some(Logout::Stopping { .. }) = self.logout {
                    return if self.jobs.is_empty() {
                        self.logout_after_jobs(now)
                    } else {
                        None
                    };
                }
                if !self.tiles[job.tile].save_on_exit {
                    return None;
                }
                if self.restore_failed {
                    self.log.note(Kind::Warn, SaveOutcome::RestoreFailed.message());
                    return None;
                }
                self.request_save()
            }
            JobResult::Saved(outcome) => {
                self.save.running = false;
                let (kind, text) = save_message(&outcome);
                self.log.note(kind, text);
                match self.logout {
                    Some(Logout::Saving { .. }) => {
                        self.logout = Some(if outcome.saved() {
                            Logout::Leaving {
                                until: now + LOGOUT_PAUSE,
                            }
                        } else {
                            Logout::Failed {
                                message: outcome.message(),
                            }
                        });
                        None
                    }
                    Some(Logout::WaitSave) => self.logout_after_jobs(now),
                    _ if self.save.again => {
                        self.save.again = false;
                        self.request_save()
                    }
                    _ => None,
                }
            }
        }
    }

    /// An answer in the logout dialog. Ignored when it does not fit the step.
    pub fn choose(&mut self, choice: Choice, now: Instant) -> Option<Effect> {
        match (&self.logout, choice) {
            (Some(Logout::Confirm | Logout::Failed { .. }), Choice::Stay) => {
                self.logout = None;
                None
            }
            (Some(Logout::Confirm), Choice::StopAndLogOut) => {
                if self.jobs.is_empty() {
                    return self.logout_after_jobs(now);
                }
                let names: Vec<&str> = self.jobs.iter().map(|j| j.name.as_str()).collect();
                self.log.note(Kind::Event, format!("Stopping {}.", names.join(", ")));
                self.logout = Some(Logout::Stopping {
                    kill_at: now + STOP_GRACE,
                    killed: false,
                });
                Some(Effect::Signal(self.pgids(), Signal::Term))
            }
            // The failure is in the log already, from when it happened.
            (Some(Logout::Failed { .. }), Choice::LogOutAnyway) => Action::Logout.exit_code().map(Effect::Exit),
            _ => None,
        }
    }

    /// Called on every frame: kills what did not stop in time, and ends the
    /// menu once "saved" has been shown for `LOGOUT_PAUSE`.
    pub fn tick(&mut self, now: Instant) -> Option<Effect> {
        match self.logout {
            Some(Logout::Leaving { until }) if now >= until => Action::Logout.exit_code().map(Effect::Exit),
            Some(Logout::Stopping { kill_at, killed: false }) if now >= kill_at => {
                self.logout = Some(Logout::Stopping { kill_at, killed: true });
                self.log.note(Kind::Warn, "Programs did not stop in time; killing them.");
                Some(Effect::Signal(self.pgids(), Signal::Kill))
            }
            _ => None,
        }
    }
}
```

Note the test `stop_them_terms_each_group_then_saves` expects the log to gain "Stopping ThinLinc, Terminal." — it does not assert the log, so the line is free to stay.

- [ ] **Step 5: Adapt `ui.rs`.** Change the import to `use crate::menu::{Choice, Logout, Menu};`. Replace the `match &menu.busy { … }` block at the top of `show` with:

```rust
    match &menu.logout {
        Some(Logout::Confirm) => {
            let mut chose = None;
            dialog(ui, "Programs are still running", |ui, t| {
                for job in &menu.jobs {
                    ui.label(egui::RichText::new(&job.name).color(t.palette.foreground));
                }
                ui.label(
                    egui::RichText::new("They are stopped before the home directory is saved.")
                        .color(t.palette.muted_foreground),
                );
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.add(Button::new("Stay")).clicked() {
                        chose = Some(Choice::Stay);
                    }
                    if ui
                        .add(Button::new("Stop them and log out").variant(ButtonVariant::Destructive))
                        .clicked()
                    {
                        chose = Some(Choice::StopAndLogOut);
                    }
                });
            });
            return chose.map(UiEvent::Chose);
        }
        Some(Logout::Stopping { kill_at, .. }) => {
            dialog(ui, "Stopping programs", |ui, t| {
                for job in &menu.jobs {
                    ui.label(egui::RichText::new(&job.name).color(t.palette.muted_foreground));
                }
            });
            // Wake for the SIGKILL deadline without any input.
            ui.ctx()
                .request_repaint_after(kill_at.saturating_duration_since(now).min(Duration::from_secs(1)));
            return None;
        }
        Some(Logout::WaitSave) => {
            dialog(ui, "Saving your home directory before logging out", |ui, t| {
                ui.label(egui::RichText::new("Waiting for the backup that is running.").color(t.palette.muted_foreground));
            });
            return None;
        }
        Some(Logout::Saving { since }) => {
            dialog(ui, "Saving your home directory before logging out", |ui, t| {
                ui.label(
                    egui::RichText::new(elapsed(now.duration_since(*since)))
                        .size(28.0)
                        .monospace()
                        .color(t.palette.ring),
                );
                ui.label(
                    egui::RichText::new("On a network-booted machine this can take a minute.")
                        .color(t.palette.muted_foreground),
                );
            });
            ui.ctx().request_repaint_after(Duration::from_secs(1));
            return None;
        }
        Some(Logout::Leaving { until }) => {
            dialog(ui, "Home directory saved", |ui, t| {
                ui.label(egui::RichText::new("Logging out.").color(t.palette.muted_foreground));
            });
            ui.ctx().request_repaint_after(until.saturating_duration_since(now));
            return None;
        }
        Some(Logout::Failed { message }) => {
            // unchanged body of the former Busy::LogoutFailed arm
        }
        None => {}
    }
```

(Move the former `Busy::LogoutFailed` arm's body verbatim into `Some(Logout::Failed { message })`.)

In the grid loop replace `let enabled = tile.usable() && menu.busy == Busy::Idle;` with `let enabled = menu.can_activate(index);` and pass `menu.status(index).as_deref()` as a new last argument to `paint_tile`. In `paint_tile` add the parameter `status: Option<&str>` and, after the `if tile.origin == Origin::User { … }` block:

```rust
    if let Some(status) = status {
        p.text(
            rect.left_top() + vec2(8.0, 6.0),
            Align2::LEFT_TOP,
            status,
            FontId::monospace(11.0),
            t.palette.ring,
        );
    }
```

A tile at work that may not run again is not usable now, so draw it with the muted colours as before: `paint_tile` receives `enabled` already through `hovered`; leave the greying as it is (driven by `tile.usable()`), the status text is what tells "running" from "unusable".

Add a UI test:

```rust
    #[test]
    fn a_running_tile_shows_its_status() {
        let mut t1 = plain_tile("T1");
        t1.multiple = true;
        let mut menu = Menu::new(
            Grid {
                tiles: vec![plain_tile("T0"), t1],
                banner: vec![],
            },
            false,
        );
        let now = Instant::now();
        menu.activate(0, now);
        menu.activate(1, now);
        menu.activate(1, now);
        let ctx = egui::Context::default();
        Theme::dark().apply(&ctx);
        let input = egui::RawInput {
            screen_rect: Some(screen(1280.0, 720.0)),
            ..Default::default()
        };
        let mut out = None;
        for _ in 0..2 {
            let mut o = ctx.run_ui(input.clone(), |ui| {
                show(ui, &menu, &[None, None], now);
            });
            o.textures_delta.clear();
            out = Some(o);
        }
        let texts: Vec<String> = out
            .unwrap()
            .shapes
            .iter()
            .filter_map(|c| match &c.shape {
                egui::Shape::Text(t) => Some(t.galley.text().to_string()),
                _ => None,
            })
            .collect();
        assert!(texts.iter().any(|t| t == "running"), "{texts:?}");
        assert!(texts.iter().any(|t| t == "2 running"), "{texts:?}");
    }
```

- [ ] **Step 6: Adapt `app.rs`.** Imports: `use crate::jobs::{self, JobResult, Paths};` stays. Replace `start`:

```rust
    fn start(&self, job: Job) {
        let proxy = self.proxy.clone();
        let feed = self.feed.clone();
        let paths = Paths {
            save_home: self.cfg.paths.save_home.clone(),
            state_dir: self.cfg.paths.state_dir.clone(),
        };
        std::thread::spawn(move || {
            let result = match job {
                Job::Save => JobResult::Saved(jobs::save(&paths, &feed)),
                Job::Run { id, name, argv } => {
                    let started = proxy.clone();
                    jobs::run(id, &name, &argv, &feed, move |pgid| {
                        let _ = started.send_event(Wake::Job(JobResult::Started { id, pgid }));
                    })
                }
            };
            // The loop is gone only when the menu is exiting; nothing to tell.
            let _ = proxy.send_event(Wake::Job(result));
        });
    }
```

In `apply` add the arm:

```rust
            Some(Effect::Signal(pgids, signal)) => {
                for pgid in pgids {
                    jobs::stop(pgid, signal);
                }
            }
```

In `redraw`: `let saving = self.cfg.menu.busy.dialog();` → `let saving = self.cfg.menu.dialog();`; `Some(ui::UiEvent::Chose(c)) => self.cfg.menu.choose(c),` → `self.cfg.menu.choose(c, now)`. In `window_event`: `self.cfg.menu.busy.refuses_input()` → `self.cfg.menu.refuses_input()`. Update the `DIM_KEEP` doc ("behind the logout dialog").

- [ ] **Step 7: Run all crate tests, clippy, fmt**

Run: `cd src/dbrrg-menu && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo test --locked -j 4 && CARGO_BUILD_JOBS=4 systemd-run --user --scope -q -p MemoryMax=2G -- cargo clippy --locked -j 4 --all-targets -- -D warnings && cargo fmt --check`
Expected: all PASS. If `cargo fmt --check` shows a diff, run `cargo fmt` and re-run.

- [ ] **Step 8: Mutation-check the two safety points.** Temporarily change `stop_target` to `Some(-pgid)` unconditionally — `stop_target_refuses_0_and_1` must FAIL (do NOT run any other test with this mutant; restore immediately). Temporarily make the `JobResult::Started` arm return `None` always — `a_program_started_late_is_stopped_when_its_group_is_known` must FAIL. Restore both, re-run Step 7.

- [ ] **Step 9: Commit**

```bash
git add src/dbrrg-menu/src
git commit -m "feat(menu): programs run in the background, several at once

One running program blocked every tile. Each program now runs in a
process group of its own while the grid stays usable; a tile runs again
only with X-DBRRG-Multiple. Saves run in the background, one at a time,
with at most one more queued. Logout with programs running asks Stay or
Stop them and log out: SIGTERM to each group, SIGKILL after 5 s, then the
logout save as before. Only logout shows a dialog.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation and gates

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.
- Produces: an image built from the branch, all gates green, a screenshot.

- [ ] **Step 1: Update `CLAUDE.md`.**
  - In "Customizing the System", Tiles bullet: after "may only `run` a program." add: "`X-DBRRG-Multiple=true` lets a run tile start again while a copy of it still runs (ThinLinc, oxulnk and Terminal set it); without it a tile runs once at a time. A user file rewording a shipped tile cannot set it."
  - Same section: in the `rc.xml` bullet ("Session/compositor"), add: "`rc.xml` also holds the window rule that keeps the window with app_id `dbrrg-menu` at the bottom (`ToggleAlwaysOnBottom`) and out of the taskbar (`skipTaskbar`)."
  - "Persistent Home Directory", the "On logout" bullet: replace "behind its dialog in three places" with the background model: saves from a Save-On-Exit tile and from Back up home run in the background, one at a time, at most one more queued; the Log out tile asks *Stay* / *Stop them and log out* when programs run (SIGTERM to each process group, SIGKILL after 5 s), waits for a running save, then saves behind its dialog before exiting 0 (a failed save asks Stay / Log out anyway).
  - Same rewording in the "Home Persistence" item of "Boot Flow Architecture" (item 5).
  - "Menu limits": remove "A tile whose program never exits and opens no window keeps the menu busy with no way to cancel." Add: "Program output keeps its SGR colours (16, 256, RGB, bold); other escape sequences are removed. At most 64 colour runs per line." Add: "Not seen on hardware: two programs at once, Stop them and log out, the colours of a real `oxulnk-desktop` log, the menu staying behind a clicked program."
  - "The menu's log" section: add one sentence on colours and that the session log copy is plain text.

- [ ] **Step 2: Build the image and run every gate.** Run each as its own command, `timeout: 600000`, in the background where it may exceed 10 min:

```bash
L=/scratch/oetiker/claude-tmp/dbrrg-build.lock; B=/scratch/oetiker/claude-tmp/dbrrg-build
flock $L make image        > $B/menu-bg-image.log 2>&1;   echo "image $?"
flock $L make test         > $B/menu-bg-test.log 2>&1;    echo "test $?"
flock $L make test-runtime > $B/menu-bg-runtime.log 2>&1; echo "runtime $?"
flock $L make qemu-smoke   > $B/menu-bg-smoke.log 2>&1;   echo "smoke $?"
```

Expected: all four exit 0. `grep -E '^(not ok|FAIL)'` on the test and runtime logs is empty; the test log contains `ok   - rc.xml keeps dbrrg-menu at the bottom and off the taskbar`; the smoke log ends in `PASSED - clean boot`.

- [ ] **Step 3: Screenshot.** With the scratchpad dir as `$S`:

```bash
timeout --kill-after=10 90 podman run --rm --cpus 4 -v $S/shot:/out:Z \
  -e WLR_BACKENDS=headless -e WLR_HEADLESS_OUTPUTS=1 -e WLR_RENDERER=pixman \
  dbrrg-runtime-test:3.0.0 sh -c 'export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p -m 700 $XDG_RUNTIME_DIR; labwc -C /etc/dbrrg/labwc -S "sh -c \"(timeout 10 dbrrg-menu &) ; sleep 5; grim /out/menu-bg.png; echo grim-rc=\$?\""'
```

Expected: `grim-rc=0`; the image shows the grid centred above the empty log, as on `main`. Read it and compare.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: background programs, coloured log, menu always behind

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
