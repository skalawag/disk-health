import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Background half of the disk-health monitor. The root-side collector
// (disk-health.timer → /usr/local/bin/disk-health-collect) writes
// /var/lib/disk-health/status.json hourly; this only reads it and raises a
// notification when a drive picks up a problem it hasn't already alerted on.
// Clicking the notification summons the skalawag.disk-health panel.
//
// Problems are compared with their numbers masked, so a temperature drifting
// 57 → 58°C doesn't re-alert, but a new kind of problem, a worse level, or
// growing reallocated sectors does. What was last alerted is kept in
// ~/.local/state/disk-health/alerted.json, so shell restarts don't repeat it.
//
// IPC: omarchy-shell diskhealth status | simulate
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string statusPath: "/var/lib/disk-health/status.json"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/disk-health/alerted.json"
  readonly property int staleSeconds: 26 * 3600
  readonly property var openArgv: ["omarchy-shell", "shell", "summon", "skalawag.disk-health"]
  readonly property string glyph: "󰋊"

  // drive key (serial or device) → array of problem signatures last alerted.
  property var alerted: ({})
  property bool alertedLoaded: false
  property string lastSummary: "waiting for data"

  function signature(problem) {
    var text = String(problem.text || "").replace(/ \(\+\d+ since last check\)/, "")
    return problem.level + ":" + text.replace(/\d+/g, "#")
  }

  function notify(urgency, headline, body) {
    Util.execArgv(["omarchy-notification-send", "--app-name", "Disk health",
      "-u", urgency, "-g", root.glyph, headline, body, "--exec"].concat(root.openArgv))
  }

  function saveAlerted() {
    Util.execArgv(["bash", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1"',
      "bash", root.statePath, JSON.stringify(root.alerted)])
  }

  function evaluate() {
    if (!root.alertedLoaded) return
    var report
    try {
      report = JSON.parse(statusFile.text())
    } catch (e) {
      root.lastSummary = "no readable status file"
      return
    }
    root.lastSummary = report.status + " at " + report.checked_at
    var next = assess(report, root.alerted)
    if (JSON.stringify(next) !== JSON.stringify(root.alerted)) {
      root.alerted = next
      saveAlerted()
    }
  }

  // Notifies about anything in `report` not already in `before`, and returns
  // the new alerted map.
  function assess(report, before) {
    var next = {}
    var lines = []
    var worst = "warning"

    var age = Date.now() / 1000 - Number(report.checked_at_epoch || 0)
    if (age > root.staleSeconds) {
      next["__stale"] = ["stale"]
      if (!before["__stale"]) {
        lines.push("No disk check for " + Math.round(age / 3600) + " hours. Is disk-health.timer running?")
      }
    }

    var drives = report.drives || []
    for (var i = 0; i < drives.length; i++) {
      var d = drives[i]
      if (d.status !== "warning" && d.status !== "critical") continue
      var key = d.serial || d.device
      var seen = before[key] || []
      var sigs = []
      var fresh = []
      for (var j = 0; j < (d.problems || []).length; j++) {
        var p = d.problems[j]
        var sig = signature(p)
        sigs.push(sig)
        if (seen.indexOf(sig) < 0 || /since last check/.test(p.text)) fresh.push(p.text)
      }
      next[key] = sigs
      if (fresh.length > 0) {
        if (d.status === "critical") worst = "critical"
        lines.push((d.model || d.device) + ": " + fresh.join("; "))
      }
    }

    if (lines.length > 0) {
      notify(worst === "critical" ? "critical" : "normal",
        worst === "critical" ? "Disk problem detected" : "Disk health warning",
        lines.join("\n"))
    }
    return next
  }

  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    onLoaded: {
      try { root.alerted = JSON.parse(text()) || {} } catch (e) { root.alerted = {} }
      root.alertedLoaded = true
      statusFile.reload()
    }
    onLoadFailed: {
      root.alertedLoaded = true
      statusFile.reload()
    }
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.evaluate()
  }

  // The collector replaces the file atomically, which can drop the watch, and
  // staleness needs a clock anyway: re-read every few minutes.
  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: statusFile.reload()
  }

  IpcHandler {
    target: "diskhealth"

    function status(): string {
      return root.lastSummary
    }

    // Runs the alert logic on a made-up failing drive (nothing is saved), so
    // the notification → panel path can be checked without a real fault.
    function simulate(): string {
      root.assess({
        checked_at_epoch: Date.now() / 1000,
        drives: [{ model: "Simulated drive", device: "/dev/simulated", serial: "SIMULATED", status: "critical",
          problems: [{ level: "critical", text: "3 sectors pending reallocation (simulated)" }] }]
      }, {})
      return "sent"
    }
  }
}
