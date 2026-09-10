# c51.meetings — implementation contract (authoritative)

A MeetingBar replacement for Omarchy: a bar widget showing the next meeting, and a
**fullscreen blanking alert** shortly before it starts, for a user who does not notice
ordinary notifications.

Plugin dir (also the git repo): `~/.config/omarchy/plugins/c51.meetings/`
Plugin id: `c51.meetings` (ids starting with `omarchy.` are rejected by the host).

## Files

| Path | Kind | Owner |
|---|---|---|
| `manifest.json` | — | schemaVersion 1, kinds `["service","overlay","bar-widget"]` |
| `Service.qml` | `service` | the brain: fetch loop, 1 Hz wall-clock tick, firing, inhibitor, IPC |
| `Alert.qml` | `overlay` | the fullscreen alert surface |
| `Widget.qml` | `bar-widget` | next-meeting text in the bar |
| `bin/meetings-fetch` | — | python3, writes the event cache (backends: eds / ics / demo) |
| `config.example.json` | — | copied to `~/.config/omarchy/meetings.json` on install |
| `install.sh` | — | idempotent installer; never calls sudo itself |
| `README.md` | — | user-facing docs incl. the Google Workspace setup |

`entryPoints` keys are `service`, `overlay`, `barWidget` (camelCase only for bar-widget).
No symlinks anywhere in the plugin dir (the validator refuses them).

## Invariants (one rule, every file)

Four questions every file has to answer the same way. They are written out once, here, because a
consumer that answers one of them on its own silently disagrees with the other two.

1. **Next event** = the first event in `start` order with `max(end, start) > now` — *not over yet*,
   not *not started yet*. A meeting that is running is still the next meeting. Widget, service and
   alert all use this expression.
2. **`end` is the fetcher's word.** No consumer invents a duration. A missing, non-numeric or
   reversed `end` collapses to `end = start` (a zero-length occurrence, which by rule 1 stays
   visible until its start has passed) — never to `start + <any guessed length>`.
3. **https only.** A join URL is handed to `omarchy-launch-browser` only if it is an `https://`
   URL with no whitespace in it — `/^https:\/\/[^\s]+$/i` in QML, the same test the fetcher's
   `clean_url` applies. `http://` is **not** enough. Each file re-checks this in its own
   cache/payload parser, because the cache is a user-writable file and neither `file://`,
   `javascript:` nor an argument containing whitespace may ever reach a browser command line.
4. **All-day events never take the alert path.** An all-day entry has no meaningful start moment,
   so the service skips it when firing regardless of `skip_all_day`; that option only decides
   whether all-day entries reach the cache and the widget at all.

## Config — `~/.config/omarchy/meetings.json`

Single source of truth, read by the fetcher AND by the QML. Every key optional; code must
supply these defaults and never crash on a missing/broken file:

```json
{
  "backend": "eds",
  "ics_urls": [],
  "lookahead_minutes": 720,
  "refresh_seconds": 300,
  "fetch_interval_seconds": 60,
  "alert_lead_seconds": 60,
  "auto_dismiss_seconds": 90,
  "inhibit_lead_seconds": 600,
  "grace_seconds": 300,
  "sound": "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
  "notify": true,
  "wake_display": true,
  "skip_all_day": true,
  "skip_declined": true,
  "min_duration_minutes": 0,
  "title_blocklist": [],
  "calendars_exclude": [],
  "widget": { "warn_minutes": 15, "max_title_chars": 28, "hide_when_empty": true }
}
```

Semantics:
- `alert_lead_seconds` — fire the fullscreen alert this many seconds before `start`.
- `grace_seconds` — if we were suspended/locked and missed the moment, still fire up to this
  long after `start` (an event whose start is older than that is never alerted).
- `inhibit_lead_seconds` — hold a Wayland idle inhibitor from `start - this` until
  `start + grace_seconds`, so the session cannot blank/lock right before a meeting. The default is
  **600**, deliberately larger than the idle timings on this machine (screensaver 150 s, lock
  300 s): a 300 s lead arrives after the blank has already happened and cannot undo a lock that is
  in progress, so the inhibitor has to be in place before the idle sequence can even start.
  Residual gap, documented rather than papered over: if the session went idle *more* than
  `inhibit_lead_seconds` before the meeting, it is already locked when the inhibitor would go up,
  and no third-party overlay can draw over `WlSessionLock`. The alert is then queued and shown at
  the unlock (see the state file), within `grace_seconds`.
- `auto_dismiss_seconds` — 0 means "stay until dismissed", bounded by the overlay's 600 s hard
  dismiss (see the overlay contract).
- `refresh_seconds` — minimum spacing between *network* refreshes (EDS `refresh_sync`).
- `fetch_interval_seconds` — how often the QML service runs the fetcher (local read).

## Event cache — `$XDG_RUNTIME_DIR/omarchy-meetings/events.json`

Written **only** by `bin/meetings-fetch`: mode 0600, atomic (tmp in the same dir + `os.replace`),
dir mode 0700. On tmpfs on purpose — no meeting content survives a reboot.

```json
{
  "schema": 1,
  "backend": "eds",
  "status": "ok",
  "error": "",
  "warning": "",
  "generated_at": 1757500000,
  "refreshed_at": 1757499900,
  "events": [
    { "id": "9f2c…", "title": "Standup", "start": 1757503200, "end": 1757505000,
      "all_day": false, "url": "https://meet.google.com/abc-defg-hij",
      "calendar": "Work", "location": "" }
  ]
}
```

- `start`/`end`: **unix seconds, UTC** — no timezone strings anywhere in the cache, so QML never
  has to parse a date format. Sorted ascending by `start`. `end` is authoritative (invariant 2);
  the fetcher is allowed to write `end == start` for an occurrence without a length.
- `url`: `https://…` or `""` (invariant 3). The fetcher never writes any other scheme, and every
  consumer still re-validates.
- `id`: stable across runs — `sha1(uid + "@" + instance_start_epoch)[:16]`. Must be identical for
  the same occurrence on every run, or the alert fires repeatedly.
- `status: "error"` + human-readable `error` when the backend fails; `events` then keeps the last
  known good list if one is available (write `stale: true` in that case). Never put tokens,
  URLs with secrets, attendee emails or full ICS text into `error`.
- `status` is `"error"` **whenever the backend reported a failure and no event survived
  filtering** — an empty list from a failed run is never dressed up as `"ok"`. "Nothing on your
  calendar" and "your calendar could not be read" must not look alike to the user.
- `warning`: always present, `""` when there is nothing to report. Non-empty means *usable but
  degraded* — the run produced events, but on fallbacks: e.g. `meetings.json` holds invalid values
  and the documented defaults were used, one of several calendars failed while the others
  delivered, or an option was ignored because it does not apply to the active backend. `status`
  stays `"ok"`, and the text is German, short and content-free (same privacy rules as `error`).
  A non-empty `warning` **must be surfaced**: the widget shows a calm marker plus the reason in
  its tooltip, and `meetings status` reports it. Without that, a typo in `meetings.json` runs on
  defaults forever without anyone noticing.
- `error` belongs to `status: "error"`. A consumer that nevertheless finds a non-empty `error` on
  an `"ok"` cache surfaces it like a warning instead of discarding it.
- **Privacy**: only the fields above. No attendees, no description, no organizer. Never log event
  content to stdout/journal beyond counts.

## Alert state — `$XDG_RUNTIME_DIR/omarchy-meetings/state.json`

Written by `Service.qml` (FileView `setText`), mode 0600 best effort. It survives a plugin
hot-reload (which re-mounts the service and would otherwise re-fire everything) and a shell
restart during a lock.

```json
{
  "schema": 2,
  "events": { "<event id>": { "notified": 1757503140, "shown": 1757503141, "failed": 0 } },
  "queue": [
    { "id": "<event id>", "title": "Standup", "start": 1757503200, "end": 1757505000,
      "allDay": false, "url": "https://meet.google.com/abc-defg-hij", "calendar": "Work",
      "location": "", "untilSec": 1757503500, "notifiedAt": 1757503140 }
  ],
  "fired": { "<event id>": 1757503140 }
}
```

- `events` — three independent timestamps per occurrence, 0 meaning "not yet":
  - `notified`: the once-per-occurrence side effects are done (display wake, critical
    notification, sound). Persisted **before** they run, so a crash mid-fire cannot loop.
  - `shown`: the fullscreen overlay was confirmed on screen by the host.
  - `failed`: it never got there inside its window (or the event was cancelled) — do not retry.
  `notified` and `shown` are separate on purpose: under `WlSessionLock` a third-party overlay
  cannot draw at all, so an occurrence can be notified but not yet shown, and it still owes the
  user a screen after the unlock. One combined "fired" flag can only lose that alert or repeat the
  notification.
- `queue` — FIFO of the alerts that still have to reach the screen, in notification order (`start`
  breaks a tie), each carrying its **whole overlay payload** plus `untilSec`
  (`start + grace_seconds`, after which it is dropped as `failed`) and `notifiedAt`. The payload
  travels with the entry because the cache may no longer contain the event by the time the alert
  can be shown. It is a queue, not one slot, because two meetings can come due while the session
  is locked; the head owns the overlay and the rest wait for it to close.
- `fired` — a schema-1 mirror (`id → notified`) written for readers of the old format and never
  read back. A file that *only* has `fired` is read as legacy: those ids count as notified **and**
  shown, because the old format cannot say whether the overlay was ever seen, and a surprise
  blanking alert is worse than a missing one for an event that old.
- On read the file is **merged** into what the session already knows (never replaced) — the state
  is re-read on every hot reload — and entries whose newest timestamp is older than 12 h are
  dropped, as are queue entries past `untilSec` or already shown/failed. A missing, half-written or
  unknown-key file must never crash the service.
- Re-summoning: a queued alert that is notified but not shown is retried every 5 s, at most 6
  times, and only inside its own grace window; the attempt cap is what keeps a failing summon from
  looping forever.

## IPC

`Service.qml` registers `IpcHandler { target: "meetings" }` (must not collide with the
first-party targets: shell, bar, idle, lock, notifications, background, nightlight, osd,
image-selector, omarchy.indicators). All args and returns are **strings**.

| Call | Effect |
|---|---|
| `omarchy-shell meetings status` | JSON string: backend, cache status/`error`/`warning`/age, next event, armed/inhibiting/locked, pending alert queue, last fetch outcome, effective settings, paths |
| `omarchy-shell meetings refresh` | run the fetcher now |
| `omarchy-shell meetings test` | show a synthetic alert immediately (no calendar needed) |
| `omarchy-shell meetings preview` | show the alert for the real next event, without touching `notified`/`shown` |
| `omarchy-shell meetings dismiss` | hide the alert |

## Overlay contract — `Alert.qml`

Root `Item` exposing exactly what the host calls (shell.qml delivers a **raw JSON string**):

```qml
property bool opened: false
function open(payloadJson) { /* JSON.parse defensively */ }
function close() { }
```

Payload:
```json
{ "title": "…", "start": 1757503200, "end": 1757505000, "url": "…", "calendar": "…",
  "location": "…", "auto_dismiss": 90, "test": false }
```

Requirements:
- `Variants { model: Quickshell.screens }` → one `PanelWindow` per monitor (eDP-1 and DP-1 here),
  all four `anchors` true, `WlrLayershell.layer: WlrLayer.Overlay`,
  `exclusionMode: ExclusionMode.Ignore`, never set `exclusiveZone`.
- `WlrKeyboardFocus.Exclusive` on **one** window only (the screen holding the focused monitor per
  `Quickshell.screens` order / Hyprland's focused monitor); `None` on the others.
- Opaque themed background (this is a *blanking* alert, not a toast): use `qs.Commons`
  (`Color`, `Style`, `Util`) and `qs.Ui` — third-party plugins may import these.
- Content: big countdown ("in 47 s" → "jetzt"), meeting title, start–end local time, calendar name,
  location if present, and the join hint when a URL exists.
- Keys: Return/Enter/Space → join (`Quickshell.execDetached(["omarchy-launch-browser", url])`) then
  dismiss; Escape or any other key → dismiss. Full-size `MouseArea` → dismiss.
- `IdleInhibitor { enabled: true; window: <this PanelWindow> }` while open, but **released after
  at most 180 s** even if the overlay is still up: an alert nobody dismissed (the user is not at
  the desk) must not keep the machine awake indefinitely. This is the overlay's own inhibitor,
  separate from the service's pre-meeting one.
- Auto-dismiss after `auto_dismiss` seconds with a visible progress indicator, clamped to 600 s so
  the indicator cannot promise longer than the overlay lives. `auto_dismiss: 0` means "stay until
  dismissed", and even then the overlay **hard-dismisses after 600 s**: a blanking surface that
  owns every monitor may never hold the session forever.
- All-day events never arrive here through the firing path (invariant 4). The overlay still
  renders whatever payload it is handed — `preview`/`test` may pass anything.
- The payload `url` is re-validated here (invariant 3); a non-https url is treated as absent, so
  the join hint and the join key disappear rather than launching something unexpected.
- `dismiss()` must call `shell.hide(manifest.id)` so the host's `openPanelIds` bookkeeping matches,
  and must be idempotent.
- Must render correctly when `title` is very long, when `url` is empty, and when `start` is in the past.

## Widget contract — `Widget.qml`

- Reads the cache and config itself via `FileView` (`watchChanges: true`, and
  `onFileChanged: reload()` — it does **not** auto-reload). Watch the parent *directory* too,
  because the cache may not exist yet.
- Renders e.g. `󰃭 14:00 Standup · 12m`; switches to the theme's urgent/attention color inside
  `widget.warn_minutes`; truncates the title to `widget.max_title_chars`;
  collapses to zero width when there is nothing (if `hide_when_empty`).
- Click → join the meeting URL when there is one, otherwise `preview` the alert.
- Shows a clear degraded state when the cache is missing or `status != "ok"` (e.g. a dim `󰃭 —`),
  never an empty crash, never a QML binding loop.
- A non-empty cache `warning` (or an `error` on an otherwise `"ok"` cache) adds a calm `󰀦` marker
  to the label and the reason to the tooltip, and keeps the widget visible even when
  `hide_when_empty` would collapse it — a degraded state the user cannot see is not reported.
- Applies invariants 1–3 in its own cache parser: it drops non-https urls, collapses a broken
  `end` to `start`, and picks the next event with `max(end, start) > now`.
- Host injects `bar`, `moduleName`, `settings` into bar widgets; read the reference widgets under
  `/usr/share/omarchy/shell/plugins/bar/` for the exact contract and styling conventions.

## Service contract — `Service.qml`

- **Timing (critical)**: one repeating `Timer { interval: 1000 }` that recomputes everything from
  `Date.now()` wall clock each tick. No long one-shot timers, no `systemd-run --on-active`
  (CLOCK_MONOTONIC, paused across suspend → fires late). If the wall clock jumped more than 15 s
  between ticks (suspend/resume or a clock correction), force a fetch immediately.
- **Fetch**: `Process` running `/usr/bin/python3 <pluginDir>/bin/meetings-fetch` — resolve the
  plugin dir with `String(Qt.resolvedUrl("bin/meetings-fetch")).replace(/^file:\/\//, "")`.
  Always the absolute `/usr/bin/python3`, never a bare `python3` (mise/pyenv shims lack `gi`).
  Re-entrancy guard (`if (proc.running) return`). Run at startup, every
  `fetch_interval_seconds`, on wall-clock jumps, and on IPC `refresh`.
- **Fetch backoff**: consecutive failures double the interval —
  `min(fetch_interval_seconds * 2^min(streak, 4), 900)` — and a single success, or any edit to
  `meetings.json`, resets it. A backend that cannot work at all (`eds` before the packages are
  installed) would otherwise respawn python every interval for ever. Journal noise is bounded by
  `logState`, which drops a repeated (event, detail) pair, and by keeping the streak *count* out
  of the logged line while keeping the backoff step in it: one line per escalation, then silence.
  `fetch.failStreak` and `fetch.retryInSeconds` in the `status` IPC make it observable.
- **Fetch watchdog**: a fetch still running after 45 s is terminated, and one that survives that
  is `SIGKILL`ed at 60 s (`Process.signal(int)`; `Process.running` is writable — both are in
  `/usr/lib/qt6/qml/Quickshell/Io/quickshell-io.qmltypes`). The outcome (`ok`/`failed`/`timeout`)
  is logged once and reported through `status`, and the next interval simply retries. Without the
  watchdog a single hung fetcher holds the re-entrancy guard forever and the cache silently stops
  updating. Note the watchdog is a backstop, not the fix for a slow backend: see the
  `wait_for_connected_seconds` note below, and remember the `ics` backend talks to the network.
- **Firing** the next event (invariant 1) when `start - now <= alert_lead_seconds` and
  `now - start <= grace_seconds` and its id is not in `notified`. All-day events are skipped here
  unconditionally (invariant 4).
  1. persist the id to `notified` in the state file first (so a crash cannot cause a re-fire loop),
  2. if `wake_display`: `omarchy-brightness-display on` (NOT `hyprctl dispatch dpms on` — that
     dispatcher no longer exists in Hyprland 0.56),
  3. if `notify`: `omarchy-notification-send -u critical -g 󰃭 "<title>" "<body>"` and, only when a
     URL exists, `--exec omarchy-launch-browser <url>` **last** and as separate argv words,
  4. if `sound` is non-empty and the file exists: `pw-play <file>`,
  5. if `omarchy-shell lock isLocked` is `true`: do **not** summon (the overlay is invisible under
     `WlSessionLock`); append the payload to the state file's `queue` and summon as soon as the
     lock is released, as long as `until` has not passed. Otherwise summon now:
     `shell.summon(manifest.id, JSON.stringify(payload))` and record the id in `shown`.
     A queued alert is only ever *shown* late — the notification and the sound in steps 2–4 have
     already happened at the right moment, which is why the timestamps are separate.
  6. a queued alert whose event has disappeared from a fresh, healthy, non-stale cache (cancelled,
     or moved out of the window) is dropped as `failed` instead of blanking the screen. Only an
     `ok` and non-stale cache may withdraw an alert: an error or stale cache is missing events for
     its own reasons.
- **Idle inhibitor**: hold one from `start - inhibit_lead_seconds` (default 600 s, see the config
  semantics) until `start + grace_seconds` for the next event, so the session cannot lock/blank
  into the alert. Implement as a 1x1 click-through `PanelWindow` (input mask empty /
  `WlrKeyboardFocus.None`) carrying `IdleInhibitor`, created only while needed. Quickshell 0.3.1
  exposes `Quickshell.Wayland.IdleInhibitor` with `enabled` and `window`; the omarchy idle service
  runs `IdleMonitor { respectInhibitors: true }`, so this genuinely suppresses blank+lock. Do **not**
  touch omarchy's persisted stay-awake flag.
- Every external command must be an argv array (`Process.command` / `Quickshell.execDetached([…])`)
  — never a shell string built from event data. `Util.execDetached` takes a shell string and is the
  unsafe one; `Util.execArgv` is safe.
- Log at most one line per state change to the journal, without event titles.

## Environment facts (verified — do not re-derive, do not "fix")

- Omarchy 4.0.x, Hyprland 0.56.2, Quickshell 0.3.1, Qt 6.11.2, systemd 261, Europe/Berlin, NTP on.
- Monitors: eDP-1 3200x2000@120 scale 1.6, DP-1 5120x2160@60 scale 1.25.
- Lock is `WlSessionLock` (ext-session-lock-v1) from the first-party `omarchy.lock` plugin;
  hyprlock is not installed. A third-party overlay can never draw over the lock surface.
- Idle defaults: screensaver 150 s, lock 300 s — the reason `inhibit_lead_seconds` defaults to
  600. `omarchy-shell idle status` reports live state; stay-awake is currently on, so idle is
  disabled on this machine right now.
- `omarchy-notification-send -u critical` bypasses DND. Omarchy ships no sound files; `pw-play`,
  `paplay`, `canberra-gtk-play` and `sound-theme-freedesktop` are installed.
- QML errors from plugins land in `journalctl --user -t omarchy-shell` and
  `/run/user/1000/quickshell/by-id/<id>/log.qslog` (`quickshell log -f`).
- Saving any file under `~/.config/omarchy/plugins/` triggers a plugin reload, but — measured on
  2026-09-10 on this machine — that reload does **not** replace the running third-party *service*
  instance with the new code: `omarchy-shell meetings status` kept returning the old schema after
  the file change, after `omarchy-shell shell rescanPlugins`, and after clearing
  `~/.cache/quickshell/qmlcache`. Only `omarchy restart shell` loads changed service code.
  Config changes do apply immediately (the config is read through a `FileView`).
- GOA/EDS is **not installed yet**; `backend: "demo"` must therefore work end to end so the whole
  plugin can be tested before the Google account exists. The required packages are exactly
  `evolution-data-server`, `gnome-online-accounts` and `gnome-online-accounts-gtk`, and the GOA
  account dialog on this machine is **`gnome-online-accounts-gtk`** — the only one installed here.
  Docs, installer output and diagnostics name that command and no other settings app.
- `libical` 4.0.5 ships `ICalGLib-4.0.typelib`, `evolution-data-server` ships `ECal-2.0` and
  `EDataServer-1.2` (both from `pacman -Fl`).

## Event source — `bin/meetings-fetch`

CLI: `meetings-fetch [--config PATH] [--out PATH] [--backend eds|ics|demo] [--in-seconds N]
[--refresh] [--diagnose] [--print]`
- `--in-seconds N`: inject one synthetic event starting N seconds from now, so the alert path can
  be tested deterministically on whatever backend is configured (see *Test injection* below).
- `--diagnose`: print a human-readable readiness report (packages, typelibs, GOA accounts,
  calendars found, last sync age) — no event content.
- `--print`: write the JSON to stdout instead of the cache file.
- Exit 0 on success; on failure still write a cache with `status: "error"` and exit non-zero.

### Test injection — `--in-seconds`

`omarchy-shell meetings test` only draws the overlay; it proves the surface renders, not that the
alert *fires*. The real path — cache → service tick → notification → summon → state file — is
tested with an injected event:

```
./bin/meetings-fetch --in-seconds 45      # writes the cache and the inject marker
omarchy-shell meetings status             # next event is the synthetic one
# the service picks the new cache up at once and fires alert_lead_seconds before that start
```

`--in-seconds N` *arms* one synthetic event — start exactly `now + N`, no rounding, so the alert
lands `alert_lead_seconds` before that — by writing an **inject marker** next to the cache:
`inject.json`, same directory as `--out` points at, same 0600 and same atomic replace as the
cache. It holds only `id`, `title`, `start`, `end`, `url`; the rest is fixed (`calendar` `Test`,
a clearly test-labelled title, a demo join URL). The marker, not the event title, is the identity
of the injected occurrence:

- Every later run reads the marker and merges that event into whatever the active backend
  returned, on **any** backend and on **every** code path — the `status: "error"` branch included,
  because on a machine without EDS every plain run ends there and the test alert has to survive
  it. This is what makes the test work at all: the service re-runs the fetcher with no arguments
  every `fetch_interval_seconds`, and an event that existed only in one run's output would be
  overwritten within a minute and could never fire.
- The `id` is written once and read back unchanged, so it is stable across runs — a recomputed id
  would re-fire the alert on every fetch. `end` is taken from the marker as written (invariant 2),
  and a stale cache copy of the same id is de-duplicated on merge.
- The marker expires by itself: once `start` is older than `grace_seconds` the run deletes it, so
  a spent test cannot resurface in a later session. A second `--in-seconds` replaces the file, so
  re-arming with a different lead just works.
- Arming an event that falls outside `lookahead_minutes`/`grace_seconds` (or that the filters drop)
  is reported through `warning`, not silently swallowed.
- `--print` also arms the marker — the arming is the point; only the payload goes to stdout
  instead of into the cache.

### backend `eds` (default, Google Workspace via GOA)

Verified API recipe — follow it exactly:
- `gi.require_version` for `EDataServer` 1.2, `ECal` 2.0, `ICalGLib` **4.0** — that is what
  `libical` 4.x installs (`/usr/lib/girepository-1.0/ICalGLib-4.0.typelib`); ICalGLib 3.0 does not
  exist on Arch. Still probe what the installed typelib declares at runtime and degrade to
  `status: "error"` with a readable message instead of raising; `registry =
  EDataServer.SourceRegistry.new_sync(None)`.
- Enumerate `registry.list_sources(None)`. Roots (no parent) with the `Collection` extension whose
  backend name is `google` identify the GOA account; the calendars are the **direct children with a
  `Calendar` extension** (backend `caldav`).
- Use `registry.check_enabled(source)` — **not** `source.get_enabled()`, which returns true even
  when the parent account is disabled.
- `client = ECal.Client.connect_sync(source, ECal.ClientSourceType.EVENTS, 1, None)`. The third
  argument, `wait_for_connected_seconds`, is **not an upper bound** — it is waited out in FULL
  whenever the backend never reports itself connected, which is what these Google CalDAV sources
  do. Measured on 2026-09-10 with two calendars: 30 s each, 60 s total, over the 45 s watchdog, so
  every service fetch was killed while a manual run right after an account sync returned instantly
  (the intermittency is what made this look like a deadlock). With `1` the same code returns every
  instance in ~2 s cold and ~0.15 s warm. The cost is paid per calendar, so keep it at 1; `0` is
  not documented as "no wait" and hung in testing.
- Expand occurrences with `client.generate_instances_sync(start_epoch, end_epoch, None, cb)` —
  plain `time_t` seconds. `get_object_list_as_comps_sync` does **not** expand recurrences.
- In the callback `cb(icomp, instance_start, instance_end, user_data)` use the **instance**
  times, never `icomp.get_dtstart()` (that returns the recurrence master's original date).
- `ICalGLib.Time.as_timet()` ignores the attached timezone and reads the wall-clock digits as UTC:
  call `convert_to_zone(ICalGLib.Timezone.get_utc_timezone())` first, or every timed event is off
  by the local offset. All-day events are `is_date() == True`.
- Network freshness: EDS's own refresh interval defaults to **60 minutes**. When the last refresh is
  older than `refresh_seconds`, call `client.refresh_sync()` (guarded by
  `client.check_refresh_supported()`), and record `refreshed_at`.
- Join URL, in this order: RFC 7986 `CONFERENCE` property → `X-GOOGLE-CONFERENCE` X-property →
  first `https://meet.google.com/…`, `https://…zoom.us/j/…`, `https://teams.microsoft.com/l/…`,
  `https://…webex.com/…` match in `LOCATION`, then in `DESCRIPTION`. Do **not** prefer the
  iCalendar `URL` property (for Google events that is the calendar web page, not the room).
  Verified on 2026-09-10 against this account: Google's CalDAV **does** emit
  `X-GOOGLE-CONFERENCE`, and it matched on every event in the window, so the X-property is the
  path that actually carries the Meet link here. The DESCRIPTION regex stays as the fallback for
  accounts or events that lack it, and `--diagnose` reports which path matched (path name only,
  never the URL).
- `skip_declined`: drop events where the account's own `ATTENDEE` `PARTSTAT` is `DECLINED`.
  Verified against real data on 2026-09-10: the account identity resolves from
  `Collection.get_identity()`, and a declined invitation was correctly absent from the cache while
  the three accepted events in the same window were present.

### backend `ics`

Documented **backstop only** — Google regenerates the private ICS feed only about once a day, so it
can miss a meeting that was moved this morning. Fetch each `ics_urls` entry with `urllib`
(timeout, no redirects to non-https), parse with `icalendar` + `recurring_ical_events`
(both in `extra`, currently not installed → import failure must degrade to `status: "error"`,
not a traceback). Treat the URLs as secrets: never log them, never put them in `error`.

### backend `demo`

Pure-python synthetic events, no dependencies, used for testing and for a first install before the
Google account exists.
