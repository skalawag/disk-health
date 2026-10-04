import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Disk health overlay, dressed like the disk speed test: no card, just
// floating cluster dials on a heavy scrim. Each drive gets a temperature dial
// and a lifespan-used dial (with amber/red zones at its limits), then its
// SMART figures and any problems. Esc or the scrim dismiss it; Enter or
// "Check Now" re-runs the collector.
//
// Data comes from /var/lib/disk-health/status.json, written hourly by the
// root-side disk-health.service. "Check Now" starts that unit, which a polkit
// rule lets this user do without a password.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string defaultStatusPath: "/var/lib/disk-health/status.json"
  // A summon payload may point at another file, for testing:
  // omarchy-shell shell summon skalawag.disk-health '{"statusPath":"/tmp/x.json"}'
  property string statusPath: defaultStatusPath

  property bool opened: false
  property var report: null
  property string error: ""
  property bool checking: false
  property int checkExit: 0
  property real nowEpoch: Date.now() / 1000

  // The scrim is a fixed near-black regardless of theme, so text on it uses
  // a fixed light palette (as the speed test overlay does).
  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  readonly property color onScrimFaint: Qt.rgba(1, 1, 1, 0.35)
  readonly property color warnColor: "#ffb454"
  readonly property color urgentColor: "#ff6b6b"

  readonly property var drives: report && report.drives ? report.drives : []

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    statusPath = payload.statusPath || defaultStatusPath
    opened = true
    nowEpoch = Date.now() / 1000
    statusFile.reload()
  }

  function close() {
    opened = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "skalawag.disk-health")
    else close()
  }

  function parseReport() {
    try {
      report = JSON.parse(statusFile.text())
      if (!checking) error = ""
    } catch (e) {
      report = null
      error = "Couldn't read " + statusPath
    }
  }

  function checkNow() {
    if (checking) return
    checking = true
    error = ""
    checkProc.running = true
  }

  function statusColor(status) {
    if (status === "critical") return urgentColor
    if (status === "warning") return warnColor
    if (status === "ok") return Color.accent
    return onScrimDim
  }

  function statusLabel(status) {
    return ({ ok: "Healthy", warning: "Warning", critical: "Critical", unavailable: "No SMART data" })[status] || status
  }

  function headline() {
    if (!report) return ""
    var bad = 0
    for (var i = 0; i < drives.length; i++)
      if (drives[i].status === "warning" || drives[i].status === "critical") bad++
    if (bad === 0) return "All drives healthy"
    return bad === 1 ? "1 drive needs attention" : bad + " drives need attention"
  }

  function ago(epoch) {
    var s = Math.max(0, nowEpoch - Number(epoch || 0))
    if (s < 90) return "just now"
    if (s < 3600) return Math.round(s / 60) + " min ago"
    if (s < 48 * 3600) return Math.round(s / 3600) + " h ago"
    return Math.round(s / 86400) + " days ago"
  }

  function num(value) {
    return Number(value).toLocaleString(Qt.locale(), 'f', 0)
  }

  function bytes(value) {
    var units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var v = Number(value), i = 0
    while (v >= 1000 && i < units.length - 1) { v /= 1000; i++ }
    return v.toLocaleString(Qt.locale(), 'f', v < 10 && i > 0 ? 1 : 0) + " " + units[i]
  }

  function hours(value) {
    var h = Number(value)
    return h >= 48 ? num(h) + " h · " + num(h / 24) + " days" : num(h) + " h"
  }

  // [label, value] rows for whatever this drive reports; nulls are skipped.
  function statRows(d) {
    var rows = []
    function add(label, value, fmt) {
      if (value !== null && value !== undefined) rows.push({ label: label, value: fmt ? fmt(value) : num(value) })
    }
    add("Power-on time", d.power_on_hours, hours)
    add("Power cycles", d.power_cycles)
    add("Unsafe shutdowns", d.unsafe_shutdowns)
    add("Data written", d.data_written_bytes, bytes)
    add("Spare capacity", d.spare_pct, function(v) { return v + "%" + (d.spare_threshold_pct !== null ? " (min " + d.spare_threshold_pct + "%)" : "") })
    add("Media errors", d.media_errors)
    add("Error log entries", d.error_log_entries)
    add("Reallocated sectors", d.reallocated_sectors)
    add("Pending sectors", d.pending_sectors)
    add("Uncorrectable", d.offline_uncorrectable)
    add("Firmware", d.firmware || null, function(v) { return v })
    return rows
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseReport()
    onLoadFailed: {
      root.report = null
      root.error = "No disk-health data yet. Run: ~/projects/omarchy/disk-health/install.sh"
    }
  }

  Process {
    id: checkProc
    command: ["systemctl", "start", "disk-health.service"]
    // Exit and stream-finished have no guaranteed order; whichever lands
    // second fills in the specific message.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (root.checkExit !== 0 && msg !== "") root.error = msg
      }
    }
    onExited: function(exitCode) {
      root.checkExit = exitCode
      root.checking = false
      root.nowEpoch = Date.now() / 1000
      if (exitCode !== 0 && root.error === "") root.error = "Disk check failed (systemctl exit " + exitCode + ")"
      statusFile.reload()
    }
  }

  Timer {
    interval: 30 * 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowEpoch = Date.now() / 1000
  }

  PanelWindow {
    id: overlay

    visible: root.opened
    onVisibleChanged: if (visible) Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "skalawag-disk-health"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.dismiss()
      Keys.onReturnPressed: root.checkNow()
      Keys.onEnterPressed: root.checkNow()

      Item {
        id: cluster
        anchors.centerIn: parent
        width: content.implicitWidth
        height: content.implicitHeight
        scale: Math.min(1,
          (keyCatcher.width - Style.space(32)) / Math.max(1, width),
          (keyCatcher.height - Style.space(32)) / Math.max(1, height))

        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          id: content
          anchors.fill: parent
          spacing: Style.space(16)

          Text {
            textFormat: Text.PlainText
            text: "DISK HEALTH"
            color: root.onScrimDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 2
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            text: root.headline()
            color: root.statusColor(root.report ? root.report.status : "")
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          Row {
            spacing: Style.space(64)
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(8)

            Repeater {
              model: root.drives
              delegate: DriveCluster {}
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.report !== null
            text: root.checking ? "Checking drives…" : "Checked " + root.ago(root.report ? root.report.checked_at_epoch : 0)
            color: root.onScrimFaint
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          Button {
            text: "Check Now"
            tooltipText: "Re-read SMART data from every drive"
            bordered: true
            enabled: !root.checking
            opacity: root.checking ? 0.35 : 1
            foreground: root.onScrim
            fontFamily: Style.font.family
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(14)
            verticalPadding: Style.space(4)
            Layout.alignment: Qt.AlignHCenter
            onClicked: root.checkNow()

            Behavior on opacity {
              NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.error !== ""
            text: root.error
            color: root.urgentColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.maximumWidth: Style.space(440)
            Layout.alignment: Qt.AlignHCenter
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // One drive: name and status over a pair of dials, then its figures and
  // any problems the collector flagged.
  component DriveCluster: Column {
    id: drive

    required property var modelData
    readonly property var d: modelData
    readonly property bool hasData: d.status !== "unavailable"

    spacing: Style.space(14)
    width: dials.width

    Column {
      width: parent.width
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: String(drive.d.model || drive.d.device).toUpperCase()
        color: root.onScrim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.5
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: [drive.d.device, drive.d.capacity_bytes ? root.bytes(drive.d.capacity_bytes) : "", drive.d.protocol]
          .filter(function(s) { return s }).join("  ·  ")
        color: root.onScrimDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.statusLabel(drive.d.status).toUpperCase()
        color: root.statusColor(drive.d.status)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 2
        horizontalAlignment: Text.AlignHCenter
      }
    }

    Row {
      id: dials
      spacing: Style.space(28)
      anchors.horizontalCenter: parent.horizontalCenter

      HealthDial {
        id: tempDial
        label: "TEMP"
        unit: "°C"
        value: drive.d.temperature_c
        fullScale: 100
        warnAt: drive.d.temperature_warn_c || 0
        critAt: drive.d.temperature_crit_c || 0
      }

      HealthDial {
        id: lifeDial
        label: "LIFE USED"
        unit: "%"
        value: drive.d.life_used_pct
        fullScale: 100
        warnAt: 80
        critAt: 90
      }
    }

    Connections {
      target: root
      function onOpenedChanged() {
        if (root.opened) Qt.callLater(function() { tempDial.ignite(); lifeDial.ignite() })
      }
    }
    Component.onCompleted: if (root.opened) Qt.callLater(function() { tempDial.ignite(); lifeDial.ignite() })

    // Figures: label left, value right, in a narrow column under the dials.
    Column {
      visible: drive.hasData
      spacing: Style.space(3)
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(parent.width, Style.space(300))

      Repeater {
        model: root.statRows(drive.d)

        delegate: Item {
          required property var modelData
          width: parent.width
          implicitHeight: labelText.implicitHeight

          Text {
            id: labelText
            textFormat: Text.PlainText
            anchors.left: parent.left
            text: parent.modelData.label
            color: root.onScrimDim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            text: parent.modelData.value
            color: root.onScrim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }

    // Problems, worst first as the collector listed them, then any note
    // (e.g. why a USB drive has no SMART data).
    Column {
      width: Math.min(parent.width, Style.space(300))
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(4)

      Repeater {
        model: drive.d.problems || []

        delegate: Text {
          required property var modelData
          textFormat: Text.PlainText
          width: parent.width
          text: "●  " + modelData.text
          color: root.statusColor(modelData.level)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: !!drive.d.note
        width: parent.width
        text: drive.d.note || ""
        color: root.onScrimDim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.italic: true
        wrapMode: Text.Wrap
        horizontalAlignment: drive.hasData ? Text.AlignLeft : Text.AlignHCenter
      }
    }
  }

  // The speed test's floating cluster dial, adapted for gauges with limits:
  // an open 270° scale, faint tick ring, amber and red zones from the warning
  // and critical limits to full scale, and a value arc and needle that take
  // the zone's color once the reading enters it. A null value parks the
  // needle and shows a dash.
  component HealthDial: Item {
    id: dial

    required property string label
    required property string unit
    property var value: null
    property real fullScale: 100
    property real warnAt: 0
    property real critAt: 0

    readonly property bool hasValue: value !== null && value !== undefined && isFinite(value)
    readonly property real target: hasValue ? Number(value) : 0
    readonly property real diameter: Style.space(170)
    readonly property real dialStart: 135
    readonly property real dialSweep: 270
    readonly property int tickCount: 41
    readonly property real arcWidth: Style.space(4)
    readonly property real arcRadius: diameter / 2 - arcWidth

    readonly property string level: !hasValue ? "none"
      : critAt > 0 && target >= critAt ? "critical"
      : warnAt > 0 && target >= warnAt ? "warning"
      : "ok"
    readonly property color levelColor: level === "none" ? root.onScrimDim : root.statusColor(level)

    property real shown: 0
    readonly property real fraction: fullScale > 0 ? Math.max(0, Math.min(1, shown / fullScale)) : 0
    readonly property bool arcVisible: fraction > 0.004

    function frac(v) { return Math.max(0, Math.min(1, v / fullScale)) }

    width: diameter
    height: diameter
    opacity: hasValue ? 1 : 0.5

    Behavior on shown {
      enabled: !ignition.running
      NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
    }

    onTargetChanged: if (!ignition.running) shown = target
    Component.onCompleted: shown = target

    function ignite() {
      ignition.restart()
    }

    SequentialAnimation {
      id: ignition
      NumberAnimation { target: dial; property: "shown"; to: dial.fullScale; duration: 550; easing.type: Easing.InOutCubic }
      NumberAnimation { target: dial; property: "shown"; to: dial.target; duration: 650; easing.type: Easing.OutCubic }
      onFinished: dial.shown = dial.target
    }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: dial.arcWidth
        strokeColor: Qt.rgba(1, 1, 1, 0.14)
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2; centerY: dial.height / 2
          radiusX: dial.arcRadius; radiusY: dial.arcRadius
          startAngle: dial.dialStart; sweepAngle: dial.dialSweep
        }
      }

      // Warning zone (amber) up to the critical limit, then the redline.
      ShapePath {
        strokeWidth: dial.arcWidth
        strokeColor: dial.warnAt > 0 ? Qt.rgba(1, 0.71, 0.33, 0.35) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathAngleArc {
          centerX: dial.width / 2; centerY: dial.height / 2
          radiusX: dial.arcRadius; radiusY: dial.arcRadius
          startAngle: dial.dialStart + dial.dialSweep * dial.frac(dial.warnAt)
          sweepAngle: dial.dialSweep * (dial.frac(dial.critAt > 0 ? dial.critAt : dial.fullScale) - dial.frac(dial.warnAt))
        }
      }

      ShapePath {
        strokeWidth: dial.arcWidth
        strokeColor: dial.critAt > 0 ? Qt.rgba(1, 0.42, 0.42, 0.45) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathAngleArc {
          centerX: dial.width / 2; centerY: dial.height / 2
          radiusX: dial.arcRadius; radiusY: dial.arcRadius
          startAngle: dial.dialStart + dial.dialSweep * dial.frac(dial.critAt)
          sweepAngle: dial.dialSweep * (1 - dial.frac(dial.critAt))
        }
      }

      ShapePath {
        strokeWidth: dial.arcWidth * 3
        strokeColor: dial.arcVisible ? Qt.rgba(dial.levelColor.r, dial.levelColor.g, dial.levelColor.b, 0.18) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2; centerY: dial.height / 2
          radiusX: dial.arcRadius; radiusY: dial.arcRadius
          startAngle: dial.dialStart; sweepAngle: dial.dialSweep * dial.fraction
        }
      }

      ShapePath {
        strokeWidth: dial.arcWidth
        strokeColor: dial.arcVisible ? dial.levelColor : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2; centerY: dial.height / 2
          radiusX: dial.arcRadius; radiusY: dial.arcRadius
          startAngle: dial.dialStart; sweepAngle: dial.dialSweep * dial.fraction
        }
      }
    }

    Repeater {
      model: dial.tickCount

      Item {
        required property int index
        readonly property bool major: index % 5 === 0

        anchors.fill: parent
        rotation: dial.dialStart + (index / (dial.tickCount - 1)) * dial.dialSweep - 270

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: dial.arcWidth * 2 + (parent.major ? 0 : Style.space(2))
          width: parent.major ? Math.max(2, Style.space(2)) : 1
          height: parent.major ? Style.space(10) : Style.space(6)
          radius: width / 2
          color: parent.major ? Qt.rgba(1, 1, 1, 0.3) : Qt.rgba(1, 1, 1, 0.12)
        }
      }
    }

    Item {
      anchors.fill: parent
      visible: dial.hasValue
      rotation: dial.dialStart + dial.fraction * dial.dialSweep - 270

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: dial.arcWidth * 2 + Style.space(10)
        width: Math.max(2, Style.space(3))
        height: dial.diameter * 0.32
        radius: width / 2

        gradient: Gradient {
          GradientStop { position: 0.0; color: dial.levelColor }
          GradientStop { position: 0.55; color: dial.levelColor }
          GradientStop { position: 1.0; color: "transparent" }
        }
      }
    }

    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.verticalCenter
      anchors.topMargin: Style.space(12)
      spacing: 0

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: dial.hasValue ? Math.round(dial.target).toLocaleString(Qt.locale(), 'f', 0) : "—"
        color: dial.level === "warning" || dial.level === "critical" ? dial.levelColor : root.onScrim
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: dial.unit
        color: root.onScrimDim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      text: dial.label
      color: root.onScrimDim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.5
    }
  }
}
