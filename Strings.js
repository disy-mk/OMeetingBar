.pragma library

// Every user-facing string of the QML side, in German and English. The plugin
// follows the session locale (the shell process's, read as Qt.locale().name,
// which honours LANGUAGE) unless omeetingbar.json pins `language` to "de" or
// "en"; English is the fallback for every other locale. Keep the two blocks
// key-for-key identical with the same placeholders: a missing key falls back
// to English at runtime, and nothing in the repo checks this, so add every key
// to both blocks. "%1", "%2" are placeholders for t()'s extra arguments.
// bin/omeetingbar-fetch carries its own table for the messages it writes into
// the cache.

var table = {
  de: {
    // shared
    tomorrow: "morgen",
    allDay: "ganztägig",
    now: "jetzt",
    running: "läuft",
    untitled: "Ohne Titel",
    meeting: "Termin",
    oneMinute: "1 Minute",
    nMinutes: "%1 Minuten",
    oneMeeting: "1 Termin",
    nMeetings: "%1 Termine",
    oneDay: "1 Tag",
    nDays: "%1 Tagen",
    inX: "in %1",
    hoursMin: "%1 h %2 min",
    hoursOnly: "%1 h",
    runningFor: "läuft seit %1",
    dateShort: "ddd, d. MMM",
    weekTag: " (KW %1)",
    // bar widget
    clickHint: "Links: Agenda öffnen · Rechts/Mitte: aktualisieren",
    runtimeMissing: "OMeetingBar: XDG_RUNTIME_DIR ist nicht gesetzt, der Termin-Cache ist nicht lesbar.",
    noDataYet: "Noch keine Termindaten.",
    notConnected: "Der Kalender ist wahrscheinlich noch nicht verbunden – siehe README.",
    cacheUnreadable: "Termin-Cache ist unlesbar.",
    calendarError: "Kalenderfehler: %1",
    lastKnown: "Angezeigt werden die letzten bekannten Termine.",
    limited: "Eingeschränkt: %1",
    dataAge: "Daten sind %1 alt – läuft der OMeetingBar-Dienst?",
    noUpcomingDot: "Kein anstehender Termin.",
    agendaLists: "Die Agenda zeigt %1 (auch erledigte und abgelehnte).",
    runningForDot: "Läuft seit %1.",
    startsNow: "Beginnt jetzt.",
    startsIn: "Beginnt in %1.",
    // agenda popup
    loading: "Termine werden geladen …",
    noData: "Keine Termindaten",
    noUpcoming: "Kein anstehender Termin",
    noMeetings: "Keine Termine",
    noneTodayTomorrow: "keine Termine heute und morgen",
    today: "heute",
    noneTomorrow: "keine morgen",
    reading: "Termindaten werden gelesen …",
    dataUnreadable: "Termindaten sind nicht lesbar.",
    dataOutdated: "Termindaten sind veraltet – läuft der OMeetingBar-Dienst?",
    noJoinLink: "Kein Meeting-Link",
    joinVia: "In %1 beitreten",
    openMeeting: "Meeting öffnen",
    createEvent: "Termin anlegen",
    refreshNow: "Jetzt aktualisieren",
    openCalendar: "Kalender öffnen",
    sectionToday: "HEUTE",
    sectionTomorrow: "MORGEN",
    sectionLater: "DEMNÄCHST",
    noneTodayDot: "Keine Termine heute.",
    noneTomorrowDot: "Keine Termine morgen.",
    noneTodayTomorrowDot: "Keine Termine heute und morgen.",
    declined: "Abgelehnt",
    clickJoinVia: "Klick: in %1 beitreten",
    clickOpenMeeting: "Klick: Meeting öffnen",
    // fullscreen alert
    // weekdays and alertDate: unused since 1.4.0 (the alert writes dateShort),
    // kept one more release with weekday() below -- see there.
    weekdays: ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"],
    alertDate: "%1, %2.%3.",
    over: "vorbei",
    inMin: "in %1 min",
    inSec: "in %1 s",
    runningForMin: "läuft seit %1 min",
    hintEsc: "Esc schließen",
    hintEnterVia: "Enter: in %1 beitreten · Esc schließen",
    hintEnter: "Enter beitreten · Esc schließen",
    queuedOne: "Danach folgt noch ein Termin",
    queuedN: "Danach folgen noch %1 Termine",
    // service: notification and `status`
    statusRuntimeMissing: "XDG_RUNTIME_DIR ist nicht gesetzt",
    statusConfigUnreadable: "omeetingbar.json ist unlesbar – Standardwerte aktiv",
    statusConfigKept: "omeetingbar.json ist unlesbar – die zuletzt gültigen Werte gelten weiter",
    statusCacheReading: "Cache wird gelesen",
    statusCacheMissing: "Noch kein Cache – Abruf läuft",
    statusCacheUnreadable: "Cache ist unlesbar",
    statusFetchFailed: "Kalenderabruf fehlgeschlagen",
    statusNoneInWindow: "Keine Termine im Vorschaufenster",
    statusReady: "Bereit",
    moreMeetings: "%1 weitere Termine",
    moreMeetingsBody: "Nicht einzeln gemeldet · siehe Agenda",
    meetingEnded: "Meeting beendet",
    testMeeting: "Testtermin",
    testCalendar: "Test"
  },
  en: {
    // shared
    tomorrow: "tomorrow",
    allDay: "all day",
    now: "now",
    running: "running",
    untitled: "Untitled",
    meeting: "Meeting",
    oneMinute: "1 minute",
    nMinutes: "%1 minutes",
    oneMeeting: "1 meeting",
    nMeetings: "%1 meetings",
    oneDay: "1 day",
    nDays: "%1 days",
    inX: "in %1",
    hoursMin: "%1 h %2 min",
    hoursOnly: "%1 h",
    runningFor: "running for %1",
    dateShort: "ddd, MMM d",
    weekTag: " (W %1)",
    // bar widget
    clickHint: "Left: open agenda · Right/middle: refresh",
    runtimeMissing: "OMeetingBar: XDG_RUNTIME_DIR is not set, the event cache cannot be read.",
    noDataYet: "No calendar data yet.",
    notConnected: "The calendar is probably not connected yet – see the README.",
    cacheUnreadable: "The event cache is unreadable.",
    calendarError: "Calendar error: %1",
    lastKnown: "Showing the last known meetings.",
    limited: "Limited: %1",
    dataAge: "Data is %1 old – is the OMeetingBar service running?",
    noUpcomingDot: "No upcoming meeting.",
    agendaLists: "The agenda lists %1 (finished and declined ones included).",
    runningForDot: "Running for %1.",
    startsNow: "Starts now.",
    startsIn: "Starts in %1.",
    // agenda popup
    loading: "Loading meetings…",
    noData: "No calendar data",
    noUpcoming: "No upcoming meeting",
    noMeetings: "No meetings",
    noneTodayTomorrow: "no meetings today or tomorrow",
    today: "today",
    noneTomorrow: "none tomorrow",
    reading: "Reading calendar data…",
    dataUnreadable: "Calendar data cannot be read.",
    dataOutdated: "Calendar data is outdated – is the OMeetingBar service running?",
    noJoinLink: "No meeting link",
    joinVia: "Join via %1",
    openMeeting: "Open meeting",
    createEvent: "New event",
    refreshNow: "Refresh now",
    openCalendar: "Open calendar",
    sectionToday: "TODAY",
    sectionTomorrow: "TOMORROW",
    sectionLater: "UPCOMING",
    noneTodayDot: "No meetings today.",
    noneTomorrowDot: "No meetings tomorrow.",
    noneTodayTomorrowDot: "No meetings today or tomorrow.",
    declined: "Declined",
    clickJoinVia: "Click: join via %1",
    clickOpenMeeting: "Click: open meeting",
    // fullscreen alert
    weekdays: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
    alertDate: "%1, %3/%2",
    over: "over",
    inMin: "in %1 min",
    inSec: "in %1 s",
    runningForMin: "running for %1 min",
    hintEsc: "Esc to dismiss",
    hintEnterVia: "Enter: join via %1 · Esc to dismiss",
    hintEnter: "Enter to join · Esc to dismiss",
    queuedOne: "One more meeting follows",
    queuedN: "%1 more meetings follow",
    // service: notification and `status`
    statusRuntimeMissing: "XDG_RUNTIME_DIR is not set",
    statusConfigUnreadable: "omeetingbar.json is unreadable – using defaults",
    statusConfigKept: "omeetingbar.json is unreadable – the last valid settings still apply",
    statusCacheReading: "Reading cache",
    statusCacheMissing: "No cache yet – fetching",
    statusCacheUnreadable: "Cache is unreadable",
    statusFetchFailed: "Calendar fetch failed",
    statusNoneInWindow: "No meetings in the lookahead window",
    statusReady: "Ready",
    moreMeetings: "%1 more meetings",
    moreMeetingsBody: "Not listed individually · see the agenda",
    meetingEnded: "Meeting ended",
    testMeeting: "Test meeting",
    testCalendar: "Test"
  }
}

// "de" or "en". `override` is omeetingbar.json's `language`; anything but
// "de"/"en" (so also "auto" and a missing key) defers to the locale name.
function pick(override, localeName) {
  var wanted = String(override || "").trim().toLowerCase()
  if (wanted === "de" || wanted === "en") return wanted
  return /^de([_\-.]|$)/i.test(String(localeName || "")) ? "de" : "en"
}

// The Qt locale to format dates with, so weekday names follow the UI language
// rather than the session (a German UI on an en_US session says "Mo.", not "Mon").
function localeName(lang) {
  return lang === "de" ? "de_DE" : "en_US"
}

function t(lang, key) {
  var block = table[lang] || table.en
  var text = block[key]
  if (text === undefined) text = table.en[key]
  if (text === undefined) return key
  for (var i = 2; i < arguments.length; i++) {
    var value = String(arguments[i])
    text = text.replace("%" + (i - 1), function() { return value })
  }
  return text
}

// "1 Termin" / "3 Termine": the singular key carries its own number.
function count(lang, n, oneKey, manyKey) {
  return n === 1 ? t(lang, oneKey) : t(lang, manyKey, n)
}

// Unused since 1.4.0. Kept one more release: the engine caches this file for
// the shell's life, so after a downgrade without `omarchy restart shell` a
// 1.3.x Alert.qml loading for the first time gets this copy, and its dayLabel
// calls weekday() (docs/SPEC.md, "Version and updates").
function weekday(lang, dayIndex) {
  return (table[lang] || table.en).weekdays[dayIndex]
}
