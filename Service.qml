import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Keeps workspaces 1-5 on the main screen and 6-10 on the other one.
//
// Mounted once for the shell. It runs `displays-ctl apply` when the shell
// starts and whenever a screen is plugged in or removed; the script does the
// work, so it can also be run by hand. At start it also installs or refreshes
// the companion workspaces widget (companion/displays-workspaces).
Item {
  id: root
  width: 0
  height: 0
  visible: false

  // Host injection.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string ctl: Qt.resolvedUrl("bin/displays-ctl").toString().replace(/^file:\/\//, "")
  property bool pending: false

  function schedule() {
    settle.restart()
  }

  function run() {
    if (applyProc.running) {
      root.pending = true
      return
    }
    applyProc.running = true
  }

  // A new screen reports its modes a moment after it appears.
  Timer {
    id: settle
    interval: 1500
    onTriggered: root.run()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && /^monitor(added|removed)/.test(String(event.name))) root.schedule()
    }
  }

  Process {
    id: applyProc
    command: [root.ctl, "apply"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") console.warn("displays: " + text)
    }
    onRunningChanged: {
      if (running || !root.pending) return
      root.pending = false
      root.run()
    }
  }

  Process {
    id: companionProc
    command: [root.ctl, "sync-companion"]
  }

  Component.onCompleted: {
    companionProc.running = true
    root.schedule()
  }
}
