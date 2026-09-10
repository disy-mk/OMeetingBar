import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Next-meeting label for the bar.
//
// Reads the two files the rest of the plugin owns — the event cache the
// fetcher writes and the user's meetings.json — rather than talking to
// Service.qml, so the bar keeps painting while the service is reloading and
// says so honestly when there is nothing to read.
//
// Left click joins the meeting when the cache carries a URL and otherwise
// previews the fullscreen alert, right click always previews it, middle click
// asks for a fresh fetch.
BarWidget {
  id: root
  moduleName: "c51.meetings"

  // The host injects moduleName; the literal is the fallback for the bare
  // instantiation the bar-widget contract allows.
  readonly property string pluginId: moduleName || "c51.meetings"

  // ---- Paths. The cache is on tmpfs on purpose, so it is legitimately
  //      absent after a reboot until the first fetch lands.
  readonly property string runtimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string cacheDir: runtimeDir === "" ? "" : runtimeDir + "/omarchy-meetings"
  readonly property string cachePath: cacheDir === "" ? "" : cacheDir + "/events.json"
  readonly property string configPath: String(Quickshell.env("HOME") || "") + "/.config/omarchy/meetings.json"

  // ---- Config. Three layers, most specific first: the inline shell.json
  //      entry the bar settings UI writes, then meetings.json's `widget`
  //      block, then these defaults. Every layer tolerates junk.
  property var fileConfig: ({})
  readonly property var fileWidget: Util.isPlainObject(fileConfig.widget) ? fileConfig.widget : ({})

  readonly property int warnMinutes: numberOption("warn_minutes", fileWidget.warn_minutes, 15, 0, 1440)
  readonly property int maxTitleChars: numberOption("max_title_chars", fileWidget.max_title_chars, 28, 4, 200)
  readonly property bool hideWhenEmpty: boolOption("hide_when_empty", fileWidget.hide_when_empty, true)
  readonly property int autoDismissSeconds: {
    var n = Number(fileConfig.auto_dismiss_seconds)
    return isFinite(n) && n >= 0 ? Math.round(n) : 90
  }

  // ---- Cache state. "unknown" until the first read resolves, so a present
  //      cache never flashes the placeholder on startup.
  property string cacheState: "unknown"
  property string cacheError: ""
  // Degraded-but-usable: the fetcher ran on fallback values (e.g. a typo in
  // meetings.json). Separate from cacheError, which belongs to status "error".
  property string cacheWarning: ""
  property bool cacheStale: false
  property real cacheGeneratedAt: 0
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

  // A meeting still running is what the user wants to see, so the window is
  // "not over yet" rather than "not started yet". This is the shared
  // definition of "next event" — Service.qml, Alert.qml and the fetcher use
  // the same rule (end > now), so please do not "fix" it back to start > now.
  // Math.max keeps a zero-length occurrence (end == start, the documented
  // fallback) from being dropped before it has even begun.
  readonly property var upcoming: {
    var out = []
    for (var i = 0; i < events.length; i++) {
      if (Math.max(events[i].end, events[i].start) > nowSec) out.push(events[i])
    }
    return out
  }
  readonly property var nextEvent: upcoming.length > 0 ? upcoming[0] : null
  readonly property bool hasEvent: nextEvent !== null
  readonly property real secondsToStart: hasEvent ? nextEvent.start - nowSec : 0
  readonly property bool urgent: hasEvent && secondsToStart <= warnMinutes * 60

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

  readonly property string tooltipText: {
    if (runtimeMissing)
      return "Meetings: XDG_RUNTIME_DIR ist nicht gesetzt, der Termin-Cache ist nicht lesbar."
    if (pending) return ""

    var lines = []
    if (cacheState === "missing") {
      lines.push("Noch keine Termindaten.")
      lines.push("Der Kalender ist wahrscheinlich noch nicht verbunden — siehe README.")
      lines.push("Klick: jetzt aktualisieren")
      return lines.join("\n")
    }
    if (cacheState === "corrupt") {
      lines.push("Termin-Cache ist unlesbar.")
      lines.push(cachePath)
      lines.push("Klick: jetzt aktualisieren")
      return lines.join("\n")
    }
    if (cacheState === "error") {
      lines.push("Kalenderfehler: " + cacheError)
      if (cacheStale) lines.push("Angezeigt werden die letzten bekannten Termine.")
    }
    if (cacheWarning !== "")
      lines.push("Eingeschränkt: " + cacheWarning)
    if (cacheOutdated)
      lines.push("Daten sind " + minutesWord(Math.floor(cacheAge / 60)) + " alt — läuft der Meetings-Dienst?")
    if (!hasEvent) {
      lines.push("Kein Termin im Vorschauzeitraum.")
      lines.push("Klick: jetzt aktualisieren")
      return lines.join("\n")
    }

    lines.push(timeRange(nextEvent) + "  " + truncate(nextEvent.title, 64))
    var meta = []
    if (nextEvent.calendar !== "") meta.push(nextEvent.calendar)
    if (nextEvent.location !== "") meta.push(truncate(nextEvent.location, 48))
    if (meta.length > 0) lines.push(meta.join(" · "))
    lines.push(longCountdown(secondsToStart))

    if (upcoming.length > 1) {
      lines.push("Danach:")
      for (var i = 1; i < upcoming.length && i < 4; i++)
        lines.push(timeLabel(upcoming[i]) + "  " + truncate(upcoming[i].title, 40))
    }

    lines.push(nextEvent.url !== ""
      ? "Links: Meeting öffnen · Rechts: Vorschau · Mitte: aktualisieren"
      : "Links: Alarm-Vorschau · Mitte: aktualisieren")
    return lines.join("\n")
  }

  // A degraded cache stays visible even with hide_when_empty on: "no
  // calendar connected" — and equally "running on fallback settings" — is
  // something the user has to be able to see.
  visible: !pending && (degraded || hasWarning || hasEvent || !hideWhenEmpty)
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Option resolution

  function numberOption(key, fileValue, fallback, min, max) {
    var n = Number(setting(key, fileValue))
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.round(n)))
  }

  function boolOption(key, fileValue, fallback) {
    var value = setting(key, fileValue)
    if (value === undefined || value === null) return fallback
    if (typeof value === "boolean") return value
    var s = String(value).toLowerCase()
    if (s === "true" || s === "1" || s === "yes" || s === "on") return true
    if (s === "false" || s === "0" || s === "no" || s === "off") return false
    return fallback
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

  function timeLabel(event) {
    return event.allDay ? "ganztägig" : clockTime(event.start)
  }

  function timeRange(event) {
    return event.allDay ? "ganztägig" : clockTime(event.start) + "–" + clockTime(event.end)
  }

  function shortCountdown(delta) {
    if (delta < -60) return "läuft"
    if (delta < 60) return "jetzt"
    var minutes = Math.floor(delta / 60)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    var rest = minutes % 60
    return rest > 0 ? hours + "h" + rest + "m" : hours + "h"
  }

  function longCountdown(delta) {
    if (delta < -60) return "Läuft seit " + minutesWord(Math.floor(-delta / 60)) + "."
    if (delta < 60) return "Beginnt jetzt."
    var minutes = Math.floor(delta / 60)
    if (minutes < 60) return "Beginnt in " + minutesWord(minutes) + "."
    return "Beginnt in " + Math.floor(minutes / 60) + " h " + (minutes % 60) + " min."
  }

  function minutesWord(minutes) {
    return minutes === 1 ? "1 Minute" : minutes + " Minuten"
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
      // meetings.json caught mid-edit: fall back to the built-in defaults
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
    for (var i = 0; i < list.length && out.length < 64; i++) {
      var raw = list[i]
      if (!Util.isPlainObject(raw)) continue
      var start = Number(raw.start)
      if (!isFinite(start)) continue
      // The fetcher owns the duration; nothing here invents one. A missing or
      // reversed end simply collapses to the start (a zero-length occurrence),
      // which the upcoming filter still shows until its start has passed.
      var end = Number(raw.end)
      if (!isFinite(end) || end < start) end = start
      out.push({
        id: String(raw.id || ""),
        title: collapse(raw.title) || "Ohne Titel",
        start: start,
        end: end,
        allDay: raw.all_day === true,
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
    return /^https:\/\/[^\s]+$/i.test(url) ? url : ""
  }

  function collapse(value) {
    return String(value || "").replace(/\s+/g, " ").trim()
  }

  function shortError(value) {
    return truncate(collapse(value), 140)
  }

  // ---- Actions

  function join(url) {
    var target = httpsUrl(url)
    if (target === "") return
    Quickshell.execDetached(["omarchy-launch-browser", target])
  }

  function requestRefresh() {
    Quickshell.execDetached(["omarchy-shell", "meetings", "refresh"])
  }

  // The plugin declares the overlay kind, so shell.summon routes the payload
  // to Alert.qml instead of back into this widget, and nothing is marked as
  // fired — which is exactly what a preview is. The IPC call is the fallback
  // for a widget instantiated without the bar facade.
  function previewAlert() {
    if (!hasEvent) {
      requestRefresh()
      return
    }
    var payload = {
      title: nextEvent.title,
      start: nextEvent.start,
      end: nextEvent.end,
      url: nextEvent.url,
      calendar: nextEvent.calendar,
      location: nextEvent.location,
      auto_dismiss: autoDismissSeconds,
      test: false
    }
    if (bar && bar.shell && typeof bar.shell.summon === "function"
      && bar.shell.summon(pluginId, JSON.stringify(payload))) return
    Quickshell.execDetached(["omarchy-shell", "meetings", "preview"])
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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText
    tooltipText: root.tooltipText
    active: root.urgent
    dimmed: root.degraded || !root.hasEvent
    fontSize: root.vertical ? Style.bar.iconFont : Style.font.body
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.requestRefresh()
      else if (b === Qt.RightButton) root.previewAlert()
      else if (root.hasEvent && root.nextEvent.url !== "") root.join(root.nextEvent.url)
      else if (root.hasEvent) root.previewAlert()
      else root.requestRefresh()
    }
  }
}
