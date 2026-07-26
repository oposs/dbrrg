# Ubuntu 26.04 / Wayland / PipeWire Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the dbrrg thin-client image to Ubuntu 26.04 LTS with ThinLinc 4.20, fix the build bug that strips GPU firmware and CPU microcode from every shipped image, replace the X11 session stack with labwc/Wayland, and move audio to PipeWire.

**Architecture:** The image is built by `containers/ubuntu/Dockerfile` (rootfs + packages + overlay), exported to a squashfs by `scripts/export-rootfs.sh`, and packaged into a bootable USB image by `scripts/make-bootable-image.sh`. All system customisation lives in `overlay/`, applied over the container filesystem during build. This plan changes the base image, the package set, the `overlay/` session and audio files, and deletes two firmware-stripping hacks.

**Tech Stack:** Podman, Ubuntu 26.04 LTS (kernel 7.0, systemd 259), Dracut, SquashFS/OverlayFS/ZRAM, labwc (wlroots), Xwayland, PipeWire, ThinLinc client 4.20.

**Design doc:** `docs/superpowers/specs/2026-07-26-ubuntu-2604-upgrade-design.md`

**Deviation from the spec:** the spec calls for a `~/.config/labwc/autostart`
file plus a way to exit the compositor when the client quits. labwc turns out
to provide `-S, --session <command>` — "Run command on startup and terminate on
exit" — which does both. Task 4 uses `labwc -S /usr/local/bin/dbrrg-session`
and creates no `autostart` file.

## Global Constraints

- Container runtime is **podman**, never docker. The Makefile uses `CONTAINER_RUNTIME ?= podman`.
- **Never use more than 4 cores in parallel** — this machine is shared with other users. Task 0 adds `BUILD_JOBS ?= 4` and wires it into every parallel step. Never introduce `-T0`, an uncapped `mksquashfs`, or a `podman build` without `--cpus`.
- Graphical behaviour cannot be verified by an implementer. `make qemu-smoke` boots headless to `multi-user.target` and is the only boot check available during execution; anything involving the compositor, the ThinLinc window or keyboard behaviour belongs on the human checklist and must not be claimed as verified.
- All comments, variable names and technical documentation in **English**.
- Base image is exactly `ubuntu:26.04`.
- ThinLinc client is exactly `thinlinc-client_4.20.0-4284_amd64.deb`.
- Package installs use `--no-install-recommends --no-install-suggests`. This is load-bearing for the firmware set: `linux-firmware-minimal` only *recommends* the per-vendor subpackages, so dropping the flag silently reinstalls all ~1.5 GB.
- The `overlay/` tree is applied with `tar --exclude="*~"`, so editor backups are never shipped. Do not commit `*~` files.
- `overlay/home/tluser/**` must end up owned by `tluser` — the Dockerfile does `chown -R tluser:tluser /home/tluser` after the overlay is applied. Keep that step after any overlay change.
- **labwc must have zero keybindings.** labwc 0.9.3 does not implement `zwp_keyboard_shortcuts_inhibit_manager_v1`, so any keybinding registered by the compositor is a key that can never reach the remote ThinLinc session. Never add `<default />` or a `<keybind>` to `rc.xml`.
- Firmware is declared by package selection only. Never re-add a `find`/`rm -rf` cleanup over `/usr/lib/firmware`.

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `test/integration/test-firmware.sh` | Asserts the shipped squashfs contains the firmware the hardware needs. Regression test for the stripping bug. |
| `test/integration/test-session-packages.sh` | Asserts the squashfs has the Wayland session binaries and none of the removed X11 ones. |
| `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf` | Autologin `tluser` on tty1, giving a logind session on seat0. |
| `overlay/etc/profile.d/10-dbrrg-session.sh` | Starts the compositor on tty1 login. |
| `overlay/home/tluser/.config/labwc/rc.xml` | labwc config; deliberately zero keybindings. |
| `overlay/home/tluser/.config/labwc/environment` | XKB keyboard settings (replaces the Xorg InputClass). |
| `overlay/usr/local/bin/dbrrg-session` | Session body: restore home, run client, save home. Compositor exits when it returns. |
| `overlay/usr/local/bin/dbrrg-restore-home` | Home restore, lifted verbatim from the old Xsession.d hook. |
| `vendor/.gitignore` | Keeps the build-context directory for the local `oxulnk-desktop` deb. |

**Modified:** `containers/ubuntu/Dockerfile`, `scripts/export-rootfs.sh`, `Makefile`, `.dockerignore`, `.gitignore`, `overlay/opt/thinlinc/lib/tlclient/pulseaudio`, `README.md`, `CLAUDE.md`.

**Deleted:** `overlay/etc/default/nodm`, `overlay/etc/X11/xorg.conf.d/00-keyboard.conf`, `overlay/etc/X11/Xsession.d/39dbrrg-restore-home`, `overlay/etc/X11/Xsession.d/90dbrrg-start-thinlinc`, `overlay/home/tluser/.xsessionrc`.

**Task order is a de-risking order.** Firmware fix and base upgrade land first and are independently verifiable; the session change and the audio change — the two with real hardware risk — land last and separately, so a failure is attributable.

---

### Task 0: Build infrastructure — core cap and headless boot smoke test

Must land before any rebuild. Two independent build-system changes, added
during execution planning rather than in the original spec.

**Files:**
- Modify: `Makefile` (add `BUILD_JOBS`, apply it, add `qemu-smoke`)
- Modify: `containers/ubuntu/Dockerfile:104`
- Modify: `scripts/export-rootfs.sh` (mksquashfs `-processors`)
- Create: `scripts/check-boot-smoke.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `BUILD_JOBS` make variable (default 4, overridable);
  `make qemu-smoke` target; `scripts/check-boot-smoke.sh LOGFILE` exiting 0
  on a clean boot, 1 otherwise. Tasks 2 and 4 use `make qemu-smoke`.

- [ ] **Step 1: Add the BUILD_JOBS variable**

In `Makefile`, next to the other configuration variables:

```make
# Parallelism cap. This machine is shared - never use more than this many
# cores for compression, container builds or QEMU.
BUILD_JOBS ?= 4
```

- [ ] **Step 2: Apply the cap to every parallel step**

`Makefile` — the USB image compression currently uses `-T0` (all cores):

```make
	zstd -f -3 -T$(BUILD_JOBS) $(USB_IMAGE) -o $(USB_IMAGE_COMPRESSED)
```

`Makefile` — add `--cpus` to all three `podman build` invocations
(`.ubuntu-container`, `.ipxe-container`, `.image-builder-container`):

```make
	$(CONTAINER_RUNTIME) build --pull --progress=plain \
		--cpu-period=100000 --cpu-quota=$$(($(BUILD_JOBS)*100000)) \
```

**Corrected during execution.** The original plan text said `--cpus=$(BUILD_JOBS)`, which does not exist: podman 4.9.3's `build` subcommand offers only `--cpu-period`, `--cpu-quota`, `--cpuset-cpus` and `--cpuset-mems`. (`--cpus` exists on `podman run`, not `build`.) The CFS quota above is the equivalent — it caps total CPU time at `BUILD_JOBS` core-equivalents. `--cpuset-cpus` was rejected as the alternative because pinning to specific physical cores on a shared machine risks colliding with other users' pinned work.

`Makefile` — pass the cap into the rootfs export container by adding to the
existing `-e` flags on the `$(KERNEL) $(INITRD) $(SQUASHFS)` rule:

```make
		-e BUILD_JOBS=$(BUILD_JOBS) \
```

`containers/ubuntu/Dockerfile` — the dracut compression at line 104:

```dockerfile
    --compress "zstd -3 -T4" \
```

`scripts/export-rootfs.sh` — add near the other configuration defaults:

```sh
BUILD_JOBS="${BUILD_JOBS:-4}"
```

and add `-processors` to the `mksquashfs` invocation:

```sh
mksquashfs / "$SQSH_OUTPUT" \
    -comp "$SQUASHFS_COMP" \
    -Xcompression-level "$SQUASHFS_COMP_LEVEL" \
    -b 1M \
    -processors "$BUILD_JOBS" \
    -noappend \
    -no-progress \
    -e boot tmp var/tmp artifacts proc sys dev run || die "mksquashfs failed"
```

- [ ] **Step 3: Write the boot log checker**

Create `scripts/check-boot-smoke.sh`:

```bash
#!/bin/bash
# Assert that a headless QEMU boot log shows a healthy boot.
#
# Usage: scripts/check-boot-smoke.sh path/to/qemu-smoke.log

set -uo pipefail

LOG="${1:?usage: check-boot-smoke.sh LOGFILE}"

if [[ ! -s "$LOG" ]]; then
    echo "FAIL: $LOG is empty - the VM produced no serial output" >&2
    exit 1
fi

fail=0

want() {
    if grep -qE -- "$2" "$LOG"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (no match for: $2)"
        fail=1
    fi
}

unwant() {
    if grep -qE -- "$2" "$LOG"; then
        echo "FAIL - $1"
        grep -nE -- "$2" "$LOG" | head -3 | sed 's/^/         /'
        fail=1
    else
        echo "ok   - $1"
    fi
}

want   "reached multi-user target"   'Reached target.*[Mm]ulti-[Uu]ser'
unwant "no i915 DMC firmware error"  'Failed to load DMC firmware'
unwant "no GuC firmware error"       'GuC firmware.*fetch failed'
unwant "GPU not wedged"              'declaring it wedged'
unwant "no dracut emergency shell"   'Entering emergency mode|dracut: FATAL'
unwant "no kernel panic"             'Kernel panic'

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - boot log shows problems (full log: $LOG)"
    exit 1
fi

echo ""
echo "PASSED - clean boot"
exit 0
```

```bash
chmod +x scripts/check-boot-smoke.sh
```

- [ ] **Step 4: Add the qemu-smoke target**

In `Makefile`, add `qemu-smoke` to the `.PHONY` list and add this target.

QEMU boots the kernel and initramfs directly with `-kernel`/`-initrd` rather
than going through syslinux. That is deliberate: driving the bootloader menu
over a serial line is racy, and booting directly is deterministic while still
exercising everything that matters — the kernel, the initramfs, the dbrrg
dracut module, the squashfs mount, the overlay setup and systemd startup.
Syslinux itself is covered by the interactive `qemu-test` target.

```make
QEMU_SMOKE_LOG := $(IMAGE_DIR)/qemu-smoke.log
QEMU_SMOKE_TIMEOUT ?= 300

qemu-smoke: $(QCOW2_BOOT_IMAGE) $(KERNEL) $(INITRD)
	@echo "Running headless boot smoke test..."
	@rm -f $(QEMU_SMOKE_LOG)
	-timeout $(QEMU_SMOKE_TIMEOUT) qemu-system-x86_64 \
		-machine type=q35,accel=kvm \
		-cpu host,migratable=off \
		-smp $(BUILD_JOBS) \
		-m $(QEMU_MEMORY) \
		-display none \
		-no-reboot \
		-object rng-random,filename=/dev/urandom,id=rng0 \
		-device virtio-rng-pci,rng=rng0 \
		-net nic,model=virtio -net user \
		-drive file=$(QCOW2_BOOT_IMAGE),format=qcow2,if=virtio \
		-kernel $(KERNEL) \
		-initrd $(INITRD) \
		-append "ramroot=tl/ramroot.sqsh console=ttyS0,115200 systemd.unit=multi-user.target rd.info systemd.log_target=console" \
		-serial file:$(QEMU_SMOKE_LOG)
	@scripts/check-boot-smoke.sh $(QEMU_SMOKE_LOG)
```

- [ ] **Step 5: Verify the cap is actually applied**

```bash
grep -n 'BUILD_JOBS\|--cpus\|-T0' Makefile
grep -n 'T0\|T4' containers/ubuntu/Dockerfile
grep -n 'processors\|BUILD_JOBS' scripts/export-rootfs.sh
```

Expected: no `-T0` remains anywhere; `--cpus=$(BUILD_JOBS)` on all three
`podman build` lines; `-processors "$BUILD_JOBS"` in the mksquashfs call.

- [ ] **Step 6: Verify the checker logic without a VM**

The checker is testable directly. Run:

```bash
printf 'Reached target Multi-User System.\n' > /tmp/smoke-good.log
scripts/check-boot-smoke.sh /tmp/smoke-good.log; echo "exit=$?"

printf 'Reached target Multi-User System.\ni915 0000:00:02.0: [drm] Failed to load DMC firmware i915/adlp_dmc.bin\n' > /tmp/smoke-bad.log
scripts/check-boot-smoke.sh /tmp/smoke-bad.log; echo "exit=$?"

: > /tmp/smoke-empty.log
scripts/check-boot-smoke.sh /tmp/smoke-empty.log; echo "exit=$?"
```

Expected: `PASSED` and `exit=0` for the first; `FAIL - no i915 DMC firmware error` and `exit=1` for the second; `FAIL: /tmp/smoke-empty.log is empty` and `exit=1` for the third.

Do not run `make qemu-smoke` in this task — there is no 26.04 image yet. Task 2 is its first real use.

- [ ] **Step 7: Commit**

```bash
git add Makefile containers/ubuntu/Dockerfile scripts/export-rootfs.sh scripts/check-boot-smoke.sh
git commit -m "build: cap parallelism at 4 cores and add headless boot smoke test

This machine is shared; zstd -T0 and an uncapped mksquashfs were using all
128 cores during every build. BUILD_JOBS (default 4) now caps compression,
container builds and QEMU.

make qemu-smoke boots the image headless via -kernel/-initrd and asserts on
the serial log, so boot regressions are catchable without a human watching a
GTK window. Driving syslinux over serial would be racy; the interactive
qemu-test target still covers the bootloader."
```

---

### Task 1: Firmware regression test (red)

This test must FAIL at the end of this task. It documents the bug before fixing it.

**Files:**
- Create: `test/integration/test-firmware.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `test/integration/test-firmware.sh [path-to-squashfs]`, exit 0 on pass, 1 on failure. Task 2 consumes it.

- [ ] **Step 1: Write the failing test**

Create `test/integration/test-firmware.sh`:

```bash
#!/bin/bash
# Regression test for the firmware-stripping bug.
#
# scripts/export-rootfs.sh used to run
#     find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete
# immediately before mksquashfs. That deleted every firmware file except
# iwlwifi*, which left deployed clients without i915 GPU firmware (wedged
# GPU, no runtime power management) and without CPU microcode.
#
# Usage: test/integration/test-firmware.sh [path/to/ramroot.sqsh]

set -uo pipefail

SQSH="${1:-artifacts/rootfs/ramroot.sqsh}"

if [[ ! -f "$SQSH" ]]; then
    echo "FAIL: $SQSH not found - run 'make rootfs' first" >&2
    exit 1
fi

if ! command -v unsquashfs >/dev/null 2>&1; then
    echo "FAIL: unsquashfs not installed (apt install squashfs-tools)" >&2
    exit 1
fi

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

if ! unsquashfs -l "$SQSH" >"$LIST" 2>/dev/null; then
    echo "FAIL: cannot list $SQSH" >&2
    exit 1
fi

fail=0
check() {
    local desc="$1" pattern="$2"
    if grep -qE -- "$pattern" "$LIST"; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (no match for: $pattern)"
        fail=1
    fi
}

# Alder Lake GPU firmware - the exact files the field dmesg reported missing.
# Files ship zstd-compressed, so the patterns intentionally omit any suffix.
check "i915 DMC firmware (adlp_dmc.bin)"     'usr/lib/firmware/i915/adlp_dmc\.bin'
check "i915 GuC firmware (adlp_guc_70.bin)"  'usr/lib/firmware/i915/adlp_guc_70\.bin'
# Deleted by the same bug: clients have never had microcode updates.
check "Intel CPU microcode"                  'usr/lib/firmware/intel-ucode/'
# On 26.04 the real iwlwifi files live under intel/iwlwifi/ with top-level
# compat symlinks; assert the real path.
check "Intel WiFi firmware"                  'usr/lib/firmware/intel/iwlwifi/iwlwifi-'
check "Intel SOF audio firmware"             'usr/lib/firmware/intel/sof/'
check "Realtek NIC firmware"                 'usr/lib/firmware/rtl_nic/'

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - shipped image is missing firmware"
    exit 1
fi

echo ""
echo "PASSED - all expected firmware present"
exit 0
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x test/integration/test-firmware.sh
```

- [ ] **Step 3: Run it against the existing artifact to verify it fails**

```bash
test/integration/test-firmware.sh
```

Expected: `FAIL - i915 DMC firmware`, `FAIL - Intel CPU microcode`, and others, ending in `FAILED - shipped image is missing firmware`, exit code 1.

If `artifacts/rootfs/ramroot.sqsh` does not exist, run `make rootfs` on the **current, unmodified** tree first so the test runs against the buggy output.

Note: `Intel SOF audio firmware` and `Realtek NIC firmware` will also fail here, because those packages are not installed yet — Task 2 adds them. `Intel WiFi firmware` will fail against a 24.04-built squashfs because 24.04 puts iwlwifi at the top level; Task 2's 26.04 build moves it to `intel/iwlwifi/`.

- [ ] **Step 4: Commit**

```bash
git add test/integration/test-firmware.sh
git commit -m "test: add firmware regression test (currently failing)

Asserts the shipped squashfs contains i915 GPU firmware, CPU microcode,
iwlwifi, SOF audio and Realtek NIC firmware. Fails against the current
build because export-rootfs.sh strips everything except iwlwifi*."
```

---

### Task 2: Ubuntu 26.04 base, ThinLinc 4.20, declarative firmware

Makes Task 1's test pass. Session stack (`xorg`/`nodm`/`wm2`) and audio (`pulseaudio`) are deliberately left alone here so that any breakage is attributable to the base upgrade alone.

**Files:**
- Modify: `containers/ubuntu/Dockerfile:1` (base image), `:5-49` (package list), `:52-55` (ThinLinc), `:104-118` (firmware cleanup)
- Modify: `scripts/export-rootfs.sh:44`
- Test: `test/integration/test-firmware.sh`

**Interfaces:**
- Consumes: `test/integration/test-firmware.sh` from Task 1.
- Produces: an image based on `ubuntu:26.04` with kernel 7.0 and the firmware package set. Tasks 3-5 build on this Dockerfile.

- [ ] **Step 1: Change the base image**

In `containers/ubuntu/Dockerfile`, line 1:

```dockerfile
FROM ubuntu:26.04
```

- [ ] **Step 2: Fix the obsolete package and add the firmware set**

In the single `apt-get install` block, replace `wireless-tools` with `iw`. `wireless-tools` has no installation candidate on 26.04 and the build will fail with `E: Package 'wireless-tools' has no installation candidate` if left in.

Then add these lines to the same block:

```dockerfile
    linux-firmware-minimal \
    linux-firmware-intel-graphics \
    linux-firmware-intel-wireless \
    linux-firmware-realtek \
    firmware-sof-signed \
```

`linux-image-generic` hard-depends on `linux-firmware`; `linux-firmware-minimal` satisfies that through `Provides`/`Replaces`/`Conflicts` while only *recommending* the per-vendor packages. With `--no-install-recommends` the installed set is exactly what is listed.

- [ ] **Step 3: Bump the ThinLinc client**

Replace the ThinLinc `RUN` block with:

```dockerfile
# Install ThinLinc
RUN wget https://www.cendio.com/downloads/clients/thinlinc-client_4.20.0-4284_amd64.deb && \
    apt install -y ./thinlinc-client_4.20.0-*_amd64.deb && \
    rm -f thinlinc-client_*.deb
```

Note the `rm` pattern is corrected — the old `rm -f tl-*deb` never matched the downloaded file, leaving a 30 MB deb in the image.

- [ ] **Step 4: Delete the firmware cleanup block**

Remove this entire `RUN` block from the Dockerfile:

```dockerfile
RUN cd /usr/lib/firmware && \
    mkdir -p /tmp/fw-keep && \
    mv iwlwifi-* i915 intel intel-ucode /tmp/fw-keep/ 2>/dev/null || true && \
    rm -rf /usr/lib/firmware/* && \
    mv /tmp/fw-keep/* /usr/lib/firmware/ && \
    rm -rf /tmp/fw-keep && \
    rm -rf /usr/lib/firmware/intel/{ice,vpu,vsc,ipu} && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* && \
    apt-get -qqy clean && apt-get -qqy autoremove
```

and replace it with the non-firmware part only:

```dockerfile
# Cleanup. Firmware content is determined by package selection alone -
# see the linux-firmware-minimal + per-vendor packages above. Never
# re-introduce a find/rm sweep over /usr/lib/firmware.
RUN rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* && \
    apt-get -qqy clean && apt-get -qqy autoremove
```

- [ ] **Step 5: Delete the firmware strip in the export script**

In `scripts/export-rootfs.sh`, delete this line entirely:

```sh
find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete 2>/dev/null || true
```

The surrounding cleanup step becomes:

```sh
# Cleanup
log_step "Cleaning up rootfs..."
rm -rf /boot/* /.dockerenv /etc/machine-id /var/lib/dbus/machine-id /var/log/* /tmp/* /var/tmp/*
log_success "Cleanup complete"
```

- [ ] **Step 6: Rebuild the rootfs**

```bash
make clean && make rootfs
```

Expected: build succeeds. If it fails on a package name, check it against 26.04 before improvising a substitute.

- [ ] **Step 7: Run the firmware test to verify it now passes**

```bash
test/integration/test-firmware.sh
```

Expected: six `ok -` lines and `PASSED - all expected firmware present`, exit code 0.

- [ ] **Step 8: Confirm the base actually changed**

```bash
podman run --rm dbrrg-ubuntu:2.0.0 cat /etc/os-release | grep PRETTY_NAME
podman run --rm dbrrg-ubuntu:2.0.0 ls /lib/modules
```

Expected: `PRETTY_NAME="Ubuntu 26.04 LTS"` and a `7.0.0-*-generic` module directory.

- [ ] **Step 9: Verify the initramfs built against kernel 7.0**

The Dockerfile's dracut invocation picks the kernel with `ls /lib/modules | head -1`. Confirm it resolved to the 7.0 kernel and that the dbrrg module is inside:

```bash
podman run --rm dbrrg-ubuntu:2.0.0 sh -c 'ls /boot/initrd.img-*'
lsinitrd artifacts/rootfs/initrd.img 2>/dev/null | grep -E 'dbrrg|mount-squashfs' | head
```

Expected: the initrd filename carries a `7.0.0-*` version, and `mount-squashfs.sh`, `setup-overlay.sh` and `parse-dbrrg.sh` are listed. If `lsinitrd` is unavailable on the host, this is covered by the boot in step 10 — a missing dbrrg module fails the boot outright.

- [ ] **Step 10: Boot it headlessly**

```bash
make image && make qemu-smoke
```

Expected: `PASSED - clean boot`. Note the squashfs size for comparison.

This is the first real use of the Task 0 smoke target. The i915 assertions in `check-boot-smoke.sh` are meaningful here — a QEMU guest has no Intel GPU, so they cannot fail for hardware reasons; they would only fire if something re-introduced firmware loading errors. The authoritative i915 check is on real hardware.

Interactive `make qemu-test` is not run by the implementer; it is on the human checklist at the end of this plan.

- [ ] **Step 11: Commit**

```bash
git add containers/ubuntu/Dockerfile scripts/export-rootfs.sh
git commit -m "feat: upgrade to Ubuntu 26.04, ThinLinc 4.20, declarative firmware

Base image 24.04 -> 26.04 LTS (kernel 7.0, systemd 259).
ThinLinc client 4.19.0-4005 -> 4.20.0-4284.

Firmware is now selected by package instead of by rm -rf: 26.04 splits
linux-firmware per vendor, and linux-firmware-minimal satisfies
linux-image-generic's dependency while recommending (not depending on)
the rest. Removes both firmware-stripping hacks, including the one in
export-rootfs.sh that deleted i915 firmware and intel-ucode from every
shipped image.

wireless-tools is obsolete on 26.04; replaced with iw."
```

---

### Task 3: VA-API packages and the oxulnk-desktop deb

**Files:**
- Modify: `containers/ubuntu/Dockerfile` (package list, plus a new `COPY`)
- Modify: `Makefile`, `.dockerignore`, `.gitignore`
- Create: `vendor/.gitignore`

**Interfaces:**
- Consumes: the 26.04 Dockerfile from Task 2.
- Produces: `OXULNK_DEB` Makefile variable (absolute path to the deb, overridable on the command line); `vendor/oxulnk-desktop.deb` inside the build context.

- [ ] **Step 1: Create the vendor directory**

`vendor/.gitignore`:

```gitignore
# Local build inputs staged into the container build context.
*.deb
```

- [ ] **Step 2: Allow vendor/ into the build context**

`.dockerignore` currently excludes everything except a whitelist. Add `vendor`:

```gitignore
*
*~
!overlay
!*.patch
!syslinux.cfg
!vendor
```

Without this the `COPY` in step 4 fails with `no such file or directory`.

- [ ] **Step 3: Stage the deb from the Makefile**

Add near the other configuration variables in `Makefile`:

```make
# Local (non-archive) packages staged into the container build context
OXULNK_DEB ?= /scratch/oetiker/cargo-target/oxulnk-desktop-ux-fixes-2404/debian/oxulnk-desktop_0.1.0+dev20260726183924_amd64.deb
```

Add this rule:

```make
vendor/oxulnk-desktop.deb: $(OXULNK_DEB)
	@mkdir -p vendor
	cp $< $@
```

and add it as a prerequisite of the container build:

```make
.ubuntu-container: containers/ubuntu/Dockerfile vendor/oxulnk-desktop.deb $(OVERLAY_FILES) | $(ROOTFS_DIR)
```

- [ ] **Step 4: Install the packages in the Dockerfile**

Add to the main `apt-get install` block:

```dockerfile
    vainfo \
    intel-media-va-driver \
    i965-va-driver \
```

`intel-media-va-driver` is the iHD driver used by Alder Lake and newer; `i965-va-driver` covers pre-Broadwell parts.

Then, immediately after the ThinLinc install block, add:

```dockerfile
# Install locally built packages staged by the Makefile into vendor/
COPY vendor/oxulnk-desktop.deb /tmp/oxulnk-desktop.deb
RUN apt-get install -yq --no-install-recommends /tmp/oxulnk-desktop.deb && \
    rm -f /tmp/oxulnk-desktop.deb
```

This must come **before** the `ADD overlay/` block, so overlay files can still override anything the package ships.

- [ ] **Step 5: Rebuild and verify both packages landed**

```bash
make rootfs
podman run --rm dbrrg-ubuntu:2.0.0 sh -c 'which vainfo oxulnk-desktop && dpkg -l oxulnk-desktop | tail -1'
```

Expected: both paths print, and the `dpkg -l` line shows `ii  oxulnk-desktop  0.1.0+dev20260726183924`.

- [ ] **Step 6: Verify the firmware test still passes**

```bash
test/integration/test-firmware.sh
```

Expected: `PASSED`.

- [ ] **Step 7: Commit**

```bash
git add Makefile .dockerignore vendor/.gitignore containers/ubuntu/Dockerfile
git commit -m "feat: add VA-API packages and oxulnk-desktop

vainfo plus the iHD and i965 VA-API drivers for hardware video decode.
oxulnk-desktop is staged from a local path into vendor/ by the Makefile
(override with OXULNK_DEB=) because the container build context is a
strict whitelist."
```

---

### Task 4: Wayland session (labwc) replacing nodm/xorg/wm2

**Files:**
- Modify: `containers/ubuntu/Dockerfile` (package list)
- Create: `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`
- Create: `overlay/etc/profile.d/10-dbrrg-session.sh`
- Create: `overlay/home/tluser/.config/labwc/rc.xml`
- Create: `overlay/home/tluser/.config/labwc/environment`
- Create: `overlay/usr/local/bin/dbrrg-session`
- Create: `overlay/usr/local/bin/dbrrg-restore-home`
- Create: `test/integration/test-session-packages.sh`
- Delete: `overlay/etc/default/nodm`, `overlay/etc/X11/xorg.conf.d/00-keyboard.conf`, `overlay/etc/X11/Xsession.d/39dbrrg-restore-home`, `overlay/etc/X11/Xsession.d/90dbrrg-start-thinlinc`, `overlay/home/tluser/.xsessionrc`

**Interfaces:**
- Consumes: the Dockerfile from Task 3.
- Produces: `/usr/local/bin/dbrrg-session` (invoked as `labwc -S /usr/local/bin/dbrrg-session`); `/usr/local/bin/dbrrg-restore-home` (no arguments, no output contract). Task 5 modifies only the audio wrapper and does not touch these.

- [ ] **Step 1: Write the session-package test**

Create `test/integration/test-session-packages.sh`:

```bash
#!/bin/bash
# Asserts the Wayland session stack shipped and the X11 stack did not.
#
# Usage: test/integration/test-session-packages.sh [path/to/ramroot.sqsh]

set -uo pipefail

SQSH="${1:-artifacts/rootfs/ramroot.sqsh}"

if [[ ! -f "$SQSH" ]]; then
    echo "FAIL: $SQSH not found - run 'make rootfs' first" >&2
    exit 1
fi

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
unsquashfs -l "$SQSH" >"$LIST" 2>/dev/null || { echo "FAIL: cannot list $SQSH" >&2; exit 1; }

fail=0
present() {
    if grep -qE -- "$2" "$LIST"; then
        echo "ok   - $1 present"
    else
        echo "FAIL - $1 missing (no match for: $2)"
        fail=1
    fi
}
absent() {
    if grep -qE -- "$2" "$LIST"; then
        echo "FAIL - $1 should have been removed (matched: $2)"
        fail=1
    else
        echo "ok   - $1 absent"
    fi
}

present "labwc"            'usr/bin/labwc$'
present "Xwayland"         'usr/bin/Xwayland$'
present "foot"             'usr/bin/foot$'
present "session script"   'usr/local/bin/dbrrg-session$'
present "restore-home"     'usr/local/bin/dbrrg-restore-home$'
present "labwc rc.xml"     'home/tluser/\.config/labwc/rc\.xml$'
present "tty1 autologin"   'getty@tty1\.service\.d/autologin\.conf$'

absent  "Xorg server"      'usr/lib/xorg/Xorg$'
absent  "nodm"             'usr/sbin/nodm$'
absent  "wm2"              'usr/bin/wm2$'
absent  "lxterminal"       'usr/bin/lxterminal$'

# Guard the standing constraint: labwc must register no keybindings, because
# it does not implement zwp_keyboard_shortcuts_inhibit_manager_v1 and any
# binding it owns can never reach the remote ThinLinc session.
RC=$(mktemp -d)
trap 'rm -rf "$LIST" "$RC"' EXIT
if unsquashfs -q -f -d "$RC" "$SQSH" 'home/tluser/.config/labwc/rc.xml' >/dev/null 2>&1; then
    if grep -qE '<keybind|<default */>' "$RC/home/tluser/.config/labwc/rc.xml"; then
        echo "FAIL - rc.xml registers keybindings (breaks remote key passthrough)"
        fail=1
    else
        echo "ok   - rc.xml registers no keybindings"
    fi
else
    echo "FAIL - could not extract rc.xml from image"
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo ""
    echo "FAILED - session stack is not as expected"
    exit 1
fi

echo ""
echo "PASSED - Wayland session stack correct"
exit 0
```

- [ ] **Step 2: Make it executable and run it to verify it fails**

```bash
chmod +x test/integration/test-session-packages.sh
test/integration/test-session-packages.sh
```

Expected: `FAIL - labwc missing`, `FAIL - Xorg server should have been removed`, etc., exit 1.

- [ ] **Step 3: Swap the packages**

In `containers/ubuntu/Dockerfile`, remove these from the install block:

```
xorg
nodm
wm2
numlockx
lxterminal
xserver-xorg-video-intel
```

and add:

```dockerfile
    labwc \
    xwayland \
    foot \
    foot-terminfo \
    xfonts-base \
    fonts-dejavu-core \
```

`xfonts-base` and `fonts-dejavu-core` were previously pulled in by the `xorg` metapackage; the ThinLinc client still needs core X fonts under Xwayland. `numlockx` is X11-only and is replaced by labwc's `<numlock>` setting.

- [ ] **Step 4: Create the tty1 autologin drop-in**

`overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`:

```ini
# Autologin tluser on the first VT. This replaces nodm, which was an X11-only
# display manager. The resulting login creates a real logind session on seat0,
# which is what labwc needs for DRM/input access (so no seatd is required) and
# what provides XDG_RUNTIME_DIR for the PipeWire user services.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin tluser --noclear %I $TERM
```

- [ ] **Step 5: Create the compositor launcher**

`overlay/etc/profile.d/10-dbrrg-session.sh`:

```sh
# Start the Wayland session after autologin on the first VT.
#
# labwc -S runs the given command on startup and terminates when it exits,
# so the compositor's lifetime is exactly the session's lifetime.
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc -S /usr/local/bin/dbrrg-session
fi
```

- [ ] **Step 6: Create the labwc configuration**

`overlay/home/tluser/.config/labwc/rc.xml`:

```xml
<?xml version="1.0"?>
<!--
  dbrrg labwc configuration.

  IMPORTANT: the <keyboard> section deliberately contains no <default />
  element and no <keybind> entries, so labwc registers ZERO keybindings.

  This is required, not cosmetic. labwc 0.9.3 does not implement
  zwp_keyboard_shortcuts_inhibit_manager_v1, so a remote-desktop client
  cannot reclaim keys that the compositor has bound - even though Xwayland
  requests inhibition on XGrabKeyboard and wlroots implements the server
  side. Every keybinding added here is a key combination that can never
  reach the ThinLinc session.

  labwc treats default keybinds as opt-in: omitting <default /> yields none.
-->
<labwc_config>
  <keyboard>
    <numlock>on</numlock>
    <repeatDelay>500</repeatDelay>
    <repeatRate>30</repeatRate>
  </keyboard>
  <mouse>
  </mouse>
</labwc_config>
```

`overlay/home/tluser/.config/labwc/environment`:

```sh
# Keyboard configuration. Replaces the Xorg InputClass that used to live in
# /etc/X11/xorg.conf.d/00-keyboard.conf.
XKB_DEFAULT_MODEL=pc105
XKB_DEFAULT_LAYOUT=us
XKB_DEFAULT_OPTIONS=compose:menu,ctrl:nocaps
```

- [ ] **Step 7: Create the session scripts**

`overlay/usr/local/bin/dbrrg-restore-home` — the body is lifted verbatim from the old `overlay/etc/X11/Xsession.d/39dbrrg-restore-home`, with a shebang added:

```sh
#!/bin/sh
# Restore /home/tluser from the boot medium.
#
# Network boot: fetch home.pkg from the boot server over HTTP.
# USB boot:     untar home.tar.gz from the EFI-SYSTEM partition.
#
# Formerly /etc/X11/Xsession.d/39dbrrg-restore-home.
BASE_PATH=$(cat /proc/cmdline | sed -n 's/.*ramroot=\(.*\)\/.*$/\1/p')
MAC_ADDR=$(cat /sys/class/net/$(ip  addr show  | sed -n 's/^2: *\([^: ]*\).*$/\1/p')/address)
BOOT_SRV=$(cat /proc/cmdline | sed -n 's/.*ramroot=http.*\/\/\([^/:]*\).*/\1/p')
cd $HOME
if [ "" != "$BOOT_SRV" ]; then
  while true; do
    ping -nc 1 $BOOT_SRV && break
    sleep 1
  done
  curl ${BASE_PATH}/home.pkg?mac=${MAC_ADDR} | /bin/tar -zxf -
elif [ -b /dev/disk/by-partlabel/EFI-SYSTEM ]; then
  sudo mkdir -p /boot/efi
  sudo mount /dev/disk/by-partlabel/EFI-SYSTEM /boot/efi
  if [ -f /boot/efi/home.tar.gz ]; then
    sudo cat /boot/efi/home.tar.gz | /bin/tar -zxf -
  fi
  sudo umount /boot/efi
fi
```

`overlay/usr/local/bin/dbrrg-session`:

```sh
#!/bin/sh
# Body of the graphical session, run by labwc via 'labwc -S'.
#
# Ordering matches the Xsession.d hooks this replaces:
#   39dbrrg-restore-home  -> dbrrg-restore-home
#   90dbrrg-start-thinlinc -> tlclient, then save-home
#
# When this script returns, labwc terminates and the tty1 login starts a
# fresh session. Leaving the compositor running would strand the user on a
# bare desktop with no keybindings and no way to recover.
/usr/local/bin/dbrrg-restore-home
/opt/thinlinc/bin/tlclient
/opt/thinlinc/bin/save-home
```

- [ ] **Step 8: Make the new scripts executable**

```bash
chmod +x overlay/usr/local/bin/dbrrg-session overlay/usr/local/bin/dbrrg-restore-home
```

The overlay is applied with `tar`, which preserves the mode. If these are not executable the session dies immediately at boot.

- [ ] **Step 9: Delete the X11 session files**

```bash
git rm overlay/etc/default/nodm \
       overlay/etc/X11/xorg.conf.d/00-keyboard.conf \
       overlay/etc/X11/Xsession.d/39dbrrg-restore-home \
       overlay/etc/X11/Xsession.d/90dbrrg-start-thinlinc \
       overlay/home/tluser/.xsessionrc
```

Note `90dbrrg-start-thinlinc`'s PulseAudio-disabling lines are dropped entirely, not carried over — Task 5 replaces that mechanism.

- [ ] **Step 10: Rebuild and run both tests**

```bash
make rootfs
test/integration/test-firmware.sh
test/integration/test-session-packages.sh
```

Expected: both print `PASSED`.

- [ ] **Step 11: Boot it headlessly**

```bash
make image && make qemu-smoke
```

Expected: `PASSED - clean boot`.

Note what this does and does not prove. `qemu-smoke` boots to `multi-user.target`, so it verifies the system still boots with the X11 stack removed — it does **not** start the graphical session. Add this assertion, which is checkable from the multi-user boot:

```bash
grep -E 'getty@tty1|autologin' artifacts/images/qemu-smoke.log | head
```

Expected: tty1 getty starts with the autologin override.

The compositor itself (labwc starts, ThinLinc appears, no keybindings respond) requires the interactive `make qemu-test` and is on the human checklist at the end of this plan. Do not mark this task's graphical behaviour verified.

- [ ] **Step 12: Commit**

```bash
git add -A overlay test/integration/test-session-packages.sh containers/ubuntu/Dockerfile
git commit -m "feat: replace X11 session with labwc/Wayland

nodm/xorg/wm2/numlockx/lxterminal out, labwc/Xwayland/foot in. wm2 has no
EWMH support, so the fullscreen hints the ThinLinc client sets were ignored.

No display manager: getty autologin on tty1 plus a profile.d hook running
'labwc -S dbrrg-session', so the compositor lives exactly as long as the
session. The Xsession.d hooks become /usr/local/bin/dbrrg-session and
dbrrg-restore-home with their ordering preserved.

labwc is configured with zero keybindings. This is mandatory: labwc 0.9.3
does not implement zwp_keyboard_shortcuts_inhibit_manager_v1, so any key
it binds can never reach the remote session."
```

---

### Task 5: PipeWire audio and the translating ThinLinc wrapper

**Files:**
- Modify: `containers/ubuntu/Dockerfile` (package list)
- Modify: `overlay/opt/thinlinc/lib/tlclient/pulseaudio` (full rewrite)

**Interfaces:**
- Consumes: the session from Task 4 (the wrapper needs `XDG_RUNTIME_DIR` and a logind user session, both provided by the tty1 autologin).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Swap the audio packages**

In `containers/ubuntu/Dockerfile`, remove:

```
pulseaudio
alsa-base
```

and add:

```dockerfile
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-audio \
    wireplumber \
    libspa-0.2-bluetooth \
    pulseaudio-utils \
    alsa-utils \
```

`pulseaudio-utils` provides `pactl`, which the wrapper depends on. `libspa-0.2-bluetooth` is needed because the image ships `bluetooth`. `alsa-base` is version 1.0.25 and obsolete; `alsa-utils` provides `alsamixer`/`speaker-test` for diagnosis.

- [ ] **Step 2: Remove the pulseaudio user-service disabling**

The Dockerfile contains:

```dockerfile
# Disable pulseaudio auto-start
RUN sudo -u tluser systemctl --user disable pulseaudio.service pulseaudio.socket || true
```

Delete it. With PipeWire there is no user PulseAudio to disable, and the socket-activated PipeWire units must remain enabled.

- [ ] **Step 3: Rewrite the ThinLinc audio wrapper**

Replace the entire contents of `overlay/opt/thinlinc/lib/tlclient/pulseaudio`:

```sh
#!/bin/sh
# Replacement for the PulseAudio 6.0 daemon that Cendio bundles with the
# ThinLinc client at /opt/thinlinc/lib/tlclient/pulseaudio.
#
# The client spawns this binary expecting a PulseAudio daemon that loads a
# module such as
#     module-native-protocol-tcp listen=127.0.0.1 port=4713 cookie='/path'
# and then stays in the foreground until killed.
#
# We do not start a second sound daemon. Instead we load the equivalent
# module into the session's PipeWire pulse server and block until told to
# stop.
#
# Argument translation: 'cookie=' is not a valid argument for either
# PulseAudio 17 or PipeWire's module-native-protocol-tcp - PulseAudio accepts
# auth-cookie/auth-cookie-enabled/auth-anonymous/auth-ip-acl/port/listen, and
# PipeWire accepts only port/listen/auth-anonymous. It is presumably an
# argument Cendio's patched PulseAudio 6.0 understands. We therefore drop it
# and authenticate anonymously. The listener is bound to loopback only, and
# this is a single-user kiosk, so the exposure is limited to local processes.
#
# The module spec is rebuilt into the argument list positionally rather than
# re-split from the original string, so no eval is needed and the quoting in
# cookie='...' cannot leak through.

set -u
unset LD_LIBRARY_PATH

log() { echo "dbrrg-tlclient-audio: $*" >&2; }

# --- locate the module specification among the arguments --------------------
spec=
for arg in "$@"; do
    case "$arg" in
        module-*) spec="$arg" ;;
    esac
done

if [ -z "$spec" ]; then
    log "no module specification found in arguments: $*"
    exit 1
fi

# --- translate it -----------------------------------------------------------
module_name=${spec%% *}
listen=
port=
for token in $spec; do
    case "$token" in
        listen=*) listen=$token ;;
        port=*)   port=$token ;;
    esac
done

set -- "$module_name"
[ -n "$listen" ] && set -- "$@" "$listen"
[ -n "$port" ] && set -- "$@" "$port"
set -- "$@" auth-anonymous=true

# --- make sure the pulse-compatible server is running -----------------------
systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service \
    >/dev/null 2>&1 || true

i=0
until pactl info >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 100 ]; then
        log "pipewire-pulse did not become available after 10s"
        exit 1
    fi
    sleep 0.1
done

# --- load the module --------------------------------------------------------
index=$(pactl load-module "$@")
if [ -z "$index" ]; then
    log "load-module failed: $*"
    exit 1
fi
log "loaded '$*' as module index $index"

cleanup() {
    pactl unload-module "$index" >/dev/null 2>&1 || true
    exit 0
}
trap cleanup TERM INT HUP

# --- behave like the daemon the client thinks it started --------------------
# Poll rather than sleep forever: a POSIX shell only runs traps between
# commands, so a short sleep bounds teardown latency.
while pactl info >/dev/null 2>&1; do
    sleep 1
done

cleanup
```

- [ ] **Step 4: Verify the wrapper is executable and still overrides the bundled binary**

```bash
chmod +x overlay/opt/thinlinc/lib/tlclient/pulseaudio
grep -n 'ADD overlay/' containers/ubuntu/Dockerfile
```

The `ADD overlay/` line must appear **after** the ThinLinc install block, otherwise the ThinLinc package overwrites the wrapper with Cendio's PulseAudio 6.0 binary.

- [ ] **Step 5: Unit-test the argument translation on the host**

The translation logic is the risky part and is testable without hardware. Run:

```bash
sh -c '
spec="module-native-protocol-tcp listen=127.0.0.1 port=4713 cookie='"'"'/tmp/c'"'"'"
module_name=${spec%% *}
listen=; port=
for token in $spec; do
  case "$token" in listen=*) listen=$token ;; port=*) port=$token ;; esac
done
set -- "$module_name"
[ -n "$listen" ] && set -- "$@" "$listen"
[ -n "$port" ] && set -- "$@" "$port"
set -- "$@" auth-anonymous=true
echo "$@"
'
```

Expected output, exactly:

```
module-native-protocol-tcp listen=127.0.0.1 port=4713 auth-anonymous=true
```

The `cookie=` token must be gone and no stray quotes present.

- [ ] **Step 6: Rebuild and check the audio stack shipped**

```bash
make rootfs
podman run --rm dbrrg-ubuntu:2.0.0 sh -c 'which pactl pipewire wireplumber; dpkg -l pulseaudio 2>/dev/null | tail -1'
test/integration/test-firmware.sh
test/integration/test-session-packages.sh
```

Expected: the three binaries resolve, `pulseaudio` is not installed, both tests `PASSED`.

- [ ] **Step 7: Commit**

```bash
git add containers/ubuntu/Dockerfile overlay/opt/thinlinc/lib/tlclient/pulseaudio
git commit -m "feat: move audio to PipeWire with a translating tlclient wrapper

The ThinLinc client spawns /opt/thinlinc/lib/tlclient/pulseaudio expecting a
PulseAudio daemon that loads module-native-protocol-tcp and stays in the
foreground. The overlay has always replaced Cendio's bundled PulseAudio 6.0
because it cannot drive modern SOF/HDA hardware.

The wrapper now loads the module into the session's PipeWire pulse server
instead of starting a second daemon, and translates the module spec:
cookie= is not valid for PulseAudio 17 or PipeWire, so it is dropped in
favour of auth-anonymous=true on the loopback-only listener."
```

---

### Task 6: Documentation and version bump

**Files:**
- Modify: `Makefile:4` (VERSION)
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Bump the version**

In `Makefile`:

```make
VERSION := 3.0.0
```

Both the base OS and the session stack changed; this is not a patch release. Note the container image tags follow `VERSION`, so the first build after this creates `dbrrg-ubuntu:3.0.0` and the stale `.ubuntu-container` stamp handling in the Makefile will force a rebuild.

- [ ] **Step 2: Record the standing constraints in CLAUDE.md**

Add a new section to `CLAUDE.md`:

```markdown
## Standing Constraints

Two rules in this repository look like ordinary configuration but are
load-bearing. Both have caused shipped-image bugs.

### Firmware is selected by package, never by cleanup

`scripts/export-rootfs.sh` once ran
`find /usr/lib/firmware -type f -not -name "iwlwifi*" -delete` before
`mksquashfs`. It silently deleted i915 GPU firmware (wedged GPUs in the
field) and `intel-ucode` (no CPU microcode updates, ever) from every image.

Ubuntu 26.04 splits `linux-firmware` per vendor, and `linux-firmware-minimal`
satisfies `linux-image-generic`'s hard dependency via `Provides` while only
*recommending* the rest. The installed set is therefore exactly what
`containers/ubuntu/Dockerfile` lists, given `--no-install-recommends`.

Never add a `find`/`rm -rf` sweep over `/usr/lib/firmware`. To change the
firmware set, change the package list. `test/integration/test-firmware.sh`
guards this.

### dracut must be invoked with --no-hostonly

`containers/ubuntu/Dockerfile` passes `--no-hostonly` to dracut. Removing it
silently breaks the initramfs.

dracut 110 defaults `hostonly` to `-h` unless told otherwise
(`/usr/bin/dracut:1361`). Because `podman build` shares the host kernel, that
makes every `instmods` call filter against **the build machine's** loaded
modules rather than the target hardware's. Measured on this repo: the shipped
initramfs went from 683 modules to 955 once the flag was added — zram, e1000,
e1000e, igb, r8169, atlantic and iwlwifi had all been silently dropped. ZRAM's
absence aborts the boot outright; the missing NIC drivers would have broken
network/PXE boot. (An isolated probe build without `--omit-drivers` showed 968;
955 is the real figure for the shipped flag set.)

It also made builds non-reproducible: the initramfs varied with whatever the
build machine happened to have loaded. `overlay` survived only because podman's
storage driver keeps overlayfs loaded.

The older dracut on 24.04 defaulted to generic, which is why the existing
comment ("Keep it generic (no --hostonly)") was true when written and became
false on dracut 110. `--add-drivers` is not a substitute: it bypasses the
filter for its own arguments only (`dracut:2768`), leaving every module
requested by `90dbrrg/module-setup.sh` still filtered.

### labwc must have zero keybindings

`overlay/home/tluser/.config/labwc/rc.xml` has a `<keyboard>` section with no
`<default />` and no `<keybind>` entries. This is mandatory.

labwc 0.9.3 does not implement `zwp_keyboard_shortcuts_inhibit_manager_v1`,
even though Xwayland requests inhibition when an X11 client calls
`XGrabKeyboard` and wlroots implements the server side. A client therefore
cannot reclaim keys the compositor has bound, so every labwc keybinding is a
key combination that can never reach the remote ThinLinc session.

If a future labwc gains this support, this constraint can be relaxed - check
for `wlr_keyboard_shortcuts_inhibit_v1_create` in the labwc binary's
undefined symbols. `test/integration/test-session-packages.sh` guards this.
```

- [ ] **Step 3: Update the session documentation in CLAUDE.md**

The "Customizing the System" section lists `overlay/etc/default/nodm` and
`overlay/etc/X11/` as customisation points. Replace those two bullets with:

```markdown
- Session/compositor: `overlay/home/tluser/.config/labwc/` (`rc.xml`, `environment`)
- Session startup: `overlay/usr/local/bin/dbrrg-session`, `overlay/etc/profile.d/10-dbrrg-session.sh`
- Autologin: `overlay/etc/systemd/system/getty@tty1.service.d/autologin.conf`
```

- [ ] **Step 4: Update README.md**

Search for references to the removed files and stack:

```bash
grep -n -iE 'nodm|xorg|wm2|xsessionrc|pulseaudio|lxterminal|24\.04|4\.19' README.md
```

Update each hit to reflect 26.04, labwc, PipeWire, `foot` and ThinLinc 4.20. In particular `.xsessionrc` no longer exists — user-level session customisation now goes in `overlay/usr/local/bin/dbrrg-session`.

- [ ] **Step 5: Full clean build and both tests**

```bash
make clean && make image
test/integration/test-firmware.sh
test/integration/test-session-packages.sh
```

Expected: build succeeds, both tests `PASSED`. Record the final squashfs size against the 498 MB baseline.

- [ ] **Step 6: Commit**

```bash
git add Makefile CLAUDE.md README.md
git commit -m "docs: document 26.04/Wayland/PipeWire stack and standing constraints

Bumps VERSION to 3.0.0. Records the two load-bearing rules that have each
caused shipped-image bugs: firmware is selected by package only, and labwc
must register no keybindings."
```

---

## Hardware verification (cannot be done in QEMU)

These are the acceptance criteria that require a real NUC. Run them before
deploying to the fleet.

- [ ] **No i915 firmware errors.** `dmesg | grep -i i915` shows no `Failed to load DMC firmware`, no `GuC initialization failed`, no `declaring it wedged`. **This is the original reported bug.**
- [ ] **Microcode loaded.** `dmesg | grep -i microcode` shows a revision update.
- [ ] **ThinLinc audio works end to end**, both playback and microphone. This is the least certain part of the design — the `auth-anonymous` translation replaces an authentication mechanism. If it fails, check `journalctl --user -u pipewire-pulse` and the `dbrrg-tlclient-audio:` lines on the client's stderr.
- [ ] **ThinLinc fullscreen**, including across multiple monitors. Cendio does not support Wayland; fullscreen-multi-monitor under Xwayland is the least-tested path.
- [ ] **Keyboard passthrough** — confirm key combinations reach the remote session and nothing is swallowed locally.
- [ ] **WiFi associates** and Bluetooth enumerates.
- [ ] **`vainfo`** reports the iHD driver and a working profile list.
- [ ] **Home persistence** survives a reboot in both USB and network boot modes.
- [ ] **`oxulnk-desktop`** launches.

### Fallbacks if hardware testing fails

| Failure | Fallback |
| --- | --- |
| Audio dead | Revert Task 5 only: reinstate `pulseaudio`, restore the old wrapper from git. Tasks 1-4 are unaffected. |
| Fullscreen/multi-monitor broken | Revert Task 4's compositor choice to `cage` (kiosk, no keybindings at all), or back to Xorg + `openbox`. |
| Kernel 7.0 boot/dracut regression | The `verbose` and `debug` entries in `configs/syslinux.cfg` already provide `rd.info`/`rd.debug`/`rd.shell` boot paths. |
