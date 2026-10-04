import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Strings.js" as Strings

// Next-meeting label for the bar, and the host of the agenda popup.
//
// Reads the two files the rest of the plugin owns — the event cache the
// fetcher writes and the user's omeetingbar.json — rather than talking to
// Service.qml, so the bar keeps painting while the service is reloading and
// says so honestly when there is nothing to read.
//
// Left click toggles the agenda popup (Popup.qml, loaded below); right and
// middle click ask for a fresh fetch. Nothing here opens the fullscreen alert
// — that alert is for someone who is not looking at the bar. Joining a
// meeting moved into the popup, which calls back through this file's join()
// so exactly one place talks to the outside world.
BarWidget {
  id: root
  moduleName: "io.github.disy-mk.omeetingbar"

  // ---- Paths. The cache is on tmpfs on purpose, so it is legitimately
  //      absent after a reboot until the first fetch lands.
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string cacheDir: runtimeDir === "" ? "" : runtimeDir + "/omeetingbar"
  readonly property string cachePath: cacheDir === "" ? "" : cacheDir + "/events.json"
  readonly property string configPath: String(Quickshell.env("HOME") || "") + "/.config/omarchy/omeetingbar.json"

  // ---- Config. Three layers, most specific first: the inline shell.json
  //      entry the bar settings UI writes, then omeetingbar.json's `widget`
  //      block, then these defaults. Every layer tolerates junk.
  property var fileConfig: ({})
  readonly property var fileWidget: Util.isPlainObject(fileConfig.widget) ? fileConfig.widget : ({})
  readonly property var fileColors: Util.isPlainObject(fileConfig.colors) ? fileConfig.colors : ({})

  readonly property string runningColor: colorOption(fileColors.running, "#FF9500")
  readonly property string upcomingColor: colorOption(fileColors.upcoming, "#00BEFF")

  readonly property int warnMinutes: numberOption("warn_minutes", fileWidget.warn_minutes, 15, 0, 1440)
  readonly property int maxTitleChars: numberOption("max_title_chars", fileWidget.max_title_chars, 28, 4, 200)
  readonly property bool hideWhenEmpty: boolOption("hide_when_empty", fileWidget.hide_when_empty, true)
  // Read straight out of omeetingbar.json, not through setting(): this one
  // mirrors an alert-side decision (invariant 5 — a declined meeting never
  // blanks the screen while it is on, but stays in the agenda), and a bar
  // layout entry must not be able to disagree with what the service does.
  readonly property bool skipDeclined: Style.boolToken(fileConfig.skip_declined, true)
  // ---- UI language: omeetingbar.json's `language` ("de" | "en" | "auto"),
  //      else the session locale, else English. Pushed to the popup; the
  //      service resolves it the same way for the alert and the notifications.
  readonly property string lang: Strings.pick(fileConfig.language, Qt.locale().name)
  readonly property var uiLocale: Qt.locale(Strings.localeName(lang))
  // ---- Cache state. "unknown" until the first read resolves, so a present
  //      cache never flashes the placeholder on startup.
  property string cacheState: "unknown"
  property string cacheError: ""
  // Degraded-but-usable: the fetcher ran on fallback values (e.g. a typo in
  // omeetingbar.json). Separate from cacheError, which belongs to status "error".
  property string cacheWarning: ""
  property bool cacheStale: false
  property real cacheGeneratedAt: 0
  // The whole two-day agenda, finished and declined occurrences included
  // (invariant 5). This is what the popup renders; the bar label speaks for
  // the `alertable` view below.
  property var events: []

  readonly property bool runtimeMissing: cacheDir === ""
  readonly property bool pending: !runtimeMissing && cacheState === "unknown"
  readonly property bool degraded: runtimeMissing || (!pending && cacheState !== "ok")
  readonly property bool hasWarning: !pending && cacheWarning !== ""

  readonly property real nowSec: Math.floor(wallClock.date.getTime() / 1000)

  // A cache nobody refreshes any more still parses fine, so the widget would
  // happily show yesterday's list. The service writes every minute by
  // default; well past that means it is not running, and the alert will not
  // fire either — say so instead of looking healthy.
  readonly property real cacheAge: cacheGeneratedAt > 0 ? nowSec - cacheGeneratedAt : -1
  readonly property bool cacheOutdated: cacheAge > 900

  // The cache is the agenda now, so the bar has to filter it back down to
  // what it has always meant: the meetings that can still interrupt you.
  // Same three tests the service's isAlertable applies over the cache — not
  // all-day (invariant 4), not declined while skip_declined is on
  // (invariant 5), not over yet — minus the grace window, which is an
  // alert-timing rule and would drop a running meeting off the bar.
  //
  // "Not over yet" rather than "not started yet" is the shared definition of
  // next event (invariant 1) — Service.qml, Alert.qml and the fetcher use the
  // same rule, so please do not "fix" it back to start > now. Math.max keeps
  // a zero-length occurrence (end == start, the documented fallback) from
  // being dropped before it has even begun.
  readonly property var alertable: {
    var out = []
    for (var i = 0; i < events.length; i++) {
      var event = events[i]
      if (event.allDay) continue
      if (event.declined && skipDeclined) continue
      if (Math.max(event.end, event.start) <= nowSec) continue
      out.push(event)
    }
    return out
  }
  readonly property var nextEvent: alertable.length > 0 ? alertable[0] : null
  readonly property bool hasEvent: nextEvent !== null
  readonly property real secondsToStart: hasEvent ? nextEvent.start - nowSec : 0
  readonly property bool urgent: hasEvent && secondsToStart <= warnMinutes * 60
  // The colour says which of the two states this is, not how close it is.
  readonly property bool runningNow: hasEvent && secondsToStart <= 0

  readonly property string glyph: "󰃭"
  // Calm marker for a cache that parses fine but ran on fallbacks: the meeting
  // stays the message, the glyph only says "read the tooltip".
  readonly property string warnGlyph: "󰀦"
  readonly property string warnMark: hasWarning ? " " + warnGlyph : ""

  readonly property string labelText: {
    if (vertical) return hasWarning ? warnGlyph : glyph
    if (!hasEvent) return glyph + " —" + warnMark
    return glyph + " " + timeLabel(nextEvent) + " " + truncate(nextEvent.title, maxTitleChars)
      + " · " + shortCountdown(secondsToStart) + warnMark
  }

  // One place for the hint, so it can never promise a binding the button
  // below does not have.
  readonly property string clickHint: Strings.t(root.lang, "clickHint")

  // The tooltip names the next meeting and every reason the data may be
  // wrong. The list of what comes after it belongs to the popup now — a
  // hover that repeats the panel is just two places to keep in step.
  readonly property string tooltipText: {
    if (runtimeMissing)
      return Strings.t(root.lang, "runtimeMissing")
    if (pending) return ""

    var lines = []
    if (cacheState === "missing") {
      lines.push(Strings.t(root.lang, "noDataYet"))
      lines.push(Strings.t(root.lang, "notConnected"))
      lines.push(clickHint)
      return lines.join("\n")
    }
    if (cacheState === "corrupt") {
      lines.push(Strings.t(root.lang, "cacheUnreadable"))
      lines.push(cachePath)
      lines.push(clickHint)
      return lines.join("\n")
    }
    if (cacheState === "error") {
      lines.push(Strings.t(root.lang, "calendarError", cacheError))
      if (cacheStale) lines.push(Strings.t(root.lang, "lastKnown"))
    }
    if (cacheWarning !== "")
      lines.push(Strings.t(root.lang, "limited", cacheWarning))
    if (cacheOutdated)
      lines.push(Strings.t(root.lang, "dataAge", minutesWord(Math.floor(cacheAge / 60))))
    if (!hasEvent) {
      lines.push(Strings.t(root.lang, "noUpcomingDot"))
      // Without this line a bar showing "—" over a popup full of rows looks
      // like a bug rather than like a day that is already done.
      if (events.length > 0)
        lines.push(Strings.t(root.lang, "agendaLists", eventsWord(events.length)))
      lines.push(clickHint)
      return lines.join("\n")
    }

    var day = dayPrefix(nextEvent)
    if (day !== "" && day !== Strings.t(root.lang, "tomorrow"))
      day = new Date(Number(nextEvent.start) * 1000).toLocaleDateString(root.uiLocale, Strings.t(root.lang, "dateShort"))
    lines.push((day === "" ? "" : day + "  ") + timeRange(nextEvent) + "  " + truncate(nextEvent.title, 64))
    var meta = []
    if (nextEvent.calendar !== "") meta.push(nextEvent.calendar)
    if (nextEvent.location !== "") meta.push(truncate(nextEvent.location, 48))
    if (meta.length > 0) lines.push(meta.join(" · "))
    lines.push(longCountdown(secondsToStart))
    lines.push(clickHint)
    return lines.join("\n")
  }

  // A degraded cache stays visible even with hide_when_empty on: "no
  // calendar connected" — and equally "running on fallback settings" — is
  // something the user has to be able to see.
  // `events.length` is in there because the left click is the popup's only
  // mouse entry point: once the last alertable meeting of the day is over,
  // collapsing to zero width would take the agenda with it, exactly when
  // "what did I have today, what is tomorrow" is the useful question.
  visible: !pending && (degraded || hasWarning || hasEvent || events.length > 0 || !hideWhenEmpty)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Agenda popup host.
  //
  // Shape contract for the bar: Bar.findPanelWidget only routes to a widget
  // that has open()/close()/opened, Bar.requestPopout prefers
  // closeForPopoutSwitch() over close() and KeyboardPanel reads
  // popoutSwitchClosing back off its owner. The popup's KeyboardPanel owner
  // must therefore be this root and not the popup object: the open-panel dot
  // compares activePopout against the item mounted in the bar slot, which is
  // this widget.
  readonly property bool opened: popupLoader.item ? popupLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: popupLoader.item ? popupLoader.item.popoutSwitchClosing === true : false

  function open() {
    // The Loader is synchronous, so the item exists by the next statement.
    root.popupWanted = true
    if (popupLoader.item) popupLoader.item.open()
  }

  function close() {
    if (popupLoader.item) popupLoader.item.close()
  }

  function toggle() {
    // Nothing to toggle before the first open — the Loader is lazy, so the
    // first click has to create the popup rather than ask a null item.
    if (!popupLoader.item) {
      root.open()
      return
    }
    popupLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (popupLoader.item) popupLoader.item.closeForPopoutSwitch()
  }

  // The label fills more slot than it paints a mark for, so the dot takes the
  // width of the text rather than of the padded slot around it. Vertical bars
  // fall through to the bar's own default: there the widget is a single glyph
  // in one icon slot, which the default already fits.
  readonly property real openPanelIndicatorWidth: button.labelWidth

  // ---- Popup wiring
  //
  // Structural handles first, exactly like the first-party clock/weather
  // hosts: bar, settings, the item to anchor the card against, and this root
  // as the popup's bar identity.
  function injectPanel() {
    var target = popupLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    injectData()
  }

  // The data goes in as bindings rather than as one-shot values: the agenda
  // changes under an open popup every time the fetcher rewrites the cache.
  // Same idiom the host uses to push bar state into a plugin's api object
  // (Bar.qml bindPluginBarApi).
  //
  // Exactly these names, and nothing else: `events` is the whole two-day
  // agenda, `nextEvent` the alertable view the bar label speaks for, and the
  // cache* / degraded / pending group is what the popup needs for its
  // degraded message.
  function injectData() {
    var target = popupLoader.item
    if (!target) return
    pushBinding(target, "events", function() { return root.events })
    pushBinding(target, "nextEvent", function() { return root.nextEvent })
    pushBinding(target, "nowSec", function() { return root.nowSec })
    pushBinding(target, "runningColor", function() { return root.runningColor })
    pushBinding(target, "upcomingColor", function() { return root.upcomingColor })
    pushBinding(target, "cacheState", function() { return root.cacheState })
    pushBinding(target, "cacheError", function() { return root.cacheError })
    pushBinding(target, "cacheWarning", function() { return root.cacheWarning })
    pushBinding(target, "cacheStale", function() { return root.cacheStale })
    pushBinding(target, "cacheOutdated", function() { return root.cacheOutdated })
    pushBinding(target, "degraded", function() { return root.degraded })
    pushBinding(target, "pending", function() { return root.pending })
    pushBinding(target, "lang", function() { return root.lang })
  }

  function pushBinding(target, key, getter) {
    if (!(key in target)) return
    try {
      target[key] = Qt.binding(getter)
    } catch (e) {
      // A popup that declares one of these read-only derives it from
      // hostWidget itself; a rejected push must not skip the rest of them.
    }
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // ---- Option resolution

  function numberOption(key, fileValue, fallback, min, max) {
    var n = Number(setting(key, fileValue))
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.round(n)))
  }

  // Only #rrggbb: an invalid colour string paints black in QML, so a typo in
  // omeetingbar.json must fall back to the documented default instead.
  function colorOption(fileValue, fallback) {
    if (fileValue === undefined || fileValue === null) return fallback
    var text = String(fileValue).trim()
    return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback
  }

  function boolOption(key, fileValue, fallback) {
    return Style.boolToken(setting(key, fileValue), fallback)
  }

  // Style.boolToken is the one boolean parser in this plugin — the service
  // reads the same keys with it, so a "yes"/"1"/"on" in omeetingbar.json can never
  // make the bar hide a meeting the service still alerts on.
  function boolValue(value, fallback) {
    return Style.boolToken(value, fallback)
  }

  // ---- Formatting

  function truncate(value, limit) {
    var s = String(value || "")
    if (limit <= 1 || s.length <= limit) return s
    return s.substring(0, limit - 1) + "…"
  }

  function clockTime(seconds) {
    return Qt.formatDateTime(new Date(seconds * 1000), "HH:mm")
  }

  // Local midnight `offset` days from now, via Date components so the DST
  // days keep their 23 and 25 hours (never now + n * 86400).
  function dayStartSec(offset) {
    var d = new Date(nowSec * 1000)
    return Math.floor(new Date(d.getFullYear(), d.getMonth(), d.getDate() + offset).getTime() / 1000)
  }

  // "" today, "tomorrow" for tomorrow, else the short weekday — the bar always
  // names the next meeting even when it is on Monday, and a bare "09:00" for a
  // Monday meeting read on Friday would be a lie. The weekday follows the UI
  // language (uiLocale), not the session locale.
  function dayPrefix(event) {
    var start = Number(event.start)
    if (start < dayStartSec(1)) return ""
    if (start < dayStartSec(2)) return Strings.t(root.lang, "tomorrow")
    return new Date(start * 1000).toLocaleDateString(root.uiLocale, "ddd")
  }

  function timeLabel(event) {
    var prefix = dayPrefix(event)
    var time = event.allDay ? Strings.t(root.lang, "allDay") : clockTime(event.start)
    return prefix === "" ? time : prefix + " " + time
  }

  function timeRange(event) {
    if (event.allDay) return Strings.t(root.lang, "allDay")
    // A zero-length occurrence (end == start, the invariant-2 fallback) reads
    // as one time, the way the popup and the notification already print it.
    if (!(event.end > event.start)) return clockTime(event.start)
    return clockTime(event.start) + "–" + clockTime(event.end)
  }

  function shortCountdown(delta) {
    if (delta < -60) return Strings.t(root.lang, "running")
    if (delta < 60) return Strings.t(root.lang, "now")
    var minutes = Math.floor(delta / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    // Past a day the hour count stops meaning anything at a glance; the label
    // already carries the weekday, so the countdown just says how many days.
    if (hours >= 24) return Math.round(delta / 86400) + "d"
    var rest = minutes % 60
    return rest > 0 ? hours + "h" + rest + "m" : hours + "h"
  }

  function longCountdown(delta) {
    if (delta < -60) return Strings.t(root.lang, "runningForDot", minutesWord(Math.floor(-delta / 60)))
    if (delta < 60) return Strings.t(root.lang, "startsNow")
    var minutes = Math.floor(delta / 60)
    if (minutes < 60) return Strings.t(root.lang, "startsIn", minutesWord(minutes))
    if (minutes >= 24 * 60) {
      var days = Math.round(delta / 86400)
      return Strings.t(root.lang, "startsIn", Strings.count(root.lang, days, "oneDay", "nDays"))
    }
    return Strings.t(root.lang, "startsIn",
      Strings.t(root.lang, "hoursMin", Math.floor(minutes / 60), minutes % 60))
  }

  function minutesWord(minutes) {
    return Strings.count(root.lang, minutes, "oneMinute", "nMinutes")
  }

  function eventsWord(count) {
    return Strings.count(root.lang, count, "oneMeeting", "nMeetings")
  }

  // ---- Parsing

  function applyConfig(body) {
    var text = String(body || "").trim()
    if (text === "") {
      fileConfig = ({})
      return
    }
    try {
      var json = JSON.parse(text)
      fileConfig = Util.isPlainObject(json) ? json : ({})
    } catch (e) {
      // omeetingbar.json caught mid-edit: fall back to the built-in defaults
      // rather than to whatever half a file parses as.
      fileConfig = ({})
    }
  }

  function setCache(state, error, stale, generatedAt, list, warning) {
    cacheState = state
    cacheError = error
    cacheWarning = String(warning || "")
    cacheStale = stale
    cacheGeneratedAt = generatedAt
    events = list
  }

  function applyCache(body) {
    var text = String(body || "").trim()
    if (text === "") {
      setCache("missing", "", false, 0, [])
      return
    }
    var json = null
    try {
      json = JSON.parse(text)
    } catch (e) {
      json = null
    }
    if (!Util.isPlainObject(json)) {
      setCache("corrupt", "", false, 0, [])
      return
    }
    var generatedAt = Number(json.generated_at)
    if (!isFinite(generatedAt) || generatedAt < 0) generatedAt = 0
    var list = parseEvents(json.events)
    var warning = shortError(json.warning)
    var error = shortError(json.error)
    if (String(json.status || "") === "ok") {
      // `error` belongs to status "error", but a cache that claims "ok" and
      // still carries one is degraded, not healthy — never drop the text.
      setCache("ok", "", json.stale === true, generatedAt, list,
        warning !== "" && error !== "" ? warning + " · " + error : warning || error)
    } else {
      setCache("error", error || "unbekannter Fehler", json.stale === true, generatedAt, list, warning)
    }
  }

  function parseEvents(list) {
    if (!Array.isArray(list)) return []
    var out = []
    // 256, not 64: since the cache became the two-day agenda it also carries
    // the finished and the declined occurrences, and a busy calendar does not
    // fit in 64 of them. The cap only exists so a corrupt file cannot make
    // the bar chew through a million entries.
    for (var i = 0; i < list.length && out.length < 256; i++) {
      var raw = list[i]
      if (!Util.isPlainObject(raw)) continue
      var start = Number(raw.start)
      if (!isFinite(start)) continue
      // The fetcher owns the duration; nothing here invents one. A missing or
      // reversed end simply collapses to the start (a zero-length occurrence),
      // which the alertable filter still shows until its start has passed.
      var end = Number(raw.end)
      if (!isFinite(end) || end < start) end = start
      out.push({
        id: String(raw.id || ""),
        title: collapse(raw.title) || Strings.t(root.lang, "untitled"),
        start: start,
        end: end,
        allDay: raw.all_day === true,
        // Flagged, not dropped: the popup strikes it through, and only
        // skip_declined decides whether it may also alert (invariant 5).
        // Anything but a literal true is "not declined" — the ics and demo
        // backends do not know, and a missing field must not strike a
        // meeting out.
        declined: raw.declined === true,
        url: httpsUrl(raw.url),
        calendar: collapse(raw.calendar),
        location: collapse(raw.location)
      })
    }
    out.sort(function(a, b) { return a.start - b.start })
    return out
  }

  // Only https ever reaches the browser: the cache is a file, and a
  // file:// or javascript: url in it must not become a launch argument.
  function httpsUrl(value) {
    var url = String(value || "").trim()
    return /^https:\/\/[^\s\\]+$/i.test(url) ? url : ""
  }

  function collapse(value) {
    return String(value || "").replace(/\s+/g, " ").trim()
  }

  function shortError(value) {
    return truncate(collapse(value), 140)
  }

  // ---- Actions. The popup renders and calls these; only this file talks to
  //      the outside world.

  // Invariant 3 lives here, at the last step before a browser command line:
  // https only, no whitespace, argv array — never a shell string built from
  // cache content.
  function openUrl(url) {
    var target = httpsUrl(url)
    if (target === "") return
    Quickshell.execDetached(["omarchy-launch-browser", target])
  }

  // Same guarded launch, kept under its own name because that is what a row
  // and the footer action mean when they hand over a meeting's join link.
  function join(url) {
    openUrl(url)
  }

  function requestRefresh() {
    Quickshell.execDetached(["omarchy-shell", "omeetingbar", "refresh"])
  }

  SystemClock {
    id: wallClock
    precision: SystemClock.Seconds
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCache(text())
    onLoadFailed: root.setCache("missing", "", false, 0, [])
    // text() is still stale inside the change signal, so both paths go
    // through reload() → onLoaded. FileView does not re-read on its own.
    onFileChanged: reload()
  }

  // The fetcher creates the cache directory, so on a fresh boot neither the
  // file nor its directory exists. Watching the directory picks up the first
  // write; the retry timer is the backstop for the window in which there is
  // no directory to watch yet. The directory never reads as text — only its
  // watch is wanted, so nothing here reads text().
  FileView {
    id: cacheDirWatch
    path: root.cacheDir
    watchChanges: true
    printErrors: false
    onFileChanged: cacheFile.reload()
  }

  Timer {
    interval: 5000
    repeat: true
    running: !root.runtimeMissing && root.cacheState !== "ok" && root.cacheState !== "error"
    onTriggered: cacheFile.reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.fileConfig = ({})
    onFileChanged: reload()
  }

  // Not a manifest kind: the popup is a plain component this widget loads, so
  // shell.qml keeps routing the plugin's summon/hide to the fullscreen alert.
  // A failed load leaves item null, every forward above a no-op, and the bar
  // label untouched.
  // Instantiated on first open, not at startup. The popup builds the whole
  // two-day agenda — a timeline strip and a row per meeting — and a bar widget
  // has no business paying for that, or for any defect in it, while it is
  // closed. `popupWanted` latches on the first open so the panel keeps its
  // close animation instead of vanishing with the Loader.
  property bool popupWanted: false

  Loader {
    id: popupLoader
    active: root.popupWanted
    source: Qt.resolvedUrl("Popup.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The plugin's `overlay` kind makes shell.qml treat summon/hide/toggle as the
  // fullscreen alert's, so the bar's own bar-widget panel route never reaches
  // this widget. Without this handler the agenda would be mouse-only: no
  // keybinding, no scripting, and nothing to drive a screenshot from.
  // One instance per bar (so per monitor) registers this target; the shell logs
  // that the later registration is unused and the first one answers, which is
  // the same shape several first-party widgets already have.
  // One IpcHandler per bar — so per monitor — and Quickshell keeps only the
  // first registration. Whichever instance answers must therefore not act on
  // itself: with two monitors that dragged a popup open on screen B over to
  // screen A. It asks the bar to route to the widget on the FOCUSED screen,
  // the same path the bar's own hotkeys take for first-party widgets
  // (Bar.summonBarWidget → findPanelWidget → BarModel.pickPanelSlot). The
  // local fallback only runs when a bar without that facade hosts us.
  function routeToFocused(action) {
    var b = root.bar
    var id = root.moduleName
    if (b && typeof b.summonBarWidget === "function" && typeof b.isBarWidgetOpen === "function") {
      if (action === "isOpen") return b.isBarWidgetOpen(id) === true
      if (action === "open") return b.summonBarWidget(id) === true
      if (action === "close") return b.hideBarWidget(id) === true
      return (b.isBarWidgetOpen(id) ? b.hideBarWidget(id) : b.summonBarWidget(id)) === true
    }
    if (action === "isOpen") return root.opened
    if (action === "open") root.open()
    else if (action === "close") root.close()
    else root.toggle()
    return true
  }

  IpcHandler {
    target: "omeetingbar-agenda"

    function open(): string {
      return root.routeToFocused("open") ? "ok" : "unavailable"
    }

    function close(): string {
      return root.routeToFocused("close") ? "ok" : "unavailable"
    }

    function toggle(): string {
      if (!root.routeToFocused("toggle")) return "unavailable"
      return root.routeToFocused("isOpen") ? "open" : "closed"
    }

    function isOpen(): string {
      return root.routeToFocused("isOpen") ? "true" : "false"
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    tooltipText: root.tooltipText
    // Every meeting in the list is colour-coded: orange once it is running,
    // turquoise while it is still ahead. warn_minutes keeps its job by driving
    // the brightness — full strength inside the window, slightly held back
    // outside it — so "soon" is still readable at a glance.
    active: root.hasEvent
    activeColor: root.runningNow
      ? root.runningColor
      : (root.urgent ? root.upcomingColor : Util.alpha(root.upcomingColor, 0.75))
    dimmed: root.degraded || !root.hasEvent
    fontSize: root.vertical ? Style.bar.iconFont : Style.font.body
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    // Left click opens the agenda, right and middle refresh. No click opens
    // the fullscreen alert. Triggering that by hand is pointless: it exists to
    // interrupt someone who is NOT looking at the bar, and whoever just
    // clicked the bar has already seen the meeting. `preview` stays available
    // over IPC as a diagnostic. Joining is a row (and a footer action) in the
    // popup now, so a mis-click can no longer throw a browser window at you.
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
      else root.requestRefresh()
    }
  }
}
