//! Drawing the grid and the save dialog. Everything that decides something
//! lives in menu.rs; this file only paints it and reports clicks.

use crate::icons::{self, IconRoots};
use crate::menu::{Busy, Choice, Menu, SaveFor};
use crate::tiles::{Origin, Tile};
use egui::{Align2, Color32, FontId, Rect, Sense, Stroke, StrokeKind, TextureHandle, Ui, Vec2, pos2, vec2};
use egui_shadcn::Theme;
use egui_shadcn::components::button::{Button, ButtonVariant};
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

/// What the person did this frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiEvent {
    Tile(usize),
    Chose(Choice),
}

/// Draw one frame.
pub fn show(ui: &mut Ui, menu: &Menu, icons: &[Option<TextureHandle>], now: Instant) -> Option<UiEvent> {
    // No background fill here: the canvas restores the page colour itself,
    // and while the dialog is up it holds the frozen grid, which a fill
    // would erase. Only the dialog is drawn then.
    match &menu.busy {
        Busy::Saving { since, purpose } => {
            let title = match purpose {
                SaveFor::Backup => "Backing up your home directory",
                SaveFor::Logout => "Saving your home directory before logging out",
            };
            dialog(ui, title, |ui, t| {
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
        Busy::LoggingOut { until } => {
            dialog(ui, "Home directory saved", |ui, t| {
                ui.label(egui::RichText::new("Logging out.").color(t.palette.muted_foreground));
            });
            ui.ctx().request_repaint_after(until.saturating_duration_since(now));
            return None;
        }
        Busy::LogoutFailed { message } => {
            let mut chose = None;
            dialog(ui, "Your home directory was not saved", |ui, t| {
                ui.label(egui::RichText::new(message).color(WARN));
                ui.label(
                    egui::RichText::new("If you log out now, the changes since the last save are lost.")
                        .color(t.palette.muted_foreground),
                );
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.add(Button::new("Stay")).clicked() {
                        chose = Some(Choice::Stay);
                    }
                    if ui
                        .add(Button::new("Log out anyway").variant(ButtonVariant::Destructive))
                        .clicked()
                    {
                        chose = Some(Choice::LogOutAnyway);
                    }
                });
            });
            return chose.map(UiEvent::Chose);
        }
        Busy::Idle | Busy::Running { .. } => {}
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
                        clicked = Some(UiEvent::Tile(index));
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

/// A centred card over the frozen grid.
fn dialog(ui: &Ui, title: &str, body: impl FnOnce(&mut Ui, &Theme)) {
    let t = Theme::current(ui.ctx());
    egui::Area::new(egui::Id::new("dialog"))
        .anchor(Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ui.ctx(), |ui| {
            egui::Frame::new()
                .fill(t.palette.card)
                .stroke(Stroke::new(1.0, t.palette.border))
                .corner_radius(t.radius_lg())
                .inner_margin(24.0)
                .show(ui, |ui| {
                    ui.set_width(460.0);
                    ui.label(egui::RichText::new(title).size(18.0));
                    body(ui, &t);
                });
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn elapsed_is_minutes_and_seconds() {
        assert_eq!(elapsed(Duration::from_secs(0)), "0:00");
        assert_eq!(elapsed(Duration::from_secs(65)), "1:05");
    }
}
