//! Icons rendered the way the menu renders them: in `dbrrg-menu
//! --render-icon` processes under the kernel limits. Run under a memory
//! cap, so an unbounded render fails the test instead of the session.

use dbrrg_menu::icons::{self, ICON_DEADLINE, ICON_MEMORY, ICONS_BUDGET, IconJob, MAX_SVG_ELEMENTS};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

const RENDERER: &str = env!("CARGO_BIN_EXE_dbrrg-menu");

/// A fresh directory under $TMPDIR, removed when dropped.
struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str) -> Dir {
        let d = std::env::temp_dir().join(format!("dbrrg-menu-render-icon-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        Dir(d)
    }

    fn file(&self, name: &str, text: &str) -> PathBuf {
        let p = self.0.join(name);
        fs::write(&p, text).unwrap();
        p
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn job(path: PathBuf) -> IconJob {
    IconJob {
        path,
        side: 96,
        rgb: [255, 255, 255],
        symbolic: true,
    }
}

fn render(paths: Vec<PathBuf>) -> Vec<Result<egui::ColorImage, String>> {
    let jobs: Vec<IconJob> = paths.into_iter().map(job).collect();
    icons::render_all(Path::new(RENDERER), &jobs, ICON_DEADLINE, ICONS_BUDGET)
}

fn svg(body: &str) -> String {
    format!(r#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">{body}</svg>"#)
}

/// A chain of patterns, each filled with the next: flat in the file, but
/// usvg and resvg recurse once per link.
fn pattern_chain(links: usize) -> String {
    let mut body = String::from("<defs>");
    for i in 0..links {
        body += &format!(
            r#"<pattern id="p{i}" width="1" height="1"><rect width="1" height="1" fill="url(#p{})"/></pattern>"#,
            i + 1
        );
    }
    body += r#"</defs><rect width="24" height="24" fill="url(#p0)"/>"#;
    svg(&body)
}

/// Patterns nested `links` deep, the outer one scaled 200x: resvg sizes a
/// pattern's tile pixmap in device pixels, so 11 elements asked for 2.88 GB
/// and 13.5 s in a release build.
fn pattern_bomb(links: usize) -> String {
    let mut body = String::from("<defs>");
    for i in 0..links {
        let scale = if i == 0 {
            r#" patternTransform="scale(200)""#
        } else {
            ""
        };
        let fill = if i + 1 < links {
            format!("url(#b{})", i + 1)
        } else {
            "#000".to_string()
        };
        body += &format!(
            r#"<pattern id="b{i}" width="24" height="24" patternUnits="userSpaceOnUse"{scale}><rect width="24" height="24" fill="{fill}"/></pattern>"#
        );
    }
    body += r#"</defs><rect width="24" height="24" fill="url(#b0)"/>"#;
    svg(&body)
}

/// The largest resident size any reaped child of this process reached.
fn children_max_rss() -> u64 {
    // SAFETY: getrusage fills the struct it is given and nothing else.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    assert_eq!(unsafe { libc::getrusage(libc::RUSAGE_CHILDREN, &mut usage) }, 0);
    usage.ru_maxrss as u64 * 1024
}

// Before the renderer ran in a process of its own, the deadline abandoned
// the 4-pattern render on a thread that went on to allocate 1.4 GB and
// more inside the menu.
#[test]
fn a_pattern_bomb_draws_the_letter_and_its_memory_is_bounded() {
    let dir = Dir::new("bomb");
    let start = Instant::now();
    let out = render(vec![
        dir.file("bomb1.svg", &pattern_bomb(1)),
        dir.file("bomb4.svg", &pattern_bomb(4)),
    ]);
    assert!(start.elapsed() < ICON_DEADLINE, "{:?}", start.elapsed());
    for r in &out {
        let e = r.as_ref().map(|_| ()).unwrap_err();
        // The kernel refused the allocation and the renderer aborted.
        assert_eq!(
            e,
            "the renderer was killed by signal 6 (memory allocation of 1474560000 bytes failed)"
        );
    }
    let peak = children_max_rss();
    assert!(peak <= ICON_MEMORY, "a renderer reached {} MiB", peak >> 20);
}

// The worst chain the element limit lets through must fit ICON_STACK and
// ICON_MEMORY in this debug build, which needs more of both than a release.
#[test]
fn the_longest_allowed_chain_renders_in_the_renderer() {
    let dir = Dir::new("chain-max");
    let out = render(vec![dir.file("chain.svg", &pattern_chain((MAX_SVG_ELEMENTS - 4) / 2))]);
    assert!(out[0].is_ok(), "{:?}", out[0].as_ref().err());
}

#[test]
fn every_shipped_icon_draws_in_the_renderer() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("icons");
    let mut svgs: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "svg"))
        .collect();
    svgs.sort();
    assert!(!svgs.is_empty());
    for (p, r) in svgs.clone().into_iter().zip(render(svgs)) {
        let img = r.unwrap_or_else(|e| panic!("{}: {e}", p.display()));
        assert_eq!(img.size, [96, 96]);
        assert!(img.pixels.iter().any(|c| c.a() > 200), "{} drew nothing", p.display());
    }
}

// Before the guard the turbulence file rendered for more than a minute;
// the deadline keeps a regression from hanging the test run.
#[test]
fn filters_are_refused() {
    let dir = Dir::new("filter");
    let turbulence = svg(
        r#"<filter id="f"><feTurbulence baseFrequency="0.01" numOctaves="100000000"/></filter><rect width="24" height="24" filter="url(#f)"/>"#,
    );
    let css = svg(r#"<rect width="24" height="24" style="filter: blur(2px)"/>"#);
    let out = render(vec![dir.file("t.svg", &turbulence), dir.file("c.svg", &css)]);
    let errors: Vec<_> = out.into_iter().map(|r| r.map(|_| ())).collect();
    assert_eq!(errors, vec![Err("SVG uses filters".to_string()); 2]);
}

#[test]
fn a_bad_command_line_is_refused() {
    let out = std::process::Command::new(RENDERER)
        .args([icons::RENDER_ICON_ARG, "96", "white", "1", "/nonexistent.svg"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(
        out.stdout.starts_with(b"FAILusage:"),
        "{:?}",
        String::from_utf8_lossy(&out.stdout)
    );
}
