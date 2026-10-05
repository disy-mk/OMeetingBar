import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Days.js" as Days
import "Providers.js" as Providers
import "Strings.js" as Strings

// The agenda popup: today's and tomorrow's meetings under a timeline strip.
//
// Not a plugin entry point. Widget.qml loads this file with a Loader and
// injects the data plus the item to anchor the card against, the same way the
// first-party clock and weather widgets host their panels. This file renders
// and navigates; every effect on the outside world goes back through the host
// (join, openUrl, requestRefresh), so exactly one file in the plugin talks to
// a browser or to the service.
//
// The surface is Ui.KeyboardPanel — it owns the card, the border, the fade,
// the outside-click dismissal, the per-output dismissal twins and the focus
// prime, so none of that is written here.
Item {
  id: root

  // ---- Injected by Widget.qml (Loader + injectPanel/injectData).
  //      Every one of them has a default, so this file also renders on its
  //      own: an empty agenda on a healthy cache.
  property QtObject bar: null
  property Item anchorItem: null
  // The bar-widget root. It is also the popup's identity towards the bar:
  // the open-panel dot and switchPanelFrom both compare against the item
  // mounted in the bar slot, which is the widget and not this object.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The whole two-day agenda — finished and declined occurrences included
  // (invariant 5). Already parsed, validated and sorted by start.
  property var events: []
  // The alertable view of the same list (invariant 1: first event with
  // max(end, start) > now, no all-day, no declined; while one is running, one
  // starting within warn_minutes takes over). The bar label speaks for this
  // one, so the hero has to as well or the panel contradicts the bar.
  property var nextEvent: null
  property real nowSec: Math.floor(fallbackClock.date.getTime() / 1000)
  property string runningColor: "#FF9500"
  property string upcomingColor: "#00BEFF"
  property string cacheState: "ok"
  property string cacheError: ""
  property string cacheWarning: ""
  property bool cacheStale: false
  property bool cacheOutdated: false
  property bool degraded: false
  property bool pending: false
  // UI language, resolved by the widget from omeetingbar.json and the session
  // locale. The default only matters when this file renders on its own.
  property string lang: Strings.pick("", Qt.locale().name)
  readonly property var uiLocale: Qt.locale(Strings.localeName(lang))

  // Not pushed by the host, so it is derived rather than injected: the widget
  // already resolved it out of omeetingbar.json and the bar's layout entry, and
  // the popup must not invent a second answer.
  readonly property int warnMinutes: {
    var value = hostWidget ? Number(hostWidget.warnMinutes) : NaN
    return isFinite(value) ? Math.max(0, value) : 15
  }

  // ---- Lifecycle. The popup owns the open state; Widget.qml forwards
  //      opened/open/close/toggle/closeForPopoutSwitch to it, which is what
  //      the bar's panel contract needs to see on the widget.
  property bool opened: false
  property bool popoutSwitchClosing: false

  function open() {
    if (root.opened) return
    root.resetCursor()
    root.opened = true
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Bar.requestPopout prefers this over close() when the user clicks a
  // different bar icon, and KeyboardPanel reads popoutSwitchClosing back off
  // its owner to skip the fade.
  function closeForPopoutSwitch() {
    root.popoutSwitchClosing = true
    root.close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: {
    if (root.opened) return
    root.cursorActive = false
    agendaScroll.contentY = 0
  }

  onEventsChanged: Qt.callLater(root.clampCursor)

  // ---- Palette. Content colour comes from the bar, the card surface from
  //      Color.popups.* (KeyboardPanel paints that itself).
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar && String(bar.fontFamily) !== "" ? bar.fontFamily : Style.font.family
  readonly property color mutedFg: Qt.darker(fg, 1.4)
  readonly property color metaFg: Qt.darker(fg, 1.5)
  readonly property color faintFg: Qt.darker(fg, 1.9)
  readonly property color hoverFill: Style.hoverFillFor(fg, Color.accent)
  readonly property color currentFill: Style.selectedFillFor(fg, Color.accent)
  readonly property color trackFill: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  // The now-marker is theme chrome, not one of the plugin's two signal
  // colours — those keep meaning "meeting state" and nothing else.
  readonly property color nowColor: Style.selectedStateColor(fg, Color.accent)

  // ---- Glyphs. Every codepoint verified present in
  //      /usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf.
  readonly property string glyphCalendar: "󰃭"                 // md-calendar U+F00ED
  readonly property string glyphAlert: "󰀦"                    // md-alert U+F0026
  readonly property string glyphChevron: "󰅂"                  // md-chevron_right U+F0142
  readonly property string glyphRefresh: "󰑐"                  // md-refresh U+F0450
  readonly property string glyphCalendarPlus: "󰃳"             // md-calendar_plus U+F00F3
  readonly property string glyphOpenExternal: "󰏌"             // md-open_in_new U+F03CC
  readonly property string glyphVideo: "󰕧"                    // md-video U+F0567
  // Provider marks and brand colours live in Providers.js, shared with Alert.qml.
  // The card surface they have to stand out against:
  readonly property color surfaceBg: Color.popups.background

  // ---- Time. A day starts at its first local instant (Days.dayStart, the
  //      fetcher's _local_epoch), never at midnight + n * 86400: Europe/Berlin
  //      has a 23 h and a 25 h day each year, and some zones switch DST at
  //      midnight itself, where a plain Date(y, m, d) lands an hour off.
  readonly property real todayStartSec: dayStartSec(0)
  readonly property real tomorrowStartSec: dayStartSec(1)
  readonly property real dayAfterStartSec: dayStartSec(2)
  // Quantised to the hour on purpose: the timeline window, its ticks and its
  // lane packing hang off this, so they are rebuilt once an hour instead of
  // once a second. Only the colours and the now-marker read nowSec directly.
  readonly property real nowHourStart: floorHourSec(nowSec)

  // Changes when the session's time zone does: omarchy-menu-timezone switches
  // it under a running shell. Every formatter that turns an instant into
  // wall-clock text reads it (clockTime, dayShort, dayLabel, laterTime), so a
  // row — whose own inputs never change — re-renders in the new zone instead
  // of keeping the old times until its section's content changes. The offsets
  // of today and of every day lookahead_minutes can reach (30 days), so two
  // zones that agree today but switch DST on different dates still differ,
  // and the zone's abbreviation, for two that switch on the same date at
  // different hours (Havana's CDT and New York's EDT); the price is one
  // harmless re-render a day while a DST switch lies inside that window, as
  // the sample that crosses it changes.
  readonly property string zoneKey: {
    var parts = [Qt.formatDateTime(new Date(root.nowSec * 1000), "t")]
    for (var day = 0; day <= 31; day++)
      parts.push(new Date((root.nowSec + day * 86400) * 1000).getTimezoneOffset())
    return parts.join("/")
  }

  function dayStartSec(offset) {
    return Days.dayStart(root.nowSec, offset)
  }

  // Subtract the wall-clock minutes and seconds instead of setMinutes(0):
  // on the DST fall-back night 02:xx exists twice, and setMinutes resolves to
  // the later instant — an hour off, which hid the now-marker once a year.
  function floorHourSec(sec) {
    var d = new Date(sec * 1000)
    return Math.floor(sec - (d.getMinutes() * 60 + d.getSeconds()))
  }

  function ceilHourSec(sec) {
    var floored = floorHourSec(sec)
    return floored >= sec ? floored : floored + 3600
  }

  // ---- Sections. A half-open day: an occurrence that ends exactly at
  //      midnight belongs to the day it started in, or every all-day entry
  //      would be listed under HEUTE and under MORGEN. A meeting that runs
  //      across midnight legitimately appears in both.
  readonly property var todayEvents: eventsInDay(todayStartSec, tomorrowStartSec)
  readonly property var tomorrowEvents: eventsInDay(tomorrowStartSec, dayAfterStartSec)
  readonly property bool hasAgenda: todayEvents.length > 0 || tomorrowEvents.length > 0

  // Beyond tomorrow: the next few meetings inside the fetcher's window, so the
  // popup answers "what is next" even when today and tomorrow are empty — on a
  // Friday evening the answer is Monday morning. Capped on purpose: this is a
  // two-day agenda plus a glance ahead, not a month view.
  readonly property int laterMax: 5
  readonly property var laterEvents: {
    var out = []
    for (var i = 0; i < root.events.length && out.length < root.laterMax; i++) {
      var ev = root.events[i]
      var start = Number(ev.start)
      if (!isFinite(start) || start < root.dayAfterStartSec) continue
      out.push(ev)
    }
    return out
  }
  readonly property bool hasLater: laterEvents.length > 0

  function eventsInDay(fromSec, toSec) {
    var out = []
    for (var i = 0; i < root.events.length; i++) {
      var ev = root.events[i]
      var start = Number(ev.start)
      if (!isFinite(start)) continue
      var end = Number(ev.end)
      if (!isFinite(end) || end < start) end = start
      if (start >= toSec) continue
      if (end <= fromSec && start < fromSec) continue
      out.push(ev)
    }
    return out
  }

  function timedOnly(list) {
    var out = []
    for (var i = 0; i < list.length; i++) if (list[i].allDay !== true) out.push(list[i])
    return out
  }

  // ---- Timeline model. The strip is a clock for one day: today's timed
  //      meetings, or tomorrow's once today has none left to show.
  readonly property int stripLaneHeight: Style.space(6)
  readonly property int stripLaneGap: Style.space(4)
  readonly property int stripMaxLanes: 3

  readonly property var stripSource: {
    var today = timedOnly(root.todayEvents)
    // dayStart/dayEnd clip the rail to the day it stands for (see stripWindow).
    if (today.length > 0)
      return { events: today, today: true, dayStart: root.todayStartSec, dayEnd: root.tomorrowStartSec }
    return { events: timedOnly(root.tomorrowEvents), today: false,
      dayStart: root.tomorrowStartSec, dayEnd: root.dayAfterStartSec }
  }

  readonly property var stripWindow: {
    var list = root.stripSource.events
    var lo = NaN
    var hi = NaN
    for (var i = 0; i < list.length; i++) {
      var start = Number(list[i].start)
      if (!isFinite(start)) continue
      var end = Number(list[i].end)
      if (!isFinite(end) || end < start) end = start
      if (!isFinite(lo) || start < lo) lo = start
      if (!isFinite(hi) || end > hi) hi = end
    }
    // Seeded from the list rather than from its first entry, so one unusable
    // timestamp cannot turn the whole window into NaN.
    if (!isFinite(lo)) return { start: 0, end: 0 }
    // Clip the seeds to the day the rail stands for: a timed Monday-to-
    // Wednesday event is listed on Tuesday, but its Monday start must not pin
    // the rail to a day nobody is looking at.
    lo = Math.max(lo, root.stripSource.dayStart)
    hi = Math.min(hi, root.stripSource.dayEnd)
    if (!(hi > lo)) hi = lo + 3600
    // A rail is only a clock if "now" is on it.
    if (root.stripSource.today) {
      lo = Math.min(lo, root.nowHourStart)
      hi = Math.max(hi, root.nowHourStart + 3600)
    }
    lo = floorHourSec(lo)
    hi = ceilHourSec(hi)
    var span = hi - lo
    if (span < 4 * 3600) hi = lo + 4 * 3600
    else if (span > 14 * 3600) {
      // Too long a day for one rail. Today's keeps "now" with an hour before it
      // and lets the morning fall off the left edge — but never shifts so far
      // right that the marker goes with it: at 07:10 with meetings at 07:30
      // and 21:00 the rail runs 07:00–21:00, and the 21:00 meeting, which
      // starts at the rail's end, is the one left off it (its row lists it).
      // Tomorrow's has no now and keeps its start.
      if (root.stripSource.today) {
        lo = Math.max(lo, Math.min(root.nowHourStart - 3600, hi - 14 * 3600))
        hi = lo + 14 * 3600
      } else {
        hi = lo + 14 * 3600
      }
    }
    return { start: lo, end: hi }
  }

  readonly property real stripStartSec: stripWindow.start
  readonly property real stripEndSec: stripWindow.end
  readonly property real stripSpanSec: Math.max(1, stripEndSec - stripStartSec)

  // An integer model: each delegate derives its own position from `index`,
  // so the notch row never allocates an array. (It was once suspected of
  // rebuilding delegates on every evaluation; measured on Qt 6.11 that is not
  // what happens — a var array with equal content does not rebuild a Repeater.
  // The loop that was actually observed came from the hour LABELS row, see the
  // strip below.)
  //
  // Read off stripWindow itself, not off stripStartSec/stripEndSec: those are
  // two bindings, and when the window changes one is re-evaluated before the
  // other. Measured: a rail going empty (a day change, the last timed meeting
  // removed) showed this count a start of 0 beside the old end, half a million
  // notches, and the Repeater below froze the shell creating them. 15 is a
  // 14-hour rail's worth, the most there can be.
  readonly property int stripTickCount: {
    var win = root.stripWindow
    if (!(win.end > win.start)) return 0
    return Math.min(15, Math.floor((win.end - win.start) / 3600) + 1)
  }

  function tickSec(index) {
    return root.stripStartSec + index * 3600
  }

  function tickFraction(index) {
    return (root.tickSec(index) - root.stripStartSec) / root.stripSpanSec
  }

  // Greedy lane packing, capped at three lanes: a fourth simultaneous meeting
  // joins the lane that frees up first rather than growing the strip.
  readonly property var stripBars: {
    var out = []
    if (root.stripEndSec <= root.stripStartSec) return out
    var list = root.stripSource.events
    var lanes = []
    for (var i = 0; i < list.length; i++) {
      var ev = list[i]
      var start = Number(ev.start)
      if (!isFinite(start)) continue
      var end = Number(ev.end)
      if (!isFinite(end) || end < start) end = start
      // Half-open, like the sections: a meeting that ended exactly at the
      // rail's start is not on it (it drew as a stub at the left edge), one
      // that starts at the rail's end is not either.
      if (start >= root.stripEndSec || (end <= root.stripStartSec && start < root.stripStartSec)) continue

      var lane = -1
      for (var l = 0; l < lanes.length; l++) {
        if (lanes[l] <= start) { lane = l; break }
      }
      if (lane < 0 && lanes.length < root.stripMaxLanes) {
        lane = lanes.length
        lanes.push(end)
      } else if (lane < 0) {
        lane = 0
        for (var k = 1; k < lanes.length; k++) if (lanes[k] < lanes[lane]) lane = k
        lanes[lane] = Math.max(lanes[lane], end)
      } else {
        lanes[lane] = end
      }

      var from = Math.max(0, Math.min(1, (start - root.stripStartSec) / root.stripSpanSec))
      var to = Math.max(from, Math.min(1, (end - root.stripStartSec) / root.stripSpanSec))
      out.push({ lane: lane, from: from, to: to, start: start, end: end, declined: ev.declined === true })
    }
    return out
  }

  readonly property int stripLaneCount: {
    var used = 0
    for (var i = 0; i < root.stripBars.length; i++) used = Math.max(used, root.stripBars[i].lane + 1)
    return Math.max(1, used)
  }

  // ---- Hero
  readonly property bool hasNext: nextEvent !== null && nextEvent !== undefined
  readonly property real nextStartSec: hasNext ? Number(nextEvent.start) : 0

  readonly property string heroTitle: {
    if (root.pending) return Strings.t(root.lang, "loading")
    if (root.hasNext) return String(root.nextEvent.title || Strings.t(root.lang, "untitled"))
    if (root.degraded) return Strings.t(root.lang, "noData")
    // The alertable view is empty, but the agenda underneath may well list the
    // day: "no meetings" over four finished rows read as a contradiction.
    return root.hasAgenda ? Strings.t(root.lang, "noUpcoming") : Strings.t(root.lang, "noMeetings")
  }

  function countPhrase(n) {
    return Strings.count(root.lang, n, "oneMeeting", "nMeetings")
  }

  readonly property string heroMeta: {
    if (root.pending) return ""
    if (!root.hasNext) {
      if (root.degraded) return ""
      if (!root.hasAgenda) return Strings.t(root.lang, "noneTodayTomorrow")
      return countPhrase(root.todayEvents.length) + " " + Strings.t(root.lang, "today") + " · "
        + (root.tomorrowEvents.length > 0
          ? countPhrase(root.tomorrowEvents.length) + " " + Strings.t(root.lang, "tomorrow")
          : Strings.t(root.lang, "noneTomorrow"))
    }
    var parts = []
    // A meeting already under way needs no day in front: its countdown says
    // how long it has been running, and the bar label still names the day.
    var prefix = root.nextStartSec > root.nowSec ? dayPrefixFor(root.nextStartSec) : ""
    if (prefix !== "") parts.push(prefix)
    if (root.nextEvent.allDay === true) {
      parts.push(Strings.t(root.lang, "allDay"))
    } else {
      parts.push(heroRange(root.nextEvent))
      // One elided line in capitals: with a day in front the minutes went to
      // the ellipsis ("TOMORROW · 10:00–10:30 · IN 14 H 3…"), so a meeting on
      // another day gets the coarse countdown — the bar's tooltip has the rest.
      parts.push(countdownPhrase(root.nextStartSec, prefix !== ""))
    }
    return parts.join(" · ")
  }

  readonly property string heroDetail: root.hasNext ? String(root.nextEvent.calendar || "") : ""

  // ---- Degraded state. Same strings the widget's tooltip uses, so the two
  //      never explain the same cache differently.
  readonly property var noticeLines: {
    var lines = []
    if (root.pending) {
      lines.push(Strings.t(root.lang, "reading"))
      return lines
    }
    if (root.cacheState === "missing") {
      lines.push(Strings.t(root.lang, "noDataYet"))
      lines.push(Strings.t(root.lang, "notConnected"))
    } else if (root.cacheState === "corrupt") {
      lines.push(Strings.t(root.lang, "cacheUnreadable"))
    } else if (root.cacheState === "error") {
      lines.push(Strings.t(root.lang, "calendarError", root.cacheError))
      if (root.cacheStale) lines.push(Strings.t(root.lang, "lastKnown"))
    } else if (root.degraded) {
      lines.push(Strings.t(root.lang, "dataUnreadable"))
    }
    if (root.cacheWarning !== "") lines.push(Strings.t(root.lang, "limited", root.cacheWarning))
    if (root.cacheOutdated) lines.push(Strings.t(root.lang, "dataOutdated"))
    return lines
  }

  readonly property bool showEmptyMessage: !pending && !degraded && !hasAgenda

  // ---- Cursor. One model for mouse and keyboard: hover moves the cursor,
  //      rows only ever read hasCursor/current, so there is never a second
  //      highlight on screen.
  property bool cursorActive: false
  property string focusSection: "today"
  property int selectedIndex: 0
  // Only a keyboard move scrolls; a hover must not pull the row out from
  // under the pointer.
  property bool cursorFromKeyboard: false

  readonly property var cursorSections: {
    var out = []
    if (root.todayEvents.length > 0) out.push("today")
    if (root.tomorrowEvents.length > 0) out.push("tomorrow")
    if (root.laterEvents.length > 0) out.push("later")
    out.push("footer")
    return out
  }

  function sectionCount(name) {
    if (name === "today") return root.todayEvents.length
    if (name === "tomorrow") return root.tomorrowEvents.length
    if (name === "later") return root.laterEvents.length
    if (name === "footer") return root.footerActions.length
    return 0
  }

  // A keyboard move asks for exactly one reveal, consumed by the row that
  // becomes selected. Without the token every Repeater rebuild under an open
  // popup (a cache rewrite, midnight) re-selected the remembered row while the
  // Column had not positioned it yet and scrolled the view to its section
  // header instead.
  property bool revealPending: false

  function setCursor(section, index, fromKeyboard) {
    var keyboard = fromKeyboard === true
    root.cursorFromKeyboard = keyboard
    // The token is armed before the selection it is meant for and cleared
    // right after it, so only the row this call selects can consume it: armed
    // after, it was still pending when that row had already been selected —
    // the first j revealed nothing, and the next hover scrolled the list away
    // from under the pointer instead.
    root.revealPending = keyboard
    // A stationary pointer must not win the cursor back when the list
    // scrolls under it — Qt re-delivers hover to whatever slides underneath.
    if (keyboard) pointerGate.reset()
    // Written as one transition: with cursorActive kept on, the first write
    // (focusSection) briefly selected the row with the OLD index in the new
    // section, and a scroll followed that phantom selection.
    root.cursorActive = false
    root.focusSection = section
    root.selectedIndex = index
    root.cursorActive = true
    root.revealPending = false
  }

  function moveCursor(delta) {
    var sections = root.cursorSections
    var sectionIndex = sections.indexOf(root.focusSection)
    if (sectionIndex < 0) {
      setCursor(sections[0], 0, true)
      return
    }
    var count = sectionCount(root.focusSection)
    var next = root.selectedIndex + (delta > 0 ? 1 : -1)
    if (next >= 0 && next < count) {
      setCursor(root.focusSection, next, true)
      return
    }
    if (delta > 0) {
      if (sectionIndex + 1 < sections.length) setCursor(sections[sectionIndex + 1], 0, true)
      else setCursor(root.focusSection, Math.max(0, count - 1), true)
      return
    }
    if (sectionIndex > 0) {
      var previous = sections[sectionIndex - 1]
      setCursor(previous, Math.max(0, sectionCount(previous) - 1), true)
    } else {
      setCursor(root.focusSection, 0, true)
    }
  }

  // open() starts here. The gate starts over too: still primed from the last
  // session, the hover that a pointer resting where the join row maps delivers
  // on open selected that row, and Enter joined the meeting.
  function resetCursor() {
    var sections = root.cursorSections
    root.focusSection = sections.length > 0 ? sections[0] : "footer"
    root.selectedIndex = 0
    root.cursorActive = false
    root.cursorFromKeyboard = false
    root.revealPending = false
    pointerGate.reset()
  }

  // The agenda is rewritten under an open popup on every fetch, so the cursor
  // has to survive a list that got shorter.
  function clampCursor() {
    var sections = root.cursorSections
    if (sections.indexOf(root.focusSection) < 0) {
      root.focusSection = sections[sections.length - 1]
      root.selectedIndex = 0
      return
    }
    var count = sectionCount(root.focusSection)
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, count - 1))
  }

  function activateCursor() {
    if (root.focusSection === "footer") {
      footerActivate(root.selectedIndex)
      return
    }
    var list = root.focusSection === "today" ? root.todayEvents
      : (root.focusSection === "later" ? root.laterEvents : root.tomorrowEvents)
    if (root.selectedIndex >= 0 && root.selectedIndex < list.length) joinEvent(list[root.selectedIndex])
  }

  function revealItem(item) {
    if (!item) return
    var top = item.mapToItem(agendaColumn, 0, 0).y
    var bottom = top + item.height
    var limit = Math.max(0, agendaScroll.contentHeight - agendaScroll.height)
    if (top < agendaScroll.contentY)
      agendaScroll.contentY = Math.max(0, Math.min(limit, top - Style.space(8)))
    else if (bottom > agendaScroll.contentY + agendaScroll.height)
      agendaScroll.contentY = Math.max(0, Math.min(limit, bottom - agendaScroll.height + Style.space(8)))
  }

  // ---- Footer actions. One model, so the keyboard cursor and the rendered
  //      rows can never disagree about what is where.
  readonly property string joinUrl: hasNext ? httpsUrl(nextEvent.url) : ""
  readonly property string eventEditUrl: "https://calendar.google.com/calendar/u/0/r/eventedit"
  readonly property string calendarUrl: "https://calendar.google.com/"

  readonly property var footerActions: [
    {
      key: "join",
      label: root.joinUrl === "" ? Strings.t(root.lang, "noJoinLink")
        : (Providers.name(root.joinUrl) !== ""
          ? Strings.t(root.lang, "joinVia", Providers.name(root.joinUrl))
          : Strings.t(root.lang, "openMeeting")),
      icon: root.joinUrl !== "" ? Providers.glyph(root.joinUrl) : root.glyphVideo,
      enabled: root.joinUrl !== ""
    },
    { key: "create", label: Strings.t(root.lang, "createEvent"), icon: root.glyphCalendarPlus, enabled: true },
    { key: "refresh", label: Strings.t(root.lang, "refreshNow"), icon: root.glyphRefresh, enabled: true },
    { key: "calendar", label: Strings.t(root.lang, "openCalendar"), icon: root.glyphOpenExternal, enabled: true }
  ]

  function footerActivate(index) {
    var action = root.footerActions[index]
    if (!action || action.enabled !== true) return
    if (action.key === "join") joinEvent(root.nextEvent)
    else if (action.key === "create") openExternal(root.eventEditUrl)
    else if (action.key === "refresh") requestRefresh()
    else if (action.key === "calendar") openExternal(root.calendarUrl)
  }

  // ---- Actions. The host owns every external effect; this file only asks.
  function joinEvent(ev) {
    if (!ev) return
    var url = httpsUrl(ev.url)
    if (url === "") return
    if (root.hostWidget && "join" in root.hostWidget) root.hostWidget.join(url)
    root.close()
  }

  function openExternal(url) {
    var target = httpsUrl(url)
    if (target === "") return
    if (root.hostWidget && "openUrl" in root.hostWidget) root.hostWidget.openUrl(target)
    root.close()
  }

  function requestRefresh() {
    if (root.hostWidget && "requestRefresh" in root.hostWidget) root.hostWidget.requestRefresh()
  }

  // Invariant 3, re-checked here as well: the cache is a user-writable file,
  // and neither file://, javascript: nor an argument with whitespace in it may
  // ever reach a browser command line — not even by way of the host.
  function httpsUrl(value) {
    var url = String(value || "").trim()
    return /^https:\/\/[^\s\\]+$/i.test(url) ? url : ""
  }

  // Brand colour of the row's provider, readable on this theme's card, or the
  // muted theme colour when the provider has none (or is not one we know).
  function providerColor(url) {
    var brand = Providers.brandColor(httpsUrl(url), root.surfaceBg)
    return brand !== "" ? Qt.color(brand) : root.mutedFg
  }

  // ---- Formatting. Dates follow the UI language (uiLocale), not the session
  //      locale; times stay 24 h in both, like Omarchy's own bar clock. The
  //      three functions that turn an instant into wall-clock text read
  //      zoneKey, so every binding that calls them follows a zone change.
  function clockTime(sec) {
    void root.zoneKey
    return Qt.formatTime(new Date(sec * 1000), "HH:mm")
  }

  // ISO 8601 week — what "KW" means in Germany: weeks start on Monday, week 1
  // is the one containing the first Thursday, so 29–31 December can be KW 1 and
  // 1–3 January KW 52/53. Computed in UTC from the local date parts so a DST
  // day cannot shift it. Qt has no formatDate token for it.
  function isoWeek(sec) {
    var d = new Date(sec * 1000)
    var date = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()))
    var day = date.getUTCDay() || 7
    date.setUTCDate(date.getUTCDate() + 4 - day)
    var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
    return Math.ceil(((date - yearStart) / 86400000 + 1) / 7)
  }

  function weekTag(sec) {
    return Strings.t(root.lang, "weekTag", isoWeek(sec))
  }

  function dayShort(sec) {
    void root.zoneKey
    return new Date(sec * 1000).toLocaleDateString(root.uiLocale, "ddd")
  }

  function dayLabel(sec) {
    void root.zoneKey
    return new Date(sec * 1000).toLocaleDateString(root.uiLocale, Strings.t(root.lang, "dateShort"))
  }

  // The hero's meta line is one elided row: "SO., 13. SEPT. · 10:15–12:45 ·
  // IN 2 TAGEN" lost its countdown to the ellipsis, so the day goes in here in
  // its short form (Days.dayPrefix, compact): "morgen", the weekday within six
  // days, and the date without its weekday beyond ("12. Okt."). The rows'
  // tooltips carry the full date.
  function dayPrefixFor(sec) {
    return Days.dayPrefix(root.lang, root.nowSec, sec, true)
  }

  // The hero's range: a meeting that ends on a later day at or after its start
  // time (a conference from Monday 09:00 to Thursday 17:00) shows its start
  // and "…", since "09:00–17:00" would read as one day's slot. An overnight
  // call keeps both times ("23:00–01:00"): an end before the start can only be
  // the next morning.
  function heroRange(ev) {
    var start = Number(ev.start)
    var end = Math.max(Number(ev.end), start)
    var days = Days.daysBetween(start, end)
    var from = new Date(start * 1000)
    var to = new Date(end * 1000)
    var endsLater = days > 1 || (days === 1
      && to.getHours() * 60 + to.getMinutes() >= from.getHours() * 60 + from.getMinutes())
    return endsLater && ev.allDay !== true ? clockTime(start) + "–…" : timeRangeText(ev)
  }

  // The DEMNÄCHST time column, 84 px wide: "So. 10:15" within six days.
  // Beyond, where a weekday alone would repeat, the date without its weekday
  // ("12. Okt.") and no time, which would not fit beside it (measured); the
  // row's tooltip has both.
  function laterTime(ev) {
    void root.zoneKey
    var start = Number(ev.start)
    var day = Days.dayPrefix(root.lang, root.nowSec, start, true)
    if (ev.allDay === true || Math.abs(Days.daysBetween(root.nowSec, start)) >= 7) return day
    return day + " " + clockTime(start)
  }

  // A meeting that runs past midnight is listed under both days, and each row
  // prints only its own day's part, with "…" at the cut — "23:00–…" under
  // HEUTE, "…–01:00" under MORGEN — so it no longer reads as a second call.
  // Without bounds (the hero, a DEMNÄCHST row) it is the whole range; a NaN
  // bound compares false and clips nothing.
  function timeRangeText(ev, dayStart, dayEnd) {
    if (ev.allDay === true) return Strings.t(root.lang, "allDay")
    var start = Number(ev.start)
    var end = Math.max(Number(ev.end), start)
    if (!(end > start)) return clockTime(start)
    return (start < dayStart ? "…" : clockTime(start)) + "–" + (end > dayEnd ? "…" : clockTime(end))
  }

  // The whole range, for a row's tooltip: the day at both ends when it runs
  // past midnight ("So., 11. Okt. 23:00 – Mo., 12. Okt. 01:00"), else the
  // row's own range, prefixed with its day where no section header names it.
  function fullRangeText(ev, withDay) {
    var start = Number(ev.start)
    var end = Math.max(Number(ev.end), start)
    if (ev.allDay !== true && end > Days.dayStart(start, 1))
      return dayLabel(start) + " " + clockTime(start) + " – " + dayLabel(end) + " " + clockTime(end)
    return (withDay ? dayLabel(start) + "  " : "") + timeRangeText(ev)
  }

  // Counted by Days.countdown, the bar's rule too: a meeting on a later
  // calendar day and 24 h or more away counts in calendar days, so "morgen
  // 20:00" read at 07:00 is "in 1 Tag". `coarse`, for the hero behind a day:
  // whole hours, and minutes in the alert's short words ("in 45 min").
  function countdownPhrase(startSec, coarse) {
    var parts = Days.countdown(root.nowSec, startSec)
    if (parts.phase === "now") return Strings.t(root.lang, "now")
    var running = parts.phase === "running"
    if (coarse === true && parts.unit === "minutes")
      return Strings.t(root.lang, running ? "runningForMin" : "inMin", parts.value)
    return Strings.t(root.lang, running ? "runningFor" : "inX",
      Days.spanText(root.lang, parts, coarse === true))
  }

  // The plugin's two signal colours, with exactly the meaning they carry in
  // the bar and in the alert: a meeting that has started is running, one that
  // has not is upcoming, and warn_minutes drives the brightness rather than
  // inventing a third colour. Mirrors Widget.qml's activeColor.
  function signalColor(startSec, endSec) {
    if (startSec <= root.nowSec && root.nowSec < endSec) return Qt.color(root.runningColor)
    if (startSec - root.nowSec <= root.warnMinutes * 60) return Qt.color(root.upcomingColor)
    return Util.alpha(root.upcomingColor, 0.75)
  }

  // Fallback only: the host pushes its own 1 Hz `nowSec` over this default,
  // and then nothing reads this clock. It stays enabled while the panel is
  // open all the same, so a popup that is rendered without a host — or before
  // the first push lands — still counts down instead of freezing at the epoch.
  // Filters synthetic hover churn from rows moving under a stationary pointer;
  // the shell's clipboard and menu surfaces use the same gate.
  PointerMoveGate {
    id: pointerGate
    referenceItem: agendaColumn
  }

  SystemClock {
    id: fallbackClock
    enabled: root.opened
    precision: SystemClock.Seconds
  }

  Component {
    id: heroIconComponent

    // Nerd-font glyphs have a single-cell advance but paint up to 15 px wide,
    // so every glyph in this file sits in a fixed-width centred box.
    OpticalGlyph {
      implicitWidth: Style.space(30)
      implicitHeight: Style.space(30)
      text: root.glyphCalendar
      fontFamily: root.fontFamily
      fontSize: Style.font.display
      color: root.fg
    }
  }

  Component {
    id: heroActionComponent

    PanelActionButton {
      iconText: root.glyphRefresh
      tooltipText: Strings.t(root.lang, "refreshNow")
      foreground: root.fg
      hoverColor: root.fg
      fontFamily: root.fontFamily
      onClicked: root.requestRefresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(agendaColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.setCursor(root.cursorSections[0], 0, true)
          return
        }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.requestRefresh() }

      Flickable {
        id: agendaScroll
        anchors.fill: parent
        contentWidth: agendaColumn.width
        contentHeight: agendaColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: agendaColumn

          HoverHandler {
            onPointChanged: pointerGate.moved(agendaColumn, point.position)
          }
          width: agendaScroll.width
          spacing: Style.space(14)

          // ---- Hero: the next meeting the bar is speaking for.
          PanelHero {
            width: parent.width
            title: root.heroTitle
            meta: root.heroMeta
            detail: root.heroDetail
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: heroIconComponent
            trailingControl: heroActionComponent
          }

          // ---- Timeline strip. The one element with no first-party
          //      equivalent, so it is assembled from in-tree idioms only: the
          //      clock panel's track rails, PanelSlider's fraction-positioned
          //      ticks notched in the card colour, and the theme accent for
          //      the now-marker.
          // Sizes come from the token scale and the lane count, rows are placed
          // by explicit y. Kept that way on purpose — it is cheap and it stays
          // legible — but note it is NOT what fixed the polish loop described at
          // the (missing) hour-labels row below.
          Item {
            id: strip
            width: parent.width
            visible: root.stripBars.length > 0
            readonly property real laneBlockHeight: root.stripLaneCount * root.stripLaneHeight
              + Math.max(0, root.stripLaneCount - 1) * root.stripLaneGap
            implicitHeight: laneBlockHeight

            Item {
              id: lanes
              x: 0
              y: 0
              width: strip.width
              height: strip.laneBlockHeight

              Repeater {
                model: root.stripLaneCount

                Rectangle {
                  required property int index
                  width: lanes.width
                  height: root.stripLaneHeight
                  y: index * (root.stripLaneHeight + root.stripLaneGap)
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  color: root.trackFill
                }
              }

              Repeater {
                model: root.stripTickCount

                Rectangle {
                  required property int index
                  readonly property real fraction: root.tickFraction(index)
                  visible: fraction > 0.001 && fraction < 0.999
                  width: Math.max(1, Style.space(2))
                  height: lanes.height
                  color: Color.popups.background
                  x: Math.round(lanes.width * fraction - width / 2)
                }
              }

              Repeater {
                model: root.stripBars

                Rectangle {
                  required property var modelData
                  readonly property bool finished: modelData.end <= root.nowSec
                  y: modelData.lane * (root.stripLaneHeight + root.stripLaneGap)
                  // A five-minute meeting has to stay visible, and a bar may
                  // never paint past the end of its rail.
                  width: Math.max(Style.space(3), Math.round(lanes.width * (modelData.to - modelData.from)))
                  x: Math.max(0, Math.min(lanes.width - width, Math.round(lanes.width * modelData.from)))
                  height: root.stripLaneHeight
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  opacity: modelData.declined ? 0.45 : 1.0
                  color: finished ? Util.alpha(root.fg, 0.18) : root.signalColor(modelData.start, modelData.end)

                  Behavior on width {
                    NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                  }
                }
              }

              Rectangle {
                id: nowMarker
                visible: root.nowSec >= root.stripStartSec && root.nowSec <= root.stripEndSec
                width: Math.max(1, Style.space(2))
                height: lanes.height + Style.space(4)
                y: -Style.space(2)
                x: Math.round(lanes.width * Math.max(0, Math.min(1, (root.nowSec - root.stripStartSec) / root.stripSpanSec))
                  - width / 2)
                color: root.nowColor

                Behavior on x {
                  NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                }
              }
            }

            // NO HOUR NUMBERS, on purpose. Any Text in an hour-label row here —
            // even a constant string with no geometry of its own — drove the
            // shell into a polish loop: one core pinned and gigabytes of growth
            // for as long as the popup was open, with no binding-loop warning
            // from Qt. Bisected on the author's machine: notches in the lane
            // row are fine, a Rectangle in the label row is fine, a Text is not,
            // and neither an integer Repeater model, nor dropping the
            // self-referential x binding, nor explicit geometry instead of
            // sibling anchors changed it. Root cause not established; the
            // var-array and geometry-feedback hypotheses were both refuted by
            // measurement. Triage recipe if someone wants it back: watch for
            // Qt's "possible QQuickItem::polish() loop" warning and run
            // `perf top -p $(pgrep -x quickshell)` with the popup open. The
            // notches carry the hour grid; every row prints its own times.
          }

          PanelSeparator {
            visible: root.hasAgenda
            foreground: root.fg
          }

          Column {
            id: todaySection
            width: parent.width
            visible: root.hasAgenda
            spacing: Style.spacing.rowGap

            PanelSectionHeader {
              text: Strings.t(root.lang, "sectionToday") + " · " + root.dayLabel(root.todayStartSec).toUpperCase() + root.weekTag(root.todayStartSec)
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.todayEvents

              EventRow {
                required property var modelData
                required property int index
                width: todaySection.width
                ev: modelData
                rowIndex: index
                sectionName: "today"
                sectionStart: root.todayStartSec
                sectionEnd: root.tomorrowStartSec
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.todayEvents.length === 0
              width: parent.width
              text: Strings.t(root.lang, "noneTodayDot")
              color: root.metaFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: root.hasAgenda
            foreground: root.fg
          }

          Column {
            id: tomorrowSection
            width: parent.width
            visible: root.hasAgenda
            spacing: Style.spacing.rowGap

            PanelSectionHeader {
              text: Strings.t(root.lang, "sectionTomorrow") + " · " + root.dayLabel(root.tomorrowStartSec).toUpperCase() + root.weekTag(root.tomorrowStartSec)
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.tomorrowEvents

              EventRow {
                required property var modelData
                required property int index
                width: tomorrowSection.width
                ev: modelData
                rowIndex: index
                sectionName: "tomorrow"
                sectionStart: root.tomorrowStartSec
                sectionEnd: root.dayAfterStartSec
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.tomorrowEvents.length === 0
              width: parent.width
              text: Strings.t(root.lang, "noneTomorrowDot")
              color: root.metaFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: root.hasLater
            foreground: root.fg
          }

          // Only when there is something: an empty "Demnächst" would just
          // restate the fetcher's horizon.
          Column {
            id: laterSection
            width: parent.width
            visible: root.hasLater
            spacing: Style.spacing.rowGap

            PanelSectionHeader {
              text: Strings.t(root.lang, "sectionLater")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.laterEvents

              EventRow {
                required property var modelData
                required property int index
                width: laterSection.width
                ev: modelData
                rowIndex: index
                sectionName: "later"
                showDay: true
              }
            }
          }

          // ---- Degraded / empty. "Nothing on your calendar" and "your
          //      calendar could not be read" must never look alike.
          Item {
            id: notice
            width: parent.width
            visible: root.noticeLines.length > 0
            implicitHeight: Math.max(noticeGlyph.height, noticeText.implicitHeight)

            Item {
              id: noticeGlyph
              anchors.left: parent.left
              anchors.top: parent.top
              width: Style.space(18)
              height: Style.font.icon + Style.space(2)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.pending ? root.glyphCalendar : root.glyphAlert
                color: root.mutedFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
            }

            Text {
              id: noticeText
              anchors.left: noticeGlyph.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.top: parent.top
              textFormat: Text.PlainText
              text: root.noticeLines.join("\n")
              color: root.mutedFg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.showEmptyMessage
            width: parent.width
            text: Strings.t(root.lang, "noneTodayTomorrowDot")
            color: root.metaFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.fg
          }

          Column {
            id: footerSection
            width: parent.width
            spacing: Style.spacing.sm

            Repeater {
              model: root.footerActions

              Button {
                id: footerButton
                required property var modelData
                required property int index
                width: footerSection.width
                leftAlign: true
                text: modelData.label
                iconText: modelData.icon
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: modelData.enabled === true
                opacity: footerButton.enabled ? 1.0 : 0.45
                hasCursor: root.cursorActive && root.focusSection === "footer" && root.selectedIndex === footerButton.index
                onHasCursorChanged: {
                  if (!footerButton.hasCursor || !root.revealPending) return
                  root.revealPending = false
                  Qt.callLater(function() { root.revealItem(footerButton) })
                }
                // Ui.Button reports hover without a position; the card-wide
                // HoverHandler below primes the gate, so this only fires once
                // the pointer has really moved since the last keyboard step.
                onHovered: function(isHovered) {
                  if (isHovered && pointerGate.primed) root.setCursor("footer", footerButton.index, false)
                }
                onClicked: root.footerActivate(footerButton.index)
              }
            }
          }
        }
      }
    }
  }

  // One agenda row — time, provider glyph, title, chevron. The skeleton is
  // the bluetooth panel's DeviceRow: same height formula, same content
  // insets, same fixed-width leading column, same trailing control slot. A
  // plugin panel that invents its own row metrics stops looking like the
  // shell it lives in.
  component EventRow: CursorSurface {
    id: row

    required property var ev
    required property int rowIndex
    required property string sectionName
    // Rows beyond tomorrow show their day in the time column instead of a
    // range that would not say which day: "So. 10:00" within six days, the
    // date further out (laterTime).
    property bool showDay: false
    // The day this row is listed under, so a meeting that runs past midnight
    // prints only that day's part (timeRangeText). NaN: no day, nothing clipped.
    property real sectionStart: NaN
    property real sectionEnd: NaN

    readonly property real startSec: Number(row.ev.start)
    readonly property real endSec: Math.max(Number(row.ev.end), row.startSec)
    readonly property bool allDay: row.ev.allDay === true
    readonly property bool declined: row.ev.declined === true
    // Invariant 1 inverted: an occurrence is over when max(end, start) <= now,
    // which is also what keeps a zero-length entry listed until its start has
    // passed. An all-day entry has no moment to be past (invariant 4).
    readonly property bool finished: !row.allDay && row.endSec <= root.nowSec
    readonly property bool running: !row.allDay && row.startSec <= root.nowSec && root.nowSec < row.endSec
    readonly property string joinTarget: root.httpsUrl(row.ev.url)
    readonly property bool rowSelected: root.cursorActive
      && root.focusSection === row.sectionName
      && root.selectedIndex === row.rowIndex

    readonly property string rowTooltip: {
      var lines = [root.fullRangeText(row.ev, row.showDay)
        + "  " + String(row.ev.title || Strings.t(root.lang, "untitled"))]
      var meta = []
      if (String(row.ev.calendar || "") !== "") meta.push(String(row.ev.calendar))
      if (String(row.ev.location || "") !== "") meta.push(String(row.ev.location))
      if (meta.length > 0) lines.push(meta.join(" · "))
      if (row.declined) lines.push(Strings.t(root.lang, "declined"))
      if (row.joinTarget !== "")
        lines.push(Providers.name(row.joinTarget) !== ""
          ? Strings.t(root.lang, "clickJoinVia", Providers.name(row.joinTarget))
          : Strings.t(root.lang, "clickOpenMeeting"))
      return lines.join("\n")
    }

    // Visuals come from the panel's cursor model only, never from
    // containsMouse, or mouse and keyboard would light two rows at once.
    hasCursor: row.rowSelected
    current: row.running
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.currentFill
    opacity: row.finished ? 0.45 : 1.0
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    onRowSelectedChanged: {
      if (!row.rowSelected || !root.revealPending) return
      root.revealPending = false
      // Deferred: at handler time a freshly created row still reports y=0,
      // its real position arrives with the Column's polish.
      Qt.callLater(function() { root.revealItem(row) })
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: row.joinTarget !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor

      // Only a pointer that actually moved takes the cursor — not one a
      // keyboard scroll slid a new row underneath.
      onPositionChanged: function(mouse) {
        if (pointerGate.moved(rowMouse, mouse)) root.setCursor(row.sectionName, row.rowIndex, false)
      }
      onClicked: root.joinEvent(row.ev)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse
      text: row.rowTooltip
      fontFamily: root.fontFamily
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(timeText.implicitHeight, titleText.implicitHeight, providerSlot.height)

      Text {
        id: timeText
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(84)
        text: row.showDay
          ? root.laterTime(row.ev)
          : root.timeRangeText(row.ev, row.sectionStart, row.sectionEnd)
        // The signal colour sits in the time column, so the list carries the
        // same two meanings as the bar without shouting them in every title.
        color: row.finished || row.allDay ? root.mutedFg : root.signalColor(row.startSec, row.endSec)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: row.running
        font.strikeout: row.declined
        elide: Text.ElideRight
      }

      Item {
        id: providerSlot
        anchors.left: timeText.right
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        height: Style.font.icon + Style.space(2)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          visible: row.joinTarget !== ""
          text: Providers.glyph(row.joinTarget)
          // Brand colour, not state colour: the time column already says
          // running/upcoming, this column says where the meeting happens.
          color: root.providerColor(row.joinTarget)
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      Text {
        id: titleText
        textFormat: Text.PlainText
        anchors.left: providerSlot.right
        anchors.leftMargin: Style.space(6)
        anchors.right: chevronSlot.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        // Meeting titles are untrusted third-party input: PlainText, always.
        text: String(row.ev.title || Strings.t(root.lang, "untitled"))
        color: row.running ? Qt.color(root.runningColor) : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.running
        // Lowercase "o": strikeOut does not exist in QML, and strikeout
        // leaves implicitWidth alone, so a declined row does not reflow.
        font.strikeout: row.declined
        elide: Text.ElideRight
      }

      Item {
        id: chevronSlot
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        height: Style.font.icon + Style.space(2)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          // The chevron is the affordance for "this row joins something", so
          // it is only there when the occurrence carries a usable link.
          visible: row.joinTarget !== ""
          text: root.glyphChevron
          color: root.faintFg
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }
    }
  }
}
