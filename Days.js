.pragma library
.import "Strings.js" as Strings

// Calendar arithmetic and the countdown: the bar label (Widget.qml), the agenda
// popup (Popup.qml) and the fullscreen alert (Alert.qml) all take the day a
// meeting is on from here, and bar and popup also how far away it is (the
// alert keeps its own second-by-second countdown). Times are unix seconds,
// days are the session's local calendar days.
//
// Uses only Strings keys and functions that every published release has: after
// an update the engine may hand this file the previous release's Strings.js
// (docs/SPEC.md, "Version and updates").

// The local date of an instant as one comparable number, yyyymmdd.
function dateKey(sec) {
  var d = new Date(sec * 1000)
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
}

// The first instant of the local day `offset` days after the one `sec` falls
// on: what the fetcher's _local_epoch(day, 0, 0) returns, so the agenda's day
// bounds are the fetcher's. Not simply new Date(y, m, d): where DST switches
// at midnight (Santiago, the Azores, Havana, Beirut, Cairo) QV4 resolves a
// midnight that does not exist to 23:00 of the day before. Noon exists on
// every day, so it fixes the target date; the candidate then walks to the
// first instant that has that date, a quarter of an hour at a time. Measured
// equal to the fetcher in every zone for every date since 2011; a few older
// ones (Newfoundland's fall-backs at 00:01 until 2010) still land an hour off.
function dayStart(sec, offset) {
  var base = new Date(sec * 1000)
  var noon = new Date(base.getFullYear(), base.getMonth(), base.getDate() + (offset || 0), 12)
  var key = noon.getFullYear() * 10000 + (noon.getMonth() + 1) * 100 + noon.getDate()
  var t = Math.floor(new Date(noon.getFullYear(), noon.getMonth(), noon.getDate()).getTime() / 1000)
  for (var i = 0; i < 16 && dateKey(t) < key; i++) t += 900
  for (var j = 0; j < 16 && dateKey(t - 900) === key; j++) t -= 900
  return t
}

// Calendar days from the local day of `fromSec` to that of `toSec`: 0 today,
// 1 tomorrow, -1 yesterday. It counts dates rather than dividing seconds, so a
// 23- or 25-hour day cannot shift it.
function daysBetween(fromSec, toSec) {
  return dayNumber(toSec) - dayNumber(fromSec)
}

function dayNumber(sec) {
  var d = new Date(sec * 1000)
  return Math.round(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / 86400000)
}

// How far `startSec` is from `nowSec`, as the parts each surface words its
// own way: { phase, unit, value, hours, minutes }.
//   phase "running": started a minute or more ago, the parts say how long ago
//   phase "now":     less than a minute either side (unit "")
//   phase "ahead":   a minute or more to go
//   unit "minutes" (value), "hours" (hours and minutes), "days" (value)
// Ahead, a meeting on a later calendar day and a day or more away counts in
// calendar days: "morgen 20:00", read at 07:00, is 1 day off, not round(37 h)
// = 2. Everything else counts in hours, which keeps a meeting late on a
// 25-hour day from reading "1 day". Running counts elapsed time: a conference
// that began at 09:00 yesterday has been running for 1 day at 09:10 today.
function countdown(nowSec, startSec) {
  var delta = Math.round(startSec - nowSec)
  if (delta <= -60) return spanParts(-delta, "running", 0)
  if (delta < 60) return { phase: "now", unit: "", value: 0, hours: 0, minutes: 0 }
  return spanParts(delta, "ahead", daysBetween(nowSec, startSec))
}

function spanParts(seconds, phase, days) {
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return { phase: phase, unit: "minutes", value: minutes, hours: 0, minutes: minutes }
  var hours = Math.floor(minutes / 60)
  if (seconds < 86400 || (phase === "ahead" && days < 1))
    return { phase: phase, unit: "hours", value: hours, hours: hours, minutes: minutes % 60 }
  var count = phase === "ahead" ? days : Math.floor(seconds / 86400)
  return { phase: phase, unit: "days", value: count, hours: 0, minutes: 0 }
}

// The parts in words: "5 Minuten", "2 h", "2 h 5 min", "1 Tag". `coarse`
// drops the minutes from an hour count, for the popup hero's one elided line.
function spanText(lang, parts, coarse) {
  if (parts.unit === "minutes") return Strings.count(lang, parts.value, "oneMinute", "nMinutes")
  if (parts.unit === "hours")
    return parts.minutes > 0 && coarse !== true
      ? Strings.t(lang, "hoursMin", parts.hours, parts.minutes)
      : Strings.t(lang, "hoursOnly", parts.hours)
  if (parts.unit === "days") return Strings.count(lang, parts.value, "oneDay", "nDays")
  return ""
}

// The day in front of a start time: "" today, "morgen" tomorrow, the short
// weekday within six days either way -- so a meeting that began before today
// and is still running says so ("Mo. 09:00 Konferenz · läuft") -- and the
// short date beyond that, where a weekday alone would be ambiguous: the
// default seven-day lookahead already reaches a day with today's weekday, and
// lookahead_minutes goes up to 30 days. `compact` leaves the weekday out of
// the date ("12. Okt." for "Mo., 12. Okt."), for the popup's narrow places.
// Weekday and date follow the UI language, not the session locale.
function dayPrefix(lang, nowSec, sec, compact) {
  var days = daysBetween(nowSec, sec)
  if (days === 0) return ""
  if (days === 1) return Strings.t(lang, "tomorrow")
  var format = "ddd"
  if (days <= -7 || days >= 7) {
    format = Strings.t(lang, "dateShort")
    if (compact === true) format = format.replace(/^d{3,4}\W*/, "")
  }
  return new Date(sec * 1000).toLocaleDateString(Qt.locale(Strings.localeName(lang)), format)
}
