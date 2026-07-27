# Patched labwc: multi-monitor fullscreen for X11 clients, and X keyboard grabs

Date: 2026-07-27
Status: design approved, not implemented

## Problem

Two defects in the 26.04/Wayland session, both rooted in labwc 0.9.3.

**1. ThinLinc fullscreen covers only one monitor.** Under the old X11 session
(wm2) the ThinLinc client spanned both monitors. Under labwc it does not.
Observed on hardware: the client's fullscreen options are selectable, the
monitor arrangement widget shows both monitors, but the window covers only
the primary screen when the client starts. Making the client size itself to
the union via `tlclient.conf` was tried first and did not work.

**2. Compositor keybindings can never be reclaimed by the remote session.**
`overlay/etc/dbrrg/labwc/rc.xml` therefore registers zero keybindings, which
is recorded in `CLAUDE.md` as a standing constraint. The constraint is
correct. The rationale recorded next to it is not - see "Corrections to
recorded knowledge" below.

## Findings

All of the following were verified against source at the shipped versions
(labwc 0.9.3, wlroots 0.19.2, Xwayland master, TigerVNC master) and, where
possible, against the binaries inside `localhost/dbrrg-ubuntu:3.0.0`.

### The clamp

`labwc-0.9.3/src/view.c:1220`:

```c
static void
view_apply_fullscreen_geometry(struct view *view)
{
	struct wlr_box box = { 0 };
	wlr_output_layout_get_box(view->server->output_layout,
		view->output->wlr_output, &box);   /* <- the clamp */
	view_move_resize(view, box);
}
```

`wlr_output_layout_get_box()` is documented at
`wlroots/include/wlr/types/wlr_output_layout.h:134-138` to return the extents
of the **entire layout** when the reference output is `NULL`. That union
bounding box is exactly the geometry wm2 left the client sitting at.

### The remote screen layout comes from real geometry, not from EWMH

`tigervnc/vncviewer/DesktopWindow.cxx`, `remoteResize()`, fullscreen branch:
the client walks every X screen, keeps those *fully enclosed by the window's
actual viewport rect*, and reports one `rfb::Screen` per monitor. Nothing in
that path reads `_NET_WM_FULLSCREEN_MONITORS`.

Consequence: forcing the union geometry compositor-side is sufficient to give
the remote session a genuine two-screen layout. It works even if the client
only asked for single-monitor fullscreen, because the client derives the
layout from where the window actually ended up.

### `_NET_WM_FULLSCREEN_MONITORS` is not worth implementing

The atom is implemented nowhere in the practical field: absent from wlroots
0.19.2 (so sway/cage/wayfire/labwc all lack it), absent from openbox and i3.
Implementing it would mean patching wlroots' xwm (atom, `_NET_SUPPORTED`
entry, client-message handling, a new event) plus labwc, and shipping a
patched `libwlroots-0.19`. The labwc half would have to map X RandR monitor
indices back to `wlr_output`s, which relies on Xwayland's `wl_output`
advertisement order - nothing guarantees that ordering.

Upstream TigerVNC greys out its multi-monitor options when the atom is
missing from `_NET_SUPPORTED` (`vncviewer/OptionsDialog.cxx:1174-1215`), and
`vncviewer` in our image does contain both `_NET_WM_FULLSCREEN_MONITORS` and
`_NET_SUPPORTING_WM_CHECK`. That greying was the expected symptom - but it is
**not** what happens on hardware, because Cendio ships its own options dialog
rather than TigerVNC's. With nothing greyed out, the atom's only observable
benefit disappears, and the clamp is the whole bug.

### Xwayland forwards X keyboard grabs by a different protocol than assumed

`zwp_keyboard_shortcuts_inhibit_manager_v1` has exactly one call site in
Xwayland, `maybe_fake_grab_devices()` in `hw/xwayland/xwayland-input.c`, and
it opens with:

```c
if (xwl_screen->rootless) return;     /* we are always rootless */
if (!xwl_screen->host_grab) return;   /* rootful -host-grab only */
```

Under labwc, Xwayland runs rootless, so it never requests shortcut
inhibition. Implementing that protocol in labwc would do nothing for
ThinLinc.

The mechanism that does apply in rootless mode: X `ActivateGrab` ->
`set_grab()` -> `zwp_xwayland_keyboard_grab_manager_v1.grab_keyboard(surface,
seat)` (`xwayland-input.c:1602`). `vncviewer` calls `XGrabKeyboard` and
`XUngrabKeyboard` (verified in the shipped binary). Xwayland installs its
grab hook only if the compositor advertises the manager
(`init_keyboard_grab()` -> `setup_keyboard_grab_handler()`), so the feature
is strictly opt-in from the compositor side.

Neither wlroots 0.19.2 nor labwc 0.9.3 implements that manager - zero matches
in either tree.

Two pieces of existing labwc machinery make the patch small:

- `view_inhibits_actions()` (`src/view.c:2374`) is already consulted by
  keybinds (`src/input/keyboard.c:199`) and by all four mousebind sites in
  `src/input/cursor.c`.
- `server_global_filter()` (`src/server.c:299`), installed via
  `wl_display_set_global_filter()` at `src/server.c:434`, already exists as
  the place to restrict a global to one client.

## Design

### Patch A - fullscreen span (~10 lines, `src/view.c`)

`view_apply_fullscreen_geometry()` passes `NULL` as the layout reference
output when both hold:

- the view is `LAB_XWAYLAND_VIEW` (`include/view.h:38`), and
- `LABWC_FULLSCREEN_SPAN_OUTPUTS` is set in the environment.

The env var is read once via `getenv()` and cached in a static, matching how
labwc already reads `LABWC_FALLBACK_OUTPUT`, `XKB_DEFAULT_LAYOUT` and
`XCURSOR_THEME`.

The X11 gate is not cosmetic. A Wayland client's `xdg_toplevel.set_fullscreen`
names a single output and the client renders one buffer at that output's size
and scale; spanning it would be a protocol-level wrong answer. Only Xwayland
views, which have no such contract with the compositor, get the union.

Deliberately unchanged:

- `output_set_has_fullscreen_view(view->output, ...)` stays per-output. It
  only suppresses the top layer-shell layer on the view's own output, and
  this image ships no layer-shell clients.
- Output hotplug already re-runs `view_apply_special_geometry()`
  (`src/view.c:2188`), so the span recomputes when a monitor is plugged or
  unplugged. wm2 required the client to notice for itself.

### Patch B - `zwp_xwayland_keyboard_grab_manager_v1` (~150-200 lines)

- `protocols/xwayland-keyboard-grab-unstable-v1.xml` from wayland-protocols
  (vendor the XML only if 26.04's wayland-protocols does not ship it), added
  to `protocols/meson.build` alongside labwc's existing self-implemented
  protocols.
- New `src/protocols/xwayland-keyboard-grab.c`: create the manager global; on
  `grab_keyboard(id, surface, seat)` resolve `view_from_wlr_surface()` and
  mark the view as grab-inhibited; clear on grab-resource destroy and on view
  unmap/destroy.
- One clause in the existing `server_global_filter()` advertising the manager
  **only** to the Xwayland `wl_client`.
- A new `view->keybinds_inhibited_by_grab` flag, OR'd into
  `view_inhibits_actions()`. It must not reuse `view->inhibits_keybinds`:
  that flag is user-toggled by labwc's `ToggleKeybinds` action and drives an
  SSD indicator, and a grab arriving mid-session must not clobber the user's
  toggle state.
- Nothing in `keyboard.c` or `cursor.c` changes.

Be clear about what this buys. With zero keybindings configured, Patch B
changes nothing observable today. Its value is that the safety property stops
depending on a documented rule a future maintainer might break, and that a
false rationale in `CLAUDE.md` gets corrected. That value is real only if the
test proves the grab actually arrives, so the grab test is load-bearing, not
garnish.

Keybindings stay at zero in this change. Adding them later becomes a
config-only decision, taken after the grab path has been seen working on
hardware.

### Wiring

`overlay/etc/dbrrg/labwc/environment` gains
`export LABWC_FULLSCREEN_SPAN_OUTPUTS=1` - default on, since restoring the
old behaviour is the point. `10-dbrrg-session.sh` already sources and exports
that file before exec'ing labwc.

`~/.dbrrg-environment` is sourced *after* the system file, so a machine that
wants single-monitor fullscreen sets `LABWC_FULLSCREEN_SPAN_OUTPUTS=0` there
and `save-home` persists it. This is the documented user-config mechanism
used as designed; `CLAUDE.md`'s `.dbrrg-environment` table gains a row.

### Build integration

A `FROM ubuntu:26.04 AS labwc-build` stage at the top of
`containers/ubuntu/Dockerfile`:

1. enable `deb-src` in the deb822 sources (`Types: deb deb-src`)
2. `apt-get build-dep labwc`, `apt-get source labwc`
3. copy both patches into `debian/patches/` and append to `series`
4. version to `0.9.3-1+dbrrg1`
5. `dpkg-buildpackage -b -uc -us`

The main stage drops `labwc` from the big `apt-get install` list and installs
the built `.deb` instead, letting apt resolve its dependencies. `+dbrrg1`
sorts above `0.9.3-1`, so no later apt operation replaces it. Patches live in
`containers/ubuntu/patches/`. The container build's existing `--cpu-quota`
already enforces the 4-core cap; no Makefile change is needed.

### Verification

Three layers, because shipping something "working but unverified" is this
project's recurring failure mode.

1. **Headless two-output rig**, in a container off the built image:
   `WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 labwc`, plus a small
   python-xlib client that maps a window, sets `_NET_WM_STATE_FULLSCREEN`,
   and reports its geometry on `ConfigureNotify`. Assert the width equals the
   sum of both outputs rather than one. Proves the compositor half without
   hardware.
2. **Grab check** in the same rig: run Xwayland with `WAYLAND_DEBUG=1`, have
   the client call `XGrabKeyboard`, and assert a
   `zwp_xwayland_keyboard_grab_manager_v1` ... `grab_keyboard` request
   appears. No input injection needed to prove the wiring.
3. **Static**, extending `test/integration/test-session-packages.sh` and run
   via `make test`: the installed labwc version carries `+dbrrg1`, the env
   var is set in `/etc/dbrrg/labwc/environment`, and the shipped binary
   contains the protocol interface string. Checked against the squashfs -
   the artifact, not the source tree.

## Corrections to recorded knowledge

`CLAUDE.md`'s "labwc must have zero keybindings" constraint keeps its
conclusion but must have its rationale rewritten. The current text says
Xwayland requests inhibition when an X11 client calls `XGrabKeyboard` and
that labwc's lack of `zwp_keyboard_shortcuts_inhibit_manager_v1` is what
blocks it. Rootless Xwayland never requests that inhibition at all. The
correct statement is that Xwayland forwards X grabs via
`zwp_xwayland_keyboard_grab_manager_v1`, which no wlroots compositor
implements - and, once Patch B lands, that labwc does implement it but the
image still ships zero keybindings pending hardware confirmation.

The suggested check for a future labwc ("look for
`wlr_keyboard_shortcuts_inhibit_v1_create` in the binary's undefined
symbols") is therefore also wrong and should be dropped.

`docs/controller-handoff.md` §7 records "patching labwc to honour
`_NET_WM_FULLSCREEN_MONITORS`" as the alternative angle. This design
supersedes that: the atom is unnecessary because the client derives its
screen layout from real geometry.

## Known limits

- Monitor *subset* selection is unsupported: fullscreen is all outputs or
  one. On a two-monitor thin client this is not a practical capability loss,
  but it is a genuine narrowing versus true `_NET_WM_FULLSCREEN_MONITORS`.
- Each labwc or wlroots upgrade needs a quilt rebase. Both patches are
  context-minimal and quilt fails loudly rather than silently, but this is a
  standing maintenance cost that did not exist before.
- The rig proves the compositor half only. The client-side result still needs
  confirmation on the dual-head machine.
- Mixed-scale outputs render one Xwayland buffer across both, the same as
  under wm2.
- Patch B has no observable effect while keybindings remain at zero.

## Out of scope

- Adding any labwc keybinding.
- Patching wlroots, for either defect.
- `save-home` crash-safety (`docs/controller-handoff.md` §7), unrelated.
