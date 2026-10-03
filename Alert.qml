import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Providers.js" as Providers

// Fullscreen blanking alert for an imminent meeting. Deliberately not a toast:
// every monitor is covered by an opaque themed surface, because the user does
// not notice ordinary notifications. Colors come from the [notifications]
// surface tokens so the alert follows whatever theme is active.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false

  // ---------------------------------------------------------- payload
  //
  // See docs/SPEC.md "Overlay contract". These defaults are what an empty or
  // corrupt payload degrades to: the surface still blanks the screens and says
  // something, rather than throwing out of open().
  property string title: ""
  property real startEpoch: 0
  property real endEpoch: 0
  property string url: ""
  property string calendar: ""
  property string location: ""
  property int autoDismissSeconds: 90
  // Defaults, so a hand-made summon without a colours block still renders.
  property string runningColorName: "#FF9500"
  property string upcomingColorName: "#00BEFF"
  property bool isTest: false
  // How many further alerts Service.qml still has queued behind this one.
  property int queuedCount: 0

  readonly property bool hasStart: root.startEpoch > 0
  // Same split the bar entry makes: the meeting has begun, or it has not.
  readonly property bool runningNow: root.hasStart && root.nowMs / 1000 >= root.startEpoch
  readonly property bool hasUrl: root.joinUrl !== ""
  // Only ever hand a real web URL to the browser launcher. Calendar bodies are
  // third-party data, so a file:// or javascript: "join link" is dropped
  // instead of launched.
    readonly property string joinUrl: /^https:\/\/[^\s]+$/i.test(root.url) ? root.url : ""

  // ---------------------------------------------------------- clock
  //
  // Everything time-derived is recomputed from the wall clock, so a suspend or
  // a clock correction cannot leave the countdown lying.
  property real nowMs: Date.now()
  property real openedAtMs: 0
  property real dismissProgress: 1

  // ---------------------------------------------------------- safety limits
  //
  // D7: the alert may never own the screen or the idle inhibitor forever. Both
  // budgets run from `openedAtMs`, so re-opening with a new payload starts them
  // over, and both are checked against the wall clock in enforceLimits() rather
  // than armed as long one-shot timers, which would stall across a suspend.

  // The inhibitor only has to bridge the moment the alert appears in; holding it
  // longer would keep an unattended session awake and unlocked with the meeting
  // title, calendar and location on screen.
  readonly property int inhibitBudgetSeconds: 180
  // Even `auto_dismiss_seconds: 0` ("stay until dismissed") must not pin a
  // meeting on an unattended screen indefinitely.
  readonly property int hardDismissSeconds: 600

  // Cleared once the inhibitor budget is spent, while the overlay may stay up.
  property bool inhibitHeld: false

  // ---------------------------------------------------------- theme
  //
  // Opaque on purpose: `Color.background` is the foundational theme color and
  // always fully opaque, which is what makes this a blanking alert.
  readonly property color surfaceColor: Util.alpha(Color.background, 1.0)
  readonly property color textColor: Color.notifications.text
  // The countdown and the glyph carry the state: orange once it is running,
  // turquoise while it is still ahead. Deliberately not a theme token — these
  // two colours are the plugin's own signal and are set in omeetingbar.json.
  readonly property color loudColor: root.runningNow ? root.runningColorName : root.upcomingColorName
  readonly property color mutedColor: Util.alpha(root.textColor, 0.62)
  readonly property color dimColor: Util.alpha(root.textColor, 0.48)
  readonly property color trackColor: Util.alpha(root.textColor, 0.14)
  readonly property color progressColor: Color.notifications.countdown

  readonly property int frameWidth: Math.max(1, Style.space(4))
  // The frame is a functional alert cue, not decoration, so its width is
  // forced uniform while the theme still owns the color/gradient.
  readonly property var frameSpec: Border.withWidth(
    Border.surfaceSpec("notifications", "border", Color.notifications.border, root.frameWidth),
    root.frameWidth)

  // ---------------------------------------------------------- type scale
  //
  // Scaled off the largest Style token so the whole alert follows
  // `omarchy display text size` and any theme [font] overrides.
  readonly property int hero: Style.font.displayLarge
  readonly property int countdownSize: Math.round(root.hero * 4.6)
  readonly property int titleSize: Math.round(root.hero * 1.9)
  readonly property int rangeSize: Math.round(root.hero * 1.15)
  readonly property int metaSize: Math.round(root.hero * 0.85)
  readonly property int hintSize: Math.round(root.hero * 0.68)
  readonly property int badgeSize: Math.round(root.hero * 0.52)
  readonly property int glyphSize: Math.round(root.hero * 1.3)

  // ---------------------------------------------------------- focus routing
  //
  // Exactly one surface may take keyboard focus: two Exclusive layer surfaces
  // fight over the compositor's keyboard and one of them ends up dead, so
  // Escape would silently stop working. Pick the output Hyprland has focused
  // (that is where the user is looking and typing) and fall back to the first
  // entry of `Quickshell.screens` when Hyprland has not reported one yet or
  // reports an output we have no surface on — never "none", or the alert would
  // be undismissable by keyboard.
  readonly property string focusScreenName: {
    var screens = Quickshell.screens
    if (!screens || screens.length === 0) return ""
    var wanted = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    if (wanted) {
      for (var i = 0; i < screens.length; i++)
        if (String(screens[i].name || "") === wanted) return wanted
    }
    return String(screens[0].name || "")
  }

  // ---------------------------------------------------------- payload helpers

  function cleanText(value) {
    return String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").replace(/^ | $/g, "")
  }

  function colorOr(value, fallback) {
    if (value === undefined || value === null) return fallback
    var text = String(value).trim()
    return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback
  }

  function numberOr(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : fallback
  }

  // ---------------------------------------------------------- formatting

  function pad2(n) {
    return (n < 10 ? "0" : "") + n
  }

  function clockLabel(epoch) {
    if (!(epoch > 0)) return ""
    var d = new Date(epoch * 1000)
    return root.pad2(d.getHours()) + ":" + root.pad2(d.getMinutes())
  }

  function dayKey(d) {
    return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
  }

  // Day names are hardcoded German rather than locale-derived: the UI is
  // German regardless of what LANG the session happens to carry.
  readonly property var weekdayNames: ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]

  function dayLabel(epoch, nowMs) {
    if (!(epoch > 0)) return ""
    var d = new Date(epoch * 1000)
    var today = new Date(nowMs)
    if (root.dayKey(d) === root.dayKey(today)) return ""
    var tomorrow = new Date(nowMs)
    tomorrow.setDate(tomorrow.getDate() + 1)
    if (root.dayKey(d) === root.dayKey(tomorrow)) return "morgen"
    return root.weekdayNames[d.getDay()] + ", " + root.pad2(d.getDate()) + "." + root.pad2(d.getMonth() + 1) + "."
  }

  readonly property string countdownText: {
    if (!root.hasStart) return "—"
    var nowSec = root.nowMs / 1000
    if (root.endEpoch > root.startEpoch && nowSec >= root.endEpoch) return "vorbei"
    var delta = Math.round(root.startEpoch - nowSec)
    if (delta >= 90) return "in " + Math.ceil(delta / 60) + " min"
    if (delta >= 1) return "in " + delta + " s"
    var since = -delta
    if (since < 60) return "jetzt"
    return "läuft seit " + Math.floor(since / 60) + " min"
  }

  readonly property string titleText: root.title || "Termin"

  readonly property string rangeText: {
    if (!root.hasStart) return ""
    var core = root.clockLabel(root.startEpoch)
    if (root.endEpoch > root.startEpoch) core += " – " + root.clockLabel(root.endEpoch)
    var prefix = root.dayLabel(root.startEpoch, root.nowMs)
    return prefix ? prefix + " · " + core : core
  }

  readonly property string metaText: {
    var parts = []
    if (root.calendar) parts.push(root.calendar)
    if (root.location) parts.push(root.location)
    return parts.join(" · ")
  }

  // Naming the provider tells the user what Enter is about to open before
  // they press it — a browser tab for Meet, the Zoom client for Zoom.
  readonly property string providerName: root.hasUrl ? Providers.name(root.joinUrl) : ""
  readonly property string hintText: !root.hasUrl ? "Esc schließen"
    : (root.providerName !== "" ? "Enter: in " + root.providerName + " beitreten · Esc schließen"
      : "Enter beitreten · Esc schließen")

  readonly property string queuedText: {
    if (root.queuedCount <= 0) return ""
    if (root.queuedCount === 1) return "Danach folgt noch ein Termin"
    return "Danach folgen noch " + root.queuedCount + " Termine"
  }

  // ---------------------------------------------------------- host contract

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (!payload || typeof payload !== "object") payload = ({})

    root.title = root.cleanText(payload.title)
    root.startEpoch = root.numberOr(payload.start, 0)
    root.endEpoch = root.numberOr(payload.end, 0)
    root.url = root.cleanText(payload.url)
    root.calendar = root.cleanText(payload.calendar)
    root.location = root.cleanText(payload.location)
    // Missing auto_dismiss means "use the documented config default" rather
    // than "stay forever"; only an explicit 0 pins the alert open. Anything
    // longer than hardDismissSeconds is capped, so the progress bar cannot
    // promise a lifetime that D7 will cut short anyway; 0 stays 0 and is
    // bounded by the hard dismiss instead.
    var wantedDismiss = Math.max(0, Math.round(root.numberOr(payload.auto_dismiss, 90)))
    root.autoDismissSeconds = wantedDismiss > 0 ? Math.min(wantedDismiss, root.hardDismissSeconds) : 0
    var palette = Util.isPlainObject(payload.colors) ? payload.colors : ({})
    root.runningColorName = root.colorOr(palette.running, "#FF9500")
    root.upcomingColorName = root.colorOr(palette.upcoming, "#00BEFF")
    root.isTest = payload.test === true
    root.queuedCount = Math.max(0, Math.round(root.numberOr(payload.queued, 0)))

    // Service.qml queues alerts, so open() can arrive while an *older* event is
    // still on screen. Everything time-derived hangs off `openedAtMs`, so
    // restamping it here resets the countdown, the auto-dismiss bar, the
    // hard-dismiss deadline and the inhibitor budget in one go — no stacked
    // timers, no leftover state from the previous payload.
    root.nowMs = Date.now()
    root.openedAtMs = root.nowMs
    // A payload without a start is not a meeting. The bar's positional panel
    // hotkey (SUPER+CTRL+N on a right-section slot, or `shell togglePanelAt`)
    // reaches this overlay with "{}", because shell.qml routes every summon of
    // a plugin that declares an overlay kind here — and blanking every monitor
    // for nothing is the one thing this surface must never do. A test payload
    // is explicit and still shows.
    if (!(root.startEpoch > 0) && !root.isTest) {
      root.dismiss()
      return
    }
    root.dismissProgress = 1
    root.inhibitHeld = true
    root.opened = true
  }

  function close() {
    root.opened = false
    root.dismissProgress = 1
    root.inhibitHeld = false
  }

  // Idempotent: the host's hide() ignores an id it does not hold open, and it
  // calls close() rather than dismiss(), so a second dismiss() (auto-dismiss
  // racing a keypress) neither recurses nor double-hides.
  function dismiss() {
    root.opened = false
    root.dismissProgress = 1
    root.inhibitHeld = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.disy-mk.omeetingbar")
  }

  function join() {
    var target = root.joinUrl
    root.dismiss()
    if (!target) return
    var launcher = root.omarchyPath ? root.omarchyPath + "/bin/omarchy-launch-browser" : "omarchy-launch-browser"
    Quickshell.execDetached([launcher, target])
  }

  // Wall-clock enforcement of the two D7 budgets, driven by the 1 Hz tick (which
  // runs whenever the overlay is up, including with auto_dismiss 0): the
  // inhibitor is released first, the overlay is torn down last.
  function enforceLimits() {
    var elapsed = (root.nowMs - root.openedAtMs) / 1000
    if (root.inhibitHeld && elapsed >= root.inhibitBudgetSeconds) root.inhibitHeld = false
    if (elapsed >= root.hardDismissSeconds) root.dismiss()
  }

  // Both timers are gated on `opened`, so dismiss() stops every one of them
  // through the same binding.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: {
      root.nowMs = Date.now()
      root.enforceLimits()
    }
  }

  // Separate, faster tick for the auto-dismiss bar so it glides instead of
  // stepping once a second. Still wall-clock derived, so it agrees with the
  // countdown text.
  Timer {
    interval: 50
    repeat: true
    running: root.opened && root.autoDismissSeconds > 0
    onTriggered: {
      var left = root.autoDismissSeconds - (Date.now() - root.openedAtMs) / 1000
      root.dismissProgress = Util.clamp(left / root.autoDismissSeconds, 0, 1)
      if (left <= 0) root.dismiss()
    }
  }

  // A plugin hot-reload destroys this component: drop the inhibitor explicitly
  // instead of trusting the surfaces below to be torn down first.
  Component.onDestruction: {
    root.inhibitHeld = false
    root.opened = false
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      readonly property string screenName: modelData ? String(modelData.name || "") : ""
      readonly property bool focusHere: root.focusScreenName !== "" && root.focusScreenName === panel.screenName
      readonly property int gutter: Style.space(64)
      readonly property int contentWidth: Math.max(Style.space(220), Math.min(panel.width - panel.gutter * 2, Style.space(1200)))

      function grabKeys() {
        if (!panel.visible || !panel.focusHere) return
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }

      screen: modelData
      visible: root.opened
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omeetingbar-alert"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: panel.focusHere ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      onVisibleChanged: panel.grabKeys()
      onFocusHereChanged: panel.grabKeys()

      // One inhibitor per surface: it is declared where a live window exists,
      // and it holds long enough that the session cannot blank or lock over the
      // thing the user is supposed to read. Not longer (D7): after
      // inhibitBudgetSeconds the overlay may still be up, but an unattended
      // machine must be allowed to blank and lock again.
      IdleInhibitor {
        enabled: root.opened && root.inhibitHeld
        window: panel
      }

      BorderSurface {
        anchors.fill: parent
        radius: 0
        color: root.surfaceColor
        borderSpec: root.frameSpec
      }

      // Any click anywhere dismisses — the alert has to clear without aiming.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: root.dismiss()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // Bare modifiers are never an answer to the alert, so they are left
          // alone; every other key clears it, join keys after launching.
          if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
            || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta
            || event.key === Qt.Key_AltGr || event.key === Qt.Key_CapsLock)
            return
          event.accepted = true
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) root.join()
          else root.dismiss()
        }
      }

      // Absolutely positioned so a test alert is pixel-identical to a real one
      // below it — only this badge is added.
      Rectangle {
        visible: root.isTest
        anchors.top: parent.top
        anchors.topMargin: panel.gutter
        anchors.horizontalCenter: parent.horizontalCenter
        width: badgeLabel.implicitWidth + Style.spacing.controlPaddingX * 2
        height: badgeLabel.implicitHeight + Style.spacing.controlPaddingY * 2
        radius: Style.cornerRadius
        color: "transparent"
        border.width: Math.max(1, Style.space(1))
        border.color: Color.accent

        Text {
          id: badgeLabel
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "TEST"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: root.badgeSize
          font.letterSpacing: Math.max(1, Style.space(2))
        }
      }

      Column {
        anchors.centerIn: parent
        width: panel.contentWidth
        spacing: Style.spacing.panelPadding

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "󰃭"
          color: root.loudColor
          font.family: Style.font.family
          font.pixelSize: root.glyphSize
        }

        // Loudest element. HorizontalFit keeps "läuft seit 128 min" inside the
        // content column instead of running off a narrow screen.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.countdownText
          color: root.loudColor
          font.family: Style.font.family
          font.pixelSize: root.countdownSize
          font.bold: true
          wrapMode: Text.NoWrap
          fontSizeMode: Text.HorizontalFit
          minimumPixelSize: root.rangeSize
        }

        Item {
          width: parent.width
          height: Style.space(8)
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.titleText
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: root.titleSize
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: root.rangeText !== ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.rangeText
          color: root.mutedColor
          font.family: Style.font.family
          font.pixelSize: root.rangeSize
        }

        Text {
          textFormat: Text.PlainText
          visible: root.metaText !== ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.metaText
          color: root.mutedColor
          font.family: Style.font.family
          font.pixelSize: root.metaSize
          elide: Text.ElideRight
        }

        Item {
          width: parent.width
          height: Style.space(24)
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.hintText
          color: root.dimColor
          font.family: Style.font.family
          font.pixelSize: root.hintSize
        }

        // Quiet note that further alerts are waiting: deliberately the smallest
        // and dimmest line on the surface, because this is not the news.
        Text {
          textFormat: Text.PlainText
          visible: root.queuedText !== ""
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.queuedText
          color: root.dimColor
          font.family: Style.font.family
          font.pixelSize: root.badgeSize
        }
      }

      // Calm auto-dismiss indicator: a thin bar draining along the bottom edge
      // so the user can see the alert will pass on its own.
      Rectangle {
        visible: root.autoDismissSeconds > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Border.left(root.frameSpec)
        anchors.rightMargin: Border.right(root.frameSpec)
        anchors.bottomMargin: Border.bottom(root.frameSpec)
        height: Math.max(2, Style.space(6))
        color: root.trackColor

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Math.round(parent.width * root.dismissProgress)
          color: root.progressColor
        }
      }
    }
  }
}
