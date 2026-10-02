//! Icon lookup and rasterisation. Icons are drawn once at startup into
//! pixmaps; nothing here runs per frame.

use crate::bounded::read_bounded;
use resvg::tiny_skia::{FilterQuality, Pixmap, PixmapPaint, Transform};
use resvg::usvg;
use std::fs;
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
    let bytes = read_bounded(path, MAX_ICON_BYTES, true)?;
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
