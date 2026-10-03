.pragma library

// Video-conferencing providers, in one place for Popup.qml (glyph + colour)
// and Alert.qml (name in the join hint). The fetcher's JOIN_URL_RE in
// bin/omeetingbar-fetch decides which links count as a meeting room at all and
// must recognise the same hosts — keep the two in step.
//
// Glyphs come from the bar's Nerd Font only (Material Design Icons, already
// licensed with the font), so nothing trademarked is bundled with the plugin.
// The font has real marks for Google, Teams, Slack and Discord; Zoom, Webex,
// Jitsi, Whereby and GoTo have none and share the camera glyph, which is where
// the brand colour does the telling apart.
//
// Colours are the providers' published brand values (sources below). They are
// not used as given: brandColor() moves each one towards white or black until
// it reaches 3:1 against the popup background (WCAG's figure for non-text UI),
// so Slack's aubergine does not vanish on a dark theme. "" means no reliable
// brand colour was found and the caller keeps its theme colour.

var glyphGoogle = String.fromCodePoint(0xF02AD)   // md-google
var glyphTeams = String.fromCodePoint(0xF02BB)    // md-microsoft_teams
var glyphSlack = String.fromCodePoint(0xF04B1)    // md-slack
var glyphDiscord = String.fromCodePoint(0xF066F)  // md-discord
var glyphVideo = String.fromCodePoint(0xF0567)    // md-video
var glyphLink = String.fromCodePoint(0xF0339)     // md-link_variant

var table = [
  // simpleicons.org "Google Meet", from Google's brand resource centre
  { id: "meet", name: "Google Meet", hosts: ["meet.google.com"], glyph: glyphGoogle, hex: "#00897B" },
  // Teams purple per Microsoft's Teams palette
  { id: "teams", name: "Teams", hosts: ["teams.microsoft.com", "teams.live.com"], glyph: glyphTeams, hex: "#5B5FC7" },
  // simpleicons.org "Zoom", from brand.zoom.us
  { id: "zoom", name: "Zoom", hosts: ["zoom.us", "zoomgov.com"], glyph: glyphVideo, hex: "#0B5CFF" },
  // the green of the Webex mark (its gradient runs blue to green; green keeps it
  // apart from Zoom and Jitsi, which share the camera glyph)
  { id: "webex", name: "Webex", hosts: ["webex.com"], glyph: glyphVideo, hex: "#51E178" },
  // jitsi-meet react/features/base/ui/tokens.json, action01
  { id: "jitsi", name: "Jitsi", hosts: ["meet.jit.si", "8x8.vc"], glyph: glyphVideo, hex: "#4687ED" },
  // no published single brand colour found — theme colour
  { id: "whereby", name: "Whereby", hosts: ["whereby.com"], glyph: glyphVideo, hex: "" },
  // simpleicons.org "GoToMeeting"
  { id: "goto", name: "GoTo", hosts: ["gotomeeting.com", "meet.goto.com", "gotomeet.me"], glyph: glyphVideo, hex: "#F68D2E" },
  // Slack aubergine, the brand primary (Slack brand guidelines)
  { id: "slack", name: "Slack Huddle", hosts: ["app.slack.com"], glyph: glyphSlack, hex: "#4A154B" },
  // discord.com/branding "Blurple"
  { id: "discord", name: "Discord", hosts: ["discord.com", "discordapp.com", "discord.gg"], glyph: glyphDiscord, hex: "#5865F2" }
]

function hostOf(url) {
  var rest = String(url || "").replace(/^https:\/\//i, "")
  var authority = rest.split(/[\/?#]/)[0]
  // Browsers read "\" as "/" in an https URL, so "evil.example\@meet.google.com"
  // lands on evil.example while a split on "@" would name Meet. No real host
  // contains one: treat the URL as unknown rather than guess.
  if (authority.indexOf("\\") !== -1) return ""
  return authority.split("@").pop().split(":")[0].toLowerCase()
}

// Exact host or a subdomain of it ("acme.zoom.us"), never a suffix match on
// the raw string — "evilzoom.us" is not Zoom.
function lookup(url) {
  var host = hostOf(url)
  if (host === "") return null
  for (var i = 0; i < table.length; i++) {
    var hosts = table[i].hosts
    for (var j = 0; j < hosts.length; j++) {
      if (host === hosts[j] || host.endsWith("." + hosts[j])) return table[i]
    }
  }
  return null
}

function glyph(url) {
  var p = lookup(url)
  return p ? p.glyph : glyphLink
}

function name(url) {
  var p = lookup(url)
  return p ? p.name : ""
}

function channel(v) {
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function luminance(r, g, b) {
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

function contrast(l1, l2) {
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
}

function hex2(v) {
  var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
  return s.length < 2 ? "0" + s : s
}

// `bg` is a QML color (r, g, b in 0..1). Returns "#rrggbb", or "" when the
// provider has no brand colour or the URL is not a known provider.
function brandColor(url, bg) {
  var p = lookup(url)
  if (!p || p.hex === "") return ""
  var r = parseInt(p.hex.substr(1, 2), 16) / 255
  var g = parseInt(p.hex.substr(3, 2), 16) / 255
  var b = parseInt(p.hex.substr(5, 2), 16) / 255
  if (!bg) return p.hex
  var lb = luminance(bg.r, bg.g, bg.b)
  // Light theme: darken towards black; dark theme: lighten towards white.
  var target = lb > 0.18 ? 0 : 1
  for (var step = 0; step <= 10; step++) {
    var t = step / 10
    var rr = r + (target - r) * t
    var gg = g + (target - g) * t
    var bb = b + (target - b) * t
    if (contrast(luminance(rr, gg, bb), lb) >= 3) return "#" + hex2(rr) + hex2(gg) + hex2(bb)
  }
  return target === 1 ? "#ffffff" : "#000000"
}
