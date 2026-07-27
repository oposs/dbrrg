# Patched labwc Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a locally patched `labwc` .deb so ThinLinc fullscreen spans all monitors again, and so X11 keyboard grabs suspend compositor keybindings.

**Architecture:** A new `labwc-build` stage in `containers/ubuntu/Dockerfile` rebuilds Ubuntu's `labwc` source package with quilt patches from `containers/ubuntu/patches/`, producing `labwc_0.9.3-1+dbrrg1_amd64.deb`, which the main stage installs instead of the archive version. Patch A makes `view_apply_fullscreen_geometry()` use whole-layout extents for Xwayland views when `LABWC_FULLSCREEN_SPAN_OUTPUTS` is set. Patch B implements `zwp_xwayland_keyboard_grab_manager_v1` and wires it to labwc's existing keybind-inhibition hook.

**Tech Stack:** Ubuntu 26.04, podman, dpkg-buildpackage/quilt, meson, C (labwc 0.9.3, wlroots 0.19.2), bash + python3-xlib for tests.

**Design spec:** `docs/superpowers/specs/2026-07-27-labwc-multimonitor-fullscreen-design.md`. Read it before starting — it records *why* each choice was made, including two corrections to previously recorded project knowledge.

## Global Constraints

- **Never more than 4 cores.** Shared machine. The container build already
  passes `--cpu-quota=$((BUILD_JOBS*100000))`; do not add parallelism that
  escapes it, and do not raise `BUILD_JOBS`.
- **Keep `--no-install-recommends --no-install-suggests`** on every
  `apt-get install` in the final image stage.
- **labwc ships zero keybindings.** `overlay/etc/dbrrg/labwc/rc.xml` must
  still contain no `<keybind>` and no `<default />` when this plan is done.
  Patch B does not license adding any.
- **dracut keeps `--no-hostonly`.** Do not touch that invocation.
- **No `find`/`rm -rf` sweeps over `/usr/lib/firmware`.** Unrelated to this
  work; listed because it is a standing repo rule.
- Patch version string is exactly `0.9.3-1+dbrrg1`.
- Env var name is exactly `LABWC_FULLSCREEN_SPAN_OUTPUTS`.
- Upstream versions this plan is written against: labwc **0.9.3**, wlroots
  **0.19.2**. If `apt-cache policy labwc` reports something else, stop and
  report — the patch hunks and line numbers below will not apply.

---

## File Structure

**Created:**
- `containers/ubuntu/patches/0001-fullscreen-span-outputs.patch` — Patch A.
- `containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch` — Patch B.
- `test/runtime/Dockerfile` — test-only image: the built rootfs image plus
  `python3-xlib`. Never shipped.
- `test/runtime/x11-probe.py` — X11 client that fullscreens itself, optionally
  grabs the keyboard, and prints its geometry.
- `test/runtime/test-labwc-runtime.sh` — runs labwc headless with two outputs
  and asserts span + grab behaviour.

**Modified:**
- `containers/ubuntu/Dockerfile` — new `labwc-build` stage; `labwc` removed
  from the main package list and installed from the built .deb.
- `overlay/etc/dbrrg/labwc/environment` — export the env var.
- `test/integration/test-session-packages.sh` — static assertions.
- `Makefile` — `test-runtime` target (kept out of `make test`, which stays
  offline and artifact-only).
- `CLAUDE.md` — corrected keybinding rationale, new env var row, patch policy.
- `docs/controller-handoff.md` — §7 open item resolved.

Patch A and Patch B are separate quilt patches so either can be dropped on a
future labwc rebase without losing the other.

---

## Task 1: labwc rebuild infrastructure

Produces an *unpatched* `+dbrrg1` rebuild. This task proves the packaging
route works before any C is written, so a later failure is unambiguously the
patch's fault and not the build's.

**Files:**
- Modify: `containers/ubuntu/Dockerfile`
- Modify: `test/integration/test-session-packages.sh`
- Create: `containers/ubuntu/patches/.gitkeep`

**Interfaces:**
- Consumes: nothing.
- Produces: an image where `dpkg -s labwc` reports version
  `0.9.3-1+dbrrg1`; a patch directory that Tasks 2 and 3 drop files into and
  that is applied automatically in series order.

- [ ] **Step 1: Write the failing static test**

Append to `test/integration/test-session-packages.sh`, immediately before the
final `exit $fail` (keep the existing `present`/`absent` helpers above it):

```bash
# The labwc in the image must be our local rebuild, not the archive version.
# Guards against the labwc-build stage silently dropping out of the image.
DPKG_TMP=$(mktemp -d)
trap 'rm -f "$LIST"; rm -rf "$DPKG_TMP"' EXIT
if unsquashfs -no-xattrs -d "$DPKG_TMP/x" "$SQSH" var/lib/dpkg/status >/dev/null 2>&1; then
    labwc_version=$(awk '/^Package: labwc$/{f=1} f&&/^Version:/{print $2; exit}' \
        "$DPKG_TMP/x/var/lib/dpkg/status")
    if [[ "$labwc_version" == *"+dbrrg1" ]]; then
        echo "ok   - labwc is the local rebuild ($labwc_version)"
    else
        echo "FAIL - labwc is '$labwc_version', expected a +dbrrg1 rebuild"
        fail=1
    fi
else
    echo "FAIL - cannot extract var/lib/dpkg/status from $SQSH"
    fail=1
fi
```

- [ ] **Step 2: Run it and watch it fail**

```bash
test/integration/test-session-packages.sh
```

Expected: `FAIL - labwc is '0.9.3-1', expected a +dbrrg1 rebuild`, exit 1.
(If `artifacts/rootfs/ramroot.sqsh` is missing, run `make rootfs` first.)

- [ ] **Step 3: Add the build stage**

Insert at the very top of `containers/ubuntu/Dockerfile`, above the existing
`FROM ubuntu:26.04`:

```dockerfile
# Local labwc rebuild.
#
# Ubuntu's labwc 0.9.3 clamps fullscreen windows to a single output and does
# not implement zwp_xwayland_keyboard_grab_manager_v1. Both are patched here;
# see docs/superpowers/specs/2026-07-27-labwc-multimonitor-fullscreen-design.md.
#
# Patches live in containers/ubuntu/patches/ and are appended to the source
# package's quilt series in filename order. dpkg-buildpackage applies them, so
# a patch that no longer applies fails the build loudly instead of being
# silently skipped.
FROM ubuntu:26.04 AS labwc-build
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBEMAIL=dbrrg@localhost DEBFULLNAME=dbrrg

RUN sed -i 's/^Types: deb$/Types: deb deb-src/' \
        /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get install -yq --no-install-recommends \
        build-essential devscripts dpkg-dev quilt ca-certificates && \
    apt-get build-dep -yq labwc

WORKDIR /build
RUN apt-get source labwc

COPY containers/ubuntu/patches/ /patches/
RUN set -eu; \
    cd /build/labwc-*/; \
    for p in /patches/*.patch; do \
        [ -e "$p" ] || continue; \
        cp "$p" debian/patches/; \
        basename "$p" >> debian/patches/series; \
    done; \
    dch --local +dbrrg --distribution unstable "dbrrg local patches"; \
    dpkg-buildpackage -b -uc -us; \
    mkdir -p /out; \
    cp /build/labwc_*.deb /out/
```

- [ ] **Step 4: Install the rebuild in the main stage**

In the main stage's big `apt-get install` list, delete the line:

```dockerfile
    labwc \
```

Then, immediately after the `oxulnk-desktop.deb` install block (around line
96-98), add:

```dockerfile
# labwc comes from the local rebuild above, not the archive. apt resolves its
# dependencies from the .deb's own control fields. 0.9.3-1+dbrrg1 sorts above
# 0.9.3-1, so a later apt-get upgrade will not replace it.
COPY --from=labwc-build /out/ /tmp/labwc-deb/
RUN apt-get install -yq --no-install-recommends --no-install-suggests /tmp/labwc-deb/labwc_*.deb && \
    rm -rf /tmp/labwc-deb
```

- [ ] **Step 5: Create the patch directory placeholder**

```bash
mkdir -p containers/ubuntu/patches
touch containers/ubuntu/patches/.gitkeep
```

- [ ] **Step 6: Rebuild and re-run the test**

```bash
make rootfs && test/integration/test-session-packages.sh
```

Expected: `ok   - labwc is the local rebuild (0.9.3-1+dbrrg1)` and exit 0,
with every pre-existing assertion in the script still passing.

- [ ] **Step 7: Commit**

```bash
git add containers/ubuntu/Dockerfile containers/ubuntu/patches/.gitkeep \
        test/integration/test-session-packages.sh
git commit -m "build: rebuild labwc locally so it can carry dbrrg patches"
```

---

## Task 2: Patch A — fullscreen spans all outputs

**Files:**
- Create: `containers/ubuntu/patches/0001-fullscreen-span-outputs.patch`
- Create: `test/runtime/Dockerfile`, `test/runtime/x11-probe.py`,
  `test/runtime/test-labwc-runtime.sh`
- Modify: `overlay/etc/dbrrg/labwc/environment`, `Makefile`,
  `test/integration/test-session-packages.sh`

**Interfaces:**
- Consumes: the `labwc-build` stage and `containers/ubuntu/patches/` from
  Task 1.
- Produces: `test/runtime/test-labwc-runtime.sh`, which Task 3 extends with a
  second assertion; `test/runtime/x11-probe.py`, which Task 3 calls with
  `--grab`.

- [ ] **Step 1: Write the X11 probe**

Create `test/runtime/x11-probe.py`:

```python
#!/usr/bin/env python3
"""Map a window, ask the WM for fullscreen, print the resulting size.

Used by test-labwc-runtime.sh against a headless labwc with two outputs.
With --grab it also takes an X11 keyboard grab, which rootless Xwayland
forwards to the compositor as zwp_xwayland_keyboard_grab_v1.
"""
import sys
import time

from Xlib import X, display
from Xlib.protocol import event

grab = "--grab" in sys.argv

d = display.Display()
screen = d.screen()
win = screen.root.create_window(
    0, 0, 400, 300, 0, screen.root_depth,
    X.InputOutput, X.CopyFromParent,
    event_mask=X.StructureNotifyMask)
win.set_wm_name("dbrrg-x11-probe")
win.set_wm_class("dbrrg-probe", "dbrrg-probe")
win.map()
d.sync()
time.sleep(1)

if grab:
    win.grab_keyboard(False, X.GrabModeAsync, X.GrabModeAsync, X.CurrentTime)
    d.sync()
    time.sleep(1)

net_wm_state = d.intern_atom("_NET_WM_STATE")
fullscreen = d.intern_atom("_NET_WM_STATE_FULLSCREEN")
# _NET_WM_STATE_ADD = 1, source = 1 (normal application)
d.screen().root.send_event(
    event.ClientMessage(window=win, client_type=net_wm_state,
                        data=(32, [1, fullscreen, 0, 1, 0])),
    event_mask=X.SubstructureRedirectMask | X.SubstructureNotifyMask)
d.sync()
time.sleep(2)

geom = win.get_geometry()
print("GEOMETRY %dx%d" % (geom.width, geom.height))
```

- [ ] **Step 2: Write the test image and runner**

Create `test/runtime/Dockerfile`:

```dockerfile
# Test-only image: the built rootfs plus python3-xlib. Never shipped.
ARG BASE
FROM ${BASE}
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -yq --no-install-recommends python3-xlib && \
    rm -rf /var/lib/apt/lists/*
COPY x11-probe.py /usr/local/bin/x11-probe.py
```

Create `test/runtime/test-labwc-runtime.sh`:

```bash
#!/bin/bash
# Runs labwc headless with two 1280x720 outputs and asserts that a fullscreen
# X11 client is given the union of both (2560x720), not a single output.
#
# Not part of 'make test': it needs network (python3-xlib) and runs a
# compositor. Use 'make test-runtime'.

set -uo pipefail

IMAGE="${1:-localhost/dbrrg-runtime-test:latest}"
fail=0

out=$(podman run --rm \
    -e WLR_BACKENDS=headless \
    -e WLR_HEADLESS_OUTPUTS=2 \
    -e WLR_RENDERER=pixman \
    -e XDG_RUNTIME_DIR=/tmp/xdg \
    "$IMAGE" \
    sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
           labwc -C /etc/dbrrg/labwc -S "python3 /usr/local/bin/x11-probe.py"' 2>&1)

geom=$(echo "$out" | grep -o 'GEOMETRY [0-9]*x[0-9]*' | tail -1 | cut -d' ' -f2)

if [[ "$geom" == "2560x720" ]]; then
    echo "ok   - fullscreen X11 window spans both outputs ($geom)"
else
    echo "FAIL - fullscreen X11 window is $geom, expected 2560x720"
    echo "--- compositor output ---"
    echo "$out"
    fail=1
fi

exit $fail
```

```bash
chmod +x test/runtime/test-labwc-runtime.sh
```

Add to the `Makefile`, after the existing `test:` target, and add
`test-runtime` to the `.PHONY` line:

```make
# Runtime session tests. Needs network (installs python3-xlib into a
# test-only image) and runs a compositor, so it is deliberately not part of
# 'make test'.
test-runtime: rootfs
	$(CONTAINER_RUNTIME) build --progress=plain \
		--cpu-period=100000 --cpu-quota=$$(($(BUILD_JOBS)*100000)) \
		--build-arg BASE=$(UBUNTU_IMAGE) \
		-t $(PROJECT_NAME)-runtime-test:$(VERSION) \
		-f test/runtime/Dockerfile \
		test/runtime
	@test/runtime/test-labwc-runtime.sh $(PROJECT_NAME)-runtime-test:$(VERSION)
```

- [ ] **Step 3: Run it and watch it fail**

```bash
make test-runtime
```

Expected: `FAIL - fullscreen X11 window is 1280x720, expected 2560x720`.
That single-output number *is* the bug this task fixes; seeing it here
reproduces the hardware symptom without hardware.

If instead the probe prints nothing, the rig is broken rather than the
assertion — debug that before writing the patch. Check in this order: labwc
started at all (look for `wlr_` log lines), Xwayland came up (the probe fails
with `DisplayConnectionError` if not), the probe's `python3-xlib` import
resolved.

- [ ] **Step 4: Generate the patch**

Work in a scratch clone so the patch is generated by git rather than written
by hand:

```bash
cd "$(mktemp -d)"
git clone --depth 1 --branch 0.9.3 https://github.com/labwc/labwc.git
cd labwc
```

Edit `src/view.c`. Replace `view_apply_fullscreen_geometry()` (at line 1219 in
0.9.3) with:

```c
/*
 * dbrrg: Xwayland fullscreen may span the whole output layout.
 *
 * labwc clamps a fullscreen view to view->output. The ThinLinc client
 * (TigerVNC) derives the remote screen layout from the geometry it actually
 * receives, comparing it against the X screens it fully covers, so handing it
 * the union of all outputs restores a genuine multi-monitor remote session.
 *
 * Xwayland views only: a Wayland client's xdg_toplevel.set_fullscreen names
 * one output and the client renders one buffer at that output's size and
 * scale, so spanning it would be protocol-incorrect.
 */
static bool
fullscreen_spans_outputs(struct view *view)
{
	static int enabled = -1;

	if (enabled < 0) {
		const char *env = getenv("LABWC_FULLSCREEN_SPAN_OUTPUTS");
		enabled = (env && env[0] != '\0' && env[0] != '0') ? 1 : 0;
	}
	if (!enabled) {
		return false;
	}
#if HAVE_XWAYLAND
	return view->type == LAB_XWAYLAND_VIEW;
#else
	return false;
#endif
}

static void
view_apply_fullscreen_geometry(struct view *view)
{
	assert(view);
	assert(view->fullscreen);
	assert(output_is_usable(view->output));

	struct wlr_box box = { 0 };
	wlr_output_layout_get_box(view->server->output_layout,
		fullscreen_spans_outputs(view)
			? NULL : view->output->wlr_output, &box);
	view_move_resize(view, box);
}
```

`wlr_output_layout_get_box()` with a NULL reference output returns the extents
of the entire layout — see `wlr_output_layout.h:134-138`.

Then:

```bash
git diff > /path/to/repo/containers/ubuntu/patches/0001-fullscreen-span-outputs.patch
```

- [ ] **Step 5: Turn the env var on by default**

Append to `overlay/etc/dbrrg/labwc/environment`:

```sh
# Make fullscreen Xwayland windows (the ThinLinc client) cover every monitor
# instead of one. Requires the local labwc patch; harmless on a stock labwc,
# which ignores the variable. Set to 0 in ~/.dbrrg-environment for
# single-monitor fullscreen on a particular machine - that file is sourced
# after this one and is persisted by save-home.
export LABWC_FULLSCREEN_SPAN_OUTPUTS=1
```

- [ ] **Step 6: Add the static assertion**

In `test/integration/test-session-packages.sh`, next to the `+dbrrg1` check
from Task 1:

```bash
present "fullscreen span enabled in labwc environment" \
        "etc/dbrrg/labwc/environment"
if unsquashfs -no-xattrs -d "$DPKG_TMP/env" "$SQSH" \
        etc/dbrrg/labwc/environment >/dev/null 2>&1 &&
   grep -q '^export LABWC_FULLSCREEN_SPAN_OUTPUTS=1' \
        "$DPKG_TMP/env/etc/dbrrg/labwc/environment"; then
    echo "ok   - LABWC_FULLSCREEN_SPAN_OUTPUTS is set"
else
    echo "FAIL - LABWC_FULLSCREEN_SPAN_OUTPUTS not set in the shipped environment"
    fail=1
fi
```

- [ ] **Step 7: Rebuild and verify both tests pass**

```bash
make rootfs && test/integration/test-session-packages.sh && make test-runtime
```

Expected: every `ok   -` line, including
`ok   - fullscreen X11 window spans both outputs (2560x720)`.

If the build fails inside the `labwc-build` stage with `patch does not apply`,
the scratch clone was not at tag 0.9.3 — regenerate the patch.

- [ ] **Step 8: Commit**

```bash
git add containers/ubuntu/patches/0001-fullscreen-span-outputs.patch \
        overlay/etc/dbrrg/labwc/environment Makefile test/runtime \
        test/integration/test-session-packages.sh
git commit -m "feat: fullscreen Xwayland windows span every output"
```

---

## Task 3: Patch B — zwp_xwayland_keyboard_grab_manager_v1

**Files:**
- Create: `containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch`
- Modify: `test/runtime/test-labwc-runtime.sh`,
  `test/integration/test-session-packages.sh`

**Interfaces:**
- Consumes: `test/runtime/x11-probe.py --grab` and the headless rig from
  Task 2.
- Produces: `view->keybinds_inhibited_by_grab`, honoured by
  `view_inhibits_actions()`, which already gates every keybind and mousebind
  site.

- [ ] **Step 1: Write the failing runtime assertion**

Append to `test/runtime/test-labwc-runtime.sh`, before `exit $fail`:

```bash
# Rootless Xwayland forwards XGrabKeyboard via
# zwp_xwayland_keyboard_grab_manager_v1, and only binds its grab hook if the
# compositor advertises that global. Seeing the request on the wire proves
# the whole chain: global advertised, filter allows Xwayland, client grabbed.
grab_out=$(podman run --rm \
    -e WLR_BACKENDS=headless \
    -e WLR_HEADLESS_OUTPUTS=2 \
    -e WLR_RENDERER=pixman \
    -e XDG_RUNTIME_DIR=/tmp/xdg \
    -e WAYLAND_DEBUG=1 \
    "$IMAGE" \
    sh -c 'mkdir -p /tmp/xdg && chmod 700 /tmp/xdg &&
           labwc -C /etc/dbrrg/labwc -S "python3 /usr/local/bin/x11-probe.py --grab"' 2>&1)

if echo "$grab_out" | grep -q 'zwp_xwayland_keyboard_grab_manager_v1.*grab_keyboard'; then
    echo "ok   - Xwayland forwarded the X11 keyboard grab to labwc"
else
    echo "FAIL - no grab_keyboard request seen; labwc is not advertising the manager"
    fail=1
fi
```

- [ ] **Step 2: Run it and watch it fail**

```bash
make test-runtime
```

Expected: the span assertion passes, then
`FAIL - no grab_keyboard request seen; labwc is not advertising the manager`.

- [ ] **Step 3: Write the protocol implementation**

In the scratch labwc clone (tag 0.9.3, same as Task 2 — start from a clean
`git checkout .` so Patch A's edit is not included in this diff), create
`src/protocols/xwayland-keyboard-grab.c`:

```c
// SPDX-License-Identifier: GPL-2.0-only
/*
 * dbrrg: zwp_xwayland_keyboard_grab_manager_v1
 *
 * Rootless Xwayland forwards X11 keyboard grabs (XGrabKeyboard) with this
 * protocol. It never uses zwp_keyboard_shortcuts_inhibit_manager_v1 - that
 * call site (maybe_fake_grab_devices) returns early when rootless, which is
 * always the case under labwc. While an X client holds a grab, labwc must
 * not swallow keys for its own bindings.
 *
 * Xwayland only installs its grab hook if this global is advertised, so a
 * compositor without it never learns about X grabs at all.
 */
#include <assert.h>
#include <stdlib.h>
#include <wayland-server-core.h>
#include <wlr/types/wlr_compositor.h>
#include "common/mem.h"
#include "labwc.h"
#include "view.h"
#include "xwayland-keyboard-grab-unstable-v1-protocol.h"

struct lab_keyboard_grab {
	struct wl_resource *resource;
	struct view *view;
	struct wl_listener on_view_destroy;
};

static void
handle_view_destroy(struct wl_listener *listener, void *data)
{
	struct lab_keyboard_grab *grab =
		wl_container_of(listener, grab, on_view_destroy);
	wl_list_remove(&grab->on_view_destroy.link);
	wl_list_init(&grab->on_view_destroy.link);
	grab->view = NULL;
}

static void
grab_handle_resource_destroy(struct wl_resource *resource)
{
	struct lab_keyboard_grab *grab = wl_resource_get_user_data(resource);

	if (grab->view) {
		grab->view->keybinds_inhibited_by_grab = false;
	}
	wl_list_remove(&grab->on_view_destroy.link);
	free(grab);
}

static void
grab_handle_destroy(struct wl_client *client, struct wl_resource *resource)
{
	wl_resource_destroy(resource);
}

static const struct zwp_xwayland_keyboard_grab_v1_interface grab_impl = {
	.destroy = grab_handle_destroy,
};

static void
manager_handle_grab_keyboard(struct wl_client *client,
		struct wl_resource *manager_resource, uint32_t id,
		struct wl_resource *surface_resource,
		struct wl_resource *seat_resource)
{
	struct lab_keyboard_grab *grab = znew(*grab);

	grab->resource = wl_resource_create(client,
		&zwp_xwayland_keyboard_grab_v1_interface,
		wl_resource_get_version(manager_resource), id);
	if (!grab->resource) {
		free(grab);
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(grab->resource, &grab_impl, grab,
		grab_handle_resource_destroy);

	wl_list_init(&grab->on_view_destroy.link);

	struct wlr_surface *surface = wlr_surface_from_resource(surface_resource);
	grab->view = surface ? view_from_wlr_surface(surface) : NULL;
	if (grab->view) {
		grab->on_view_destroy.notify = handle_view_destroy;
		wl_signal_add(&grab->view->events.destroy,
			&grab->on_view_destroy);
		grab->view->keybinds_inhibited_by_grab = true;
	}
}

static void
manager_handle_destroy(struct wl_client *client, struct wl_resource *resource)
{
	wl_resource_destroy(resource);
}

static const struct zwp_xwayland_keyboard_grab_manager_v1_interface manager_impl = {
	.destroy = manager_handle_destroy,
	.grab_keyboard = manager_handle_grab_keyboard,
};

static void
manager_bind(struct wl_client *client, void *data, uint32_t version,
		uint32_t id)
{
	struct wl_resource *resource = wl_resource_create(client,
		&zwp_xwayland_keyboard_grab_manager_v1_interface, version, id);
	if (!resource) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &manager_impl, NULL, NULL);
}

void
xwayland_keyboard_grab_manager_create(struct server *server)
{
	assert(server);
	wl_global_create(server->wl_display,
		&zwp_xwayland_keyboard_grab_manager_v1_interface, 1,
		NULL, manager_bind);
}
```

There is intentionally no per-view refcount: Xwayland's `set_grab()` destroys
its previous grab before creating a new one, so at most one grab exists per
seat.

- [ ] **Step 4: Wire it into the build and the server**

`protocols/meson.build` — add to the `server_protocols` list, after the
`xwayland-shell` entry:

```meson
	wl_protocol_dir / 'unstable/xwayland-keyboard-grab/xwayland-keyboard-grab-unstable-v1.xml',
```

(The file ships in Ubuntu 26.04's `wayland-protocols`; nothing to vendor.)

`src/protocols/meson.build` — add the source:

```meson
labwc_sources += files(
  'transaction-addon.c',
  'xwayland-keyboard-grab.c',
)
```

`include/view.h` — add the field directly below `inhibits_keybinds`
(line 189):

```c
	bool inhibits_keybinds; /* also inhibits mousebinds */
	/*
	 * dbrrg: set while an X11 client holds a keyboard grab forwarded by
	 * Xwayland. Kept separate from inhibits_keybinds, which the user
	 * toggles via the ToggleKeybinds action and which drives an SSD
	 * indicator - a grab must not clobber that state.
	 */
	bool keybinds_inhibited_by_grab;
```

`include/labwc.h` — declare the constructor next to the other server-side
prototypes:

```c
void xwayland_keyboard_grab_manager_create(struct server *server);
```

`src/view.c` — replace `view_inhibits_actions()` (line 2373):

```c
bool
view_inhibits_actions(struct view *view, struct wl_list *actions)
{
	if (!view) {
		return false;
	}
	/*
	 * dbrrg: a forwarded X11 grab takes everything, including
	 * ToggleKeybinds - the client asked for every key.
	 */
	if (view->keybinds_inhibited_by_grab) {
		return true;
	}
	return view->inhibits_keybinds && !actions_contain_toggle_keybinds(actions);
}
```

`src/server.c` — inside `server_init()`, next to the other manager
constructors (near the `wlr_tearing_control_manager_v1_create()` call at line
706):

```c
#if HAVE_XWAYLAND
	xwayland_keyboard_grab_manager_create(server);
#endif
```

`src/server.c` — in `server_global_filter()`, inside the existing
`#if HAVE_XWAYLAND` block that already computes `xwayland_client`, directly
after the `xwayland_shell_v1_interface` clause:

```c
	if (client != xwayland_client && !strcmp(iface->name,
			zwp_xwayland_keyboard_grab_manager_v1_interface.name)) {
		/*
		 * Only Xwayland may take keyboard grabs; for any other client
		 * this would be a global keylogger.
		 */
		return false;
	}
```

Add the generated header include at the top of `src/server.c` if it is not
already reachable:

```c
#include "xwayland-keyboard-grab-unstable-v1-protocol.h"
```

- [ ] **Step 5: Compile it before packaging it**

Building inside the .deb stage first would bury compiler errors in a long
build log. Compile in the scratch clone:

```bash
sudo apt-get build-dep -y labwc     # once, on the dev machine
meson setup build && ninja -C build -j4
```

Expected: a clean build. Two likely errors, both mechanical: a missing
`#include` for the generated protocol header, and `view->events.destroy` not
resolving — confirm the signal's exact name in `include/view.h` and use it.

- [ ] **Step 6: Generate the patch**

```bash
git diff > /path/to/repo/containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch
```

`git diff` does not include untracked files — `git add -N
src/protocols/xwayland-keyboard-grab.c` first, or the new file is silently
missing from the patch and the build will fail with an undefined reference to
`xwayland_keyboard_grab_manager_create`.

- [ ] **Step 7: Add the static assertion**

In `test/integration/test-session-packages.sh`, beside the other labwc checks:

```bash
if unsquashfs -no-xattrs -d "$DPKG_TMP/bin" "$SQSH" usr/bin/labwc >/dev/null 2>&1 &&
   grep -aq 'zwp_xwayland_keyboard_grab_manager_v1' "$DPKG_TMP/bin/usr/bin/labwc"; then
    echo "ok   - labwc implements zwp_xwayland_keyboard_grab_manager_v1"
else
    echo "FAIL - shipped labwc has no xwayland keyboard grab support"
    fail=1
fi
```

- [ ] **Step 8: Rebuild and verify everything passes**

```bash
make rootfs && test/integration/test-session-packages.sh && make test-runtime
```

Expected: all `ok   -`, including
`ok   - Xwayland forwarded the X11 keyboard grab to labwc` and the span
assertion from Task 2 still passing.

- [ ] **Step 9: Verify the zero-keybindings constraint still holds**

```bash
grep -c 'keybind' overlay/etc/dbrrg/labwc/rc.xml
```

Expected: only the explanatory comment matches; no `<keybind>` element and no
`<default />` exists. This patch does not license adding one.

- [ ] **Step 10: Commit**

```bash
git add containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch \
        test/runtime/test-labwc-runtime.sh \
        test/integration/test-session-packages.sh
git commit -m "feat: honour X11 keyboard grabs forwarded by Xwayland"
```

---

## Task 4: Correct the recorded knowledge

Two documented facts in this repo are wrong. Both were load-bearing for
decisions, so leaving them would send the next maintainer down the same dead
end.

**Files:**
- Modify: `CLAUDE.md`, `docs/controller-handoff.md`

**Interfaces:**
- Consumes: the behaviour shipped by Tasks 1-3.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Rewrite the keybindings constraint rationale**

In `CLAUDE.md`, under "labwc must have zero keybindings", replace the
paragraph beginning "labwc 0.9.3 does not implement
`zwp_keyboard_shortcuts_inhibit_manager_v1`" and the following paragraph
("If a future labwc gains this support...") with:

```markdown
The reason is *not* the missing `zwp_keyboard_shortcuts_inhibit_manager_v1` -
that was this repo's earlier explanation and it is wrong. Xwayland's only use
of that protocol is `maybe_fake_grab_devices()`, which returns immediately
when the server is rootless, and Xwayland is always rootless under labwc.

Rootless Xwayland instead forwards X11 grabs via
`zwp_xwayland_keyboard_grab_manager_v1`, which upstream labwc and every
wlroots compositor lack. Our labwc carries a patch implementing it
(`containers/ubuntu/patches/0002-xwayland-keyboard-grab.patch`), so a
keybinding *would* now be suspended while the ThinLinc client holds the
keyboard.

Keybindings nonetheless stay at zero until that path has been confirmed on
hardware with a real ThinLinc session. `vncviewer` calls `XGrabKeyboard`, and
the headless test asserts the request reaches labwc, but neither proves the
grab is held for the whole session. Adding a keybinding is now a config
decision rather than an impossibility - make it deliberately, and re-run
`make test-runtime` after.
```

- [ ] **Step 2: Document the patched labwc and the env var**

In `CLAUDE.md`, add to the `.dbrrg-environment` description a row for
`LABWC_FULLSCREEN_SPAN_OUTPUTS` (default `1`, set `0` for single-monitor
fullscreen), and add a "Patched labwc" subsection under Standing Constraints:

```markdown
### labwc is a local rebuild, not the archive package

`containers/ubuntu/Dockerfile` builds `labwc_0.9.3-1+dbrrg1` from Ubuntu's
source package with the patches in `containers/ubuntu/patches/`, applied as a
quilt series. Two behaviours depend on it:

- fullscreen Xwayland windows span every output
  (`LABWC_FULLSCREEN_SPAN_OUTPUTS`), which is what makes the ThinLinc client
  fill both monitors;
- `zwp_xwayland_keyboard_grab_manager_v1` exists, so X11 keyboard grabs
  suspend compositor keybindings.

Reverting to the archive `labwc` silently loses both. On a labwc or wlroots
version bump, expect to rebase the patches; `dpkg-buildpackage` fails loudly
when a hunk no longer applies, and `make test` plus `make test-runtime` cover
the rest. `_NET_WM_FULLSCREEN_MONITORS` was investigated and rejected - see
the design spec for why it is unnecessary.
```

- [ ] **Step 3: Close the handoff's open item**

In `docs/controller-handoff.md` §7, replace the "Multi-monitor fullscreen"
bullet with:

```markdown
- **Multi-monitor fullscreen: implemented, hardware-unverified.** labwc now
  carries a local patch spanning fullscreen Xwayland windows across the whole
  output layout. Proven in a headless two-output rig (`make test-runtime`);
  still unconfirmed against a real ThinLinc session on the dual-head machine.
  The `_NET_WM_FULLSCREEN_MONITORS` angle recorded here previously is
  unnecessary - TigerVNC derives its remote screen layout from the geometry it
  is actually given, not from that atom.
```

- [ ] **Step 4: Verify nothing else still asserts the old rationale**

```bash
grep -rn "shortcuts_inhibit" CLAUDE.md docs/ README.md
```

Expected: matches only in the design spec (which explains the correction) and
in the rewritten CLAUDE.md paragraph. Any other hit is stale text — fix it.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/controller-handoff.md
git commit -m "docs: correct the keybinding rationale and record the labwc patches"
```

---

## Done when

- `make test` passes, including the three new static assertions.
- `make test-runtime` reports both `ok` lines.
- `overlay/etc/dbrrg/labwc/rc.xml` still has zero keybindings.
- The remaining unknown is stated plainly to the user: the span is proven
  compositor-side only, and needs one boot on the dual-head machine with a
  real ThinLinc session to be called done.
