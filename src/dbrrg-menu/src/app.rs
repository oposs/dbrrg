//! The event loop: winit for the Wayland window, egui-winit for input,
//! egui for layout, raster.rs for pixels, softbuffer to put them on screen.
//! Driven by hand rather than through eframe so that nothing here needs a
//! GPU. The rules this file follows are in the spec under "Rendering
//! without a GPU".

use crate::damage::Tracker;
use crate::icons::IconRoots;
use crate::jobs::{self, JobResult, Paths};
use crate::menu::{Effect, Job, Menu};
use crate::raster::{Background, Canvas, Textures};
use crate::ui;
use egui::{TextureHandle, ViewportId};
use std::num::NonZeroU32;
use std::rc::Rc;
use std::time::Instant;
use winit::application::ApplicationHandler;
use winit::event::{StartCause, WindowEvent};
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
    /// The scale the last frame was laid out and damaged at.
    ppp: f32,
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
        let mut event = None;
        let out = self.ctx.run_ui(input, |ui| {
            event = ui::show(ui, &self.cfg.menu, &live.icons, now);
        });
        live.egui.handle_platform_output(&live.window, out.platform_output);

        // The dialog dims the grid once, when it opens, and un-freezes it
        // when it closes. Either way every pixel must be redrawn once.
        let saving = self.cfg.menu.busy.dialog();
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
        // Fingerprint bounds are in pixels, so a scale change invalidates
        // every one of them.
        if (ppp - live.ppp).abs() > f32::EPSILON {
            live.ppp = ppp;
            live.tracker.reset();
            force_full = true;
        }
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

        let effect = match event {
            Some(ui::UiEvent::Tile(i)) => self.cfg.menu.activate(i, now),
            Some(ui::UiEvent::Chose(c)) => self.cfg.menu.choose(c),
            None => self.cfg.menu.tick(now),
        };
        if effect.is_some() || event.is_some() {
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
        if self.cfg.debug {
            let drawn = icons.iter().filter(|i| i.is_some()).count();
            eprintln!("dbrrg-menu: {drawn} of {} tile icons drawn", icons.len());
        }
        let bg = egui_shadcn::Theme::dark().palette.background;
        self.live = Some(Live {
            window: window.clone(),
            surface,
            egui,
            canvas: Canvas::new(1, 1, bg),
            textures: Textures::default(),
            tracker: Tracker::default(),
            icons,
            ppp: 0.0,
        });
        window.request_redraw();
    }

    fn new_events(&mut self, _: &ActiveEventLoop, cause: StartCause) {
        if wake_needs_frame(&cause)
            && let Some(live) = self.live.as_ref()
        {
            live.window.request_redraw();
        }
    }

    // A finished job arrives here through the proxy, which wakes the loop.
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
        if self.cfg.menu.busy.refuses_input() && is_input(&event) {
            return;
        }
        let resp = live.egui.on_window_event(&live.window, &event);
        if resp.repaint {
            live.window.request_redraw();
        }
    }
}

/// Whether a loop wake-up needs a frame. `ControlFlow::WaitUntil` only
/// ends the wait; winit then reports `ResumeTimeReached` and does nothing
/// else, so without a redraw here the save timer and the pause before
/// logout would never advance.
fn wake_needs_frame(cause: &StartCause) -> bool {
    matches!(cause, StartCause::ResumeTimeReached { .. })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reached_deadline_needs_a_frame() {
        let now = Instant::now();
        let reached = StartCause::ResumeTimeReached {
            start: now,
            requested_resume: now,
        };
        assert!(wake_needs_frame(&reached));
        assert!(!wake_needs_frame(&StartCause::Poll));
        assert!(!wake_needs_frame(&StartCause::Init));
    }
}
