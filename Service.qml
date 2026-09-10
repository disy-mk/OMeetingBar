import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

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

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property bool runtimeReady: runtimeDir !== ""
  readonly property string configPath: home + "/.config/omarchy/omeetingbar.json"
  readonly property string cacheDir: runtimeDir + "/omeetingbar"
  readonly property string cachePath: cacheDir + "/events.json"
  readonly property string statePath: cacheDir + "/state.json"
  readonly property string fetcherPath: String(Qt.resolvedUrl("bin/omeetingbar-fetch")).replace(/^file:\/\//, "")

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
  // Spacing and hard cap for re-summoning an alert that was queued but never
  // confirmed on screen. The cap is what keeps a re-summon from looping.
  readonly property int resummonIntervalSeconds: 5
  readonly property int maxSummonAttempts: 6

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
    notify: true,
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

  readonly property int fetchIntervalSeconds: intConfig("fetch_interval_seconds", 5, 3600)
  // A backend that cannot work at all — eds before the packages are installed —
  // must not respawn python every interval for ever. Back off to at most 15 min
  // while it keeps failing; a single success drops straight back to normal.
  readonly property int effectiveFetchIntervalSeconds: Math.min(
    root.fetchIntervalSeconds * Math.pow(2, Math.min(root.fetchFailStreak, 4)), 900)
  readonly property int alertLeadSeconds: intConfig("alert_lead_seconds", 0, 3600)
  readonly property int autoDismissSeconds: intConfig("auto_dismiss_seconds", 0, 3600)
  readonly property int inhibitLeadSeconds: intConfig("inhibit_lead_seconds", 0, 7200)
  readonly property int graceSeconds: intConfig("grace_seconds", 0, 3600)
  readonly property string soundPath: stringConfig("sound")
  readonly property string runningColor: colorConfig("running", "#FF9500")
  readonly property string upcomingColor: colorConfig("upcoming", "#00BEFF")
  readonly property bool notifyEnabled: boolConfig("notify")
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
  //   notified — wake/notification/sound are done, never repeat them
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

  property int nowSec: 0
  property real lastTickMs: 0
  property bool armed: false
  property bool inhibitActive: false
  property bool sessionLocked: false
  property bool soundAvailable: false
  property string probedSoundPath: ""
  // Why the head of the queue is not on screen right now:
  // "" (nothing pending) | locked | lock-unknown | waiting | summon-failed.
  property string deferredReason: ""
  property int lastLockProbeSec: 0
  property int lockKnownAtSec: 0
  property int lastFetchAtSec: 0
  property int lastFetchStartedAtSec: 0
  property int lastFetchExitCode: -1
  property string lastFetchReason: ""
  property string lastFetchError: ""
  // never | running | ok | failed | timeout
  property string lastFetchOutcome: "never"
  property int fetchFailStreak: 0
  // Repeated identical cache/fetch lines carry no information — the counters in
  // `meetings status` do. Without this a permanently failing backend writes two
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
    if (!root.runtimeReady) return "XDG_RUNTIME_DIR ist nicht gesetzt"
    if (!root.configValid) return "omeetingbar.json ist unlesbar — Standardwerte aktiv"
    if (root.cacheStatus === "unknown") return "Cache wird gelesen"
    if (root.cacheStatus === "missing") return "Noch kein Cache — Abruf läuft"
    if (root.cacheStatus === "invalid") return "Cache ist unlesbar"
    if (root.cacheStatus === "error") return root.cacheError !== "" ? root.cacheError : "Kalenderabruf fehlgeschlagen"
    // A warning on an otherwise usable cache means "eingeschränkt nutzbar" and
    // must be visible, so it outranks the everyday messages below.
    if (root.cacheWarning !== "") return "Eingeschränkt: " + root.cacheWarning
    if (root.events.length === 0) return "Keine Termine im Vorschaufenster"
    return "Bereit"
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

  function intConfig(key, min, max) {
    var n = Math.round(Number(configValue(key)))
    if (!isFinite(n)) n = Math.round(Number(root.configDefaults[key]))
    return Math.max(min, Math.min(max, n))
  }

  // Style.boolToken is the one boolean parser in this plugin; Widget.qml reads
  // the same keys with it, so a "yes"/"1"/"on" in omeetingbar.json cannot make the
  // bar and the alert path disagree. An unrecognised value keeps the default.
  function boolConfig(key) {
    return Style.boolToken(configValue(key), root.configDefaults[key] === true)
  }

  function stringConfig(key) {
    var value = configValue(key)
    return value === undefined || value === null ? "" : String(value)
  }

  // Only #rrggbb is accepted: a typo must fall back to the documented default
  // rather than reach QML as an invalid colour, which paints black.
  function colorConfig(key, fallback) {
    var group = configValue("colors")
    var value = Util.isPlainObject(group) ? group[key] : undefined
    if (value === undefined || value === null) return fallback
    var text = String(value).trim()
    return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback
  }

  function applyConfig(raw) {
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
    root.config = valid ? parsed : ({})
    root.configValid = valid || text === ""
    root.configLoaded = true
    // Editing the config is the moment to retry: switching backend to eds once
    // the packages are there must not wait out a 15-minute backoff.
    root.fetchFailStreak = 0
    root.lastFetchLogged = ""
    if (!root.configValid) logState("config-invalid", root.configPath)
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
      // Only https is ever handed to the browser or to a notification --exec,
      // and every file drops the rest in its own cache parser.
      if (!/^https:\/\/[^\s]+$/i.test(url)) url = ""
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
    out.sort(function(a, b) { return a.start - b.start })
    return out
  }

  function logCache(message) {
    if (message === root.lastCacheLogged) return
    root.lastCacheLogged = message
    logState("cache", message)
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
    root.cacheWarning = String(parsed.warning === undefined || parsed.warning === null ? "" : parsed.warning)
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
  // screen. Only a healthy, fresh cache is allowed to say that: an error or
  // stale cache is missing events for its own reasons and would withdraw
  // alerts that are still due.
  function dropCancelledAlerts() {
    if (root.cacheStatus !== "ok" || root.cacheStale) return
    if (root.alertQueue.length === 0) return
    var atSec = Math.floor(Date.now() / 1000)
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
      dequeueAlert(i)
      saveState()
      logState("alert-withdrawn", "id=" + pending.id + (index === -1 ? " gone from cache" : " no longer alertable"))
    }
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

  function probeSound() {
    if (root.soundPath === "") {
      root.soundAvailable = false
      root.probedSoundPath = ""
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
  // reach the screen, so `armed` and `meetings preview` ask isAlertable()
  // instead of re-deriving half of the rule here.
  function nextAlertableEvent(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      if (isAlertable(root.events[i], atSec)) return root.events[i]
    }
    return null
  }

  function dueEvent(atSec) {
    for (var i = 0; i < root.events.length; i++) {
      var entry = root.events[i]
      // Ascending by start, so once one is beyond the lead nothing after it can
      // be due either. Sound even though isAlertable() may reject entries
      // before this one: rejecting them never moves a later start earlier.
      if (entry.start - atSec > root.alertLeadSeconds) return null
      // Every other reason not to fire is in the one predicate: all-day,
      // already over, past the grace window, declined.
      if (!isAlertable(entry, atSec)) continue
      if (isNotified(entry.id)) continue
      return entry
    }
    return null
  }

  function relativeText(seconds) {
    if (seconds <= 0) return "jetzt"
    if (seconds < 60) return "in " + seconds + " s"
    var minutes = Math.round(seconds / 60)
    return "in " + minutes + (minutes === 1 ? " Minute" : " Minuten")
  }

  function timeRangeText(entry) {
    if (entry.allDay) return "ganztägig"
    var from = Qt.formatDateTime(new Date(entry.start * 1000), "HH:mm")
    if (entry.end <= entry.start) return from
    return from + "–" + Qt.formatDateTime(new Date(entry.end * 1000), "HH:mm")
  }

  // The headline lands in omarchy-notification-send's option position, where a
  // title the script recognises as one of its flags is consumed as that flag
  // (`-g`, `--urgency=x`, `-p`, …). Matching that option table here would mean
  // keeping a copy of it in sync forever, so neutralise the only way in
  // instead: a leading dash. A leading space cannot start an option, and the
  // script passes the headline through to D-Bus as a plain string.
  function notificationHeadline(title) {
    var text = String(title || "").trim()
    if (text === "") return "Termin"
    return /^-/.test(text) ? " " + text : text
  }

  function notificationBody(entry, atSec) {
    var parts = ["Beginnt " + relativeText(entry.start - atSec), timeRangeText(entry)]
    if (entry.location !== "") parts.push(entry.location)
    else if (entry.calendar !== "") parts.push(entry.calendar)
    return parts.join(" · ")
  }

  function sendNotification(entry, atSec) {
    var argv = ["omarchy-notification-send", "-u", "critical", "-g", "󰃭",
      notificationHeadline(entry.title), notificationBody(entry, atSec)]
    // --exec must come last and as separate words; the script hands them to the
    // click action as argv, so a URL can never become a command.
    if (entry.url !== "") argv = argv.concat(["--exec", "omarchy-launch-browser", entry.url])
    Quickshell.execDetached(argv)
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

  function probeLock(force) {
    if (lockProbe.running) return
    if (!force && root.nowSec - root.lastLockProbeSec < root.lockProbeIntervalSeconds) return
    root.lastLockProbeSec = root.nowSec
    lockProbe.running = true
  }

  // The one place "shown" is set. The witness is the host: isPluginOpen reads
  // the overlay's own `opened` property, so a summon the overlay never
  // rendered does not count as displayed.
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
    // repeat the wake, the notification or the sound, on this tick or after a
    // hot reload.
    setAlertState(entry.id, { notified: atSec })
    saveState()
    logState("notified", "id=" + entry.id + " lead=" + (entry.start - atSec) + "s")

    if (root.wakeDisplayEnabled) Quickshell.execDetached(["omarchy-brightness-display", "on"])
    if (root.notifyEnabled) sendNotification(entry, atSec)
    if (root.soundPath !== "" && root.soundAvailable) Quickshell.execDetached(["pw-play", root.soundPath])

    // Whether the overlay reaches the screen is the second, separate fact: it
    // is queued here and only marked shown once the host confirms it.
    if (enqueueAlert(entry, atSec)) saveState()
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
      if (entry.start - atSec > root.alertLeadSeconds) break
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
    if (open && head.summonedAtSec > 0 && head.shownAt === 0 && root.lastSummonKind === "queue")
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
        dequeueAlert(0)
        saveState()
        logState("alert-withdrawn", "id=" + head.id + " no longer alertable")
        return
      }
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
      dequeueAlert(0)
      saveState()
      logState("alert-unconfirmed", "id=" + head.id + " attempts=" + head.attempts)
      return
    }

    head.attempts += 1
    head.summonedAtSec = atSec
    var accepted = summonAlert(head, false, "queue")
    root.deferredReason = accepted ? "waiting" : "summon-failed"
    logState(accepted ? "alert-summoned" : "alert-summon-failed",
      "id=" + head.id + " attempt=" + head.attempts)
    if (!accepted) return
    // The host delivers straight to an already mounted overlay, so the
    // confirmation can be in immediately; otherwise confirmTimer samples it
    // faster than the 1 Hz tick, which could miss an alert that was shown and
    // dismissed inside the same second.
    if (alertOpen()) confirmShown(head, atSec)
    else confirmTimer.start()
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
      wanted = true
      break
    }
    if (wanted === root.inhibitActive) return
    root.inhibitActive = wanted
    logState("inhibitor", wanted ? "on" : "off")
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
      pruneState(atSec)
      runFetch("clock-jump")
    }

    checkFetchWatchdog(atSec)

    if (root.stateDirty && atSec >= root.saveRetryAtSec && root.saveAttempts < root.maxSaveAttempts) {
      retrySaveState()
    }
    if (atSec - root.lastPruneAtSec >= root.pruneIntervalSeconds) pruneState(atSec)

    var upcoming = nextAlertableEvent(atSec)
    root.armed = root.stateLoaded && upcoming !== null && !isNotified(upcoming.id)
    updateInhibit(atSec)

    // A lock probe that never answers must not be what keeps the alert off the
    // screen: reap it and treat the session as usable.
    if (lockProbe.running && atSec - root.lastLockProbeSec >= root.lockProbeTimeoutSeconds) {
      lockProbe.running = false
      root.sessionLocked = false
      root.lockKnownAtSec = atSec
      logState("lock-probe-timeout", "at=" + root.lastLockProbeSec)
    }
    // Anything still waiting for the screen needs a current lock answer, and
    // this is the only place a probe is started outside fireEvent.
    if (root.alertQueue.length > 0 && root.alertQueue[0].shownAt === 0) probeLock(false)

    if (root.stateLoaded && root.cacheLoaded && root.configLoaded) {
      // Two meetings in the same minute are two alerts: every due event fires
      // this tick, not only the earliest one. Bounded because fireEvent marks
      // each id notified before dueEvent looks again.
      for (var fires = 0; fires < 8; fires++) {
        var due = dueEvent(atSec)
        if (due === null) break
        fireEvent(due, atSec)
      }
      requeueUnshown(atSec)
    }

    drainQueue(atSec)

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
      id: entry.id,
      title: entry.title,
      start: entry.start,
      end: entry.end,
      inSeconds: entry.start - atSec,
      endsInSeconds: entry.end - atSec,
      allDay: entry.allDay,
      // The two facts the agenda added to the cache, so "why did it alert" and
      // "why did it not" are answerable from `meetings status` alone.
      declined: entry.declined === true,
      ended: entry.end <= atSec,
      hasUrl: entry.url !== "",
      calendar: entry.calendar,
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
        title: pending.title,
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
    return JSON.stringify({
      pluginId: root.pluginId(),
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
      runtimeReady: root.runtimeReady,
      soundAvailable: root.soundAvailable,
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
        wakeDisplay: root.wakeDisplayEnabled,
        skipDeclined: root.skipDeclined,
        sound: root.soundPath
      },
      paths: {
        config: root.configPath,
        cache: root.cachePath,
        state: root.statePath,
        fetcher: root.fetcherPath
      },
      lastEvent: root.logLine,
      lastEventAt: root.logAt
    })
  }

  // Both IPC previews bypass the queue on purpose: they are an explicit
  // request for the overlay and touch no notified/shown state.
  function showTestAlert() {
    var atSec = Math.floor(Date.now() / 1000)
    return summonAlert({
      id: "test",
      title: "Testtermin",
      start: atSec + 60,
      end: atSec + 1860,
      allDay: false,
      url: "",
      calendar: "Test",
      location: ""
    }, true, "test")
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
      if (root.alertOpen() && root.lastSummonKind === "queue")
        root.confirmShown(head, Math.floor(Date.now() / 1000))
    }
  }

  Process {
    id: fetchProcess
    command: ["/usr/bin/python3", root.fetcherPath]
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
    }
  }

  Process {
    id: lockProbe
    command: ["omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector { id: lockProbeOut; waitForEnd: true }
    onExited: function(exitCode) {
      // A probe that cannot answer must never swallow the alert: only a literal
      // "true" defers it.
      root.sessionLocked = exitCode === 0 && String(lockProbeOut.text || "").trim() === "true"
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
    id: soundProbe
    onExited: function(exitCode) {
      root.soundAvailable = exitCode === 0
      // A config reload can move the path while the probe runs; that answer
      // belongs to the previous file.
      if (root.probedSoundPath !== root.soundPath) root.probeSound()
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
    onFileChanged: reload()
  }

  FileView {
    id: cacheFile
    path: root.cachePath
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
    // summon anything, and the config before it decides when.
    applyConfig(configFile.text())
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
