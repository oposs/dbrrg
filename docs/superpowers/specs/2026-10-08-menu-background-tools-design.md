# Menu: programs in the background, coloured log, menu always behind

Date: 2026-10-08. Branch: `menu-bg`. Follows the field feedback on the
`menu-log` image (square tiles and log, published 2026-10-08).

## What the user asked for

1. Start a second program while the first one runs. Programs run in the
   background.
2. Programs such as `oxulnk-desktop` write ANSI colours. The log shows
   `[33m` and similar. Show the colours instead.
3. A program window can go behind the menu. The menu must always be the
   bottom window.

Decisions taken in the conversation:

- Logout with programs running asks *Stay* / *Stop them and log out*.
  Stopping is SIGTERM, up to 5 s, then SIGKILL; the home is saved after
  the programs have ended.
- A tile may run several times only when it says so:
  `X-DBRRG-Multiple=true`. The shipped ThinLinc, oxulnk and Terminal tiles
  set it. Back up home, Upgrade image and Log out do not.
- Saves run in the background without a dialog, one at a time; a request
  during a save queues one more save, never more than one.

## (a) Programs in the background

### State (`menu.rs`)

`Busy` goes. `Menu` holds three independent parts:

```rust
jobs: Vec<Job>            // Job { id: u64, tile: usize, name: String, pgid: Option<i32> }
save: Save                // Save { running: bool, again: bool }
logout: Option<Logout>
```

```rust
enum Logout {
    Confirm,                        // dialog: names of running programs, Stay / Stop them and log out
    Stopping { kill_at: Instant },  // SIGTERM sent; SIGKILL at kill_at for what is left
    WaitSave,                       // programs gone; a background save is still running
    Saving,                         // the logout save runs
    Failed { message: String },     // dialog: Stay / Log out anyway (as today)
    Leaving { until: Instant },     // saved; exit 0 at until (as today)
}
```

The dialog is up, and the grid frozen and dimmed, exactly when `logout` is
`Some`. Nothing else shows a dialog.

### Tiles

A tile can be clicked when all of these hold:

- it is usable (no `problem`), as today;
- `logout` is `None`;
- `Run` tile: it has `X-DBRRG-Multiple=true`, or no job of this tile runs;
- `SaveHome` tile: no save runs and the restore did not fail (as today);
- `Logout` tile: always.

A tile with running jobs shows `running`, or `N running` for N > 1. Back up
home shows `running` while a save runs.

`X-DBRRG-Multiple` is parsed in `tiles.rs` like `X-DBRRG-Save-On-Exit`
(`true`/`false`, default false). A user file that rewords a shipped tile
cannot set it: it is not Name, Comment or Icon. A user's own tile can.

### Starting and ending a program (`jobs.rs`)

- `run` starts the program in its own process group
  (`CommandExt::process_group(0)`) and reports `Started { id, pgid }` before
  it waits, then `Ran { id, status }` when it has exited and its output is
  drained (`DRAIN_GRACE` as today).
- Output lines carry the tile name as source, as today. Two copies of one
  tile write under the same name.
- `stop(pgid, signal)` sends the signal to the whole group
  (`kill(-pgid, sig)`), so a program's children end with it. A group that
  is already gone (`ESRCH`) is not an error.

When a job ends, the menu logs its exit as today and removes it from
`jobs`. If its tile has Save-On-Exit, the restore did not fail and no
logout is in progress, it asks for a save. If the restore failed, it logs
the existing warning instead.

### Saves

- Asking for a save while none runs starts one and logs
  `Saving the home directory…`.
- Asking while one runs sets `again`. When the save ends, its outcome is
  logged; if `again` was set it is cleared and one more save starts.
- Save outcomes are logged as today (Event when saved, Warn otherwise).

### Logout

1. Click Log out. With jobs running: `Confirm`. With none: step 4.
2. `Confirm`, *Stay*: `logout = None`. *Stop them and log out*: SIGTERM to
   each job's group, `Stopping { kill_at: now + 5 s }`.
3. `Stopping`: each `Ran` removes its job; Save-On-Exit is not acted on.
   When `jobs` is empty, go on. At `kill_at`, SIGKILL every group left and
   keep waiting for their `Ran`.
4. A background save running: `WaitSave` until it ends; `again` is
   dropped, because the logout save follows. Then `Saving`.
5. `Saving`, then `Leaving` or `Failed` exactly as today; *Stay* in
   `Failed` returns to the grid, *Log out anyway* exits 0.

Programs started with `Terminal=true` run inside `foot`; the group is
foot's, and stopping it ends the program inside.

Upgrade image stopped by step 3 is safe for the stick: `upgrade-image`
sets `DEFAULT new` only after `tl.new` is complete, each `syslinux.cfg`
copy through a rename. The dialog lists it by name before anyone confirms.

### Tests

Unit tests on `Menu` with fake job events: two jobs at once; a
non-Multiple tile refuses a second start while a Multiple tile accepts it;
Save-On-Exit requests a save; a request during a save gives exactly one
more save, three requests too; logout with no jobs, with jobs (Confirm,
Stay, Stop), with a job ignoring SIGTERM (SIGKILL at `kill_at`), with a
save running (WaitSave), failed logout save (existing tests adapted).
`jobs.rs`: stopping a group ends a child the program started in the
background; `stop` on a finished group does nothing.

## (b) ANSI colours in the log

### Model (`log.rs`)

`Line.text: String` becomes `Line.runs: Vec<Run>` with
`Run { text: String, fg: Option<Ansi>, bold: bool }`, plus a
`Line::plain()` for the session log and for tests. `Ansi` is a basic index
(0-15), a 256-palette index, or RGB.

`clean()` becomes a parser over one line (already cut at `LINE_BYTES`):

- `ESC [ params m` (SGR): reset (0 or empty), bold (1), normal (22),
  foreground 30-37, 90-97, 39 (default), `38;5;n`, `38;2;r;g;b`.
  Background and other attributes are read and ignored.
- Any other CSI sequence (`ESC [` … final byte `@`–`~`), OSC
  (`ESC ]` … BEL or `ESC \`), and two-byte escapes are removed whole.
- A sequence cut off by the end of the line is removed.
- Tab becomes a space; other control characters are removed, as today.
- At most 64 runs per line; further colour changes are ignored and the
  text joins the last run.

### Drawing (`ui.rs`)

Each run becomes one section of the row's `LayoutJob`. The 16 basic
colours map to a palette readable on the dark log background (ANSI black
and blue lightened); 256-colour and RGB values are drawn as given. Bold
uses the strong text colour (no bold font is loaded). A run without
colour uses the line's colour by kind, as today.

### Session log

The stderr copy is `Line::plain()`: no escape sequences, as today.

### Tests

Parser tests: a line as `oxulnk-desktop` writes it; reset; bold; 256 and
RGB; an OSC title; a cursor move; a sequence cut at the end; a line of
escapes only; more than 64 colour changes. A UI test draws a coloured
line and finds its section colour.

## (c) The menu is always the bottom window

- `app.rs`: the window gets the Wayland app_id `dbrrg-menu`
  (`WindowAttributesExtWayland::with_name`).
- `overlay/etc/dbrrg/labwc/rc.xml`:

  ```xml
  <windowRules>
    <windowRule identifier="dbrrg-menu" skipTaskbar="yes">
      <action name="ToggleAlwaysOnBottom" />
    </windowRule>
  </windowRules>
  ```

  `ToggleAlwaysOnBottom`, `skipTaskbar` and window rules exist in the
  shipped labwc 0.9.3 (names found in `/usr/bin/labwc`).
- `test/integration/test-session-packages.sh` asserts the rule and that
  `rc.xml` still has zero keybindings. `make test-runtime` proves labwc
  accepts the file and the menu still maps.

Not provable headless: the stacking order after a click. Hardware check.

## Documentation

`CLAUDE.md`: the tile section gains `X-DBRRG-Multiple`; Persistent Home
Directory describes background saves and the logout steps; Menu limits
drops "a tile whose program never exits keeps the menu busy" and gains
the hardware-only checks; the rc.xml paragraph mentions the window rule.
The standing constraint "dbrrg-session never saves; dbrrg-menu saves
before it exits 0" is unchanged.

## Out of scope

The oxulnk logo as tile icon; restarting a program; a per-job log filter.
