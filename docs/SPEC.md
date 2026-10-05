# OMeetingBar (`io.github.disy-mk.omeetingbar`) — implementation contract (authoritative)

A MeetingBar replacement for Omarchy: a bar widget showing the next meeting, and a
**fullscreen blanking alert** shortly before it starts, for a user who does not notice
ordinary notifications.

Plugin dir (also the git repo): `~/.config/omarchy/plugins/io.github.disy-mk.omeetingbar/`
Plugin id: `io.github.disy-mk.omeetingbar` (ids starting with `omarchy.` are rejected by the host).

## Files

| Path | Kind | Owner |
|---|---|---|
| `manifest.json` | — | schemaVersion 1, kinds `["service","overlay","bar-widget"]`; `version` must equal `Service.qml`'s `codeVersion` (release rule, see *Version and updates*) |
| `Service.qml` | `service` | the brain: fetch loop, 1 Hz wall-clock tick, firing, inhibitor, IPC |
| `Alert.qml` | `overlay` | the fullscreen alert surface |
| `Widget.qml` | `bar-widget` | next-meeting text in the bar, and the host of the agenda popup |
| `Popup.qml` | — | the agenda popup body (loaded by `Widget.qml`; not an entry point) |
| `Providers.js` | — | video providers: host → name, Nerd-Font glyph, brand colour; imported by `Popup.qml` and `Alert.qml` |
| `Strings.js` | — | every QML-side UI string in German and English, plus the language rule (`pick`); imported by all four QML files and `Days.js` |
| `Days.js` | — | calendar arithmetic: a day's first local instant (`dayStart`, equal to the fetcher's `_local_epoch`), calendar days between two instants and the day in front of a start time (`Widget.qml`, `Popup.qml`, `Alert.qml`), and the countdown's parts and words (`Widget.qml`, `Popup.qml`; the alert keeps its own second-by-second countdown) |
| `bin/omeetingbar-fetch` | — | python3, writes the event cache (backends: eds / ics / demo) |
| `bin/omeetingbar-join` | — | POSIX sh, click action of a meeting notification: `omeetingbar-join <event id> [<grace seconds>]` looks the event up by id in the 0600 cache and opens its link only until the meeting ends (a zero-length one until `start + grace`); the legacy form `omeetingbar-join <url> <end>` is still accepted for one or two releases (firing step 2) |
| `bin/omeetingbar-notify` | — | python3 (Gio D-Bus), sends or replaces a notification from a JSON payload on **stdin**, so no toast text or link is ever an argument of a plugin process; prints the notification id |
| `config.example.json` | — | copied to `~/.config/omarchy/omeetingbar.json` on install |
| `install.sh` | — | idempotent installer; never calls sudo itself |
| `README.md` | — | user-facing docs incl. the Google Workspace setup |

`entryPoints` keys are `service`, `overlay`, `barWidget` (camelCase only for bar-widget).
No symlinks anywhere in the plugin dir (the validator refuses them).

## Invariants (one rule, every file)

Five questions every file has to answer the same way. They are written out once, here, because a
consumer that answers one of them on its own silently disagrees with the other two.

1. **Next event** = the first event in `start` order with `max(end, start) > now` — *not over yet*,
   not *not started yet*. A meeting that is running is still the next meeting. Over the **whole
   agenda** this is `status.next` and the popup's notion of next; the bar label, the popup hero and
   `preview` speak for the **alertable view** of the same list (no all-day, no declined while
   `skip_declined`, not over), so they can legitimately name a different meeting than `status.next`.
   "Over" is `max(end, start) <= now` on every surface, `isAlertable()` included — a zero-length
   occurrence (invariant 2's fallback) is therefore over the second it starts, everywhere.
2. **`end` is the fetcher's word.** No consumer invents a duration. A missing, non-numeric or
   reversed `end` collapses to `end = start` (a zero-length occurrence, which by rule 1 stays
   visible until its start has passed) — never to `start + <any guessed length>`.
3. **https only.** A join URL is handed to `omarchy-launch-browser` only if it is an `https://`
   URL with no whitespace and no backslash in it — `/^https:\/\/[^\s\\]+$/i` in QML (Service,
   Widget, Popup, Alert), and at most 2048 characters in Service.qml. `http://` is **not** enough.
   The backslash matters because browsers read `\` as `/` in an https URL: `Providers.js` would
   name `https://evil.example\@meet.google.com/…` as Google Meet while the browser lands on
   evil.example, so `hostOf` also returns `""` for any authority containing one. Each file
   re-checks this in its own cache/payload parser, because the cache is a user-writable file and
   neither `file://`, `javascript:` nor an argument containing whitespace may ever reach a
   browser command line. The fetcher's `clean_url` applies the same test (plus the 2048-character
   cap) before anything is written to the cache.
4. **All-day events never take the alert path.** An all-day entry has no meaningful start moment,
   so the service skips it when firing regardless of `skip_all_day`; that option only decides
   whether all-day entries reach the cache and the popup's agenda rows. The bar label never shows
   an all-day entry — it speaks for the alertable view (invariant 1).
5. **The cache is the agenda, not a list of alert candidates.** Since schema 2 it holds the whole
   two-day agenda — events that are already over, and declined ones (flagged, not dropped) — because
   the popup shows them. The invariant the fetcher used to enforce for everyone therefore moved into
   `Service.qml` as exactly one predicate, `isAlertable(entry, atSec)`: not all-day, not already
   ended, inside the grace window, and not declined while `skip_declined` is on. `skip_declined`
   keeps its meaning that way — on (the default) a declined meeting never blanks the screen but is
   still listed, struck through, in the agenda; off, a declined meeting is treated like any other. Every alert-side path goes through it — `dueEvent`,
   `requeueUnshown`, `updateInhibit`, `nextAlertableEvent`, and `dropCancelledAlerts` (where
   "present in the cache" becomes "present **and** still alertable", so declining a meeting still
   withdraws its queued alert). Nothing else may iterate the event list to decide whether to alert — the queue included:
   `drainQueue` re-checks the head against the live cache entry right before every summon, so an
   alert queued under the lock for a meeting that has since ended is withdrawn, not shown.
   `omeetingbar status` reports `agendaCount` beside `eventCount` and `declined`/`ended` per event, so
   a wrong decision is diagnosable instead of invisible. `declined` is eds-only: the `ics` and
   `demo` backends always write `false`, which is correct rather than a bug.

## Config — `~/.config/omarchy/omeetingbar.json`

Single source of truth, read by the fetcher AND by the QML. Every key optional; code must
supply these defaults and never crash on a missing/broken file:

```json
{
  "backend": "eds",
  "ics_urls": [],
  "lookahead_minutes": 10080,
  "refresh_seconds": 300,
  "fetch_interval_seconds": 60,
  "alert_lead_seconds": 60,
  "auto_dismiss_seconds": 90,
  "colors": { "running": "#FF9500", "upcoming": "#00BEFF" },
  "inhibit_lead_seconds": 600,
  "grace_seconds": 300,
  "sound": "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
  "language": "auto",
  "notify": true,
  "notify_details": true,
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
- `alert_lead_seconds` — fire the fullscreen alert this many seconds before `start`. A
  zero-length occurrence (`end == start`) gets at least 5 s (`zeroLengthMinLeadSeconds`): it is
  over the second it starts (invariant 1), so with a lead of 0 no tick could find it both due
  and not over.
- `grace_seconds` — if we were suspended/locked and missed the moment, still fire up to this
  long after `start` (an event whose start is older than that is never alerted).
- `inhibit_lead_seconds` — hold a Wayland idle inhibitor from `start - this` until
  `start + grace_seconds`, so the session cannot blank/lock right before a meeting — or until
  the alert has been on screen for 5 s (`inhibitHandoverSeconds`), when the overlay's own
  inhibitor takes over for at most 180 s, or has failed for good. An unattended machine is
  then free to lock again instead of staying unlocked until `start + grace`. The default is
  **600**, deliberately larger than the idle timings on this machine (screensaver 150 s, lock
  300 s): a 300 s lead arrives after the blank has already happened and cannot undo a lock that is
  in progress, so the inhibitor has to be in place before the idle sequence can even start.
  Residual gap, documented rather than papered over: if the session went idle *more* than
  `inhibit_lead_seconds` before the meeting, it is already locked when the inhibitor would go up,
  and no third-party overlay can draw over `WlSessionLock`. The alert is then queued and shown at
  the unlock (see the state file), within `grace_seconds`.
- `colors.running` / `colors.upcoming` — the plugin colour-codes exactly two states, and both the
  bar entry and the fullscreen alert use the same two values, so the colour means the same thing
  wherever it appears: a meeting that has started is `running`, one that has not is `upcoming`.
  Only `#rrggbb` is accepted — an invalid colour string paints black in QML, so anything else falls
  back to the default. These are deliberately not theme tokens: they are the plugin's own signal.
- `auto_dismiss_seconds` — 0 means "stay until dismissed", bounded by the overlay's 600 s hard
  dismiss (see the overlay contract).
- `refresh_seconds` — minimum spacing between *network* refreshes (EDS `refresh_sync`).
- `notify_details` — default `true`: a meeting's toast carries the title plus the location, or
  the calendar name when there is no location. `false` sends a toast without title, location
  or calendar name — summary "Termin"/"Meeting", body the time range — with the same click
  action, because the toast text leaves the plugin's control in Omarchy's daemon (firing step
  2). `notify: false` sends no toast at all.
- `sound` — an audio file for `pw-play`. A leading `~/` is expanded and surrounding spaces are
  dropped; `""` or a false boolean (`false`, `"off"`, `"no"`, `"0"`, the plugin's one boolean
  rule) silences the alarm, `true` or `null` keep the default. It plays for at most 60 s
  (`soundCapSeconds`, through `timeout`). Under the lock the sound is the only cue that reaches
  the user, so a path that is not a file is logged (`sound-missing`), and so is a player that
  fails (`sound-failed`, with the last line of its stderr) or hits the cap (`sound-capped`); the
  file is looked for again after every fetch.
- `language` — `"de"`, `"en"` or `"auto"` (default). Resolved in exactly two places with the
  same rule: `Strings.pick(override, Qt.locale().name)` in `Strings.js` (Widget, Popup via the
  widget, Service; the alert gets the result in its payload as `lang`) and `pick_language()` in
  the fetcher (`LC_ALL`, `LC_MESSAGES`, `LANG`). "auto" means `de*` → German, everything else →
  English; English is also the fallback for a missing key. Every user-facing string lives in
  `Strings.js` (QML) or the fetcher's `MESSAGES` table, key-for-key identical in both languages
  with the same placeholders — never inline. Dates and weekday names follow the UI language
  (`Qt.locale("de_DE")` / `Qt.locale("en_US")`, so a German UI on an en_US session still says
  "Mo."), times stay 24 h in both like Omarchy's own bar clock, the ISO week reads "KW 40" /
  "W 40". Manifest texts (the bar's settings UI) cannot be localised and are English.
- `fetch_interval_seconds` — how often the QML service runs the fetcher (local read); 5 to 900,
  clamped. 900 is also the failure backoff's ceiling, so nothing longer could take effect, and
  `status` reports the clamped value. The bar calls a cache outdated past `900 + 120` s: the
  longest gap a running service leaves between two written caches is that ceiling plus a run,
  which the watchdog ends at 60 s. A run the watchdog has to end writes no cache, so fetches that
  keep hanging do get flagged — rightly, the data is old, even though the tooltip's question
  ("läuft der OMeetingBar-Dienst?") then has the answer yes.
- `lookahead_minutes` — only ever **extends** the agenda past tomorrow; it can never shorten it.
  Default 7 days, because the bar's promise is to *always* name the next meeting: on a Friday
  evening that is Monday's first one, and a 12 h horizon left the bar blank all weekend. The
  popup lists today and tomorrow in full and the next few later events under DEMNÄCHST. The
  fetcher's window is `[local midnight today, local midnight the day after tomorrow)`, widened to
  cover `now - grace_seconds … now + lookahead_minutes` so the alert horizon can only grow. Compute
  the day boundaries with `datetime.date` arithmetic plus naive `.timestamp()`, **never**
  `midnight + N * 86400`: Europe/Berlin has a 25 h and a 23 h day each year, and the naive form was
  measured to move the agenda end by ±1 h — losing tomorrow's late meetings, or leaking a
  day-after-tomorrow meeting into the "Morgen" section.

## Event cache — `$XDG_RUNTIME_DIR/omeetingbar/events.json`

Written **only** by `bin/omeetingbar-fetch`: mode 0600, atomic (tmp in the same dir + `os.replace`),
dir mode 0700. On tmpfs on purpose — nothing this plugin writes survives a reboot. One thing
outside its control does: the critical notification carries the title plus the location, or the
calendar name when there is no location (often an account address). Omarchy keeps every open
toast under `~/.local/state/omarchy/notifications/`, where it survives a reboot; a toast the
service replaced with "Meeting ended" reaches the history without content, but one the user
closed or clicked earlier keeps its text in Omarchy's history, which is on disk too (`history/`
in the same directory, the newest 10, surviving a reboot; `omarchy-shell notifications clear`
empties it). `notify_details: false` keeps meeting content out of the toast, `notify: false` sends none.

```json
{
  "schema": 2,
  "backend": "eds",
  "status": "ok",
  "error": "",
  "warning": "",
  "generated_at": 1757500000,
  "refreshed_at": 1757499900,
  "refresh_ok_at": 1757499900,
  "events": [
    { "id": "9f2c…", "title": "Standup", "start": 1757503200, "end": 1757505000,
      "all_day": false, "declined": false, "url": "https://meet.google.com/abc-defg-hij",
      "calendar": "Work", "location": "", "calendar_uid": "1d5f0c9e…" }
  ]
}
```

- `start`/`end`: **unix seconds, UTC** — no timezone strings anywhere in the cache, so QML never
  has to parse a date format. Sorted ascending by `start`. `end` is authoritative (invariant 2);
  the fetcher is allowed to write `end == start` for an occurrence without a length.
- `url`: `https://…` or `""` (invariant 3). The fetcher never writes any other scheme, and every
  consumer still re-validates.
- `title`, `calendar`, `location`: plain text with whitespace collapsed, capped at 200, 120 and
  200 characters, and without the bidi embedding, override and isolate controls (U+202A–U+202E,
  U+2066–U+2069; `_short`): an unterminated one reverses everything after it on the line it is
  drawn in, the bar label's countdown included. The widget's parser and the alert's payload
  cleaning drop them again.
- `id`: stable across runs — `sha1(uid + "@" + instance_start_epoch)[:16]`. Must be identical for
  the same occurrence on every run, or the alert fires repeatedly. An event without a UID hashes
  `"~" + title` in its place, so two UID-less meetings at the same time stay two events.
- `refreshed_at`: the last **attempted** network refresh (the throttle for `refresh_seconds`);
  `refresh_ok_at`: the last one that **succeeded** (the freshness). Both unix seconds, 0 for never.
  They differ on purpose: a refresh that keeps failing — revoked token, VPN down — must throttle
  like any other (or every run blocks on it again) and still be visible as "the data is old".
  A stamp in the future means the clock stepped back since it was taken: a `refreshed_at` ahead
  of now makes a refresh due (only an age of 0 up to `refresh_seconds` throttles), and a
  `refresh_ok_at` in the future is read as now - 1, a success from before this run: the
  staleness warning would otherwise stay quiet until the clock caught up — two hours for an RTC
  kept in local time — and a refresh failing right after the step would not read as newer.
- `calendar_uid`: the EDS source uid, lower-cased; for an ICS feed `ics-` plus the first 16 hex
  digits of the SHA-256 of its URL — a key, never the URL, which is a bearer token; `""` for demo
  and the test event. `date` and `end_date` (`YYYY-MM-DD`, `end_date` exclusive, both the local
  dates nearest to `start`/`end`): on all-day entries only. `signin_needed_at` (unix seconds,
  present only when set): the eds backend's sign-in stamp, see *Network freshness*. All three are
  for the fetcher's next run and every other consumer ignores them: carry-forward matches the
  uid (display names are not unique), `calendars_exclude` matches it as well as the name (names
  compared on both sides in the form the cache writes them — bidi controls dropped, whitespace
  collapsed, lower-cased — on live sources as on cache entries, so an entry typed the way a name
  reads on screen and one pasted with a control in it both match; `title_blocklist` terms lose
  their bidi controls the same way, and a term that was nothing else is ignored), and an
  all-day entry is rebuilt from its dates in the current zone, because its epochs are the
  midnights of the zone that wrote it.
- `status: "error"` + human-readable `error` when the backend fails; `events` then keeps the last
  known good list if one is available (write `stale: true` in that case), re-validated with the
  rules a fresh entry is written by (the URL passes the provider allow-list again, text fields are
  capped), re-filtered with the current config and without occurrences that ended before the
  agenda window. A deliberate state is not a failure — no Google account, no enabled calendar, no
  `ics_urls` — and drops the list, so a removed account's meetings stop alerting, and the sign-in
  stamp; a broken `omeetingbar.json` (unreadable, not an object, invalid values — a capped option
  is not broken) keeps the list, as it may be what made the state look deliberate. Never put tokens,
  URLs with secrets, attendee emails or full ICS text into `error`; calendars are named by
  position ("Kalender 2") because display names are often an address, and backend error text is
  scrubbed before it is quoted: URLs, then the names the run knows (the calendar's display name,
  the account's addresses), then quoted spans holding an `@` or a space, then any address
  (`<url>`, `<name>`, `<email>`) — and only then shortened, so a cut cannot leave half an address
  behind.
- `status` is `"error"` **whenever the backend reported a failure and no event survived
  filtering** — an empty list from a failed run is never dressed up as `"ok"`. "Nothing on your
  calendar" and "your calendar could not be read" must not look alike to the user.
- `warning`: always present, `""` when there is nothing to report. Non-empty means *usable but
  degraded* — the run produced events, but on fallbacks: e.g. `omeetingbar.json` holds invalid values
  and the documented defaults were used, one of several calendars failed while the others
  delivered (its previous events were carried forward), the pushed network refresh failed or
  has not succeeded for longer than 30 min or `refresh_seconds`, whichever is longer, a Google
  sign-in is due, a calendar, feed or series hit an instance cap, a feed's broken or runaway
  series was skipped, or an option was ignored
  because it does not apply to the active backend. `status` stays `"ok"`, and the text is in
  the UI language (see `language`), short and content-free (same privacy rules as `error`).
  One warning is not about the run at all: the restart notice (see *Restart notice* under the
  fetcher). It comes first and is set whatever `status` is; `restart_notice`, present only then,
  repeats its text so that a reader can cut it again, and `restart_shell_pid` names the process
  that started the run (the desktop shell, for every run of the service).
  A non-empty `warning` **must be surfaced**: the widget shows a calm marker plus the reason in
  its tooltip, and `omeetingbar status` reports it. Without that, a typo in `omeetingbar.json` runs on
  defaults forever without anyone noticing.
- `error` belongs to `status: "error"`. A consumer that nevertheless finds a non-empty `error` on
  an `"ok"` cache surfaces it like a warning instead of discarding it.
- **Privacy**: only the fields above. No attendees, no description, no organizer. Never log event
  content to stdout/journal beyond counts.

## Alert state — `$XDG_RUNTIME_DIR/omeetingbar/state.json`

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
  "toasts": [ { "id": "<event id>", "end": 1757505000, "nid": 12, "sent": 1757503140215 } ],
  "toastsShellPid": 3364032,
  "fired": { "<event id>": 1757503140 }
}
```

- `events` — three independent timestamps per occurrence, 0 meaning "not yet":
  - `notified`: the once-per-occurrence side effects are done (critical notification, sound).
    Persisted **before** they run, so a crash mid-fire cannot loop. The display wake is not one
    of them: `drainQueue` does it right before the alert is first summoned (firing step 4).
  - `shown`: the fullscreen overlay was confirmed on screen — by the overlay itself
    (`Alert.open()` calls `service.overlayShown(id)` with the queue id carried in the payload),
    or, as a fallback, by the host's `isPluginOpen` once `confirmGraceSeconds` (2 s) have passed
    since the summon. The host alone is not a witness: it reports "open" from the moment a summon
    is accepted, before Alert.qml has loaded, and only clears that again when the load fails.
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
- `toasts` — the meeting notifications this service sent and has not taken down yet: event id,
  `end` (`max(end, start + grace_seconds)`, so a meeting without a real end keeps its toast as
  long as its alert stays relevant), `nid`, the notification id the helper reported (0 until it
  has), and `sent`, the send time in milliseconds (see *Toast cleanup*: it tells the helper which
  popup files are this toast's). An entry stays until its "Meeting ended" replacement has run,
  so a replacement lost in a remount is sent again. `toastsShellPid` is the shell process the
  ids belong to: Omarchy's notification daemon restarts with the shell and numbers from 1
  again, so entries loaded under another `Quickshell.processId` keep their `end` but lose
  their `nid` and `sent`. Files written before 1.3.0 also carry the `headline` each toast was
  sent with; it is not read any more, and no meeting title is kept here. See "Toast cleanup"
  under the firing rules. Merged by id on load, like the rest of the file.
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

`Service.qml` registers `IpcHandler { target: "omeetingbar" }` (must not collide with the
first-party targets: shell, bar, idle, lock, notifications, background, nightlight, osd,
image-selector, omarchy.indicators). All args and returns are **strings**.

| Call | Effect |
|---|---|
| `omarchy-shell omeetingbar status` | JSON string: `version` (the code answering, `codeVersion`), `installedVersion` (the manifest the host last read, `""` when unknown) and `restartNeeded` (`installedVersion` non-empty and different from `version`; see *Version and updates*), backend, cache status/`error`/`warning`/age, next event, armed/inhibiting/locked, pending alert queue, last fetch outcome, effective settings, paths. Events and queue entries carry ids and times only, never titles or calendar names — `status` is what ends up in bug reports |
| `omarchy-shell omeetingbar refresh` | run the fetcher now |
| `omarchy-shell omeetingbar test` | show a synthetic alert immediately and play the alarm sound (no calendar needed), so the whole cue, Esc included, can be tried |
| `omarchy-shell omeetingbar preview` | show the alert for the event the alert path would fire on next (`isAlertable`'s view — a running meeting past its grace window is skipped even though the bar still shows it as "läuft"), without touching `notified`/`shown`; a preview or test overlay is never mistaken for a queued alert's confirmation (`lastSummonKind`) |
| `omarchy-shell omeetingbar dismiss` | hide the alert, stop the alarm sound and discard the **whole** pending queue (entries that never reached the screen are recorded as `failed`). Unlike Esc in the overlay, which closes only the head and lets `drainQueue` summon the next queued alert — an explicit dismiss means "give me the screen back" |
| `omarchy-shell omeetingbar-agenda open` / `close` / `toggle` / `isOpen` | the agenda popup, routed the way the bar routes its own panel hotkeys: to the copy whose agenda is open, else to the widget on the focused monitor; `isOpen` is true while any copy's agenda is open (`Widget.qml`'s handler, see the widget contract) — the target to bind a Hyprland key to |

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
  "location": "…", "auto_dismiss": 90,
  "colors": { "running": "#FF9500", "upcoming": "#00BEFF" }, "queued": 0, "test": false }
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
  location if present, and the join hint when a URL exists. A start that is not today carries its
  day in front of the time: "morgen", else the short date in the form the bar's tooltip and the
  agenda use (`dateShort`: "So., 11. Okt." / "Sun, Oct 11"; seen only for `preview` of a meeting
  further out, or a grace alert just after midnight).
- Keys: Return/Enter → join (`Quickshell.execDetached(["omarchy-launch-browser", url])`) then
  dismiss; Escape or any other key → dismiss; bare modifiers do nothing. Space is no join key:
  it is the key most likely to be in flight while the user is typing. Full-size `MouseArea` →
  dismiss. The decision is `keyAction(key, isAutoRepeat)` (`pass`/`swallow`/`join`/`dismiss`).
- Input guard: keys and clicks within the first second — `keyGuardMs` (1000 ms) after `open()` —
  are ignored. The overlay takes exclusive keyboard focus the instant it appears, and an Enter
  already on its way down must not join a meeting — the invite's URL — that the user has not
  read yet; it can also map between the two clicks of a double-click, whose second click must
  not clear the alert unread. A click is judged at its press, because it only reports at the
  release, which may come after the guard. Typing that goes on past the second is swallowed
  too: a key within `keyQuietMs` (400 ms) of the last swallowed one belongs to the same burst,
  and so does any autorepeat — a user still typing when the second ends must not join or
  dismiss unread with the next keystroke. Escape is exempt from that extension, so the alert can
  always be cleared deliberately once the first second is over. A negative age (the wall clock
  stepped back since `open()`) ends the guard, so no clock correction can lock input out.
  `open()` restamps the time for a queued follow-up alert, which re-arms the guard and forgets
  the burst.
- Every way the overlay closes (`opened` → false: a key, a click, auto-dismiss, the host's
  `hide()`) calls `service.stopSound(alertId)`, so Esc silences the alarm too — this alert's
  alarm only: an older alert reaching its hard dismiss must not cut short the sound of one that
  fired meanwhile, and the service checks the owner (a call without an id, from the IPC
  dismiss or an older Alert.qml, stops any sound). `service` is the plugin's own Service.qml
  instance, which the host injects into a declared `property var service`.
- A payload without a `start` (and not `test: true`) is not a meeting: the bar's positional
  panel hotkey reaches the overlay with `"{}"`, because shell.qml routes every summon of a plugin
  that declares an overlay kind here. `open()` refuses it before writing anything, so an alert
  already on screen stays as it is, and unloads a closed overlay only after the host's delivery
  loop (a zero-interval timer): a `dismiss()` inside the loop would destroy the item under the
  host, and a real payload right behind the empty one in the same loop must still open. One
  exception: the host keeps the payload of a summon that was hidden while Alert.qml loaded
  (see firing step 5) and delivers it right ahead of the next summon, so an alert that just
  opened from it may be one the service has given up on. An empty payload therefore asks
  `service.alertWanted(alertId)` (missing on a service before 1.3.0: the alert stays), and an
  alert that is not wanted leaves the screen at once (`opened` false) and unloads after the
  loop.
- The D7 budgets below (inhibitor 180 s, hard dismiss 600 s) and the auto-dismiss run from
  `openedAtMs` against the wall clock. A backward step (seen by the 1 Hz timer as
  `Date.now() < nowMs`) moves `openedAtMs` back by the step, so the time elapsed since `open()`
  is kept: a clock correction cannot stretch either budget — two hours for an RTC kept in local
  time, with the inhibitor held all along. A forward jump (a suspend) still counts in full.
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
- Renders e.g. `󰃭 14:00 Standup · 12m` in `colors.upcoming`, switching to `colors.running` once the
  meeting has started. A meeting that is not today carries a day prefix — `morgen 09:00`, or the
  short weekday (`So. 10:15`) beyond that, and the short date (`Mo., 12. Okt.`) seven or more days
  out, where a weekday alone would repeat: the default seven-day lookahead already reaches a day
  with today's weekday, and `lookahead_minutes` goes up to 30 days. The bar always names the next
  meeting, and a bare `09:00` on a Friday for a Monday meeting would be a lie. A meeting that
  began before today and is still running names its day the same way (`Mo. 23:00 Late call ·
  läuft`). The countdown (`Days.countdown`, the popup's too): minutes, then hours and minutes, and
  the calendar days to a meeting on a later calendar day once it is 24 h or more away —
  `morgen 20:00` read at 07:00 is `1d` (not round(37 h) = `2d`), Friday evening to Monday `3d`,
  while `morgen 08:00` read at 22:00 still reads `10h`; a meeting later the same day stays in hours
  even on the 25-hour day. Running, the tooltip counts elapsed time, in whole 24-hour days past a
  day ("Läuft seit 1 h 10 min.", "Läuft seit 1 Tag." — also for Monday 09:00 read on Wednesday
  08:00), and whole hours drop the minutes ("Beginnt in 2 h."). A meeting that runs past midnight
  names the day at both ends of the tooltip's range ("heute 23:00 – morgen 01:00"). The title is
  wrapped in a first-strong isolate (U+2068 … U+2069) in the label and the tooltip: a title in a
  right-to-left script otherwise sets the direction of the whole line and drags the countdown into
  it (measured: "14:00 12 · <title>m").
  `widget.warn_minutes` no longer decides *whether* there is colour — it drives
  the brightness: full strength inside the window, 75 % alpha outside it, so "soon" stays readable
  at a glance without inventing a third colour. Truncates the title to `widget.max_title_chars`
  (never through a surrogate pair: a cut that would leave half of one drops it);
  collapses to zero width only when the whole agenda is empty (if `hide_when_empty`): while today
  or tomorrow still hold entries it stays as a dimmed `󰃭 —`, because the left click is the popup's
  mouse entry point and "what did I have today, what is tomorrow" is exactly the evening question.
- Left click → toggle the agenda popup. Right and middle click → refresh. **No click opens the
  fullscreen alert**: it exists to interrupt someone who is not looking at the bar, so whoever just
  clicked it has already seen the meeting. `preview` remains an IPC diagnostic only. Joining moved
  into the popup (a row click, and a footer action).
- The widget hosts the popup and satisfies the bar's panel contract (`opened`, `open()`, `close()`,
  `toggle()`, `closeForPopoutSwitch()`, `popoutSwitchClosing`, `openPanelIndicatorWidth`; the
  `KeyboardPanel`'s `owner` is the `BarWidget` root). Two consequences of the plugin's `overlay` kind
  follow from that and are handled, not wished away: (a) the bar's positional panel hotkey resolves
  the plugin by manifest kind and reaches `Alert.open("{}")` — so `Alert.qml` refuses to blank for a
  payload without a start; (b) the bar instantiates the widget once per monitor and Quickshell keeps
  only the first `IpcHandler` registration, so the `omeetingbar-agenda` handler never acts on its own
  instance. A third-party widget's `bar` is the plugin facade (`Ui/PluginBarApi.qml`), which has no
  `summonBarWidget` but lists this module's live copies (`moduleWidgets(moduleName)`), so the
  handler picks among them by the bar's own rules (`BarModel.pickPanelSlot`): a copy whose agenda
  is open first, so `close` and `toggle` reach the one the user sees; among those the copy on
  Hyprland's focused monitor (its screen read as `item.QsWindow.window.screen.name`, like
  `Bar.qml`); and a drawn copy (visible, non-zero size) over a placeholder. `isOpen` is true while
  any copy's agenda is open. A bar that offers `summonBarWidget/hideBarWidget/isBarWidgetOpen` is
  asked instead.
- The widget keeps reading the cache and the config; the popup renders what it is handed. `events`
  is the full agenda, while the bar label, its colour, the tooltip and "next meeting" all come from
  an alertable-filtered view of it (no declined, no all-day, not over), so their meaning is
  unchanged. The parser's event cap is 512, the fetcher's own: a two-day agenda with its finished and
  declined entries does not fit in 64, and a lower cap would cut a list the fetcher already chose
  by relevance.
- Shows a clear degraded state when the cache is missing or `status != "ok"` (e.g. a dim `󰃭 —`),
  never an empty crash, never a QML binding loop.
- A non-empty cache `warning` (or an `error` on an otherwise `"ok"` cache) adds a calm `󰀦` marker
  to the label and the reason to the tooltip, and keeps the widget visible even when
  `hide_when_empty` would collapse it — a degraded state the user cannot see is not reported.
- Applies invariants 1–3 in its own cache parser: it drops non-https urls, collapses a broken
  `end` to `start`, and picks the next event with `max(end, start) > now`. It also drops the bidi
  embedding, override and isolate controls (U+202A–U+202E, U+2066–U+2069) from title, calendar and
  location, as the fetcher does at the source: an unterminated one reverses the rest of the label,
  countdown included. `Alert.qml`'s `cleanText` does the same for the payload. Both write the
  controls as `\uXXXX` escapes in their regex, never as the characters themselves: invisible
  characters in source are the "Trojan Source" pattern, and an editor that drops them silently
  turns the class into one that deletes every hyphen. An entry whose `start` (or `end`) lies
  outside what a JavaScript `Date` can hold (±8.64e12 s) is dropped (its `end` collapsed), or every
  date and countdown would read `NaN`.
- Host injects `bar`, `moduleName`, `settings` into bar widgets; read the reference widgets under
  `/usr/share/omarchy/shell/plugins/bar/` for the exact contract and styling conventions.

## Popup contract — `Popup.qml`

Not an entry point: `Widget.qml` loads it with a `Loader` and injects `bar`, `anchorItem`,
`hostWidget` and the data. The popup renders; the host acts. It calls back only through the host
(`hostWidget.join(url)`, `hostWidget.requestRefresh()`, `hostWidget.openUrl(url)`), so exactly one
file talks to the outside world.

- The surface is `Ui.KeyboardPanel` (from `qs.Ui`) anchored to the widget's `WidgetButton`. It owns
  the card, border, padding, fade, outside-click and per-output dismissal and the focus prime —
  write none of that. Do **not** add a `panel` kind to the manifest: `shell.qml` collapses a
  plugin's kinds to one loader, `panel` beats `overlay`, and the fullscreen alert would never load
  again.
- Body: `PanelKeyCatcher` → `Flickable` (clip, `StopAtBounds`, `interactive: contentHeight > height`)
  → `Column { spacing: Style.space(14) }` of: `PanelHero` (next meeting, countdown, refresh action),
  the timeline strip, `PanelSeparator`, a `HEUTE · DO., 10. SEPT. (KW 37)` section (ISO week, computed
  in QML — Qt has no format token for it), `PanelSeparator`, the
  same for `MORGEN`, then — only when non-empty — a `DEMNÄCHST` section with the next (at most
  five) meetings after tomorrow, their time column reading the weekday and time (`So. 10:15`)
  within six days and the date without its weekday (`12. Okt.`) beyond, where a weekday alone
  would repeat — the date and the time together do not fit the 84 px column (measured), so the
  time is in the row's tooltip — then the
  degraded/empty message, `PanelSeparator`, the footer action rows. The later section exists
  because the bar promises to always name the next meeting: on a Friday evening that is Monday.
- Days and rows: the sections' bounds are the first local instant of each day (`Days.dayStart`),
  the fetcher's `_local_epoch` exactly — measured equal for every day of 2026 in 13 zones,
  Santiago, the Azores, Havana, Beirut and Cairo included, where DST switches at midnight and a
  plain `Date(y, m, d)` lands an hour off. A meeting that runs past midnight is listed under both
  days, and each row prints only its own day's part with `…` at the cut: `23:00–…` under HEUTE,
  `…–01:00` under MORGEN, `…–…` on a day it runs through. Its tooltip keeps the whole range with
  the date at both ends. The formatters that turn an instant into wall-clock text (`clockTime`,
  `dayShort`, `dayLabel`, the DEMNÄCHST column) read `zoneKey` — the zone's abbreviation now and
  the UTC offsets of today and the next 31 days, so two zones that switch DST on the same date at
  different hours (Havana, New York) still differ — so the rows follow a time-zone change under a
  running shell (`omarchy-menu-timezone`) within a second instead of keeping the old times until
  their section's content changes. The key also changes once a day while a DST switch lies inside
  its window, a harmless re-render.
- The hero's meta line is one elided row of capitals (about 270 px), so it is kept short: a
  meeting already under way gets no day in front (its countdown says how long it has run; the bar
  label still names the day); one that is not today gets its day in the compact form — "morgen",
  the weekday within six days, the date without its weekday beyond (`12. Okt.`) — and a coarse
  countdown: whole hours, and minutes in the alert's short words ("in 45 min"). A meeting that
  ends on a later day at or after its start time reads `09:00–…` (a conference from Monday 09:00 to
  Thursday 17:00 is not one day's `09:00–17:00`); an overnight call keeps `23:00–01:00`, and a
  zero-length occurrence reads as one time. Measured on the real `PanelHero` inside the panel's
  inset: none of the day-prefixed lines is cut off in either language.
- Rows are `CursorSurface`, and the panel owns the cursor state (`cursorActive`, `focusSection`,
  `selectedIndex`); a row must never colour itself from `containsMouse`, or mouse and keyboard show
  two highlights at once. Hover goes through `Ui/PointerMoveGate` (reset on every keyboard move):
  Qt re-delivers hover to whatever a keyboard scroll slides under a stationary pointer, and without
  the gate `j`/`k` could not cross the viewport edge while the mouse rested on the list. A keyboard
  move arms one `revealPending` token before its selection and clears it right after, so exactly
  the row it selects consumes it (the reveal itself is deferred, because a freshly created row
  reports `y = 0` until the Column's polish): Repeater rebuilds under an open popup never scroll,
  and neither does a later hover. `open()` resets the token and the gate, so a pointer resting
  where the join row maps cannot select it; that relies on Qt delivering the hover to the button's
  own HoverHandler before the card-wide one primes the gate (measured with Qt 6.11.2). Cursor
  transitions toggle `cursorActive` off and on around the two writes, so
  no row is selected with the old index in the new section for a frame. Row states: finished → 45 % opacity, running → `current` + bold + the
  running colour, declined → `font.strikeout` (lowercase "o"; it leaves `implicitWidth` untouched).
- The timeline strip carries **no hour numbers**, and that is a deliberate scar rather than an
  omission: any `Text` in that axis row — even a constant string with no geometry of its own — put
  the shell into a polish loop, one core pinned and gigabytes of growth for as long as the popup was
  open, with no binding-loop warning from Qt. Bisected on this machine: the notches in the lane row
  are fine, a `Rectangle` in the axis row is fine, a `Text` there is not, and neither an integer
  `Repeater` model, nor removing the self-referential `x` binding, nor replacing every sibling
  anchor with explicit geometry changed it. Root cause not established. The notches carry the hour
  grid and every row shows its own times, so the axis was dropped instead of shipped as a
  desktop-freezing decoration. Do not re-add it without reproducing the measurement.
- The timeline strip is otherwise the one element with no first-party equivalent; build it from
  in-tree idioms:
  the clock's track/fill with the `Style.cornerRadius > 0 ? height / 2 : 0` guard (this theme is
  square), `PanelSlider`'s fraction-positioned ticks, greedy lane packing capped at 3 lanes, and a
  now-marker in `Style.selectedStateColor(fg, Color.accent)` — theme chrome, so the plugin's two
  colours keep meaning "meeting state". A rail is 4 to 14 hours; when today's day is longer than
  that, its rail starts no earlier than an hour before the current hour, so "now" stays on it.
  Bars are half-open like the sections: a meeting that starts at or after the rail's end, or ended
  at or before its start, is left off (its row still lists it) instead of drawing a stub at the
  edge. The notch count is read off `stripWindow` itself and
  capped at 15: read off `stripStartSec`/`stripEndSec`, two separate bindings, it was seen with a
  start of 0 beside the old end when the rail went empty, and the notch `Repeater` froze the shell
  creating half a million delegates.
- Every `Text` sets `textFormat: Text.PlainText`: meeting titles are untrusted third-party input.
  Nerd-font glyphs sit in a fixed-width centred `Item` (single-cell advance, up to 15 px of paint).
- The provider glyph per row and the join footer come from `Providers.js`, the one table shared
  with `Alert.qml`. Host matching is exact-or-subdomain (`acme.zoom.us` is Zoom, `evilzoom.us`
  is not). Only Nerd-Font marks are used — Google, Teams, Slack, Discord have one, the rest share
  `md-video` — so no trademarked artwork ships with the plugin. The glyph carries the provider's
  published brand colour (sources in the file), moved towards white or black until it reaches 3:1
  against `Color.popups.background` (WCAG's figure for non-text UI); a provider without a reliable
  brand colour (Whereby) keeps the muted theme colour. Brand colour is deliberately confined to
  the glyph: the time column keeps the two signal colours (running/upcoming).
- Dates are formatted with the UI language's locale, never the session's (`uiLocale`,
  `Qt.locale(Strings.localeName(lang))`): `toLocaleDateString(uiLocale, Strings.t(lang,
  "dateShort"))` → `Do., 10. Sept.` in German, `Thu, Sep 10` in English.
- Sizes come from `Style.space()` / `Style.font.*` only, never a bare pixel number. Width
  `fittedContentWidth(Style.space(380))` like every anchored first-party panel, height
  `fittedContentHeight(column.implicitHeight, Style.space(560))`.

## Service contract — `Service.qml`

- **Timing (critical)**: one repeating `Timer { interval: 1000 }` that recomputes everything from
  `Date.now()` wall clock each tick. No long one-shot timers, no `systemd-run --on-active`
  (CLOCK_MONOTONIC, paused across suspend → fires late). If the wall clock jumped more than 15 s
  between ticks (suspend/resume or a clock correction), force a fetch immediately. After a
  backward step every stamp a throttle measures from lies in the future — `lastFetchAtSec`,
  `lastFetchStartedAtSec`, the notify helper's start, `lastLockProbeSec`, the pending lock
  probe, `saveRetryAtSec`, `lastPruneAtSec`, each queue entry's `summonedAtSec` — and interval
  fetches, both watchdogs, lock probing, re-summons and save retries would stall until the clock
  caught up (two hours for an RTC kept in local time): `rebaseStamps` pulls them back to now. On
  any jump the last lock answer is dropped (`lockKnownAtSec = 0`); it predates the jump. A lock
  probe or a notify helper running across a jump did not run for the time the clock skipped,
  so their timeouts start over at the jump instead of reaping them as hung, and the probe's
  answer is not taken (`lockProbeStale`): it may describe the session before the sleep, and a
  fail-open "unlocked" from it would summon the alert under the lock. The next tick asks
  again. A fetch from before a suspend is the opposite case and is reaped on purpose (firing).
- **Fetch**: `Process` running `/usr/bin/python3 <pluginDir>/bin/omeetingbar-fetch` — resolve the
  plugin dir with `String(Qt.resolvedUrl("bin/omeetingbar-fetch")).replace(/^file:\/\//, "")`.
  Always the absolute `/usr/bin/python3`, never a bare `python3` (mise/pyenv shims lack `gi`).
  Re-entrancy guard (`if (proc.running) return`). Run at startup, every
  `fetch_interval_seconds`, on wall-clock jumps, and on IPC `refresh`.
- **Fetch backoff**: consecutive failures double the interval —
  `min(fetch_interval_seconds * 2^min(streak, 4), 900)` — and a single success, or any edit to
  `omeetingbar.json`, resets it. A backend that cannot work at all (`eds` before the packages are
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
- **Notify watchdog**: toasts go out through one helper at a time, so a helper that never ends
  would hold every later toast back for the rest of the session. The helper ends itself after
  30 s (`SIGALRM`); one still running after 40 s is terminated and killed at 50 s, and its
  `exited` drops the job and starts the next. A helper that fails to start emits no `exited` at
  all (see the environment facts): `runningChanged` with `running` false while a job is still
  current drops that job instead (logged once as `notify-failed: not started`).
- **Version and updates**: `omarchy plugin update` fast-forwards the plugin's git checkout and
  ends with `omarchy-shell shell rescanPlugins`; the plugin registry's file watcher triggers the
  same reload when the files change. A reload destroys and recreates the service
  (`unloadPluginServices`, then `ensureService` in `shell.qml`), but from the engine's
  component cache: `finishPluginReload` clears it only if `Qt.clearComponentCache` exists, and
  Qt 6.11 has none. So after an update `manifest.version` names the installed version while the
  old `Service.qml` and `Widget.qml` code runs on until `omarchy restart shell` (which Omarchy
  refuses while the session is locked); in-memory state such as summon attempts and the
  notify queue starts over, and the state file carries the rest. `codeVersion`, a
  constant in `Service.qml`, is the only thing that says which code is running. `status` reports
  `version` (`codeVersion`), `installedVersion` and `restartNeeded`, and every fetch gets
  `OMEETINGBAR_SERVICE=<codeVersion>` added to the inherited environment: the fetcher is read
  from disk on every run, so it is the new code first and raises the restart notice (see
  *Restart notice* under the fetcher). **Release rule**: `codeVersion` in `Service.qml` must
  equal `version` in `manifest.json`; bump both together. A mismatch reports
  `restartNeeded: true` and a fetcher warning on every run, and no restart clears either. QML
  files that were not cached yet when the update landed — `Alert.qml` if no alert, test or
  preview has been shown since the shell started, `Popup.qml` if the agenda was never opened —
  load as new code beside the old `Service.qml` and `Widget.qml`, so a release must keep them
  compatible with the previous version's alert payload and popup bindings. They also run
  against the previous version's JavaScript: the engine caches every JavaScript file it has loaded
  — `Strings.js`, `Providers.js`, and from 1.4.0 `Days.js` — for its whole life (measured with
  Quickshell 0.3.1 / Qt 6.11.2: a never-loaded component gets the new QML with the old JS
  imports), so a new key there reads as its raw name and a new function is missing, and `open()`
  would throw. New QML may use a new key or JS function only behind a fallback or a `typeof`
  check. A JavaScript file that is new in a release has no cached copy and loads fresh, but its
  own imports are the cached ones: `Days.js` therefore uses only `Strings` keys and functions that
  every published release has. Check each release's QML and JS against the JS of every release a
  user may still be updating from, not only the previous tag — a marketplace user can skip
  versions (1.1.0 → 1.4.0). Measured for 1.4.0: the new `Popup.qml` and `Days.js` hosted by every
  `Widget.qml` from 1.0.0 to 1.3.0, and the new `Alert.qml` with those releases' payloads, each
  with that release's `Strings.js` and `Providers.js`, load and render without an error or a raw
  key. The other way round — a downgrade without a restart, as when a dev checkout goes back to
  an older commit — a never-loaded old QML file gets the new cached JS, so a key or function the
  previous release's QML calls stays one release after its last use: 1.4.0 keeps `weekday()`,
  `weekdays` and `alertDate`, which only the 1.3.x alert read.
- **Firing** every alertable event (invariant 1) with `start - now <= alert_lead_seconds` (at
  least `zeroLengthMinLeadSeconds`, 5 s, for a zero-length occurrence: see the config) and
  `now - start <= grace_seconds` whose id is not in `notified` — all of them on the same tick,
  not only the earliest, bounded at `maxFiresPerTick` (8) per tick. All-day events are skipped
  here unconditionally (invariant 4). Not during the first `fireHoldSeconds` (30 s: after any
  longer sleep that fetch is refresh-due and may spend up to 25 s in `refresh_sync`) after a
  clock jump until a fetch started after the jump has finished: the cache then predates the
  sleep, and a meeting cancelled or moved while the machine slept must not wake the display,
  notify and ring. A fetch that ran across the suspend is refused as the re-run and reaped by
  the watchdog (its age counts the sleep); the re-run is retried every tick inside the hold
  (`jumpRefetchPending`), and the hold covers that wait too, so the reaped fetch cannot lift it
  on its way out. The queue's payloads predate the sleep as much as the cache does, so in the
  same window no queued alert is summoned for the first time either (`deferredReason`
  "refreshing"): an alert queued under the lock before a suspend, for a meeting cancelled
  meanwhile, must not be shown — and wake the display — before that fetch can withdraw it.
  1. persist the id to `notified` in the state file first (so a crash cannot cause a re-fire loop),
  2. if `notify`: a critical toast through `bin/omeetingbar-notify`, run as a child `Process`
     one at a time (`notifyQueue`) with the payload written to its **stdin** — title, body,
     glyph `󰃭`, urgency, and, only when a URL exists, the click action
     `["<plugin>/bin/omeetingbar-join", "<event id>", "<grace seconds>"]`. **No process of this
     plugin may ever carry calendar content in its arguments**: `omarchy-notification-send` and
     `busctl` put summary, body and `--exec` into argv, which any local user can read from
     `/proc/<pid>/cmdline` while they run (the marketplace review of 2026-10-04 flagged exactly
     that). The helper calls `org.freedesktop.Notifications.Notify` over Gio with the hints
     Omarchy's daemon reads (`urgency` byte, `omarchy-glyph`, `omarchy-exec-argv` as a JSON
     string) and `app_name` `omarchy-action` (the daemon's DND bypass), and prints the
     notification id, which lands in the toast's `nid`. Without Gio it falls back to
     `omarchy-notification-send -p` with the content-free `safe` text (the word "Meeting" and
     the time range) and the same click action, and prints the id too, so such a toast still
     joins and is still taken down at the end; a
     sender that fails or hangs (15 s) exits 2 like a failed D-Bus call. The body is the time
     range plus the location, or else the calendar name — nothing relative: the critical toast
     stays up until the meeting ends, so "starts in 1 minute" would still read so at 14:40, and
     "now" would greet a resume four minutes late. Past the helper the text is out of the
     plugin's hands: Omarchy's daemon saves
     every toast it shows (`persistPopupFile`) by handing summary, body and click argv as one
     JSON string to a short-lived `bash -c` job as an argument, so title and location, or the
     calendar name, are briefly readable in that job's `/proc/<pid>/cmdline`, and the popup file
     keeps them (see the event cache). `notify_details: false` sends "Termin"/"Meeting" with the
     time range instead. The click argv carries no URL either way, so the join
     URL never reaches the daemon. `omeetingbar-join <id> <grace>` reads URL, start and end from
     the 0600 cache when clicked and opens the URL with `omarchy-launch-browser` until the
     meeting ends, before its start too (`end`; for a zero-length occurrence `start + grace`, the
     same window its toast lives; a grace that is not a plain decimal 0–3600 means 300); after
     that, or when the event is gone from the cache, a click just closes the toast — and so
     does a click on a meeting declined since (`declined` in the cache), unless `skip_declined`
     is explicitly off in `omeetingbar.json` (`false`, `"off"`, `"no"`, `0`: the plugin's
     boolean rule, read with `jq` from exactly one JSON object as the service's `JSON.parse`
     reads it, numbers the way JavaScript's `String()` writes them), the same rule the alert
     follows. So the URL
     never appears on a command line, nor in Omarchy's persisted notification files, before the
     browser launch itself. The legacy form `omeetingbar-join <url> <end>` is still accepted for
     one or two releases, with its 1.0.x rules (https, no whitespace or backslash, nothing once a
     numeric `end` has passed): toasts from a service that has not been restarted since the
     update, and toasts Omarchy restores from disk, still call it that way. Location and
     calendar name are markup-escaped (`& < >`) because Omarchy renders the body as
     `StyledText`; the headline is plain text there and needs none. Only the first
     `maxToastsPerBurst` (3) meetings of a burst get their own toast — a burst being the ticks
     whose fire loop hit `maxFiresPerTick`, and the tick that ends them; the rest share one
     summary toast ("N weitere Termine", body "Nicht einzeln gemeldet · siehe Agenda", no join
     link, tracked under its own id until the last of them ends), sent once the burst is over.
     A single meeting past the budget gets its own toast instead: a summary for one saves no
     toast and loses the join link. N invites for the same minute must not mean N critical,
     never-expiring toasts,
  3. if `sound` resolves to a file (see the config): `timeout -k 5 60 pw-play <file>` as a
     child `Process`, not detached, so closing the overlay can stop it, and capped
     (`soundCapSeconds`) so a stalled player cannot mute every later alert until a restart; a
     sound still playing is not restarted by a second meeting in the same minute. The sound
     belongs to the alert that started it (`soundOwner`): the overlay's `stopSound(id)` stops
     that one only, the IPC dismiss any,
  4. append the payload to the state file's `queue` in every case and start a lock probe. The
     queue is capped at `maxQueueLength` (8): a ninth alert waiting is a flood, not a schedule,
     and is recorded as `failed` without blanking the screen. `drainQueue` summons the head
     (`shell.summon(manifest.id, JSON.stringify(payload))`) only once a lock answer at most
     `lockStaleSeconds` old says the session is unlocked — nothing draws over `WlSessionLock` —
     and as long as `untilSec` has not passed; `shown` is recorded only on a witness (see the
     state file). A probe that brings no answer within `lockProbeTimeoutSeconds` (5 s) — hung,
     or never started at all, which emits no `exited` — counts as "unlocked", so a broken probe
     is never what keeps the alert off the screen. The 5 s run from the first unanswered request
     (`lockProbePendingSinceSec`), not from the latest: a probe is asked for again every 2 s, and
     a timeout measured from that would never expire. Right before the head's first summon,
     past that fresh "unlocked" answer — a sure one, `false` from a probe that exited cleanly
     (`lockAnswerSure`); a probe given up on lets the alert through but is no answer that the
     session is unlocked — it wakes the display if `wake_display`:
     `omarchy-brightness-display on` (NOT
     `hyprctl dispatch dpms on` — that dispatcher no longer exists in Hyprland 0.56). Never under
     the lock: a wake there lights the panels, and Omarchy's one-shot blank timer never turns
     them off again. Re-summons leave the display alone (the attempt count is not persisted, so
     a reload re-arms the wake once), and test and preview alerts never wake it. A queued alert
     is only ever *shown* late — the notification and the sound in steps 2–3 have already
     happened at the right moment, which is why the timestamps are separate.
  5. a queued alert whose event has disappeared from a fresh, healthy, non-stale cache (cancelled,
     or moved out of the window) is dropped as `failed` instead of blanking the screen. Only an
     `ok` and non-stale cache may withdraw an alert: an error or stale cache is missing events for
     its own reasons. A withdrawn alert also takes its toast down (`withdrawToast`: the recorded
     toast's `end` is pulled to now, and the next tick's toast cleanup replaces it by
     notification id, see *Toast cleanup*), so no live join link is left behind for a meeting
     that is off. The toast outlives its alert, so the same healthy cache takes down the toast
     of any meeting that is gone, or declined while `skip_declined` is on, also after its alert
     was shown and closed. Not `isAlertable()` there, which would take down the toast of a long
     meeting past its grace window; summary toasts carry no link and stay. A queue head that was
     summoned but not confirmed yet may still be loading: before such a head is dequeued —
     withdrawn, past its grace window, or given up as unconfirmed — `cancelPendingSummon` hides
     the overlay, which cancels the load; otherwise the host would deliver the withdrawn
     meeting's payload once Alert.qml has loaded, and `open()` would show it. Never from
     `overlayShown`, where a hide would break the next payload of the same delivery loop. The
     host's `hide()` keeps that payload, though, and delivers it right ahead of the next summon:
     a real payload behind it takes the screen, and an empty one asks `alertWanted(id)` — true
     for an id still in the queue, for a test or preview summoned since, and false after the
     IPC dismiss (`lastSummonKind` "dismissed") — so the withdrawn alert leaves at once.
- **Bounds on calendar input**: `normalizeEvents` keeps at most `maxEvents` (512) occurrences,
  chosen by the fetcher's relevance rule (`capByRelevance`, see *Bounds* under the fetcher; ties
  broken by start, then id, since Qt's JS sort is not stable; the service's `grace_seconds` is
  capped at an hour, the fetcher's at six), and
  drops a URL longer than `maxUrlChars` (2048). Both bound hostile input: a
  `FREQ=SECONDLY` rule expands to hundreds of thousands of instances, and an invite can carry a
  URL of any length. No argv limit is at stake: no notification carries a URL (the click action
  carries the event id), and the browser launch takes it as one argument far below any limit. The fetcher caps on its side too; this is the second line.
- **Toast cleanup**: critical toasts never expire in Omarchy, so a meeting notification would
  stay on screen until clicked — and a stale one, clicked after a meeting taken on the phone,
  used to reopen the call. Once `now >= end` of a recorded toast, the service **replaces** it by
  notification id (`replaces_id = nid`) through the same helper with a low-urgency "Meeting
  beendet" / "Meeting ended", empty body and an expiry of `toastReplaceExpireMs` (1500 ms). That
  is only a request: Omarchy shows a low-urgency toast for at least 5 s (`lowPopupDuration`, its
  floor), then lets it expire into the notification history — rewritten by the replacement, so
  that history entry carries no meeting content. The entry stays until that replacement has run
  (sent, answered `gone`, or failed): the notify queue lives in memory, so after a remount that
  lost it the next tick sends the replacement again from the state file.
  - Why replace: a freedesktop `CloseNotification(id)` leaves an Omarchy popup on screen
    (measured on 4.x: the server object closes, the popup row stays), and the only IPC that
    closes one — `omarchy-shell notifications dismiss "<summary substring>"` — would put the
    title on a command line again. Replacing works by id and carries no calendar content.
  - A toast the user already closed must not be replaced: the daemon would treat the stale id as
    a new notification and show a stray "Meeting ended". The helper therefore checks Omarchy's
    popup state directory (`~/.local/state/omarchy/notifications/<timestamp>-<id>.json` exists
    while a toast is on screen) and answers `gone` without sending; an unknown layout reads as
    "open", so the replace is still sent. Omarchy restores popups after a shell restart under
    their old ids, and the next daemon numbers from 1 again, so a recycled id can match an old
    restored file: the replace payload carries `sent_ms` (the entry's `sent`), and the helper
    counts only files whose name starts no more than 5 s before it (the prefix is the daemon's
    millisecond timestamp). Any file in the directory named another way is a layout the helper
    does not know, and reads as "open" too.
  - A toast without an id — the helper failed, or the entry was recorded under another shell
    process (`toastsShellPid`), i.e. before a shell restart — is forgotten without a dismiss
    unless the helper is sending it right now (a slow helper can report the id after the
    meeting was withdrawn, and that id must still land on the entry); a first send still
    waiting in the queue is dropped with it, so a meeting that is over or off gets no toast at
    all. Toasts forgotten this way, like those from before a reboot (below), are not taken
    down. It still closes by click
    (`omeetingbar-join`, which checks the end itself) or by right click, which Omarchy maps to
    "close without action". Every toast is tracked, including ones with an empty title; no title
    is kept, and none is ever used to dismiss.
  - Nothing holds the cleanup back after a start: a hot reload keeps the shell process, its
    toasts and their ids, and after a shell restart `toastsShellPid` has dropped the ids before
    anything could be replaced. The state file is tmpfs, so after a reboot nothing is recorded;
    `omeetingbar-join` is the fallback.
- **Idle inhibitor**: hold one from `start - inhibit_lead_seconds` (default 600 s, see the config
  semantics) until `start + grace_seconds` for the next alertable event, so the session cannot
  lock/blank into the alert — but not for an event whose alert has been on screen for
  `inhibitHandoverSeconds` (5 s; the overlay's own inhibitor takes over, for at most 180 s) or
  has failed for good: an unattended session must be free to lock again, not stay unlocked
  until `start + grace` (a `shown` stamp in the future, after a backward clock step, counts as
  long ago). Implement as a 1x1 click-through `PanelWindow` (input mask empty /
  `WlrKeyboardFocus.None`) carrying `IdleInhibitor`, created only while needed. Quickshell 0.3.1
  exposes `Quickshell.Wayland.IdleInhibitor` with `enabled` and `window`; the omarchy idle service
  runs `IdleMonitor { respectInhibitors: true }`, so this genuinely suppresses blank+lock. Do **not**
  touch omarchy's persisted stay-awake flag.
- Every external command must be an argv array (`Process.command` / `Quickshell.execDetached([…])`)
  — never a shell string built from event data. `Util.execDetached` takes a shell string and is the
  unsafe one; `Util.execArgv` is safe.
- Log at most one line per state change to the journal, without event titles.

## Environment facts (the author's reference machine — verified there, do not re-derive)

- Omarchy 4.0.x, Hyprland 0.56.2, Quickshell 0.3.1, Qt 6.11.2, systemd 261, Europe/Berlin, NTP on.
- Monitors: eDP-1 3200x2000@120 scale 1.6, DP-1 5120x2160@60 scale 1.25.
- Lock is `WlSessionLock` (ext-session-lock-v1) from the first-party `omarchy.lock` plugin;
  hyprlock is not installed. A third-party overlay can never draw over the lock surface.
- Idle defaults: screensaver 150 s, lock 300 s — the reason `inhibit_lead_seconds` defaults to
  600. `omarchy-shell idle status` reports live state; stay-awake is currently on, so idle is
  disabled on this machine right now.
- Omarchy's notification daemon bypasses DND for `app_name` `omarchy-action` (what
  `omarchy-notification-send` sends and `bin/omeetingbar-notify` reuses) and for critical
  `notify-send` toasts; it reads `omarchy-glyph` and `omarchy-exec-argv` from the hints
  (`NotificationLogic.js`). Omarchy ships no sound files; `pw-play`, `paplay`,
  `canberra-gtk-play` and `sound-theme-freedesktop` are installed.
- QML errors from plugins land in `journalctl --user -t omarchy-shell` and
  `/run/user/1000/quickshell/by-id/<id>/log.qslog` (`quickshell log -f`).
- Quickshell 0.3.1 `Process`, measured on 2026-10-05 offscreen: a normal run emits `started`,
  then `exited` (inside which `running` already reads false), then `runningChanged`. A program
  that fails to start emits only `runningChanged` with `running` false — no `started`, no
  `exited`. Restarting the process inside `exited` works; the `runningChanged` that follows
  then reads `running` true. After `running = false` the property still reads true until the
  process is gone, and `exited` reports the signal (code 15, crash status). Wrapped in
  `timeout`, a terminated child reads the same way, an expired timeout as a normal exit 124 —
  but a player that catches SIGTERM and exits by itself reports its own normal exit code, which
  is why a stopped sound is recognised by a flag (`soundStopRequested`), not by its exit.
- Hyprland 0.56's Lua config takes `no_screen_share` in `hl.layer_rule` as well as in window
  rules (`/usr/share/hypr/stubs/hl.meta.lua`, `HL.LayerRuleSpec`). Omarchy's toasts are the layer
  namespace `omarchy-notifications`, the alert's is `omeetingbar-alert`; the user's personal
  rules go at the end of `~/.config/hypr/hyprland.lua`.
- Saving any file under `~/.config/omarchy/plugins/` triggers a plugin reload, but — measured on
  2026-09-10 on this machine — that reload does **not** replace the running third-party *service*
  instance with the new code: `omarchy-shell omeetingbar status` kept returning the old schema after
  the file change, after `omarchy-shell shell rescanPlugins`, and after clearing
  `~/.cache/quickshell/qmlcache`. Only `omarchy restart shell` loads changed service code.
  Config changes do apply immediately (the config is read through a `FileView`).
- `backend: "demo"` must work end to end so the whole plugin can be tested before a Google
  account exists (it did here: GOA/EDS were installed only after the first version ran). The
  required packages are exactly `evolution-data-server`, `gnome-online-accounts`,
  `gnome-online-accounts-gtk` and `python-gobject` (in Omarchy's base set, but nothing else in
  the list depends on it, so it is named), and the GOA account dialog on this machine is
  **`gnome-online-accounts-gtk`** — the only one installed here. Docs, installer output and
  diagnostics name that command and no other settings app.
- `libical` 4.0.5 ships `ICalGLib-4.0.typelib`, `evolution-data-server` ships `ECal-2.0` and
  `EDataServer-1.2` (both from `pacman -Fl`).

## Event source — `bin/omeetingbar-fetch`

CLI: `omeetingbar-fetch [--config PATH] [--out PATH] [--backend eds|ics|demo] [--in-seconds N]
[--refresh] [--diagnose] [--print]`
- `--in-seconds N`: inject one synthetic event starting N seconds from now, so the alert path can
  be tested deterministically on whatever backend is configured (see *Test injection* below). A
  start already more than `grace_seconds` in the past is spent on the spot and said so in
  `warning`; the marker is subject to the window only, never to `title_blocklist` or
  `min_duration_minutes`.
- `--diagnose`: print a human-readable readiness report (packages, typelibs, GOA accounts,
  calendars found, last sync attempt and last success, the installed plugin version beside
  `OMEETINGBAR_SERVICE`) — no event content. It reads the calendar like a normal run, a due
  network refresh included, but writes no cache. A module that fails on import is reported as
  installed but broken (status `DEFEKT`/`BROKEN`), not as a traceback that loses the report — a
  broken `gi` included; only a module that is not found at all reads as missing, an ImportError
  from inside one (a native library, a dependency) is broken. GOA's `accounts.conf` is looked for where goa-daemon keeps it
  (`$XDG_CONFIG_HOME` when set), then in `~/.config`, and an unreadable one is reported as such
  rather than as "0 accounts".
- `--print`: write the JSON to stdout instead of the cache file and leave that file alone, the
  refresh stamp a due refresh would persist included (full event content — an explicit opt-in,
  the one exception to the privacy rule above).
- Exit 0 on success; on failure still write a cache with `status: "error"` and exit non-zero.
- **Restart notice**: the environment variable `OMEETINGBAR_SERVICE` names the version of the
  service that started the run (see *Version and updates*). When it differs from `version` in
  the `manifest.json` of the plugin directory the script lives in (resolved through its real
  path), the run puts `restartNeeded` ("OMeetingBar was updated – restart the shell (omarchy
  restart shell) to run the new version.") **first** into `warning`, ahead of the config
  warning: the widget cuts a long warning to 140 characters in its tooltip, and this is the one
  that a single command clears. An empty value counts as set and differs. Unset is either a
  service from before 1.1.0, recognised by its parent process being the desktop shell
  (`/proc/<ppid>/comm` is `quickshell` or `qs`), which warns too, or a run from a terminal, which
  must not. A manifest that cannot be read, or has no non-empty string `version`, leaves nothing
  to compare and skips the check. `--diagnose` does not run the check itself (it prints the cache's last
  `warning`, which may carry the notice) and prints both versions.
  The notice is meant for the shell that ran the fetch, but the cache outlives that shell: right
  after `omarchy restart shell` the new code reads it until its first fetch replaces it, and
  would ask for the restart that has just happened. So the run also writes the notice's text to
  `restart_notice` and its parent's pid (`os.getppid()`, taken with the check) to
  `restart_shell_pid`. `Service.qml` and `Widget.qml` cut that text from the start of `warning`,
  keeping the rest, only when that pid is a positive number other than their own
  `Quickshell.processId` — the same test the alert state uses for `toastsShellPid`. A rescan, a
  rebuilt bar or a new monitor keeps the shell process and with it the notice, a wall-clock step
  changes nothing, and a missing or malformed pid keeps the notice. A run from a terminal that
  sets `OMEETINGBAR_SERVICE` by hand names the terminal, so the readers cut its notice. Readers
  from before 1.1.0 ignore both fields and show `warning` as it is, which is what they need.
- **Bounds** (calendar data is third-party input): one series contributes at most 512
  occurrences — the rest is skipped, never the expansion stopped: EDS walks the series in hash
  order, and stopping hid every later series of the calendar. A calendar or feed keeps at most its
  2000 earliest occurrences, and an ICS series that repeats every second or minute and would
  flood the window is dropped before the expansion (see *backend `ics`*). `warning` names each
  cut. The cache keeps at most 512 events, chosen by
  relevance, not by start (`cap_events`): what has not started more than `grace_seconds` ago,
  earliest first, up to three quarters of the limit; then what is running; then what finished
  most recently; then the rest ahead. The agenda starts at local midnight, and an earliest-first
  cut let a dense morning push every meeting still ahead out of an "ok" cache. URLs over 2048
  characters are dropped. Service.qml caps again by the same rule, Widget.qml at 512.
- **Deadlines**: the service kills the fetcher at 45 s and a killed run writes no cache, so every
  blocking call has one — 15 s for all pushed refreshes together, charged only for the time
  inside `refresh_sync` (a `Gio.Cancellable` fired from a timer), and no refresh started or left
  running past 25 s into the calendar loop (connects and expansion count towards that) — the
  cutoff bounds the refreshes, not the loop: the calendars after it are still connected and read,
  from the local copy; 30 s for all ICS
  downloads together, each held to what is left of it (a download thread abandoned at the
  deadline: the socket timeout applies per operation and name resolution has none); 1 s per
  `connect_sync` (see below).

### Test injection — `--in-seconds`

`omarchy-shell omeetingbar test` only draws the overlay and plays the sound; it proves the surface
renders, not that the alert *fires*. The real path — cache → service tick → notification → summon → state file — is
tested with an injected event:

```
./bin/omeetingbar-fetch --in-seconds 45      # writes the cache and the inject marker
omarchy-shell omeetingbar status             # next event is the synthetic one
# the service picks the new cache up at once and fires alert_lead_seconds before that start
```

`--in-seconds N` *arms* one synthetic event — start exactly `now + N`, no rounding, so the alert
lands `alert_lead_seconds` before that — by writing an **inject marker** next to the cache:
`inject.json`, same directory as `--out` points at, same 0600 and same atomic replace as the
cache. It holds only `id`, `title`, `start`, `end`, `url`; the rest is fixed (`calendar` `Test`,
`location` `Arbeitszimmer`, a clearly test-labelled title, a demo join URL). The marker, not the event title, is the identity
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
- The marker is read after the backend has run, not before: a run that started before the test
  was armed — the service's, during a slow refresh — must not write its cache without it.

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
  older than `refresh_seconds`, call `client.refresh_sync(cancellable)` (guarded by
  `client.check_refresh_supported()`) for every calendar, within the budget and cutoff above,
  starting at another calendar every refresh cycle (`now // refresh_seconds`) so that a spent
  budget never starves the same calendars; one left out is read from the local copy and counts
  as skipped, not failed. Only the order of the refreshes rotates: results are merged in registry
  order, so which copy of a meeting listed in two calendars wins does not change from cycle to
  cycle. The attempt is stamped into `refreshed_at` and **persisted before** the
  refresh starts (the previous cache is rewritten with the new stamp), so a refresh killed by the
  watchdog cannot make the next run hang on the same refresh again; the in-memory cache gets the
  stamp too, so an error branch writes it back instead of the old one.
  `refresh_sync` returns success whatever the server answered — measured on EDS 3.60.2 with
  synthetic webcal sources: 200, 401 and 500 all return without an error and without
  `backend-error`, at once when the server answers at once and only after its answer when it is
  slow. The source's connection status is no reliable witness: it turns `awaiting-credentials`
  after a 401, but EDS sets it back to `disconnected` when the refresh returns, and when a
  client is released. What does tell is the source's `credentials-required` signal, connected
  before the calendar is opened: a backend that the server turned down asks for credentials,
  with reason `required` or `rejected` after a 401 and `error` after a 500, for every refresh
  that fails (a fast or a slow answer, one calendar or several, a fresh process per run) and
  never for a 200. Signals are queued until the main context runs, so after the loop the run
  lets them in for 0.3 s and only then releases the clients. A calendar counts as failed when it
  asked for credentials, when its status still reads `awaiting-credentials` or `ssl-failed`,
  when the client reported `backend-error` or `backend-died` (heard if a backend sends them; the
  webcal backend sent neither), when `is_online()` is false (EDS's network monitor sees no
  network), or when connecting failed. An unreachable server that the network monitor does not
  notice may still pass unreported, so `refresh_ok_at` means "accepted by EDS without a reported
  error". Outcomes go to `refresh_ok_at` and `warning`: all failed → `refresh_ok_at`
  unchanged; some failed → "teilweise fehlgeschlagen (n von m)"; on every run, refreshing or not,
  "Kalender-Sync fehlgeschlagen" while `refreshed_at` is newer than `refresh_ok_at` (after login
  too, when the tmpfs cache knows no success at all), and "Letzter erfolgreicher Kalender-Sync
  vor …" once `refresh_ok_at` is older than 30 min or `refresh_seconds`, whichever is longer.
  A run in which a calendar asks for a sign-in (`required`, `rejected`, or the status
  `awaiting-credentials`) stamps `signin_needed_at`, and "Google-Anmeldung nötig – in
  gnome-online-accounts-gtk neu anmelden" is shown while the stamp is set: by the next run the
  backend that asked is gone. A run whose refreshes were read without such a request clears
  it — failures of other kinds say nothing about the sign-in — and so does a deliberate state
  (no account any more). A refresh failure never discards the local copy: EDS still has it, and
  a stale list that says so beats an empty one.
- One failing calendar: any exception from `connect_sync` or the expansion is that calendar's
  problem, not the run's. So is a calendar that hands over no occurrence at all when a direct
  query of the window (`get_object_list_as_comps_sync`) then fails: a calendar factory that died
  hands over nothing and no error, which read as an empty calendar. Occurrences that fail to
  convert fail the calendar only when they are at least as many as the converted ones; fewer are
  a warning ("n Termine nicht auswertbar") and the rest is used. A failing calendar is reported as
  "Kalender N (…)" in `warning` (or in `error` when nothing at all was read), and its events from
  the previous cache are carried forward (with `_join_path: "cache"`) — matched by
  `calendar_uid`, since a healthy namesake's deleted meeting must not come back (entries from
  before 1.2.0 have only the name), and only those that end inside the window — so a one-minute
  hiccup neither empties the agenda nor makes Service.qml withdraw a queued alert as "gone from
  the cache".
- `STATUS:CANCELLED` occurrences are dropped (`get_status()` on eds, the `STATUS` property on
  ics) — a backend that still hands them over must not blank the screen for them.
- Join URL, in this order: RFC 7986 `CONFERENCE` property → `X-GOOGLE-CONFERENCE` X-property →
  the first `JOIN_URL_RE` match in `LOCATION`, then in `DESCRIPTION`, that still passes the
  whole-value test after trailing punctuation is trimmed (a bare `https://discord.gg/` names no
  room and must not hide a real link after it). `JOIN_URL_RE` accepts these
  hosts (and their subdomains): `meet.google.com`, `zoom.us`, `zoomgov.com`,
  `teams.microsoft.com`, `teams.live.com`, `webex.com`, `meet.jit.si`, `8x8.vc`, `whereby.com`,
  `gotomeeting.com`, `meet.goto.com`, `gotomeet.me`; for Slack and Discord, which also carry
  plain message and server links, only `app.slack.com/huddle/…`, `discord.com/channels/…`,
  `discordapp.com/channels/…` and `discord.gg/…` count. `Providers.js` must know the same hosts.
  Every path is allow-listed: a `CONFERENCE` / `X-GOOGLE-CONFERENCE` value counts only if the
  whole value matches `JOIN_URL_RE` (`fullmatch`), not merely because it starts with `https://` —
  those properties come from the invite like everything else. The host has to **end** after the
  allow-listed name (a port may follow), so `zoom.us.evil.example` is rejected instead of being
  truncated to `zoom.us`; a URL ends at whitespace, `<>"'`, Markdown `*` and `|`, a backslash and
  zero-width characters, and trailing sentence punctuation (plus `*_~|`) is stripped. Only
  `&lt; &gt; &quot; &#39; &apos; &nbsp; &amp;` are unescaped before matching — `html.unescape()`
  also decodes legacy entities without a semicolon and turned `?pwd=x&region=eu` into `®ion=eu`.
  Do **not** prefer the iCalendar `URL` property (for Google events that is the calendar web
  page, not the room).
  Verified on 2026-09-10 against this account: Google's CalDAV **does** emit
  `X-GOOGLE-CONFERENCE`, and it matched on every event in the window, so the X-property is the
  path that actually carries the Meet link here. The DESCRIPTION regex stays as the fallback for
  accounts or events that lack it, and `--diagnose` reports which path matched (path name only,
  never the URL).
- Declined invitations are **flagged, not dropped**: the account's own `ATTENDEE` `PARTSTAT` becomes
  `declined: true` on the event, so the agenda can strike it through. Whether it may alert is the
  alert side's decision (`skip_declined`, see invariant 5). Only the exact string `DECLINED` sets
  the flag — an empty `PARTSTAT` means "not an attendee" or "no answer recorded", never "declined".
  Verified against real data on 2026-09-10: the account identity resolves from
  `Collection.get_identity()` (1 identity, 1 Google collection root, 2 enabled calendars), and the
  `PARTSTAT` read is correct — over a 65 h window it returned ACCEPTED 7, DECLINED 1, and empty for
  2 occurrences where the user is not in the attendee list at all. Under schema 1 that one declined
  occurrence was dropped from the cache; since schema 2 it is present with `declined: true`.

### backend `ics`

Documented **backstop only** — Google regenerates the private ICS feed only about once a day, so it
can miss a meeting that was moved this morning. Fetch each `ics_urls` entry with `urllib`
(timeout, no redirects to non-https), parse with `icalendar` + `recurring_ical_events`
(both in `extra`, currently not installed → import failure must degrade to `status: "error"`,
not a traceback). Treat the URLs as secrets: never log them, never put them in `error`.

One feed's trouble stays that feed's. Before the expansion — which expands the whole window first
and walks a series from its DTSTART (one `FREQ=SECONDLY` invite costs a minute and gigabytes) —
a series whose rule repeats every second or minute is dropped when it can put more than 512
occurrences into the window, or when the walk from its DTSTART would take more than 200 000
steps; `COUNT`, `UNTIL` and `INTERVAL` all count (`MINUTELY;INTERVAL=1440` is a daily meeting,
and ten minutely occurrences up to an `UNTIL` are ten). A series that can put no occurrence into
the window is dropped silently, a rule without a readable `FREQ` as malformed. Any other
malformed series (RRULE, EXDATE, DTSTART) makes the expansion run again with `skip_bad_series`
instead of making the feed unreadable. These notes about a feed that was read — dropped, skipped
or cut series, a few unparseable entries — go to `warning` and do not make the run fail. A feed
counts as lost, though, when it cannot be read (https only, network, budget, unparseable), when
at least as many of its entries fail to convert as convert, or when broken series were skipped,
nothing came out and the last cache held meetings of that feed in the window. A lost feed keeps
its events from the previous cache as long as another feed was read, matched by its
`calendar_uid` key, so same-named feeds stay apart, a feed removed from `ics_urls` is not kept
alive, and a URL listed twice and read once counts as read; entries written before 1.2.0 have no
key and count by name, and only out of a cache the ics backend wrote. With every feed lost the
run ends in `status: "error"` with the stale list, as before.

### backend `demo`

Pure-python synthetic events, no dependencies, used for testing and for a first install before the
Google account exists.
