import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Capture toolbar, Snipping Tool style. Opening it freezes the focused monitor;
// the toolbar floats on top and the picker is live underneath: drag a region,
// click a window, or click empty space for the whole monitor.
//
// Screenshots crop the frozen frame (bin/shot). Recordings go through
// omarchy-capture-screenrecording, with a stand-in region picker on PATH that
// returns the toolbar's selection, so audio, webcam, finishing and the stop
// key all stay Omarchy's.
//
// Summon: omarchy-shell shell toggle ziru.capture '{}'
// Payload keys: "mode" (screenshot|record), "skipDelay" (after a timer).
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  property bool opened: false
  property bool grabbing: false
  property bool skipDelay: false

  property string mode: "screenshot"   // screenshot | record
  property string target: "region"    // region | window | screen
  property int delay: 0
  property bool desktopAudio: false
  property bool microphone: false
  property bool webcam: false
  readonly property var delays: [0, 3, 5, 10]

  readonly property string home: Quickshell.env("HOME")
  // Helper scripts ship inside the plugin folder (bin/).
  readonly property string helperDir: decodeURIComponent(Qt.resolvedUrl("bin").toString().replace(/^file:\/\//, ""))
  readonly property string stateFile: home + "/.local/state/ziru-capture-toolbar.json"
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"

  // Captured when the toolbar opens
  property var monitor: null     // { name, x, y } in global logical coordinates
  property var windows: []       // [{ x, y, w, h }] in overlay coordinates, topmost first
  property int frozenSerial: 0
  // Each grab gets its own frame file, so a pending screenshot never reads the
  // next capture's frame. shot deletes it after cropping; close() deletes an
  // unused one.
  property string frameFile: ""
  property bool frameHandedOff: false
  // False once the toolbar is closed, so a grab that finishes late is dropped.
  property bool wanted: false

  // Selection
  property bool pressed: false
  property bool dragging: false
  property real pressX: 0
  property real pressY: 0
  property real dragX: 0
  property real dragY: 0
  property var hoverRect: null

  // A screenshot timer runs before selecting; a recording delay runs after it.
  readonly property bool timerPending: mode === "screenshot" && delay > 0 && !skipDelay
  readonly property var highlight: dragging ? dragRect() : (target === "screen" ? fullRect() : hoverRect)

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color accent: Commons.Color.accent
  property var borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))

  FileView {
    id: stateView
    path: root.stateFile
    blockLoading: true
  }

  Process {
    id: grab
    command: ["bash", root.helperDir + "/grab", root.frameFile]
    stdout: StdioCollector { id: grabOut }
    onExited: function(exitCode) { root.finishGrab(exitCode === 0 ? grabOut.text : "") }
  }

  // ---- state -------------------------------------------------------------

  function loadState() {
    stateView.reload()
    var s = ({})
    try { s = JSON.parse(stateView.text() || "{}") } catch (e) { s = ({}) }
    if (s.mode === "screenshot" || s.mode === "record") root.mode = s.mode
    if (["region", "window", "screen"].indexOf(s.target) !== -1) root.target = s.target
    if (root.delays.indexOf(s.delay) !== -1) root.delay = s.delay
    root.desktopAudio = s.desktopAudio === true
    root.microphone = s.microphone === true
    root.webcam = s.webcam === true
  }

  function saveState() {
    stateView.setText(JSON.stringify({
      mode: root.mode, target: root.target, delay: root.delay,
      desktopAudio: root.desktopAudio, microphone: root.microphone, webcam: root.webcam
    }) + "\n")
  }

  // ---- open / close ------------------------------------------------------

  function open(payloadJson) {
    if (root.opened || root.grabbing) return
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.loadState()
    if (payload.mode === "screenshot" || payload.mode === "record") root.mode = payload.mode
    root.skipDelay = payload.skipDelay === true
    root.pressed = false
    root.dragging = false
    root.hoverRect = null
    // Freeze before the overlay maps, so it is never in the frame.
    root.frameFile = root.runtimeDir + "/ziru-capture-frame-" + Date.now() + ".png"
    root.frameHandedOff = false
    root.wanted = true
    root.grabbing = true
    grab.running = true
  }

  function finishGrab(text) {
    root.grabbing = false
    if (!root.wanted) { discardFrame(); return }
    var d = null
    try { d = JSON.parse(text) } catch (e) { d = null }
    if (!d || !d.monitor) {
      notify("Capture toolbar", "Could not read the screen")
      root.dismiss()
      return
    }
    var m = d.monitor
    root.monitor = { name: m.name, x: m.x, y: m.y }

    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === m.name) panel.screen = screens[i]

    var shown = [m.activeWorkspace ? m.activeWorkspace.id : -1,
                 m.specialWorkspace && m.specialWorkspace.id ? m.specialWorkspace.id : -1]
    var special = shown[1]
    var list = (d.clients || []).filter(function(c) {
      return c.mapped && !c.hidden && c.monitor === m.id && shown.indexOf(c.workspace.id) !== -1
    })
    list.sort(function(a, b) {
      var sa = a.workspace.id === special ? 1 : 0, sb = b.workspace.id === special ? 1 : 0
      if (sa !== sb) return sb - sa
      if (!!a.fullscreen !== !!b.fullscreen) return a.fullscreen ? -1 : 1
      if (a.floating !== b.floating) return a.floating ? -1 : 1
      return a.focusHistoryID - b.focusHistoryID
    })
    root.windows = list.map(function(c) {
      return { x: c.at[0] - m.x, y: c.at[1] - m.y, w: c.size[0], h: c.size[1] }
    })

    root.frozenSerial += 1
    root.opened = true
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.wanted = false
    root.opened = false
    root.pressed = false
    root.dragging = false
    if (!root.grabbing) discardFrame()
  }

  function discardFrame() {
    if (root.frameFile && !root.frameHandedOff)
      Quickshell.execDetached(["rm", "-f", root.frameFile])
    root.frameFile = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ziru.capture")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- geometry ----------------------------------------------------------

  function fullRect() { return { x: 0, y: 0, w: panel.width, h: panel.height } }

  function dragRect() {
    var x1 = Math.max(0, Math.min(root.pressX, root.dragX))
    var y1 = Math.max(0, Math.min(root.pressY, root.dragY))
    var x2 = Math.min(panel.width, Math.max(root.pressX, root.dragX))
    var y2 = Math.min(panel.height, Math.max(root.pressY, root.dragY))
    return { x: x1, y: y1, w: x2 - x1, h: y2 - y1 }
  }

  function windowAt(px, py) {
    for (var i = 0; i < root.windows.length; i++) {
      var r = root.windows[i]
      if (px >= r.x && py >= r.y && px < r.x + r.w && py < r.y + r.h) return clip(r)
    }
    return null
  }

  function clip(r) {
    var x1 = Math.max(0, r.x), y1 = Math.max(0, r.y)
    var x2 = Math.min(panel.width, r.x + r.w), y2 = Math.min(panel.height, r.y + r.h)
    return { x: x1, y: y1, w: Math.max(0, x2 - x1), h: Math.max(0, y2 - y1) }
  }

  // What a click or Enter at this point would capture.
  function targetAt(px, py) {
    if (root.target === "screen") return fullRect()
    var w = windowAt(px, py)
    if (w) return w
    return root.target === "region" ? fullRect() : null
  }

  function isFull(r) {
    return r.x <= 0 && r.y <= 0 && r.w >= panel.width && r.h >= panel.height
  }

  // ---- actions -----------------------------------------------------------

  function shellQuote(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  function notify(title, body) {
    Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-notification-send", title, body || ""])
  }

  // Close the overlay first so it is never recorded, then run.
  function run(command, useDelay) {
    root.saveState()
    root.dismiss()
    var script = "export PATH=" + shellQuote(root.omarchyPath + "/bin") + ":\"$PATH\"; sleep 0.2; "
    if (useDelay && root.delay > 0) {
      script += "omarchy-notification-send 'Recording in " + root.delay + " seconds' -t " + (root.delay * 1000) + " || true; "
      script += "sleep " + root.delay + "; omarchy-notification-dismiss 'Recording in'; sleep 0.3; "
    }
    Quickshell.execDetached(["bash", "-c", script + command])
  }

  function captureRect(r) {
    if (!r || r.w < 2 || r.h < 2) return
    if (root.mode === "screenshot") {
      var f = frozen.sourceSize.width > 0 ? frozen.sourceSize.width / panel.width : 1
      var x = Math.round(r.x * f), y = Math.round(r.y * f)
      var w = Math.round(r.w * f), h = Math.round(r.h * f)
      root.frameHandedOff = true
      root.run(shellQuote(root.helperDir + "/shot") + " " + shellQuote(root.frameFile) + " " + [x, y, w, h].join(" "), false)
      return
    }
    // Name the monitor now: --fullscreen would pick whichever monitor has focus
    // when the recording delay ends.
    var sel = isFull(r) ? "monitor:" + root.monitor.name
      : Math.round(r.x + root.monitor.x) + "," + Math.round(r.y + root.monitor.y) + " " + Math.round(r.w) + "x" + Math.round(r.h)
    var args = []
    if (root.desktopAudio) args.push("--with-desktop-audio")
    if (root.microphone) args.push("--with-microphone-audio")
    if (root.webcam) args.push("--with-webcam")
    var cmd = "ZIRU_CAPTURE_SELECTION=" + shellQuote(sel) + " PATH=" + shellQuote(root.helperDir + "/shim") + ":\"$PATH\" "
      + "omarchy-capture-screenrecording " + args.join(" ")
    root.run(cmd, true)
  }

  // Enter: start the timer, or take what is highlighted.
  function confirm() {
    if (root.timerPending) { startTimer(); return }
    captureRect(root.target === "screen" ? fullRect() : (root.hoverRect || (root.target === "window" ? null : fullRect())))
  }

  function startTimer() {
    root.saveState()
    root.dismiss()
    var n = root.delay
    Quickshell.execDetached(["bash", "-c",
      "export PATH=" + shellQuote(root.omarchyPath + "/bin") + ":\"$PATH\"; "
      + "omarchy-notification-send 'Screenshot in " + n + " seconds' -t " + (n * 1000) + " || true; "
      + "sleep " + n + "; omarchy-notification-dismiss 'Screenshot in'; sleep 0.3; "
      + "omarchy-shell shell summon ziru.capture '{\"skipDelay\":true}'"])
  }

  function setTarget(t) {
    root.target = t
    root.hoverRect = null
  }

  function cycleDelay() {
    var i = root.delays.indexOf(root.delay)
    root.delay = root.delays[(i + 1) % root.delays.length]
    root.skipDelay = false
  }

  function glyph(cp) { return String.fromCodePoint(cp) }

  readonly property string hint: {
    if (root.timerPending) return "Click or press Enter to start the " + root.delay + " second timer"
    if (root.target === "screen") return "Click anywhere or press Enter to capture the whole screen"
    if (root.target === "window") return "Click a window to capture it"
    return "Drag a region, click a window, or click empty space for the whole screen"
  }

  // ---- UI ----------------------------------------------------------------

  component Divider: Rectangle {
    width: Math.max(1, Style.space(1))
    height: Style.font.body * 1.6
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: root.foreground
    opacity: 0.18
  }

  component ToolButton: Button {
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    foreground: root.foreground
    fontFamily: Style.font.menuFamily
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ziru-capture"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The frozen frame (screenshots). Recordings show the live screen.
    Image {
      id: frozen
      anchors.fill: parent
      source: root.frozenSerial > 0 && root.frameFile ? "file://" + root.frameFile : ""
      cache: false
      smooth: false
      fillMode: Image.Stretch
      visible: root.mode === "screenshot" && !root.timerPending
    }

    // Dim everything except the highlight.
    Item {
      anchors.fill: parent
      readonly property var r: root.highlight
      readonly property color dim: Qt.rgba(0, 0, 0, 0.38)
      Rectangle { color: parent.dim; x: 0; y: 0; width: parent.width; height: parent.r ? parent.r.y : parent.height }
      Rectangle {
        visible: !!parent.r; color: parent.dim
        x: 0; y: parent.r ? parent.r.y + parent.r.h : 0
        width: parent.width; height: parent.r ? parent.height - (parent.r.y + parent.r.h) : 0
      }
      Rectangle {
        visible: !!parent.r; color: parent.dim
        x: 0; y: parent.r ? parent.r.y : 0
        width: parent.r ? parent.r.x : 0; height: parent.r ? parent.r.h : 0
      }
      Rectangle {
        visible: !!parent.r; color: parent.dim
        x: parent.r ? parent.r.x + parent.r.w : 0; y: parent.r ? parent.r.y : 0
        width: parent.r ? parent.width - (parent.r.x + parent.r.w) : 0; height: parent.r ? parent.r.h : 0
      }
      Rectangle {
        visible: !!parent.r
        x: parent.r ? parent.r.x : 0; y: parent.r ? parent.r.y : 0
        width: parent.r ? parent.r.w : 0; height: parent.r ? parent.r.h : 0
        color: "transparent"
        border.color: root.accent
        border.width: Math.max(2, Style.space(2))
      }
    }

    // Size readout while dragging (physical pixels, what the file will be).
    Rectangle {
      visible: root.dragging
      readonly property real f: frozen.sourceSize.width > 0 ? frozen.sourceSize.width / panel.width : 1
      readonly property var r: root.highlight
      x: r ? Math.min(panel.width - width - 8, r.x + r.w + 8) : 0
      y: r ? Math.min(panel.height - height - 8, r.y + r.h + 8) : 0
      width: sizeText.implicitWidth + Style.spacing.lg * 2
      height: sizeText.implicitHeight + Style.spacing.sm * 2
      radius: Style.cornerRadius
      color: root.background
      Text {
        id: sizeText
        anchors.centerIn: parent
        text: parent.r ? Math.round(parent.r.w * parent.f) + " × " + Math.round(parent.r.h * parent.f) : ""
        color: root.foreground
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.CrossCursor

      onPositionChanged: function(mouse) {
        if (root.pressed) {
          root.dragX = mouse.x
          root.dragY = mouse.y
          if (!root.dragging && root.target === "region"
              && (Math.abs(mouse.x - root.pressX) > 4 || Math.abs(mouse.y - root.pressY) > 4))
            root.dragging = true
        } else {
          root.hoverRect = root.targetAt(mouse.x, mouse.y)
        }
      }
      onPressed: function(mouse) {
        if (root.timerPending) return
        root.pressed = true
        root.pressX = mouse.x; root.pressY = mouse.y
        root.dragX = mouse.x; root.dragY = mouse.y
      }
      onReleased: function(mouse) {
        if (root.timerPending) { root.pressed = false; root.startTimer(); return }
        var wasDragging = root.dragging
        var r = wasDragging ? root.dragRect() : root.targetAt(mouse.x, mouse.y)
        root.pressed = false
        root.dragging = false
        root.captureRect(r)
      }
    }

    BorderSurface {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Style.space(56)
      width: content.implicitWidth + card.contentLeftInset + card.contentRightInset
      height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.lg

      // Keep clicks on the toolbar from reaching the picker.
      MouseArea { anchors.fill: parent; hoverEnabled: true; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var k = event.key
          var handled = true
          if (k === Qt.Key_Escape) root.dismiss()
          else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.confirm()
          else if (k === Qt.Key_1) root.mode = "screenshot"
          else if (k === Qt.Key_2) root.mode = "record"
          else if (k === Qt.Key_R) root.setTarget("region")
          else if (k === Qt.Key_W) root.setTarget("window")
          else if (k === Qt.Key_F) root.setTarget("screen")
          else if (k === Qt.Key_D) root.cycleDelay()
          else if (k === Qt.Key_A && root.mode === "record") root.desktopAudio = !root.desktopAudio
          else if (k === Qt.Key_M && root.mode === "record") root.microphone = !root.microphone
          else if (k === Qt.Key_C && root.mode === "record") root.webcam = !root.webcam
          else if (k === Qt.Key_T) root.run("omarchy-capture-text", false)
          else if (k === Qt.Key_Q) root.run("omarchy-capture-qr", false)
          else if (k === Qt.Key_P) root.run("pkill hyprpicker || hyprpicker -a", false)
          else handled = false
          event.accepted = handled
        }
      }

      Column {
        id: content
        x: card.contentLeftInset
        y: card.contentTopInset
        spacing: Style.spacing.md

        Row {
          spacing: Style.spacing.sm

          ToolButton {
            iconText: root.glyph(0xF030); text: "Screenshot"; tooltipText: "1"
            selected: root.mode === "screenshot"
            onClicked: root.mode = "screenshot"
          }
          ToolButton {
            iconText: root.glyph(0xF03D); text: "Record"; tooltipText: "2"
            selected: root.mode === "record"
            onClicked: root.mode = "record"
          }

          Divider {}

          ToolButton {
            iconText: root.glyph(0xF0A6D); text: "Region"; tooltipText: "R"
            selected: root.target === "region"
            onClicked: root.setTarget("region")
          }
          ToolButton {
            iconText: root.glyph(0xF05AF); text: "Window"; tooltipText: "W"
            selected: root.target === "window"
            onClicked: root.setTarget("window")
          }
          ToolButton {
            iconText: root.glyph(0xF0379); text: "Screen"; tooltipText: "F"
            selected: root.target === "screen"
            onClicked: root.setTarget("screen")
          }

          Divider {}

          ToolButton {
            iconText: root.glyph(0xF051B)
            text: root.delay > 0 ? root.delay + " s" : "No delay"
            tooltipText: "D  (cycle delay)"
            selected: root.delay > 0
            onClicked: root.cycleDelay()
          }

          Divider { visible: root.mode === "record" }
          ToolButton {
            visible: root.mode === "record"
            iconText: root.glyph(0xF057E); tooltipText: "A  (desktop audio)"
            selected: root.desktopAudio
            onClicked: root.desktopAudio = !root.desktopAudio
          }
          ToolButton {
            visible: root.mode === "record"
            iconText: root.glyph(0xF036C); tooltipText: "M  (microphone)"
            selected: root.microphone
            onClicked: root.microphone = !root.microphone
          }
          ToolButton {
            visible: root.mode === "record"
            iconText: root.glyph(0xF05A0); tooltipText: "C  (webcam overlay)"
            selected: root.webcam
            onClicked: root.webcam = !root.webcam
          }

          Divider {}

          ToolButton {
            iconText: root.glyph(0xF0D11); tooltipText: "T  (copy text from screen)"
            onClicked: root.run("omarchy-capture-text", false)
          }
          ToolButton {
            iconText: root.glyph(0xF0432); tooltipText: "Q  (read a QR code)"
            onClicked: root.run("omarchy-capture-qr", false)
          }
          ToolButton {
            iconText: root.glyph(0xF00C9); tooltipText: "P  (pick a color)"
            onClicked: root.run("pkill hyprpicker || hyprpicker -a", false)
          }

          Divider {}

          ToolButton {
            iconText: root.glyph(0xF0156); tooltipText: "Esc"
            onClicked: root.dismiss()
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.hint
          color: root.foreground
          opacity: 0.6
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
