//! Icon lookup and rasterisation. Icons are drawn once at startup into
//! pixmaps; nothing here runs per frame.

use crate::bounded::read_bounded;
use resvg::tiny_skia::{FilterQuality, Pixmap, PixmapPaint, Transform};
use resvg::usvg;
use std::fs;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

/// Icon files larger than this are not read.
pub const MAX_ICON_BYTES: u64 = 1024 * 1024;
/// A PNG declaring a larger side is refused before it is decoded, so a small
/// file cannot ask for gigabytes.
pub const MAX_PNG_SIDE: u32 = 4096;
/// Deeper SVG nesting is refused. Among the 20000 SVGs under
/// /usr/share/icons on a desktop host the deepest nests 15 levels.
pub const MAX_SVG_DEPTH: usize = 64;
/// SVGs with more elements are refused. The largest icon on the same host
/// has 6741.
pub const MAX_SVG_ELEMENTS: usize = 10_000;

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

/// Index just past the first `needle` at or after `from`, or the end.
fn skip_past(b: &[u8], from: usize, needle: &[u8]) -> usize {
    b.get(from..)
        .and_then(|rest| rest.windows(needle.len()).position(|w| w == needle))
        .map_or(b.len(), |at| from + at + needle.len())
}

/// Refuse an SVG whose shape alone can kill the process, before any parser
/// sees it. Parsing and rendering recurse once per nesting level and per
/// `url(#…)` reference followed, and running out of stack is an
/// abort that no `catch_unwind` and no deadline can turn into a letter: the
/// menu would die on every boot. The depth limit covers nesting; the element
/// limit bounds how long a chain of references can be, and RENDER_STACK is
/// sized for the longest one it lets through. An entity can expand into
/// markup this scan never sees, and icons have no use for entities.
///
/// The scan only has to be right for files roxmltree would accept: a file
/// it misreads is either refused here or rejected by the parser.
fn svg_shape(text: &str, max_depth: usize, max_elements: usize) -> Result<(), String> {
    if text.contains("<!ENTITY") {
        return Err("SVG declares entities".to_string());
    }
    let b = text.as_bytes();
    let (mut i, mut depth, mut elements) = (0, 0usize, 0usize);
    while let Some(at) = b[i..].iter().position(|&c| c == b'<') {
        i += at;
        let rest = &b[i..];
        i = if rest.starts_with(b"<!--") {
            skip_past(b, i + 4, b"-->")
        } else if rest.starts_with(b"<![CDATA[") {
            skip_past(b, i + 9, b"]]>")
        } else if rest.starts_with(b"<?") {
            skip_past(b, i + 2, b"?>")
        } else if rest.starts_with(b"<!") {
            skip_past(b, i + 2, b">")
        } else if rest.starts_with(b"</") {
            depth = depth.saturating_sub(1);
            skip_past(b, i + 2, b">")
        } else {
            // A start tag. Attribute values may hold `>` and `/>`.
            let mut j = i + 1;
            let mut quote = None;
            while j < b.len() {
                match (quote, b[j]) {
                    (Some(q), c) if c == q => quote = None,
                    (None, c @ (b'"' | b'\'')) => quote = Some(c),
                    (None, b'>') => break,
                    _ => {}
                }
                j += 1;
            }
            elements += 1;
            if elements > max_elements {
                return Err(format!("more than {max_elements} elements"));
            }
            if depth >= max_depth {
                return Err(format!("elements nested deeper than {max_depth}"));
            }
            if b[j - 1] != b'/' {
                depth += 1;
            }
            j + 1
        };
        if i >= b.len() {
            break;
        }
    }
    Ok(())
}

/// Parser options that load nothing a tile icon names. usvg's default `<image
/// href>` resolver does an unbounded `fs::read` of any path (`/dev/zero` never
/// ends, a FIFO blocks) and decodes `data:` URIs of any declared size, which
/// would bypass `MAX_ICON_BYTES` and `MAX_PNG_SIDE` from a file the user can
/// write. Icons need no embedded images, so both resolvers return nothing.
fn svg_options() -> usvg::Options<'static> {
    let mut opts = usvg::Options::default();
    opts.image_href_resolver.resolve_string = Box::new(|_, _| None);
    opts.image_href_resolver.resolve_data = Box::new(|_, _, _| None);
    opts
}

/// Rasterise the icon at `path` into a `side` x `side` premultiplied RGBA
/// image, keeping its aspect ratio and centring it.
pub fn render(path: &Path, side: u32, rgb: [u8; 3], symbolic: bool) -> Result<egui::ColorImage, String> {
    let bytes = read_bounded(path, MAX_ICON_BYTES, true)?;
    let mut out = Pixmap::new(side, side).ok_or("bad icon size")?;
    let is_svg = path.extension().is_some_and(|e| e == "svg");
    if is_svg {
        let text = String::from_utf8(bytes).map_err(|_| "SVG is not UTF-8".to_string())?;
        svg_shape(&text, MAX_SVG_DEPTH, MAX_SVG_ELEMENTS)?;
        let text = recolour_svg(&text, symbolic, rgb);
        let tree = usvg::Tree::from_str(&text, &svg_options()).map_err(|e| e.to_string())?;
        // Filters are where a small file costs unbounded time: one
        // feTurbulence with a huge numOctaves rendered for over a minute.
        // A tile icon needs none, and the tree lists every one in use,
        // including those written as CSS (`filter: blur()`).
        if !tree.filters().is_empty() {
            return Err("SVG uses filters".to_string());
        }
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

/// How long one icon may take to render before its tile draws the letter.
pub const ICON_DEADLINE: Duration = Duration::from_secs(2);
/// How long the first frame may wait for all icons together.
pub const ICONS_BUDGET: Duration = Duration::from_secs(5);
/// usvg and resvg recurse once per level of nesting and per `url(#…)`
/// reference they follow. A thread's default 2 MiB overflows on a chain of
/// about 1000 patterns. A release build renders the 5000-pattern chain
/// MAX_SVG_ELEMENTS allows in 64 MiB, a debug build (the tests) does not, so
/// this has room for both. Only the pages a render touches cost memory.
const RENDER_STACK: usize = 256 * 1024 * 1024;

/// Run `render` on every job, each on a thread of its own and one at a time,
/// and give each its result or why it has none.
///
/// The renderers parse files the user can write, so a render can run
/// forever and the first frame must not wait for it. A render that misses
/// `per_icon`, or the `budget` all of them share, is abandoned: its thread is
/// left running detached and its tile draws the letter. Rendering one at a
/// time leaves at most `budget / per_icon` such threads behind.
pub fn render_all<J, T, F>(jobs: Vec<J>, per_icon: Duration, budget: Duration, render: F) -> Vec<Result<T, String>>
where
    J: Send + 'static,
    T: Send + 'static,
    F: Fn(J) -> Result<T, String> + Send + Sync + 'static,
{
    let render = Arc::new(render);
    let end = Instant::now() + budget;
    jobs.into_iter()
        .map(|job| {
            let wait = per_icon.min(end.saturating_duration_since(Instant::now()));
            if wait.is_zero() {
                return Err("no time left at startup".to_string());
            }
            let (tx, rx) = mpsc::channel();
            let render = render.clone();
            thread::Builder::new()
                .name("dbrrg-menu-icon".into())
                .stack_size(RENDER_STACK)
                .spawn(move || {
                    // A panic in usvg or resvg is a tile drawing its letter,
                    // not a reason to lose the menu. This needs the default
                    // panic = "unwind"; Cargo.toml must not set "abort".
                    let result = panic::catch_unwind(AssertUnwindSafe(|| render(job)))
                        .unwrap_or_else(|_| Err("the renderer panicked".to_string()));
                    let _ = tx.send(result);
                })
                .map_err(|e| e.to_string())?;
            match rx.recv_timeout(wait) {
                Ok(result) => result,
                Err(RecvTimeoutError::Timeout) if wait < per_icon => Err("no time left at startup".to_string()),
                Err(RecvTimeoutError::Timeout) => Err(format!("took longer than {per_icon:?}")),
                Err(RecvTimeoutError::Disconnected) => Err("the renderer stopped without a result".to_string()),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testdir::TestDir;

    /// The directory goes when the returned guard drops, so callers bind it
    /// to a named variable for the length of the test.
    fn roots(tag: &str) -> (TestDir, IconRoots) {
        let base = TestDir::new("icons", tag);
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
        (base, r)
    }

    fn touch(p: &Path) {
        fs::write(p, "x").unwrap();
    }

    #[test]
    fn resolution_order() {
        let (_dir, r) = roots("order");
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
        let (_dir, r) = roots("abs");
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
        let (_dir, r) = roots("render");
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

    // A referenced SVG is the one image kind usvg loads without a raster
    // decoder, so drawing it is observable; the files are small and real, so
    // a regression cannot run unbounded.
    #[test]
    fn embedded_images_are_not_loaded() {
        let (_dir, r) = roots("embed");
        let sub = r##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" fill="#ff0000"/></svg>"##;
        let sub_path = r.dbrrg.join("sub.svg");
        fs::write(&sub_path, sub).unwrap();
        let data_uri = format!("data:image/svg+xml;base64,{}", b64(sub.as_bytes()));
        for (tag, href) in [("file", sub_path.to_str().unwrap().to_string()), ("data", data_uri)] {
            let p = r.dbrrg.join(format!("outer-{tag}.svg"));
            fs::write(
                &p,
                format!(
                    r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="24" height="24"><image width="24" height="24" xlink:href="{href}"/></svg>"#
                ),
            )
            .unwrap();
            let img = render(&p, 24, [0; 3], false).unwrap();
            assert!(img.pixels.iter().all(|c| c.a() == 0), "{tag} image drawn");
        }
    }

    fn b64(data: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for c in data.chunks(3) {
            let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
            for i in 0..4 {
                if i <= c.len() {
                    out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
                } else {
                    out.push('=');
                }
            }
        }
        out
    }

    fn svg(body: &str) -> String {
        format!(r#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">{body}</svg>"#)
    }

    fn nested(depth: usize) -> String {
        svg(&format!(
            r#"{}<rect width="24" height="24"/>{}"#,
            "<g>".repeat(depth - 2),
            "</g>".repeat(depth - 2)
        ))
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

    fn render_text(tag: &str, text: &str) -> Result<egui::ColorImage, String> {
        let (_dir, r) = roots(tag);
        let p = r.dbrrg.join("x.svg");
        fs::write(&p, text).unwrap();
        render(&p, 24, [0; 3], false)
    }

    // Before the scan, the deep file overflowed the stack: an abort, not a
    // panic, so it ended the whole test binary rather than failing a test.
    #[test]
    fn deep_nesting_is_refused_before_parsing() {
        assert_eq!(
            render_text("deep", &nested(100_000)).unwrap_err(),
            "elements nested deeper than 64"
        );
        assert!(
            render_text("deep64", &nested(64)).is_ok(),
            "the limit itself is allowed"
        );
        assert!(render_text("deep65", &nested(65)).is_err());
    }

    #[test]
    fn a_long_reference_chain_is_refused_before_parsing() {
        // 1000 links overflowed a 2 MiB stack.
        assert_eq!(
            render_text("chain", &pattern_chain(6_000)).unwrap_err(),
            "more than 10000 elements"
        );
    }

    // The worst chain the element limit lets through must fit the render
    // thread's stack; RENDER_STACK is sized from this.
    #[test]
    fn the_longest_allowed_chain_renders_on_the_icon_thread() {
        let (_dir, r) = roots("chain-max");
        let p = r.dbrrg.join("x.svg");
        fs::write(&p, pattern_chain((MAX_SVG_ELEMENTS - 4) / 2)).unwrap();
        let out = render_all(vec![p], Duration::from_secs(60), Duration::from_secs(60), |p| {
            render(&p, 24, [0; 3], false)
        });
        assert!(out[0].is_ok(), "{:?}", out[0].as_ref().err());
    }

    #[test]
    fn every_shipped_icon_passes_the_guards_and_draws() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("icons");
        let mut svgs: Vec<PathBuf> = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "svg"))
            .collect();
        svgs.sort();
        assert!(!svgs.is_empty());
        for p in svgs {
            let img = render(&p, 96, [255, 255, 255], true).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
            assert!(img.pixels.iter().any(|c| c.a() > 200), "{} drew nothing", p.display());
        }
    }

    // Before the guard the turbulence file rendered for more than a minute;
    // the deadline keeps a regression from hanging the test run.
    #[test]
    fn filters_are_refused() {
        let turbulence = svg(
            r#"<filter id="f"><feTurbulence baseFrequency="0.01" numOctaves="100000000"/></filter><rect width="24" height="24" filter="url(#f)"/>"#,
        );
        let css = svg(r#"<rect width="24" height="24" style="filter: blur(2px)"/>"#);
        let (_dir, r) = roots("filter");
        let mut jobs = Vec::new();
        for (name, text) in [("turbulence", turbulence), ("css", css)] {
            let p = r.dbrrg.join(format!("{name}.svg"));
            fs::write(&p, text).unwrap();
            jobs.push(p);
        }
        let out = render_all(jobs, Duration::from_secs(10), Duration::from_secs(20), |p| {
            render(&p, 24, [0; 3], false).map(|_| ())
        });
        assert_eq!(out, vec![Err("SVG uses filters".to_string()); 2]);
    }

    #[test]
    fn entity_declarations_are_refused() {
        let text = r#"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "<g><rect width='1' height='1'/></g>">]><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">&a;</svg>"#;
        assert_eq!(render_text("entity", text).unwrap_err(), "SVG declares entities");
    }

    #[test]
    fn the_scan_reads_comments_cdata_and_quoted_brackets_as_text() {
        let body = r#"<!-- <g><g><g> --><style><![CDATA[ <g><g> ]]></style><?pi <g> ?><g title="a > b <g" id='x/>'><rect width="1" height="1"/></g>"#;
        assert_eq!(svg_shape(&svg(body), 3, 100), Ok(()));
        assert_eq!(
            svg_shape(&svg(body), 2, 100),
            Err("elements nested deeper than 2".to_string())
        );
        assert_eq!(svg_shape(&svg(body), 3, 3), Err("more than 3 elements".to_string()));
    }

    fn instant(job: u32) -> Result<u32, String> {
        Ok(job)
    }

    // The slow render sleeps far past every deadline here, so the test only
    // passes when the deadline gave up on it; the sleeping thread is left
    // behind and ends with the test process.
    #[test]
    fn a_slow_render_times_out_into_the_letter() {
        let start = std::time::Instant::now();
        let out = render_all(
            vec![1, 2, 3],
            Duration::from_millis(200),
            Duration::from_secs(2),
            |job| {
                if job == 2 {
                    std::thread::sleep(Duration::from_secs(60));
                }
                instant(job)
            },
        );
        assert!(start.elapsed() < Duration::from_secs(1), "{:?}", start.elapsed());
        assert_eq!(out[0], Ok(1));
        assert_eq!(out[1], Err("took longer than 200ms".to_string()));
        assert_eq!(out[2], Ok(3), "the icons after a slow one still render");
    }

    #[test]
    fn the_startup_budget_bounds_the_wait_for_all_icons() {
        let start = std::time::Instant::now();
        let out = render_all(
            vec![1, 2, 3, 4],
            Duration::from_millis(300),
            Duration::from_millis(500),
            |job| {
                std::thread::sleep(Duration::from_secs(60));
                instant(job)
            },
        );
        assert!(start.elapsed() < Duration::from_millis(800), "{:?}", start.elapsed());
        assert_eq!(out[0], Err("took longer than 300ms".to_string()));
        assert_eq!(out[1], Err("no time left at startup".to_string()));
        assert_eq!(out[2], Err("no time left at startup".to_string()));
        assert_eq!(out[3], Err("no time left at startup".to_string()));
    }

    #[test]
    fn a_panicking_render_falls_back_to_the_letter() {
        let out = render_all(vec![1, 2], Duration::from_secs(5), Duration::from_secs(5), |job| {
            if job == 1 {
                panic!("renderer bug");
            }
            instant(job)
        });
        assert_eq!(out, vec![Err("the renderer panicked".to_string()), Ok(2)]);
    }

    #[test]
    fn refuses_png_bombs_before_decoding() {
        let (_dir, r) = roots("bomb");
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
