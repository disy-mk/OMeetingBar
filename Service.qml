import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Strings.js" as Strings

// The brain of OMeetingBar. Reads the event cache written by
// bin/omeetingbar-fetch, decides on a 1 Hz wall clock when a meeting is close
// enough to blank the screen, and holds a Wayland idle inhibitor across the
// alert window so the session cannot lock into the alert.
Item {
  id: root

  // Injected by omarchy-shell after createObject returns (see
  // services/PluginShellApi.qml), so nothing in Component.onCompleted may
  // touch them. Service plugins get no `settings`, hence the config file below.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // The version of this code; keep it equal to manifest.json's "version".
  // `omarchy plugin update` ends with a plugin rescan, which destroys and
  // recreates this service -- but from the engine's component cache, which Qt
  // 6.11 offers no way to clear (Qt.clearComponentCache does not exist), so the
  // old code runs on until `omarchy restart shell` while root.manifest already
  // names the installed version. Only this constant says which code is running.
  readonly property string codeVersion: "1.5.0"
  // Handed to every fetch. The fetcher is read from disk on every run, so after
  // an update it is already the new code while this service may still be the
  // old one; OMEETINGBAR_SERVICE tells it which service started it (one before
  // 1.1.0 sets nothing). OMEETINGBAR_LANG is the UI language this service
  // resolved, so the fetcher's warnings speak the bar's language even when the
  // config cannot be read and the locale variables would say otherwise. A
  // property rather than an inline literal only because qmllint types the
  // literal as QVariantMap against Process.environment's QVariantHash;
  // Quickshell takes either.
  readonly property var fetchEnvironment: ({ OMEETINGBAR_SERVICE: root.codeVersion, OMEETINGBAR_LANG: root.lang })

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property bool runtimeReady: runtimeDir !== ""
  readonly property string configPath: home + "/.config/omarchy/omeetingbar.json"
  readonly property string cacheDir: runtimeDir + "/omeetingbar"
  readonly property string cachePath: cacheDir + "/events.json"
  readonly property string statePath: cacheDir + "/state.json"
  readonly property string fetcherPath: String(Qt.resolvedUrl("bin/omeetingbar-fetch")).replace(/^file:\/\//, "")
  readonly property string joinPath: String(Qt.resolvedUrl("bin/omeetingbar-join")).replace(/^file:\/\//, "")
  readonly property string notifyPath: String(Qt.resolvedUrl("bin/omeetingbar-notify")).replace(/^file:\/\//, "")

  readonly property int stateRetentionSeconds: 43200
  readonly property int pruneIntervalSeconds: 3600
  readonly property int clockJumpMs: 15000
  readonly property int lockProbeIntervalSeconds: 2
  readonly property int lockProbeTimeoutSeconds: 5
  // A lock answer older than this is not trusted to decide whether the alert
  // can reach the screen: summoning under the lock would mark an alert shown
  // that is in fact hidden below the lock surface.
  readonly property int lockStaleSeconds: 4
  readonly property int saveRetrySeconds: 2
  readonly property int maxSaveAttempts: 10
  // A hung fetcher must never stop the refresh loop: reap it after 45 s,
  // escalate to SIGKILL if it survives that, and let the next interval retry.
  readonly property int fetchTimeoutSeconds: 45
  readonly property int fetchKillTimeoutSeconds: 60
  // The same for the notify helper, which ends itself after 30 s (SIGALRM):
  // a helper that hangs anyway must not hold every later toast back.
  readonly property int notifyTimeoutSeconds: 40
  readonly property int notifyKillTimeoutSeconds: 50
  // Spacing and hard cap for re-summoning an alert that was queued but never
  // confirmed on screen. The cap is what keeps a re-summon from looping.
  readonly property int resummonIntervalSeconds: 5
  readonly property int maxSummonAttempts: 6
  // Calendar data is third-party input. These bound what one hostile invite,
  // or a runaway recurrence rule, can make the shell do.
  readonly property int maxEvents: 512
  readonly property int maxUrlChars: 2048
  readonly property int maxQueueLength: 8
  readonly property int maxFiresPerTick: 8
  // Meetings due together beyond this share one summary toast instead of each
  // sending a critical, never-expiring one. "Together" is a burst: the ticks
  // whose fire loop hit maxFiresPerTick, and the tick that ends them.
  readonly property int maxToastsPerBurst: 3
  // A zero-length occurrence is over the second it starts (invariant 1), so
  // with alert_lead_seconds 0 no tick could find it both due and not over: it
  // is alerted at least this long ahead.
  readonly property int zeroLengthMinLeadSeconds: 5
  // Once an alert has been on screen this long, the overlay's own inhibitor
  // (Alert.qml, at most 180 s) holds the session, and the service's lets go.
  readonly property int inhibitHandoverSeconds: 5
  // pw-play runs under `timeout`: a player that stalls (a sink that vanished
  // under the lock) would otherwise mute every later alert until a restart.
  readonly property int soundCapSeconds: 60
  // The expiry the "meeting ended" replacement toast asks for. Omarchy takes it
  // as a request and enforces its own minimum for low urgency
  // (lowPopupDuration, 5 s), so the replacement stays at least that long.
  readonly property int toastReplaceExpireMs: 1500
  // The host reports an overlay "open" from the moment a summon is accepted,
  // before Alert.qml has loaded. Its witness only counts once a failed load
  // would have had time to clear that state again; the overlay's own callback
  // (overlayShown) is the primary witness and needs no delay.
  readonly property int confirmGraceSeconds: 2
  // After a clock jump the cache predates the sleep; firing waits at most this
  // long for the forced fetch so a meeting cancelled while suspended stays
  // silent. That fetch is refresh-due after any longer sleep and may spend up
  // to 25 s in refresh_sync (the fetcher's cutoff) before it writes the cache.
  readonly property int fireHoldSeconds: 30

  // Only the keys this service acts on; the rest of omeetingbar.json belongs to
  // bin/omeetingbar-fetch and to Widget.qml, which read the same file themselves.
  readonly property var configDefaults: ({
    fetch_interval_seconds: 60,
    alert_lead_seconds: 60,
    auto_dismiss_seconds: 90,
    // 600, not 300: omarchy blanks at 150 s and locks at 300 s of idle, so a
    // 300 s lead cannot cancel an idle cycle that has already started. The
    // residual gap (idle already running when the inhibitor arrives) is
    // covered by the deferred-until-unlock path below, not by this number.
    inhibit_lead_seconds: 600,
    grace_seconds: 300,
    sound: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga",
    // "auto" follows the session locale (de* → German, else English); "de" or
    // "en" pins it. Read by Widget.qml and bin/omeetingbar-fetch as well.
    language: "auto",
    notify: true,
    // Off, a meeting's toast says "Termin"/"Meeting" and the time instead of
    // title and location. This plugin's own processes never carry that text,
    // but Omarchy's notification daemon passes each toast's summary and body
    // to a short-lived bash job as an argument (readable in
    // /proc/<pid>/cmdline) when it saves the toast, and a closed toast stays
    // in its history.
    notify_details: true,
    wake_display: true,
    // On (the default) a declined meeting never blanks the screen; it stays in
    // the agenda, struck through. Off, it is treated like any other meeting.
    skip_declined: true,
    // The two states the whole plugin colour-codes: a meeting that has started
    // and one that has not. Both the bar entry and the fullscreen alert use
    // these, so the colour means the same thing wherever it shows up.
    colors: ({ running: "#FF9500", upcoming: "#00BEFF" })
  })

  property var config: ({})
  property bool configLoaded: false
  property bool configValid: true
  // The text of the config in force, to tell an edit from a save that changed
  // nothing; and an edit that still waits for its fetch (see tick).
  property string appliedConfigText: ""
  property bool configRefetchPending: false
  property int configEditAtSec: 0
  // How long an edit holds firing at most while its fetch cannot start yet:
  // an older fetch still running is killed by the watchdog at 60 s.
  readonly property int configHoldSeconds: 75

  // At most 900 s, the backoff's own ceiling below: anything longer was cut
  // to 900 there anyway, and `status` should report the interval in effect.
  readonly property int fetchIntervalSeconds: intConfig("fetch_interval_seconds", 5, 900)
  // A backend that cannot work at all — eds before the packages are installed —
  // must not respawn python every interval for ever. Back off to at most 15 min
  // while it keeps failing; a single success drops straight back to normal.
  readonly property int effectiveFetchIntervalSeconds: Math.min(
    root.fetchIntervalSeconds * Math.pow(2, Math.min(root.fetchFailStreak, 4)), 900)
  readonly property int alertLeadSeconds: intConfig("alert_lead_seconds", 0, 3600)
  // The longest lead any entry gets (see leadFor), where the start-ordered
  // scans may stop.
  readonly property int maxLeadSeconds: Math.max(root.alertLeadSeconds, root.zeroLengthMinLeadSeconds)
  // At most 600 s: Alert.qml ends every alert then (hardDismissSeconds), and
  // `status` should report the value in effect.
  readonly property int autoDismissSeconds: intConfig("auto_dismiss_seconds", 0, 600)
  readonly property int inhibitLeadSeconds: intConfig("inhibit_lead_seconds", 0, 7200)
  readonly property int graceSeconds: intConfig("grace_seconds", 0, 3600)
  readonly property string soundPath: soundPathOf(configValue("sound"))
  readonly property string lang: Strings.pick(stringConfig("language"), Qt.locale().name)
  readonly property string runningColor: colorConfig("running", "#FF9500")
  readonly property string upcomingColor: colorConfig("upcoming", "#00BEFF")
  readonly property bool notifyEnabled: boolConfig("notify")
  readonly property bool notifyDetails: boolConfig("notify_details")
  readonly property bool wakeDisplayEnabled: boolConfig("wake_display")
  readonly property bool skipDeclined: boolConfig("skip_declined")

  property var events: []
  property bool cacheLoaded: false
  // unknown | missing | invalid | error | ok
  property string cacheStatus: "unknown"
  property string cacheError: ""
  // Degraded but usable: a non-empty warning on a status-"ok" cache has to
  // reach the user, while `error` stays reserved for status "error".
  property string cacheWarning: ""
  property string cacheBackend: ""
  property bool cacheStale: false
  property int cacheGeneratedAt: 0
  property int cacheRefreshedAt: 0

  // Three facts per event id, all persisted:
  //   notified — notification and sound are done, never repeat them
  //   shown    — the fullscreen overlay was confirmed on screen by the host
  //   failed   — it never got there inside its window; do not retry it
  // An id that is notified but not shown is re-summoned while it is still
  // inside its grace window, which is what makes a hot reload, a shell
  // restart or a locked session survivable.
  property var alertState: ({})
  property bool stateLoaded: false
  property bool stateDirty: false
  property int saveRetryAtSec: 0
  property int saveAttempts: 0
  property int lastPruneAtSec: 0

  // FIFO of alerts that still have to reach the screen. A single slot used to
  // collapse two overlapping meetings into one lost alert, so the head owns
  // the overlay and the rest wait for it to close. Persisted with its payload,
  // because a re-mount must not lose the tail.
  property var alertQueue: []

  // Meeting notifications this service put on screen, as { id, end, nid,
  // sent }: nid is the notification id the helper reported (0 until then),
  // sent the send time in ms. They are critical, so they never expire on their
  // own; each one is taken down once its meeting is over. Persisted, because
  // the toasts outlive a shell restart and so must the list.
  property var openToasts: []
  // Notifications go out one at a time through bin/omeetingbar-notify, which
  // reads the content from stdin and answers with the notification id. The
  // queue holds { payload, toastId, replace }: toastId names the openToasts
  // entry the job is for, replace says whether it takes that toast down.
  property var notifyQueue: []
  property var notifyCurrent: null
  property int notifyStartedAtSec: 0
  // How far checkNotifyWatchdog went with the running helper: 0 not at all,
  // 1 terminated, 2 killed.
  property int notifyReapStage: 0
  // The toast budget of the burst in progress (see maxToastsPerBurst) and the
  // meetings past it, which share one summary toast once the burst ends.
  property int burstToasts: 0
  property var burstOverflow: []
  property int fireHoldUntilSec: 0
  // Set by a clock jump until a fetch has started after it: the fetch that was
  // running across a suspend is refused as a re-run, reaped by the watchdog,
  // and must not lift the fire hold on its way out.
  property bool jumpRefetchPending: false

  property int nowSec: 0
  property real lastTickMs: 0
  property bool armed: false
  property bool inhibitActive: false
  property bool sessionLocked: false
  property bool soundAvailable: false
  property string probedSoundPath: ""
  // Whose alarm is playing (an event id, "test"), and whether stopSound asked
  // it to end, which is then no failure to log.
  property string soundOwner: ""
  property bool soundStopRequested: false
  // Why the head of the queue is not on screen right now:
  // "" (nothing pending) | refreshing (clock-jump or config-edit hold) | locked | lock-unknown
  // | waiting | summon-failed.
  property string deferredReason: ""
  property int lastLockProbeSec: 0
  // When the oldest unanswered lock probe was asked for; 0 when none is. Not
  // lastLockProbeSec: a probe that fails to start emits no `exited`, and
  // probeLock asks again every 2 s, which would push a timeout measured from
  // the last request out for ever.
  property int lockProbePendingSinceSec: 0
  // Set by a clock jump while a probe runs: its answer may describe the
  // session before the sleep and is not taken; the next probe's is.
  property bool lockProbeStale: false
  property int lockKnownAtSec: 0
  // Whether the last lock answer came from the probe itself ("true"/"false"
  // on a clean exit) rather than from giving up on it. Only a sure "unlocked"
  // may wake the display: under the lock a wake lights the panels for good.
  property bool lockAnswerSure: false
  property int lastFetchAtSec: 0
  property int lastFetchStartedAtSec: 0
  property int lastFetchExitCode: -1
  property string lastFetchReason: ""
  property string lastFetchError: ""
  // never | running | ok | failed | timeout
  property string lastFetchOutcome: "never"
  property int fetchFailStreak: 0
  // Repeated identical cache/fetch lines carry no information — the counters in
  // `omeetingbar status` do. Without this a permanently failing backend writes two
  // journal lines every minute for ever.
  property string lastCacheLogged: ""
  property string lastFetchLogged: ""
  property int lastFetchDurationSeconds: -1
  property int fetchTimeoutCount: 0
  property bool fetchKilled: false
  property bool fetchKillSent: false
  property string logLine: ""
  property string logAt: ""
  // Last detail logged per state name, so a repeating fetch cycle logs nothing
  // while a genuine change still gets its one line.
  property var logStates: ({})

  readonly property string statusMessage: {
    if (!root.runtimeReady) return Strings.t(root.lang, "statusRuntimeMissing")
    // After a valid read, a broken file keeps those values (applyConfig).
    if (!root.configValid)
      return Strings.t(root.lang, root.appliedConfigText !== "" ? "statusConfigKept" : "statusConfigUnreadable")
    if (root.cacheStatus === "unknown") return Strings.t(root.lang, "statusCacheReading")
    if (root.cacheStatus === "missing") return Strings.t(root.lang, "statusCacheMissing")
    if (root.cacheStatus === "invalid") return Strings.t(root.lang, "statusCacheUnreadable")
    if (root.cacheStatus === "error")
      return root.cacheError !== "" ? root.cacheError : Strings.t(root.lang, "statusFetchFailed")
    // A warning on an otherwise usable cache means "usable but degraded" and
    // must be visible, so it outranks the everyday messages below.
    if (root.cacheWarning !== "") return Strings.t(root.lang, "limited", root.cacheWarning)
    if (root.events.length === 0) return Strings.t(root.lang, "statusNoneInWindow")
    return Strings.t(root.lang, "statusReady")
  }

  function pluginId() {
    return root.manifest && root.manifest.id ? String(root.manifest.id) : ""
  }

  function logState(event, detail) {
    var name = String(event)
    var text = detail === undefined || detail === null ? "" : String(detail)
    if (root.logStates[name] === text) return
    var next = ({})
    for (var key in root.logStates) next[key] = root.logStates[key]
    next[name] = text
    root.logStates = next
    root.logLine = name + (text === "" ? "" : ": " + text)
    root.logAt = new Date().toISOString()
    console.log("omeetingbar " + root.logAt + " " + root.logLine)
  }

  function configValue(key) {
    var value = root.config ? root.config[key] : undefined
    return value === undefined || value === null ? root.configDefaults[key] : value
  }

  // The plugin's one rule for an integer setting, shared with the fetcher's
  // load_config and Widget.numberOption (docs/SPEC.md, "Configuration"): a JSON
  // number, or a string holding a decimal number; rounded half up (Math.round),
  // then clamped. Number()'s own leniency is not the rule -- "" would be 0, true
  // 1 and [5] 5 -- so those keep the default, as the fetcher reports them.
  function numberOf(value) {
    if (typeof value === "number") return value
    if (typeof value === "string" && /^\s*-?\d+(\.\d+)?\s*$/.test(value)) return Number(value)
    return NaN
  }

  function intConfig(key, min, max) {
    var n = numberOf(configValue(key))
    if (!isFinite(n)) n = Number(root.configDefaults[key])
    return Math.max(min, Math.min(max, Math.round(n)))
  }

  // Style.boolToken is the one boolean parser in this plugin; Widget.qml and
  // the fetcher read the same keys by it, so a "yes"/"1"/"on" in
  // omeetingbar.json cannot make the bar and the alert path disagree. An
  // unrecognised value -- an object or a list included, which boolToken would
  // read through String() -- keeps the default.
  function boolConfig(key) {
    var value = configValue(key)
    var fallback = root.configDefaults[key] === true
    if (value !== null && typeof value === "object") return fallback
    return Style.boolToken(value, fallback)
  }

  // A string setting is a string: String() would read ["de"] as "de", which
  // the fetcher reports as invalid.
  function stringConfig(key) {
    var value = configValue(key)
    return typeof value === "string" ? value : ""
  }

  // `sound` is a path to an audio file: "~/…" is expanded, surrounding spaces
  // are dropped, and a boolean -- false, "off", "no", "0" -- turns the alarm
  // off, while true keeps the default. null or a missing key is the default,
  // and so is anything else (a number, an object, a list), as the fetcher
  // reports it: read through String() it would be a path to nothing, and the
  // alarm silent.
  function soundPathOf(value) {
    var fallback = String(root.configDefaults.sound)
    if (value !== null && typeof value === "object") return fallback
    var flag = Style.boolToken(value, null)
    if (flag === false) return ""
    if (flag === true || typeof value !== "string") return fallback
    var text = value.trim()
    if (text === "~" || text.indexOf("~/") === 0) text = root.home + text.slice(1)
    return text
  }

  // Only a string holding #rrggbb is accepted: a typo must fall back to the
  // documented default rather than reach QML as an invalid colour, which
  // paints black.
  function colorConfig(key, fallback) {
    var group = configValue("colors")
    var value = Util.isPlainObject(group) ? group[key] : undefined
    if (typeof value !== "string") return fallback
    var text = value.trim()
    return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback
  }

  // `present` says whether the file exists: missing, it means the defaults.
  // Present but unusable -- empty (an editor between truncate and write), not
  // JSON, not an object, unreadable -- the last valid config stays in force
  // and only configValid drops: a trailing comma must not switch the toasts,
  // the sound and the display wake back on. Before any valid read there is no
  // last config, and the defaults apply (a broken file at startup).
  function applyConfig(raw, present) {
    var text = String(raw || "").trim()
    var parsed = null
    if (text !== "") {
      try {
        parsed = JSON.parse(text)
      } catch (e) {
        parsed = null
      }
    }
    var valid = Util.isPlainObject(parsed)
    var firstRead = !root.configLoaded
    if (valid) {
      // A real edit after the first read also starts a fetch, so a new
      // exclusion applies before the next alert fires, not up to
      // fetch_interval_seconds later (see tick). So does fixing a broken
      // file, even back to the text in force: the fetches in between read the
      // broken one, and their warning would stay until the next interval.
      if (!firstRead && (text !== root.appliedConfigText || !root.configValid)) {
        root.configRefetchPending = true
        root.configEditAtSec = Math.floor(Date.now() / 1000)
      }
      root.config = parsed
      root.appliedConfigText = text
    } else if (present !== true) {
      if (!firstRead && root.appliedConfigText !== "") {
        root.configRefetchPending = true
        root.configEditAtSec = Math.floor(Date.now() / 1000)
      }
      root.config = ({})
      root.appliedConfigText = ""
    } else if (firstRead) {
      root.config = ({})
    }
    root.configValid = valid || present !== true
    root.configLoaded = true
    // Editing the config is the moment to retry: switching backend to eds once
    // the packages are there must not wait out a 15-minute backoff.
    root.fetchFailStreak = 0
    root.lastFetchLogged = ""
    if (!root.configValid) logState("config-invalid", root.configPath + (firstRead ? "" : " (last valid kept)"))
    else logState("config-loaded", "lead=" + root.alertLeadSeconds + "s grace=" + root.graceSeconds + "s")
    probeSound()
  }

  // Unix seconds only: the cache carries no timezone strings, so anything that
  // is not an integer-ish number is a broken record rather than a date format.
  function epochOf(value) {
    if (typeof value === "number") return isFinite(value) ? Math.round(value) : NaN
    var text = String(value === undefined || value === null ? "" : value).trim()
    if (!/^-?\d+(\.\d+)?$/.test(text)) return NaN
    return Math.round(Number(text))
  }

  function normalizeEvents(list) {
    var out = []
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!entry || typeof entry !== "object") continue
      var id = String(entry.id === undefined || entry.id === null ? "" : entry.id)
      var start = epochOf(entry.start)
      if (id === "" || !isFinite(start)) continue
      var end = epochOf(entry.end)
      var url = String(entry.url === undefined || entry.url === null ? "" : entry.url)
      // Only https is ever handed to the browser, and every file drops the
      // rest in its own cache parser. No backslash: browsers read it as "/",
      // so it could hide the real host from Providers.js. The length cap is a
      // bound on hostile input like maxEvents; no URL travels in a
      // notification, whose click action carries the event id instead.
      if (url.length > root.maxUrlChars || !/^https:\/\/[^\s\\]+$/i.test(url)) url = ""
      out.push({
        id: id,
        title: String(entry.title === undefined || entry.title === null ? "" : entry.title),
        start: start,
        // Whatever the fetcher wrote: no consumer invents a duration, so a
        // missing or broken end falls back to the start, never to start+30min.
        end: isFinite(end) && end > start ? end : start,
        allDay: entry.all_day === true,
        // Flagged, not dropped, since schema 2: the popup lists a declined
        // meeting struck through, and isAlertable() alone decides whether it
        // may still reach the screen.
        declined: entry.declined === true,
        url: url,
        calendar: String(entry.calendar === undefined || entry.calendar === null ? "" : entry.calendar),
        location: String(entry.location === undefined || entry.location === null ? "" : entry.location)
      })
    }
    // Ties broken by id: Qt's JS sort is not stable, and the cap below has to
    // pick the same entries as the fetcher's.
    out.sort(function(a, b) {
      if (a.start !== b.start) return a.start - b.start
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    })
    // The second line behind the fetcher's own cap, by the same rule
    // (cap_events) with the service's own grace_seconds: the cache starts at
    // local midnight and keeps finished meetings, so cutting earliest-first
    // let a dense morning push every meeting still ahead out -- and with it
    // the alert about to fire.
    if (out.length > root.maxEvents) {
      logState("events-capped", "count=" + out.length)
      out = capByRelevance(out, Math.floor(Date.now() / 1000), root.graceSeconds, root.maxEvents)
    }
    return out
  }

  // Kept first: what has not started more than `grace` ago, earliest first,
  // up to three quarters of `limit`; then what is still running; then what
  // finished most recently; then the rest of what lies ahead. Returned in
  // start order.
  function capByRelevance(list, nowSec, grace, limit) {
    var ahead = []
    var behind = []
    for (var i = 0; i < list.length; i++) {
      if (list[i].start >= nowSec - grace) ahead.push(list[i])
      else behind.push(list[i])
    }
    function lastSec(entry) { return Math.max(entry.end, entry.start) }
    behind.sort(function(a, b) {
      var aOver = lastSec(a) <= nowSec
      var bOver = lastSec(b) <= nowSec
      if (aOver !== bOver) return aOver ? 1 : -1
      if (lastSec(a) !== lastSec(b)) return lastSec(b) - lastSec(a)
      if (a.start !== b.start) return a.start - b.start
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    })
    var first = limit - Math.floor(limit / 4)
    var kept = ahead.slice(0, first)
    kept = kept.concat(behind.slice(0, limit - kept.length))
    kept = kept.concat(ahead.slice(first, first + limit - kept.length))
    kept.sort(function(a, b) {
      if (a.start !== b.start) return a.start - b.start
      return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
    })
    return kept
  }

  function logCache(message) {
    if (message === root.lastCacheLogged) return
    root.lastCacheLogged = message
    logState("cache", message)
  }

  // `restart_notice` repeats the text `warning` starts with when the service
  // that ran the fetch was outdated (see codeVersion), and `restart_shell_pid`
  // names the shell process that ran it. The notice is meant for that shell:
  // read in another one -- `omarchy restart shell` has happened since -- it is
  // cut and the rest of the warning kept. A rescan or a rebuilt bar keeps the
  // shell and so the notice; without a usable pid it is kept too. Widget.qml
  // reads the cache by the same rule.
  function cacheWarningOf(parsed) {
    var warning = String(parsed.warning === undefined || parsed.warning === null ? "" : parsed.warning)
    var notice = typeof parsed.restart_notice === "string" ? parsed.restart_notice : ""
    var pid = parsed.restart_shell_pid
    if (notice === "" || warning.indexOf(notice) !== 0
      || typeof pid !== "number" || !(pid > 0) || pid === Quickshell.processId)
      return warning
    return warning.slice(notice.length).trim()
  }

  function applyCache(raw) {
    var text = String(raw || "").trim()
    root.cacheLoaded = true

    if (text === "") {
      root.events = []
      root.cacheStatus = "missing"
      root.cacheError = ""
      root.cacheWarning = ""
      root.cacheBackend = ""
      root.cacheStale = false
      root.cacheGeneratedAt = 0
      root.cacheRefreshedAt = 0
      logCache("missing")
      return
    }

    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      parsed = null
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      root.events = []
      root.cacheStatus = "invalid"
      root.cacheError = ""
      root.cacheWarning = ""
      logCache("invalid")
      return
    }

    var status = String(parsed.status === undefined ? "" : parsed.status) === "ok" ? "ok" : "error"
    root.cacheBackend = String(parsed.backend === undefined ? "" : parsed.backend)
    // `error` belongs to status "error" only; `warning` is the separate
    // "usable but degraded" channel and is read whatever the status is.
    root.cacheError = status === "error"
      ? String(parsed.error === undefined || parsed.error === null ? "" : parsed.error) : ""
    root.cacheWarning = cacheWarningOf(parsed)
    root.cacheStale = parsed.stale === true
    var generated = epochOf(parsed.generated_at)
    var refreshed = epochOf(parsed.refreshed_at)
    root.cacheGeneratedAt = isFinite(generated) ? generated : 0
    root.cacheRefreshedAt = isFinite(refreshed) ? refreshed : 0
    root.events = normalizeEvents(parsed.events)
    root.cacheStatus = status
    dropCancelledAlerts()
    logCache(status + " events=" + root.events.length
      + (root.cacheStale ? " stale" : "") + (root.cacheWarning !== "" ? " warning" : ""))
  }

  function eventIndexOf(id) {
    for (var i = 0; i < root.events.length; i++) if (root.events[i].id === id) return i
    return -1
  }

  // A meeting the next fetch no longer knows (cancelled, or moved out of the
  // window) — or one it now reports as declined — must not still blank the
  // screen, nor keep a toast with a live join link. Only a healthy, fresh
  // cache is allowed to say that: an error or stale cache is missing events
  // for its own reasons and would withdraw alerts that are still due.
  function dropCancelledAlerts() {
    if (root.cacheStatus !== "ok" || root.cacheStale) return
    var atSec = Math.floor(Date.now() / 1000)
    var changed = false
    for (var i = root.alertQueue.length - 1; i >= 0; i--) {
      var pending = root.alertQueue[i]
      if (pending.shownAt > 0) continue
      // "Still in the cache" stopped being enough at schema 2: a declined or
      // finished meeting is retained for the agenda, so the presence test that
      // makes declining a queued meeting withdraw its alert has to be "present
      // AND still alertable" or it silently stops working.
      var index = eventIndexOf(pending.id)
      if (index !== -1 && isAlertable(root.events[index], atSec)) continue
      setAlertState(pending.id, { failed: atSec })
      if (i === 0) cancelPendingSummon(pending)
      dequeueAlert(i)
      withdrawToast(pending.id, atSec)
      changed = true
      logState("alert-withdrawn", "id=" + pending.id + (index === -1 ? " gone from cache" : " no longer alertable"))
    }
    // A toast outlives its alert: the meeting can be cancelled or declined
    // after the alert was shown and closed, and the toast would keep its join
    // link until the end. Not isAlertable() here, which would also take down
    // the toast of a long meeting past its grace window. Summary toasts carry
    // no link and stay.
    var toasts = root.openToasts.slice()
    for (var t = 0; t < toasts.length; t++) {
      var toast = toasts[t]
      if (/^summary-/.test(toast.id) || atSec >= toast.end) continue
      var live = eventIndexOf(toast.id)
      var off = live === -1 || (root.events[live].declined === true && root.skipDeclined)
      if (off && withdrawToast(toast.id, atSec)) changed = true
    }
    if (changed) saveState()
  }

  function tsOf(value) {
    var at = epochOf(value)
    return isFinite(at) && at > 0 ? at : 0
  }

  function stateOf(id) {
    var entry = root.alertState[String(id)]
    return entry && typeof entry === "object" ? entry : null
  }

  function isNotified(id) {
    var entry = stateOf(id)
    return entry !== null && entry.notified > 0
  }

  function isShown(id) {
    var entry = stateOf(id)
    return entry !== null && entry.shown > 0
  }

  function isFailed(id) {
    var entry = stateOf(id)
    return entry !== null && entry.failed > 0
  }

  // The three timestamps are only ever set, never cleared, so patching one
  // cannot lose another.
  function setAlertState(id, patch) {
    var key = String(id)
    var next = ({})
    for (var known in root.alertState) next[known] = root.alertState[known]
    var prev = next[key]
    var merged = {
      notified: prev ? prev.notified : 0,
      shown: prev ? prev.shown : 0,
      failed: prev ? prev.failed : 0
    }
    for (var field in patch) merged[field] = patch[field]
    next[key] = merged
    root.alertState = next
  }

  function queueIndexOf(id) {
    for (var i = 0; i < root.alertQueue.length; i++) if (root.alertQueue[i].id === id) return i
    return -1
  }

  function enqueueAlert(entry, atSec) {
    if (queueIndexOf(entry.id) !== -1) return false
    var next = root.alertQueue.slice()
    next.push({
      id: entry.id,
      title: entry.title,
      start: entry.start,
      end: entry.end,
      allDay: entry.allDay === true,
      url: entry.url,
      calendar: entry.calendar,
      location: entry.location,
      // The alert is pointless once the grace window is over, so every queue
      // entry carries its own deadline.
      untilSec: entry.start + root.graceSeconds,
      notifiedAt: atSec,
      summonedAtSec: 0,
      attempts: 0,
      shownAt: 0
    })
    root.alertQueue = next
    return true
  }

  function dequeueAlert(index) {
    if (index < 0 || index >= root.alertQueue.length) return
    var next = root.alertQueue.slice()
    next.splice(index, 1)
    root.alertQueue = next
  }

  function normalizeQueueEntry(raw, atSec) {
    if (!raw || typeof raw !== "object") return null
    var id = String(raw.id === undefined || raw.id === null ? "" : raw.id)
    var start = epochOf(raw.start)
    if (id === "" || !isFinite(start)) return null
    var end = epochOf(raw.end)
    var until = epochOf(raw.untilSec)
    var url = String(raw.url === undefined || raw.url === null ? "" : raw.url)
    if (!/^https:\/\/[^\s]+$/i.test(url)) url = ""
    return {
      id: id,
      title: String(raw.title === undefined || raw.title === null ? "" : raw.title),
      start: start,
      end: isFinite(end) && end > start ? end : start,
      allDay: raw.allDay === true,
      url: url,
      calendar: String(raw.calendar === undefined || raw.calendar === null ? "" : raw.calendar),
      location: String(raw.location === undefined || raw.location === null ? "" : raw.location),
      untilSec: isFinite(until) ? until : start + root.graceSeconds,
      notifiedAt: tsOf(raw.notifiedAt) > 0 ? tsOf(raw.notifiedAt) : atSec,
      // Never persisted: a re-mount has summoned nothing yet, so the head is
      // summoned again — that is the whole point of keeping the queue.
      summonedAtSec: 0,
      attempts: 0,
      shownAt: 0
    }
  }

  // state.json, schema 2:
  //   { "schema": 2,
  //     "events": { "<id>": { "notified": ts, "shown": ts, "failed": ts } },
  //     "queue":  [ { <alert payload>, "untilSec": ts, "notifiedAt": ts } ],
  //     "toasts": [ { "id": id, "end": ts, "nid": n, "sent": ms } ],
  //     "toastsShellPid": pid,       // the shell process the nids belong to
  //     "fired":  { "<id>": ts } }   // schema-1 mirror, written for readers of
  //                                  // the old format, never read back here
  // A schema-1 file only knew "fired". Those ids count as notified AND shown,
  // because the old format cannot say whether the overlay was ever seen and a
  // surprise blanking alert is worse than a missing one for an event that old.
  function loadState(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      parsed = null
    }
    var atSec = Math.floor(Date.now() / 1000)
    var cutoff = atSec - root.stateRetentionSeconds

    var incoming = ({})
    if (parsed && Util.isPlainObject(parsed.events)) {
      for (var id in parsed.events) {
        var record = parsed.events[id]
        if (!record || typeof record !== "object") continue
        incoming[id] = {
          notified: tsOf(record.notified),
          shown: tsOf(record.shown),
          failed: tsOf(record.failed)
        }
      }
    } else if (parsed && Util.isPlainObject(parsed.fired)) {
      for (var legacyId in parsed.fired) {
        var at = tsOf(parsed.fired[legacyId])
        if (at === 0) continue
        incoming[legacyId] = { notified: at, shown: at, failed: 0 }
      }
    }

    // Merged, never replaced: the file is re-read on every hot reload, and this
    // session may already know about an alert the file on disk predates.
    var merged = ({})
    for (var known in root.alertState) merged[known] = root.alertState[known]
    for (var incomingId in incoming) {
      var have = merged[incomingId]
      var want = incoming[incomingId]
      merged[incomingId] = have === undefined ? want : {
        notified: Math.max(have.notified, want.notified),
        shown: Math.max(have.shown, want.shown),
        failed: Math.max(have.failed, want.failed)
      }
    }
    var kept = ({})
    for (var key in merged) {
      var value = merged[key]
      if (Math.max(value.notified, value.shown, value.failed) >= cutoff) kept[key] = value
    }
    root.alertState = kept

    // The pending queue outlives the process too: without it a hot reload 30 s
    // before a meeting would drop the alert on the floor.
    var queue = root.alertQueue.slice()
    if (parsed && Array.isArray(parsed.queue)) {
      for (var q = 0; q < parsed.queue.length; q++) {
        var entry = normalizeQueueEntry(parsed.queue[q], atSec)
        if (entry === null) continue
        var already = false
        for (var s = 0; s < queue.length; s++) if (queue[s].id === entry.id) already = true
        if (already) continue
        queue.push(entry)
      }
    }
    var restored = []
    for (var r = 0; r < queue.length; r++) {
      var candidate = queue[r]
      if (isShown(candidate.id) || isFailed(candidate.id)) continue
      if (atSec > candidate.untilSec) continue
      restored.push(candidate)
    }
    // Notification order is the alert order; start time breaks a tie.
    restored.sort(function(a, b) {
      return a.notifiedAt === b.notifiedAt ? a.start - b.start : a.notifiedAt - b.notifiedAt
    })
    root.alertQueue = restored

    var toasts = root.openToasts.slice()
    if (parsed && Array.isArray(parsed.toasts)) {
      // Notification ids belong to one daemon generation: Omarchy's
      // notifications plugin restarts with the shell and hands out ids from 1
      // again, so an id recorded under another shell process would now name a
      // stranger's toast. Those entries keep their end (the join script still
      // checks it) but lose the id, and are forgotten instead of replaced.
      // Files written before 1.3.0 also carry the headline; it is not read.
      var sameShell = tsOf(parsed.toastsShellPid) === Quickshell.processId
      for (var t = 0; t < parsed.toasts.length; t++) {
        var toast = parsed.toasts[t]
        if (!toast || typeof toast !== "object") continue
        var toastId = toast.id === undefined || toast.id === null ? "" : String(toast.id)
        var toastEndSec = tsOf(toast.end)
        if (toastId === "" || toastEndSec === 0) continue
        var seen = false
        for (var k = 0; k < toasts.length; k++) if (toasts[k].id === toastId) seen = true
        if (seen) continue
        toasts.push({ id: toastId, end: toastEndSec,
                      nid: sameShell ? tsOf(toast.nid) : 0,
                      sent: sameShell ? tsOf(toast.sent) : 0 })
      }
    }
    root.openToasts = toasts

    root.stateLoaded = true
    if (restored.length > 0) logState("queue-restored", "pending=" + restored.length)
  }

  // The queue carries the alert payload (title, url, location) because the
  // cache may no longer contain the event by the time the alert is shown. Same
  // tmpfs directory, same 0600, same "gone after a reboot" as the cache itself.
  function saveState() {
    root.stateDirty = true
    root.saveAttempts = 0
    root.saveRetryAtSec = Math.floor(Date.now() / 1000) + root.saveRetrySeconds
    if (!root.runtimeReady) return
    var legacy = ({})
    for (var id in root.alertState) legacy[id] = root.alertState[id].notified
    var queue = []
    for (var i = 0; i < root.alertQueue.length; i++) {
      var pending = root.alertQueue[i]
      queue.push({
        id: pending.id,
        title: pending.title,
        start: pending.start,
        end: pending.end,
        allDay: pending.allDay,
        url: pending.url,
        calendar: pending.calendar,
        location: pending.location,
        untilSec: pending.untilSec,
        notifiedAt: pending.notifiedAt
      })
    }
    stateFile.setText(JSON.stringify({
      schema: 2,
      events: root.alertState,
      queue: queue,
      toasts: root.openToasts,
      toastsShellPid: Quickshell.processId,
      fired: legacy
    }, null, 2) + "\n")
  }

  function retrySaveState() {
    var attempts = root.saveAttempts + 1
    ensureCacheDir()
    saveState()
    root.saveAttempts = attempts
  }

  function pruneState(atSec) {
    root.lastPruneAtSec = atSec
    var cutoff = atSec - root.stateRetentionSeconds
    var kept = ({})
    var removed = 0
    for (var id in root.alertState) {
      var entry = root.alertState[id]
      // Newest of the three, so an entry is only forgotten once every fact
      // about it is old enough to be irrelevant.
      if (Math.max(entry.notified, entry.shown, entry.failed) >= cutoff) kept[id] = entry
      else removed += 1
    }
    if (removed === 0) return
    root.alertState = kept
    saveState()
  }

  function ensureCacheDir() {
    if (!root.runtimeReady || cacheDirProcess.running) return
    cacheDirProcess.running = true
  }

  // probedSoundPath names the file the running (or last) probe looks at; the
  // silent case leaves it alone, so a probe still running for the old file is
  // told apart when it answers.
  function probeSound() {
    if (root.soundPath === "") {
      root.soundAvailable = false
      return
    }
    if (soundProbe.running) return
    root.probedSoundPath = root.soundPath
    soundProbe.command = ["/usr/bin/test", "-f", root.soundPath]
    soundProbe.running = true
  }

  function runFetch(reason) {
    if (fetchProcess.running) return false
    if (root.fetcherPath === "") return false
    root.lastFetchAtSec = Math.floor(Date.now() / 1000)
    root.lastFetchStartedAtSec = root.lastFetchAtSec
    root.lastFetchReason = String(reason || "")
    root.lastFetchOutcome = "running"
    root.fetchKilled = false
    root.fetchKillSent = false
    fetchProcess.running = true
    // Whatever asked for it, a fetch started now postdates any clock jump,
    // and reads the config as it is now. One that follows an edit holds firing
    // until it lands, like the re-run after a jump (fireHoldActive).
    root.jumpRefetchPending = false
    if (root.configRefetchPending) {
      root.configRefetchPending = false
      root.fireHoldUntilSec = Math.max(root.fireHoldUntilSec, root.lastFetchAtSec + root.fireHoldSeconds)
    }
    return true
  }

  // Without this a fetcher that hangs — EDS on a network that comes and goes —
  // stops every later refresh for good, because runFetch bails while one is
  // running and nothing ever reaped the child.
  function checkFetchWatchdog(atSec) {
    if (!fetchProcess.running || root.lastFetchStartedAtSec <= 0) return
    var ranFor = atSec - root.lastFetchStartedAtSec
    if (ranFor < root.fetchTimeoutSeconds) return
    if (!root.fetchKilled) {
      root.fetchKilled = true
      root.lastFetchOutcome = "timeout"
      root.fetchTimeoutCount += 1
      // Clearing `running` terminates the child, the same reap the first-party
      // tailscale service uses for its own hung polls.
      fetchProcess.running = false
      logState("fetch-timeout", "after=" + ranFor + "s started=" + root.lastFetchStartedAtSec)
      return
    }
    // Once, not once per tick: still there after the terminate, so
    // Process.signal(int) gets the last word.
    if (ranFor >= root.fetchKillTimeoutSeconds && !root.fetchKillSent) {
      root.fetchKillSent = true
      fetchProcess.signal(9)
      logState("fetch-kill", "after=" + ranFor + "s started=" + root.lastFetchStartedAtSec)
    }
  }

  // The notify queue runs one helper at a time, so one that never ends would
  // hold every later toast back for the rest of the session. The helper ends
  // itself after 30 s (SIGALRM); this is the backstop, in two steps like the
  // fetch watchdog. The helper's `exited` then drops the job and moves on.
  function checkNotifyWatchdog(atSec) {
    if (!notifySender.running || root.notifyStartedAtSec <= 0) return
    var ranFor = atSec - root.notifyStartedAtSec
    if (ranFor >= root.notifyTimeoutSeconds && root.notifyReapStage === 0) {
      root.notifyReapStage = 1
      notifySender.running = false
      logState("notify-timeout", "after=" + root.notifyTimeoutSeconds + "s")
    } else if (ranFor >= root.notifyKillTimeoutSeconds && root.notifyReapStage === 1) {
      root.notifyReapStage = 2
      notifySender.signal(9)
      logState("notify-kill", "after=" + root.notifyKillTimeoutSeconds + "s")
    }
  }

  // Invariant 1 over the whole agenda: the earliest event that is not over yet.
  // This is `status.next` and the popup's notion of "next", declined and
  // all-day entries included. The bar label and `preview` speak for the
  // alertable view instead (nextAlertableEvent), so the two can legitimately
  // name different meetings — e.g. a declined 14:00 here, the 15:00 there.
  function nextEvent(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      if (root.events[i].end > atSec) return root.events[i]
    }
    return null
  }

  // The one gate on the alert side (invariant 5). Since schema 2 the cache is
  // the whole agenda: it keeps meetings that are already over and meetings the
  // user declined, because the popup lists them. Everything that can put the
  // fullscreen alert on screen — or hold the idle inhibitor for one — asks this
  // and decides nothing for itself. The forward bound deliberately stays with
  // the callers: the alert leads by alert_lead_seconds and the inhibitor by
  // inhibit_lead_seconds, so there is no single "how early" to put in here.
  function isAlertable(entry, atSec) {
    if (!entry || typeof entry !== "object") return false
    // An all-day event has no meaningful start moment, so it never fires the
    // blanking alert — whatever skip_all_day says, and even though the widget
    // may still show it. Otherwise a whole-day entry blanks every monitor at
    // one minute to midnight.
    if (entry.allDay) return false
    // Over is over (invariant 1), with the same expression the bar, the popup
    // rows and `status.next` use: max(end, start) <= now. A zero-length
    // occurrence (end == start, the invariant-2 fallback for a broken `end`)
    // is therefore over the second it starts — on every surface alike. The
    // grace window below is for meetings with a real length that we missed.
    if (Math.max(entry.end, entry.start) <= atSec) return false
    // Missed by more than the grace window — suspended or locked for too long
    // — is too late to be worth a screen.
    if (atSec - entry.start > root.graceSeconds) return false
    // "No" means no: a declined meeting stays in the agenda, struck through,
    // but never interrupts while skip_declined is on.
    if (entry.declined === true && root.skipDeclined) return false
    return true
  }

  // The next event the alert path would act on. Not a filter on nextEvent():
  // the agenda also holds finished and declined meetings, and neither can ever
  // reach the screen, so `armed` and `omeetingbar preview` ask isAlertable()
  // instead of re-deriving half of the rule here.
  function nextAlertableEvent(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      if (isAlertable(root.events[i], atSec)) return root.events[i]
    }
    return null
  }

  // How far ahead an entry is alerted: alert_lead_seconds, and at least
  // zeroLengthMinLeadSeconds for a zero-length occurrence, which no later
  // tick could still catch.
  function leadFor(entry) {
    return entry.end > entry.start ? root.alertLeadSeconds
      : Math.max(root.alertLeadSeconds, root.zeroLengthMinLeadSeconds)
  }

  function dueEvent(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      var entry = root.events[i]
      // Ascending by start, so once one is beyond the longest lead nothing
      // after it can be due either. Sound even though isAlertable() may
      // reject entries before this one: rejecting them never moves a later
      // start earlier.
      if (entry.start - atSec > root.maxLeadSeconds) return null
      if (entry.start - atSec > leadFor(entry)) continue
      // Every other reason not to fire is in the one predicate: all-day,
      // already over, past the grace window, declined.
      if (!isAlertable(entry, atSec)) continue
      if (isNotified(entry.id)) continue
      return entry
    }
    return null
  }

  function timeRangeText(entry) {
    if (entry.allDay) return Strings.t(root.lang, "allDay")
    var from = Qt.formatDateTime(new Date(entry.start * 1000), "HH:mm")
    if (entry.end <= entry.start) return from
    return from + "–" + Qt.formatDateTime(new Date(entry.end * 1000), "HH:mm")
  }

  // The headline reaches D-Bus as a plain string through bin/omeetingbar-notify
  // (stdin JSON, never argv), so no option parser ever sees it, and the
  // helper's Gio-less fallback sends the content-free `safe` text instead.
  // A meeting without a title is named as the bar and the agenda name it.
  function notificationHeadline(title) {
    var text = String(title || "").trim()
    return text === "" ? Strings.t(root.lang, "untitled") : text
  }

  // Omarchy renders a toast's body as StyledText (the summary is plain text),
  // so a location of "<b>…" from an invite would restyle the toast. The
  // headline needs no escaping.
  function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  // The toast stays up until the meeting ends, so its body says nothing that
  // goes stale -- no "starts in 1 minute" at 14:40, no "now" for a meeting
  // that started four minutes before a resume: the time range, then location
  // or calendar name. Those two come from the invite, so without details the
  // time range is all.
  function notificationBody(entry, details) {
    var parts = [timeRangeText(entry)]
    if (details && entry.location !== "") parts.push(escapeMarkup(entry.location))
    else if (details && entry.calendar !== "") parts.push(escapeMarkup(entry.calendar))
    return parts.join(" · ")
  }

  // When a meeting's toast stops being useful. A meeting without a real end
  // (end <= start) keeps its toast as long as the alert itself stays relevant.
  function toastEnd(entry) {
    return Math.max(entry.end, entry.start + root.graceSeconds)
  }

  // No process of this plugin carries calendar content on its command line:
  // the helper reads this payload from stdin, and the click action carries the
  // event id and the grace window only -- bin/omeetingbar-join looks the URL
  // up in the 0600 cache when clicked, and only until the meeting ends, before
  // its start too (one without a real end until start + grace). Omarchy's daemon does put summary
  // and body on a bash command line when it saves the toast, and keeps closed
  // toasts in its history; notify_details off sends "Termin"/"Meeting" and the
  // time range there instead of title and location. `safe` is the
  // content-free text the helper falls back to without Gio.
  function sendNotification(entry) {
    var details = root.notifyDetails
    var headline = details ? notificationHeadline(entry.title) : Strings.t(root.lang, "meeting")
    var payload = {
      summary: headline,
      body: notificationBody(entry, details),
      glyph: "󰃭",
      urgency: "critical",
      safe: { summary: Strings.t(root.lang, "meeting"), body: timeRangeText(entry) }
    }
    if (entry.url !== "") payload.exec = [root.joinPath, String(entry.id), String(root.graceSeconds)]
    trackToast(entry)
    enqueueNotify(payload, String(entry.id), false)
  }

  // The meetings past a burst's maxToastsPerBurst get one toast for all of
  // them: no join link (the agenda has those), tracked under its own id so it
  // comes down with the last of them.
  function sendSummaryNotification(extra, atSec) {
    var latestEnd = atSec
    for (var i = 0; i < extra.length; i++) latestEnd = Math.max(latestEnd, toastEnd(extra[i]))
    var headline = Strings.t(root.lang, "moreMeetings", extra.length)
    var id = "summary-" + atSec
    trackToast({ id: id, start: atSec, end: latestEnd })
    enqueueNotify({
      summary: headline,
      body: Strings.t(root.lang, "moreMeetingsBody"),
      glyph: "󰃭",
      urgency: "critical",
      safe: { summary: headline, body: "" }
    }, id, false)
  }

  // Every toast this service sends is recorded with the notification id the
  // helper reports (0 until it does) and the time it was sent, so it can be
  // replaced by id once the meeting is over. Omarchy ignores
  // CloseNotification for its popups (measured on 4.x) and dismisses by
  // summary substring only, which would put the title on a command line again
  // -- hence the replacement.
  function trackToast(entry) {
    var id = String(entry.id)
    for (var i = 0; i < root.openToasts.length; i++) if (root.openToasts[i].id === id) return
    root.openToasts = root.openToasts.concat([{ id: id, end: toastEnd(entry), nid: 0, sent: Date.now() }])
    saveState()
  }

  function setToastNid(id, nid) {
    var next = []
    var hit = false
    for (var i = 0; i < root.openToasts.length; i++) {
      var toast = root.openToasts[i]
      if (toast.id === id) {
        next.push({ id: toast.id, end: toast.end, nid: nid, sent: toast.sent })
        hit = true
      } else next.push(toast)
    }
    if (!hit) return
    root.openToasts = next
    saveState()
  }

  // A toast's replacement has run its course -- sent, answered "gone" (the
  // user closed it first), or failed: the entry is done with either way, or a
  // helper that keeps failing would be retried every second.
  function forgetToast(id) {
    var next = root.openToasts.filter(function(toast) { return toast.id !== id })
    if (next.length === root.openToasts.length) return
    root.openToasts = next
    saveState()
  }

  function enqueueNotify(payload, toastId, replace) {
    root.notifyQueue = root.notifyQueue.concat([{ payload: payload, toastId: toastId, replace: replace === true }])
    pumpNotify()
  }

  // Whether a job for this toast is queued or running: its first send
  // (replace false) or its replacement (replace true).
  function notifyPending(toastId, replace) {
    var jobs = root.notifyCurrent !== null ? [root.notifyCurrent].concat(root.notifyQueue) : root.notifyQueue
    for (var i = 0; i < jobs.length; i++)
      if (jobs[i].toastId === toastId && jobs[i].replace === replace) return true
    return false
  }

  // The first send of this toast, if it is still waiting in the queue.
  function dropQueuedSend(toastId) {
    var next = root.notifyQueue.filter(function(job) { return job.toastId !== toastId || job.replace })
    if (next.length !== root.notifyQueue.length) root.notifyQueue = next
  }

  function pumpNotify() {
    if (notifySender.running || root.notifyCurrent !== null || root.notifyQueue.length === 0) return
    root.notifyCurrent = root.notifyQueue[0]
    root.notifyQueue = root.notifyQueue.slice(1)
    root.notifyStartedAtSec = Math.floor(Date.now() / 1000)
    root.notifyReapStage = 0
    notifySender.command = ["/usr/bin/python3", root.notifyPath]
    notifySender.running = true
  }

  // Once a meeting is over its toast is replaced, by notification id, with a
  // low-urgency "meeting ended" that Omarchy lets expire after its own 5 s
  // minimum (toastReplaceExpireMs is only the request) -- no title, no IPC
  // argument. The entry stays until that replacement has run: the notify
  // queue lives in memory, and after a remount the next tick sends it again
  // from the state file. A toast without an id is kept while the helper is
  // sending it -- a slow helper answers after the meeting was withdrawn, and
  // the id must land on the entry -- and forgotten otherwise (the helper
  // failed, or the shell restarted since): it still closes by click or right
  // click, and the join script checks the end anyway. A first send still
  // waiting in the queue goes with it: a meeting that is over or off gets no
  // toast at all. Not held back after a start: a remount keeps the shell
  // process, its toasts and their ids, and a shell restart drops the ids
  // (toastsShellPid) before anything could be replaced.
  function clearEndedToasts(atSec) {
    if (root.openToasts.length === 0) return
    var kept = []
    var replaced = 0
    var forgotten = 0
    for (var i = 0; i < root.openToasts.length; i++) {
      var toast = root.openToasts[i]
      if (atSec < toast.end) {
        kept.push(toast)
        continue
      }
      if (toast.nid > 0) {
        kept.push(toast)
        if (notifyPending(toast.id, true)) continue
        enqueueNotify({
          summary: Strings.t(root.lang, "meetingEnded"),
          body: "",
          glyph: "󰃭",
          urgency: "low",
          replaces_id: toast.nid,
          expire_ms: root.toastReplaceExpireMs,
          // Omarchy restores popups after a restart under their old ids, which
          // the next daemon hands out again: the helper counts only popup
          // files from this send on (see bin/omeetingbar-notify).
          sent_ms: toast.sent > 0 ? toast.sent : 0,
          safe: { summary: Strings.t(root.lang, "meetingEnded"), body: "" }
        }, toast.id, true)
        replaced += 1
      } else if (root.notifyCurrent !== null && root.notifyCurrent.toastId === toast.id
        && !root.notifyCurrent.replace) kept.push(toast)
      else {
        dropQueuedSend(toast.id)
        forgotten += 1
      }
    }
    if (replaced === 0 && forgotten === 0) return
    if (forgotten > 0) {
      root.openToasts = kept
      saveState()
    }
    logState("toasts-cleared", "replaced=" + replaced + " forgotten=" + forgotten)
  }

  // A meeting that is off -- cancelled, or declined -- must not leave a toast
  // with a live join link behind, whether its alert was shown or not. Its end
  // is pulled to now, and clearEndedToasts replaces it on the next tick like
  // any other ended toast. Returns whether anything changed; the caller saves
  // state.
  function withdrawToast(id, atSec) {
    var key = String(id)
    var next = []
    var hit = false
    for (var i = 0; i < root.openToasts.length; i++) {
      var toast = root.openToasts[i]
      if (toast.id === key && atSec < toast.end) {
        next.push({ id: toast.id, end: atSec, nid: toast.nid, sent: toast.sent })
        hit = true
      } else next.push(toast)
    }
    if (!hit) return false
    root.openToasts = next
    logState("toast-withdrawn", "id=" + key)
    return true
  }

  // Alert.qml echoes an alert's id back through its cleanText, so ids that come
  // from the overlay are compared in that same form.
  function overlayKey(id) {
    return String(id === undefined || id === null ? "" : id).replace(/\s+/g, " ").replace(/^ | $/g, "")
  }

  // Alert.qml asks this when a payload without a start reaches an open
  // overlay. The host keeps the payload of a summon that was hidden while
  // Alert.qml was still loading -- cancelPendingSummon, the IPC dismiss -- and
  // delivers it right ahead of the next summon of the overlay, which may be
  // that empty one from the bar's panel hotkey: the alert it opened is then
  // one the service has given up on. A test or preview the user asked for
  // since is wanted.
  function alertWanted(id) {
    if (root.lastSummonKind === "dismissed") return false
    if (root.lastSummonKind !== "queue") return true
    var key = overlayKey(id)
    for (var i = 0; i < root.alertQueue.length; i++) if (root.alertQueue[i].id === key) return true
    return false
  }

  // A child process, not a detached one, so closing the alert can cut it
  // short, and capped at soundCapSeconds by `timeout`. A second meeting in the
  // same minute does not restart a sound still playing; it stays the first
  // one's.
  function playSound(owner) {
    if (root.soundPath === "" || !root.soundAvailable || soundPlayer.running) return
    root.soundOwner = overlayKey(owner)
    root.soundStopRequested = false
    soundPlayer.command = ["timeout", "-k", "5", String(root.soundCapSeconds), "pw-play", root.soundPath]
    soundPlayer.running = true
  }

  // An alert that closes stops its own sound only: an older alert reaching
  // its hard cap must not cut short the alarm of one that fired meanwhile.
  // Without an owner -- the IPC dismiss, or an Alert.qml from before 1.3.0
  // that is still loaded -- any sound stops.
  function stopSound(owner) {
    if (!soundPlayer.running) return
    if (owner !== undefined && owner !== null && overlayKey(owner) !== root.soundOwner) return
    root.soundStopRequested = true
    soundPlayer.running = false
  }

  // What the last summon was for. drainQueue may only confirm a queued alert as
  // "shown" when the overlay it sees is that alert — not a preview or a test
  // the user opened by hand while something was queued.
  property string lastSummonKind: ""

  function summonAlert(entry, isTest, kind) {
    root.lastSummonKind = kind || (isTest === true ? "test" : "queue")
    var id = root.pluginId()
    if (id === "" || !root.shell || typeof root.shell.summon !== "function") {
      logState("summon-unavailable", id === "" ? "no manifest" : "no shell api")
      return false
    }
    var payload = {
      id: entry.id,
      lang: root.lang,
      title: entry.title,
      start: entry.start,
      end: entry.end,
      url: entry.url,
      calendar: entry.calendar,
      location: entry.location,
      auto_dismiss: root.autoDismissSeconds,
      colors: ({ running: root.runningColor, upcoming: root.upcomingColor }),
      // Alert.qml renders a "one more alert waits behind this" hint from this;
      // without it that line was unreachable in exactly the two-meetings-while-
      // locked case the queue exists for.
      queued: root.lastSummonKind === "queue"
        ? Math.max(0, root.alertQueue.length - 1) : root.alertQueue.length,
      test: isTest === true
    }
    // True means the host accepted the summon, not that anything is on screen.
    // Only alertOpen() below can say that.
    return root.shell.summon(id, JSON.stringify(payload)) === true
  }

  function alertOpen() {
    var id = root.pluginId()
    if (id === "" || !root.shell || typeof root.shell.isPluginOpen !== "function") return false
    return root.shell.isPluginOpen(id) === true
  }

  // A queue head that was summoned but not confirmed yet may still be loading:
  // the host delivers its payload once Alert.qml has loaded, and open() shows
  // it -- for a meeting withdrawn in the meantime. Hiding cancels that load.
  // Called before the head is dequeued; never from overlayShown, where a hide
  // would break the next payload of the same delivery loop.
  function cancelPendingSummon(entry) {
    if (!entry || entry.summonedAtSec === 0 || entry.shownAt > 0 || root.lastSummonKind !== "queue") return
    confirmTimer.stop()
    var id = root.pluginId()
    if (id === "" || !root.shell || typeof root.shell.hide !== "function" || !alertOpen()) return
    root.shell.hide(id)
    logState("alert-summon-cancelled", "id=" + entry.id)
  }

  function probeLock(force) {
    if (lockProbe.running) return
    if (!force && root.nowSec - root.lastLockProbeSec < root.lockProbeIntervalSeconds) return
    root.lastLockProbeSec = root.nowSec
    if (root.lockProbePendingSinceSec === 0) root.lockProbePendingSinceSec = root.nowSec
    lockProbe.running = true
  }

  // Alert.qml calls this from open(): the overlay itself is the witness that
  // the alert is on screen. The host's isPluginOpen is not one on its own — it
  // says "open" from the moment a summon is accepted, before the overlay has
  // loaded (see confirmGraceSeconds).
  function overlayShown(id) {
    if (root.alertQueue.length === 0 || root.lastSummonKind !== "queue") return
    var head = root.alertQueue[0]
    if (head.summonedAtSec === 0 || head.shownAt > 0 || head.id !== String(id)) return
    confirmShown(head, Math.floor(Date.now() / 1000))
  }

  // The one place "shown" is set. Witnesses: the overlay's own open() through
  // overlayShown, or the host's isPluginOpen once confirmGraceSeconds have
  // passed since the summon — so a summon the overlay never rendered does not
  // count as displayed.
  function confirmShown(entry, atSec) {
    if (entry.shownAt > 0) return
    entry.shownAt = atSec
    root.deferredReason = ""
    setAlertState(entry.id, { shown: atSec })
    saveState()
    confirmTimer.stop()
    logState("alert-shown", "id=" + entry.id)
  }

  function fireEvent(entry, atSec) {
    // "notified" is persisted before any side effect: a crash below must not
    // repeat the notification or the sound, on this tick or after a hot
    // reload. The display is not woken here but in drainQueue, right before
    // the alert is first summoned on an unlocked session.
    setAlertState(entry.id, { notified: atSec })
    saveState()
    logState("notified", "id=" + entry.id + " lead=" + (entry.start - atSec) + "s")

    // Past the burst's budget the meeting waits for the summary toast that
    // flushBurst sends once the burst is over.
    if (root.notifyEnabled) {
      if (root.burstToasts < root.maxToastsPerBurst) {
        root.burstToasts += 1
        sendNotification(entry)
      } else root.burstOverflow = root.burstOverflow.concat([entry])
    }
    playSound(entry.id)

    // Whether the overlay reaches the screen is the second, separate fact: it
    // is queued here and only marked shown once a witness confirms it. A full
    // queue is a flood, not a schedule: the entry is recorded as failed instead
    // of blanking the screen a ninth time in a row.
    if (root.alertQueue.length >= root.maxQueueLength) {
      setAlertState(entry.id, { failed: atSec })
      saveState()
      logState("alert-queue-full", "id=" + entry.id)
    } else if (enqueueAlert(entry, atSec)) saveState()
    probeLock(true)
  }

  // Anything notified but never confirmed on screen goes back into the queue
  // while it is inside its window: a hot reload (every file save under
  // ~/.config/omarchy/plugins triggers one), a shell restart, or a crash
  // between the two state writes in fireEvent would otherwise lose the alert
  // silently. isShown/isFailed are what make this terminate.
  function requeueUnshown(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      var entry = root.events[i]
      if (entry.start - atSec > root.maxLeadSeconds) break
      if (entry.start - atSec > leadFor(entry)) continue
      // Re-arming is an alert too: a meeting that ended, or that was declined
      // while it sat unshown, must not come back to the screen.
      if (!isAlertable(entry, atSec)) continue
      if (!isNotified(entry.id) || isShown(entry.id) || isFailed(entry.id)) continue
      if (queueIndexOf(entry.id) !== -1) continue
      if (!enqueueAlert(entry, atSec)) continue
      saveState()
      logState("alert-requeued", "id=" + entry.id)
    }
  }

  // The only place the queue moves: expire what is out of time, keep the head
  // on screen until it closes, then hand the overlay to the next one.
  function drainQueue(atSec) {
    var open = alertOpen()

    for (var i = root.alertQueue.length - 1; i >= 0; i--) {
      var stale = root.alertQueue[i]
      if (atSec <= stale.untilSec) continue
      // One exception: an alert that is still on screen is popped when it
      // closes, never yanked out from under the user.
      if (i === 0 && stale.shownAt > 0 && open) continue
      if (i === 0) cancelPendingSummon(stale)
      dequeueAlert(i)
      if (stale.shownAt === 0) setAlertState(stale.id, { failed: atSec })
      saveState()
      logState("alert-dropped", "id=" + stale.id + " grace over")
    }

    if (root.alertQueue.length === 0) {
      root.deferredReason = ""
      return
    }

    var head = root.alertQueue[0]
    if (open && head.summonedAtSec > 0 && head.shownAt === 0 && root.lastSummonKind === "queue"
      && atSec - head.summonedAtSec >= root.confirmGraceSeconds)
      confirmShown(head, atSec)

    if (head.shownAt > 0) {
      if (open) {
        root.deferredReason = ""
        return
      }
      // It was displayed and is gone again (dismissed, auto-dismissed, or torn
      // down by a reload): it is finished, and the next one may have the
      // screen. It is not re-summoned — "shown" is permanent.
      dequeueAlert(0)
      saveState()
      logState("alert-closed", "id=" + head.id)
      if (root.alertQueue.length === 0) {
        root.deferredReason = ""
        return
      }
      head = root.alertQueue[0]
      open = false
    }

    // isAlertable is the only gate (invariant 5), and the queue was the one
    // path that reached the screen without passing it: an alert queued under
    // the lock stayed queued after its meeting ended and was shown to the
    // returning user for a meeting that was over. So the head is re-checked
    // against the live cache entry — or its own times if the event is gone —
    // right before every summon.
    if (head.shownAt === 0) {
      var liveIndex = eventIndexOf(head.id)
      if (!isAlertable(liveIndex !== -1 ? root.events[liveIndex] : head, atSec)) {
        setAlertState(head.id, { failed: atSec })
        cancelPendingSummon(head)
        dequeueAlert(0)
        withdrawToast(head.id, atSec)
        saveState()
        logState("alert-withdrawn", "id=" + head.id + " no longer alertable")
        return
      }
    }

    // The queue's payloads predate a clock jump as much as the cache does: a
    // meeting cancelled while the machine slept would be summoned, and the
    // display woken, before the fetch after the jump could withdraw it. The
    // same goes for a meeting a config edit has just excluded.
    if (head.shownAt === 0 && fireHoldActive(atSec)) {
      root.deferredReason = "refreshing"
      return
    }

    // Nothing draws over the WlSessionLock surface, so a locked session waits
    // instead of showing the alert to nobody. tick() keeps the answer fresh
    // while anything is pending and lockProbe drains again the moment it
    // flips, so the alert appears one probe after the unlock. No probe is
    // started from here: this function also runs inside lockProbe's own exit
    // handler, and restarting that process from its handler is not sound.
    if (root.sessionLocked) {
      root.deferredReason = "locked"
      return
    }
    if (atSec - root.lockKnownAtSec > root.lockStaleSeconds) {
      // A stale answer is not good enough to summon on: under the lock the
      // host would still report the overlay open, and this would mark an alert
      // shown that nobody can see.
      root.deferredReason = "lock-unknown"
      return
    }
    if (head.summonedAtSec > 0 && atSec - head.summonedAtSec < root.resummonIntervalSeconds) {
      root.deferredReason = "waiting"
      return
    }
    if (head.attempts >= root.maxSummonAttempts) {
      // The overlay never reported itself open. The notification and the sound
      // already went out, so give this id up instead of summoning it forever.
      setAlertState(head.id, { failed: atSec })
      cancelPendingSummon(head)
      dequeueAlert(0)
      saveState()
      logState("alert-unconfirmed", "id=" + head.id + " attempts=" + head.attempts)
      return
    }

    // The display is woken once per alert, right before its first summon, and
    // only past a fresh "unlocked" answer: under the lock a wake lights the
    // panels, and Omarchy's one-shot blank timer never turns them off again.
    // Re-summons leave it alone; test and preview alerts never come here. A
    // probe that was given up on lets the alert through (fail open) but does
    // not wake the display: it is no answer that the session is unlocked.
    if (head.attempts === 0 && root.wakeDisplayEnabled && root.lockAnswerSure)
      Quickshell.execDetached(["omarchy-brightness-display", "on"])
    head.attempts += 1
    head.summonedAtSec = atSec
    var accepted = summonAlert(head, false, "queue")
    root.deferredReason = accepted ? "waiting" : "summon-failed"
    logState(accepted ? "alert-summoned" : "alert-summon-failed",
      "id=" + head.id + " attempt=" + head.attempts)
    if (!accepted) return
    // Alert.qml's open() confirms through overlayShown the moment it renders,
    // whether the overlay was mounted already or has just been loaded.
    // confirmTimer is the fallback witness via the host: sampled faster than
    // the 1 Hz tick, but only after the grace.
    confirmTimer.start()
  }

  function updateInhibit(atSec) {
    var wanted = false
    for (var i = 0; i < root.events.length; i++) {
      var entry = root.events[i]
      if (entry.start - atSec > root.inhibitLeadSeconds) break
      // Exactly the alert's rule, or the inhibitor promises a screen the alert
      // will never draw: no all-day entry holds the session awake from 23:55
      // every day, and nothing keeps the machine up for a meeting that is over
      // or that the user said no to.
      if (!isAlertable(entry, atSec)) continue
      // Not either for an alert that has done its job: once it has been on
      // screen for a moment the overlay holds its own inhibitor (Alert.qml,
      // at most 180 s), and this one would keep an unattended session
      // unlocked until start + grace. One that failed will not come back. A
      // `shown` in the future (the clock stepped back) counts as long ago.
      var state = stateOf(entry.id)
      if (state !== null && (state.failed > 0 || (state.shown > 0
        && (atSec - state.shown >= root.inhibitHandoverSeconds || atSec < state.shown)))) continue
      wanted = true
      break
    }
    if (wanted === root.inhibitActive) return
    root.inhibitActive = wanted
    logState("inhibitor", wanted ? "on" : "off")
  }

  // After a backward clock step every stamp below lies in the future, and
  // every throttle computes now - stamp: interval fetches, the fetch and
  // notify watchdogs, lock probing, re-summons and save retries would stall
  // until the clock caught up -- two hours for an RTC kept in local time.
  function rebaseStamps(atSec) {
    root.lastFetchAtSec = Math.min(root.lastFetchAtSec, atSec)
    root.lastFetchStartedAtSec = Math.min(root.lastFetchStartedAtSec, atSec)
    root.notifyStartedAtSec = Math.min(root.notifyStartedAtSec, atSec)
    // One interval back, so the next probe may go out at once.
    root.lastLockProbeSec = Math.min(root.lastLockProbeSec, atSec - root.lockProbeIntervalSeconds)
    root.lockProbePendingSinceSec = Math.min(root.lockProbePendingSinceSec, atSec)
    root.saveRetryAtSec = Math.min(root.saveRetryAtSec, atSec)
    root.lastPruneAtSec = Math.min(root.lastPruneAtSec, atSec)
    root.configEditAtSec = Math.min(root.configEditAtSec, atSec)
    for (var i = 0; i < root.alertQueue.length; i++) {
      var pending = root.alertQueue[i]
      if (pending.summonedAtSec > atSec) pending.summonedAtSec = atSec
    }
  }

  // Right after a clock jump the cache predates the sleep, and right after a
  // config edit it predates the new exclusions: until a fetch started after
  // either has landed (bounded by fireHoldSeconds once it runs) nothing fires,
  // and no queued alert reaches the screen for the first time. An edit whose
  // fetch cannot start yet -- an older one still runs -- holds for at most
  // configHoldSeconds.
  function fireHoldActive(atSec) {
    if (atSec < root.fireHoldUntilSec && (fetchProcess.running || root.jumpRefetchPending)) return true
    return root.configRefetchPending && atSec - root.configEditAtSec < root.configHoldSeconds
  }

  // The meetings past a burst's toast budget share one summary toast once the
  // burst is over -- unless there is just one: a summary for one meeting saves
  // no toast and loses its join link.
  function flushBurst(atSec) {
    var extra = root.burstOverflow
    root.burstToasts = 0
    if (extra.length === 0) return
    root.burstOverflow = []
    if (extra.length === 1) sendNotification(extra[0])
    else sendSummaryNotification(extra, atSec)
  }

  function tick() {
    var ms = Date.now()
    var atSec = Math.floor(ms / 1000)
    root.nowSec = atSec

    // Everything is recomputed from the wall clock, so a suspend/resume or an
    // NTP correction only has to force a fetch: the cache is what went stale.
    var sinceLastTickMs = root.lastTickMs > 0 ? ms - root.lastTickMs : 0
    var jumped = Math.abs(sinceLastTickMs) > root.clockJumpMs
    root.lastTickMs = ms
    if (jumped) {
      logState("clock-jump", Math.round(sinceLastTickMs / 1000) + "s")
      if (sinceLastTickMs < 0) rebaseStamps(atSec)
      // The last lock answer predates the jump, whichever way it went.
      root.lockKnownAtSec = 0
      // A lock probe or a notify helper running across the jump did not run
      // for the time the clock skipped, so neither is reaped as hung for it.
      // The probe's answer is not taken (see lockProbeStale). The fetch is
      // different: one from before a suspend is reaped on purpose (#0 above).
      if (root.lockProbePendingSinceSec > 0) root.lockProbePendingSinceSec = atSec
      if (lockProbe.running) root.lockProbeStale = true
      if (notifySender.running) root.notifyStartedAtSec = atSec
      pruneState(atSec)
      root.fireHoldUntilSec = atSec + root.fireHoldSeconds
      root.jumpRefetchPending = true
      // Refused while a fetch from before the jump still runs. The re-run is
      // retried below, and the interval fetch is due the moment it is gone.
      if (!runFetch("clock-jump")) root.lastFetchAtSec = 0
    }

    checkFetchWatchdog(atSec)
    // The fetch that ran across a suspend is reaped by the watchdog above
    // (its age counts the sleep); the re-run goes out once it is gone.
    if (root.jumpRefetchPending && atSec < root.fireHoldUntilSec) runFetch("clock-jump")
    // A config edit fetches as soon as no other fetch runs (see applyConfig).
    if (root.configRefetchPending) runFetch("config")
    checkNotifyWatchdog(atSec)

    if (root.stateDirty && atSec >= root.saveRetryAtSec && root.saveAttempts < root.maxSaveAttempts) {
      retrySaveState()
    }
    if (atSec - root.lastPruneAtSec >= root.pruneIntervalSeconds) pruneState(atSec)

    var upcoming = nextAlertableEvent(atSec)
    root.armed = root.stateLoaded && upcoming !== null && !isNotified(upcoming.id)
    updateInhibit(atSec)

    // A lock probe that never answers -- hung, or never started at all, which
    // emits no `exited` -- must not be what keeps the alert off the screen:
    // give up on it and treat the session as usable.
    if (root.lockProbePendingSinceSec > 0
      && atSec - root.lockProbePendingSinceSec >= root.lockProbeTimeoutSeconds) {
      var hung = lockProbe.running
      root.lockProbePendingSinceSec = 0
      if (hung) lockProbe.running = false
      root.sessionLocked = false
      root.lockKnownAtSec = atSec
      root.lockAnswerSure = false
      logState("lock-probe-timeout", hung ? "hung" : "not started")
    }
    // Anything still waiting for the screen needs a current lock answer, and
    // this is the only place a probe is started outside fireEvent.
    if (root.alertQueue.length > 0 && root.alertQueue[0].shownAt === 0) probeLock(false)

    // Right after a clock jump the cache predates the sleep. Firing waits for
    // a fetch started after the jump to land (bounded by fireHoldSeconds), so
    // a meeting cancelled or moved while the machine slept does not wake,
    // notify and ring -- also when the fetch that ran across the suspend kept
    // the re-run out at first. A config edit holds the same way, so a meeting
    // just put on the blocklist does not fire from the cache before it.
    var holdFires = fireHoldActive(atSec)
    if (root.stateLoaded && root.cacheLoaded && root.configLoaded && !holdFires) {
      // Two meetings in the same minute are two alerts: every due event fires
      // this tick, not only the earliest one. Bounded because fireEvent marks
      // each id notified before dueEvent looks again.
      var fired = 0
      for (; fired < root.maxFiresPerTick; fired++) {
        var due = dueEvent(atSec)
        if (due === null) break
        fireEvent(due, atSec)
      }
      // A burst ends with the first tick whose loop did not hit the cap.
      if (fired < root.maxFiresPerTick) flushBurst(atSec)
      requeueUnshown(atSec)
    }

    drainQueue(atSec)
    if (root.stateLoaded) clearEndedToasts(atSec)

    if (atSec - root.lastFetchAtSec >= root.effectiveFetchIntervalSeconds) runFetch("interval")
  }

  function lastLine(value) {
    var lines = String(value || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line !== "") return line.length > 200 ? line.slice(0, 200) : line
    }
    return ""
  }

  function eventJson(entry, atSec) {
    var state = stateOf(entry.id)
    return {
      // Ids and times only: `status` is what people paste into bug reports.
      id: entry.id,
      start: entry.start,
      end: entry.end,
      inSeconds: entry.start - atSec,
      endsInSeconds: entry.end - atSec,
      allDay: entry.allDay,
      // The two facts the agenda added to the cache, so "why did it alert" and
      // "why did it not" are answerable from `omeetingbar status` alone.
      declined: entry.declined === true,
      ended: entry.end <= atSec,
      hasUrl: entry.url !== "",
      notified: state !== null && state.notified > 0,
      shown: state !== null && state.shown > 0,
      failed: state !== null && state.failed > 0,
      queued: queueIndexOf(entry.id) !== -1
    }
  }

  function queueJson(atSec) {
    var out = []
    for (var i = 0; i < root.alertQueue.length; i++) {
      var pending = root.alertQueue[i]
      out.push({
        id: pending.id,
        start: pending.start,
        inSeconds: pending.start - atSec,
        graceLeftSeconds: pending.untilSec - atSec,
        notifiedAt: pending.notifiedAt,
        summonAttempts: pending.attempts,
        summonedAgoSeconds: pending.summonedAtSec > 0 ? atSec - pending.summonedAtSec : -1,
        shown: pending.shownAt > 0
      })
    }
    return out
  }

  // Counts plus the newest handful of ids, so the state file's notified/shown
  // split is inspectable without growing with 12 h of history.
  function alertStateJson() {
    var summary = { total: 0, notified: 0, shown: 0, failed: 0 }
    var recent = []
    for (var id in root.alertState) {
      var entry = root.alertState[id]
      summary.total += 1
      if (entry.notified > 0) summary.notified += 1
      if (entry.shown > 0) summary.shown += 1
      if (entry.failed > 0) summary.failed += 1
      recent.push({ id: id, notified: entry.notified, shown: entry.shown, failed: entry.failed })
    }
    recent.sort(function(a, b) { return b.notified - a.notified })
    summary.recent = recent.slice(0, 10)
    return summary
  }

  function statusJson() {
    var atSec = Math.floor(Date.now() / 1000)
    var upcoming = nextEvent(atSec)
    var alertable = nextAlertableEvent(atSec)
    var alertableCount = 0
    for (var i = 0; i < root.events.length; i++) {
      if (isAlertable(root.events[i], atSec)) alertableCount += 1
    }
    var head = root.alertQueue.length > 0 ? root.alertQueue[0] : null
    var installedVersion = String((root.manifest && root.manifest.version) || "")
    return JSON.stringify({
      pluginId: root.pluginId(),
      // `version` is the code answering this call, `installedVersion` what the
      // host last read from disk (see codeVersion); they differ after an
      // update until the shell restarts.
      version: root.codeVersion,
      installedVersion: installedVersion,
      restartNeeded: installedVersion !== "" && installedVersion !== root.codeVersion,
      message: root.statusMessage,
      backend: root.cacheBackend,
      cacheStatus: root.cacheStatus,
      cacheError: root.cacheError,
      // Non-empty with status "ok" means usable but degraded.
      cacheWarning: root.cacheWarning,
      degraded: root.cacheStatus === "ok" && root.cacheWarning !== "",
      cacheStale: root.cacheStale,
      cacheAgeSeconds: root.cacheGeneratedAt > 0 ? atSec - root.cacheGeneratedAt : -1,
      refreshedAgeSeconds: root.cacheRefreshedAt > 0 ? atSec - root.cacheRefreshedAt : -1,
      // agendaCount is the whole cache — the agenda the popup draws, finished
      // and declined meetings included. eventCount keeps the meaning it had
      // while the cache was alert candidates only: how many of them the alert
      // path can still act on. The pair is what makes the guard visible.
      agendaCount: root.events.length,
      eventCount: alertableCount,
      // `next` is the shared definition (end > now, invariant 1);
      // `nextAlertable` is the alert view, i.e. what the alert path would
      // actually fire on.
      next: upcoming === null ? null : eventJson(upcoming, atSec),
      nextAlertable: alertable === null ? null : eventJson(alertable, atSec),
      armed: root.armed,
      inhibiting: root.inhibitActive,
      deferred: root.deferredReason !== "",
      deferredReason: root.deferredReason,
      deferredId: head === null ? "" : head.id,
      deferredSeconds: head === null ? -1 : head.untilSec - atSec,
      queueLength: root.alertQueue.length,
      queue: queueJson(atSec),
      alerts: alertStateJson(),
      alertOpen: root.alertOpen(),
      locked: root.sessionLocked,
      lockAgeSeconds: root.lockKnownAtSec > 0 ? atSec - root.lockKnownAtSec : -1,
      lockProbeRunning: lockProbe.running,
      state: {
        loaded: root.stateLoaded,
        pendingWrite: root.stateDirty,
        saveAttempts: root.saveAttempts
      },
      configLoaded: root.configLoaded,
      configValid: root.configValid,
      configFetchPending: root.configRefetchPending,
      runtimeReady: root.runtimeReady,
      soundAvailable: root.soundAvailable,
      soundPlaying: soundPlayer.running,
      toastsOpen: root.openToasts.length,
      notifyQueued: root.notifyQueue.length + (root.notifyCurrent !== null ? 1 : 0),
      fetch: {
        running: fetchProcess.running,
        outcome: root.lastFetchOutcome,
        ageSeconds: root.lastFetchAtSec > 0 ? atSec - root.lastFetchAtSec : -1,
        runningSeconds: fetchProcess.running && root.lastFetchStartedAtSec > 0
          ? atSec - root.lastFetchStartedAtSec : -1,
        durationSeconds: root.lastFetchDurationSeconds,
        reason: root.lastFetchReason,
        exitCode: root.lastFetchExitCode,
        error: root.lastFetchError,
        timeouts: root.fetchTimeoutCount,
        failStreak: root.fetchFailStreak,
        retryInSeconds: root.effectiveFetchIntervalSeconds
      },
      settings: {
        alertLeadSeconds: root.alertLeadSeconds,
        graceSeconds: root.graceSeconds,
        inhibitLeadSeconds: root.inhibitLeadSeconds,
        autoDismissSeconds: root.autoDismissSeconds,
        fetchIntervalSeconds: root.fetchIntervalSeconds,
        fetchTimeoutSeconds: root.fetchTimeoutSeconds,
        resummonIntervalSeconds: root.resummonIntervalSeconds,
        maxSummonAttempts: root.maxSummonAttempts,
        notify: root.notifyEnabled,
        notifyDetails: root.notifyDetails,
        wakeDisplay: root.wakeDisplayEnabled,
        skipDeclined: root.skipDeclined,
        sound: root.soundPath,
        language: root.lang
      },
      paths: {
        config: root.configPath,
        cache: root.cachePath,
        state: root.statePath,
        fetcher: root.fetcherPath,
        join: root.joinPath,
        notify: root.notifyPath
      },
      lastEvent: root.logLine,
      lastEventAt: root.logAt
    })
  }

  // Both IPC previews bypass the queue on purpose: they are an explicit
  // request for the overlay and touch no notified/shown state.
  // The test alert plays the sound too, so the whole cue — including Esc
  // cutting the sound short — can be tried without waiting for a meeting.
  function showTestAlert() {
    var atSec = Math.floor(Date.now() / 1000)
    var summoned = summonAlert({
      id: "test",
      title: Strings.t(root.lang, "testMeeting"),
      start: atSec + 60,
      end: atSec + 1860,
      allDay: false,
      url: "",
      calendar: Strings.t(root.lang, "testCalendar"),
      location: ""
    }, true, "test")
    if (summoned) playSound("test")
    return summoned
  }

  function showPreview() {
    // A real alert on screen is not overwritten by a preview of the next one.
    if (root.alertQueue.length > 0 && root.alertQueue[0].shownAt > 0) return "busy"
    // Shows what the alert path would fire on next: isAlertable's view, so a
    // meeting that started more than grace_seconds ago is skipped even while
    // it is still running (the bar still shows that one as "läuft").
    var entry = nextAlertableEvent(Math.floor(Date.now() / 1000))
    if (entry === null) return "no-event"
    return summonAlert(entry, false, "preview") ? "ok" : "failed"
  }

  function dismissAlert() {
    stopSound()
    var id = root.pluginId()
    if (id === "" || !root.shell || typeof root.shell.hide !== "function") return "unavailable"
    // An explicit dismiss means "give me the screen back", so it drops the
    // whole queue and not just the head — otherwise the backlog would reappear
    // one alert at a time, or the moment the session unlocks. Entries that
    // never reached the screen are recorded as failed, not as shown.
    if (root.alertQueue.length > 0) {
      var dropped = root.alertQueue.length
      var atSec = Math.floor(Date.now() / 1000)
      for (var i = 0; i < root.alertQueue.length; i++) {
        var pending = root.alertQueue[i]
        if (pending.shownAt === 0) setAlertState(pending.id, { failed: atSec })
      }
      root.alertQueue = []
      root.deferredReason = ""
      confirmTimer.stop()
      saveState()
      logState("alert-dismissed", "dropped=" + dropped)
    }
    // Whatever the host still holds from a summon that was loading is not
    // wanted any more (see alertWanted); the next summon sets the kind anew.
    root.lastSummonKind = "dismissed"
    return root.shell.hide(id) === true ? "ok" : "failed"
  }

  onSoundPathChanged: probeSound()

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }

  Timer {
    // Started right after a summon and stopped as soon as the host reports the
    // overlay open. The 1 Hz tick alone would miss an alert that was shown and
    // dismissed inside one second, and would then re-summon it as unshown.
    // Self-stopping, so nothing polls once the head is confirmed or gone.
    id: confirmTimer
    interval: 200
    repeat: true
    running: false
    onTriggered: {
      if (root.alertQueue.length === 0) {
        stop()
        return
      }
      var head = root.alertQueue[0]
      if (head.summonedAtSec === 0 || head.shownAt > 0) {
        stop()
        return
      }
      var atSec = Math.floor(Date.now() / 1000)
      if (atSec - head.summonedAtSec >= root.confirmGraceSeconds
        && root.alertOpen() && root.lastSummonKind === "queue")
        root.confirmShown(head, atSec)
    }
  }

  Process {
    id: fetchProcess
    command: ["/usr/bin/python3", root.fetcherPath]
    // Added on top of the inherited environment (clearEnvironment stays off).
    environment: root.fetchEnvironment
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lastFetchExitCode = exitCode
      root.lastFetchDurationSeconds = root.lastFetchStartedAtSec > 0
        ? Math.floor(Date.now() / 1000) - root.lastFetchStartedAtSec : -1
      root.lastFetchOutcome = root.fetchKilled
        ? "timeout" : (exitCode === 0 ? "ok" : "failed")
      // Kept out of the journal on purpose: only counts and codes are logged,
      // never anything the fetcher printed about a calendar.
      root.lastFetchError = exitCode === 0 ? "" : root.lastLine(fetchStderr.text)
      if (root.lastFetchOutcome === "ok") {
        if (root.fetchFailStreak > 0) root.logState("fetch-recovered", "after=" + root.fetchFailStreak)
        root.fetchFailStreak = 0
        root.lastFetchLogged = ""
      } else {
        root.fetchFailStreak += 1
      }
      // The streak count is deliberately not in the line: it would defeat the
      // dedupe. The backoff step is, so each escalation is visible once.
      var fetchLine = root.lastFetchOutcome + (exitCode === 0 ? "" : " exit=" + exitCode)
        + (root.fetchFailStreak > 1 ? " retry-in=" + root.effectiveFetchIntervalSeconds + "s" : "")
      if (fetchLine !== root.lastFetchLogged) {
        root.lastFetchLogged = fetchLine
        root.logState("fetch", fetchLine)
      }
      // The fetcher replaces the cache with os.replace, which moves the inode
      // out from under the file watch, so the reload has to be explicit.
      cacheFile.reload()
      // Once per fetch cycle the sound file is looked for again, so one added
      // or removed after the config was read does not go unnoticed.
      root.probeSound()
    }
  }

  Process {
    id: lockProbe
    command: ["omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector { id: lockProbeOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.lockProbePendingSinceSec = 0
      // Asked before a clock jump: no answer for the session after it. The
      // next tick asks again.
      if (root.lockProbeStale) {
        root.lockProbeStale = false
        return
      }
      // A probe that cannot answer must never swallow the alert: only a literal
      // "true" defers it.
      var answer = String(lockProbeOut.text || "").trim()
      root.sessionLocked = exitCode === 0 && answer === "true"
      root.lockAnswerSure = exitCode === 0 && (answer === "true" || answer === "false")
      root.lockKnownAtSec = Math.floor(Date.now() / 1000)
      // Drained from here as well, so an alert appears one probe after the
      // unlock instead of waiting for the next tick.
      root.drainQueue(root.lockKnownAtSec)
    }
  }

  Process {
    id: cacheDirProcess
    command: ["mkdir", "-p", "-m", "700", root.cacheDir]
  }

  Process {
    id: soundPlayer
    stderr: StdioCollector { id: soundErr; waitForEnd: true }
    onExited: function(exitCode) {
      var stopped = root.soundStopRequested
      root.soundOwner = ""
      root.soundStopRequested = false
      // A sound that stopSound cut short is no failure, whatever exit the
      // player or `timeout` reports for it.
      if (stopped) return
      if (exitCode === 124) root.logState("sound-capped", "after=" + root.soundCapSeconds + "s")
      else if (exitCode !== 0)
        root.logState("sound-failed", "exit=" + exitCode + " " + root.lastLine(soundErr.text))
    }
  }

  // One notification at a time through bin/omeetingbar-notify. The content is
  // written to its stdin once it runs, so no process of this plugin shows
  // toast text or a join link in /proc/<pid>/cmdline (Omarchy's daemon briefly
  // shows the toast text when it saves the toast, see notify_details); its
  // stdout is the notification id.
  Process {
    id: notifySender
    stdinEnabled: true
    stdout: StdioCollector { id: notifyOut; waitForEnd: true }
    stderr: StdioCollector { id: notifyErr; waitForEnd: true }
    onStarted: {
      var job = root.notifyCurrent
      if (job) notifySender.write(JSON.stringify(job.payload) + "\n")
    }
    onExited: function(exitCode) {
      var job = root.notifyCurrent
      root.notifyCurrent = null
      var answer = String(notifyOut.text || "").trim()
      if (job && job.replace) root.forgetToast(job.toastId)
      else if (job && job.toastId !== null && exitCode === 0 && /^\d+$/.test(answer))
        root.setToastNid(job.toastId, Number(answer))
      if (exitCode !== 0) root.logState("notify-failed", "exit=" + exitCode + " " + root.lastLine(notifyErr.text))
      root.pumpNotify()
    }
    // A helper that fails to start emits no `exited` (Quickshell 0.3.1,
    // measured), and the queue would wait on it for the rest of the session.
    // After a normal run `exited` comes first: it has cleared notifyCurrent,
    // or started the next job, which reads as running here.
    onRunningChanged: {
      if (notifySender.running || root.notifyCurrent === null) return
      var job = root.notifyCurrent
      root.notifyCurrent = null
      root.logState("notify-failed", "not started")
      if (job.replace) root.forgetToast(job.toastId)
      Qt.callLater(root.pumpNotify)
    }
  }

  Process {
    id: soundProbe
    onExited: function(exitCode) {
      // A config reload can move the path while the probe runs; that answer
      // belongs to the previous file and is not taken.
      if (root.probedSoundPath !== root.soundPath) {
        root.probeSound()
        return
      }
      root.soundAvailable = exitCode === 0
      // Under the lock the sound is the only cue that reaches the user, so a
      // path that leads nowhere gets its journal line.
      if (exitCode !== 0) root.logState("sound-missing", root.soundPath)
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text(), true)
    // Only a missing file means the defaults; any other failure is a file that
    // exists and cannot be used, which keeps the last valid config.
    onLoadFailed: function(error) { root.applyConfig("", error !== FileViewError.FileNotFound) }
    onFileChanged: reload()
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    // Synchronous: the reload in fetchProcess's onExited has to land before
    // the next tick, which lifts the fire hold of a clock jump or a config
    // edit -- else that tick still fires from the cache the hold was for.
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCache(text())
    onLoadFailed: root.applyCache("")
    onFileChanged: reload()
  }

  // The cache lives on tmpfs and may not exist yet; watching the directory
  // catches its first appearance, which a watch on the file alone cannot.
  FileView {
    path: root.cacheDir
    watchChanges: true
    printErrors: false
    onFileChanged: cacheFile.reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    blockLoading: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
    onSaved: {
      root.stateDirty = false
      root.saveAttempts = 0
      // Atomic writes rename a fresh file into place, so the mode is reset on
      // every save. Best effort; the directory is already 0700.
      Quickshell.execDetached(["chmod", "600", root.statePath])
    }
    onSaveFailed: root.logState("state-write-failed", root.statePath)
  }

  Loader {
    // Alive only inside the inhibit window, so nothing holds the session awake
    // outside it.
    active: root.inhibitActive
    sourceComponent: inhibitorComponent
  }

  Component {
    id: inhibitorComponent

    // A 1x1 transparent layer surface whose only job is to carry the idle
    // inhibitor: the protocol binds an inhibitor to a mapped surface, so the
    // window has to exist and be visible while it holds one.
    PanelWindow {
      id: inhibitorWindow

      color: "transparent"
      implicitWidth: 1
      implicitHeight: 1
      anchors { top: true; left: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omeetingbar-inhibitor"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Nothing may reach this surface: an empty input region leaves the
      // pointer to whatever is underneath, and it never takes keyboard focus.
      mask: Region {}

      IdleInhibitor {
        enabled: true
        window: inhibitorWindow
      }
    }
  }

  Component.onCompleted: {
    ensureCacheDir()
    // Both are read blocking: the notified/shown state and any queue left by
    // the previous mount have to be known before the first tick can fire or
    // summon anything, and the config before it decides when. The config's
    // blocking read reports through onLoaded / onLoadFailed, which apply it;
    // this only covers a read that reported neither.
    var configText = configFile.text()
    if (!root.configLoaded) applyConfig(configText, configFile.loaded)
    loadState(stateFile.text())
    logState("service-ready", root.runtimeReady ? "" : "no XDG_RUNTIME_DIR")
    runFetch("startup")
  }

  IpcHandler {
    target: "omeetingbar"

    function status(): string {
      return root.statusJson()
    }

    function refresh(): string {
      return root.runFetch("ipc") ? "ok" : "busy"
    }

    function test(): string {
      return root.showTestAlert() ? "ok" : "failed"
    }

    function preview(): string {
      return root.showPreview()
    }

    function dismiss(): string {
      return root.dismissAlert()
    }
  }
}
