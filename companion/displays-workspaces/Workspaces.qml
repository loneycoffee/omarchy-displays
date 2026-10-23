import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Omarchy's workspaces widget, narrowed to the bar's own screen, with the
// icons of the apps open on each workspace next to its number.
//
// The displays plugin writes which workspaces belong to which screen
// ($XDG_RUNTIME_DIR/omarchy-displays/layout.json); each bar shows its screen's
// range plus any other workspace that currently sits on that screen. A dim
// laptop or monitor glyph in front says which screen the numbers are on.
// Without the displays plugin it falls back to the stock 1-5.
BarWidget {
  id: root

  moduleName: "displays-workspaces"

  property var layout: ({})
  readonly property int maxIcons: 3

  readonly property string screenName: {
    var win = root.QsWindow ? root.QsWindow.window : null
    return win && win.screen ? String(win.screen.name) : ""
  }
  readonly property bool internalScreen: /^(eDP|LVDS|DSI)-/.test(root.screenName)
  readonly property color foreground: root.bar ? root.bar.barForeground : Color.foreground
  readonly property string fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
  readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceIds() {
    var known = Object.keys(root.layout).length > 0
    var ids = known ? (root.layout[root.screenName] || []).slice() : [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      var here = !known || (ws.monitor && ws.monitor.name === root.screenName)
      if (ws.id > 0 && ws.id <= 10 && here && ids.indexOf(ws.id) === -1) ids.push(ws.id)
    }
    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  function appIdOf(toplevel) {
    if (toplevel.wayland && toplevel.wayland.appId) return String(toplevel.wayland.appId)
    var ipc = toplevel.lastIpcObject
    return ipc && ipc["class"] ? String(ipc["class"]) : ""
  }

  // Web app host -> icon, from the launchers that open a URL (Omarchy's
  // "omarchy-launch-webapp https://..." entries, including the ones that are
  // not installed in ~/.local/share/applications).
  property var webIcons: ({})

  function hasIcon(name) {
    if (!name) return false
    if (name.charAt(0) === "/") return true
    if (root.appLibrary && root.appLibrary.iconIndex[name]) return true
    return Quickshell.iconPath(name, true).length > 0
  }

  function sourceOf(icon) {
    return root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon || "application-x-executable", true)
  }

  // Chromium-family web apps get a class like brave-web.whatsapp.com__-Default.
  function webHostOf(appId) {
    var m = /^(?:google-chrome[a-z-]*|chromium|chrome|brave|microsoft-edge[a-z-]*|msedge|vivaldi[a-z-]*|opera|helium)-([^_]+)__/.exec(appId)
    return m ? m[1].toLowerCase() : ""
  }

  function webIconFor(host) {
    // web.whatsapp.com, then whatsapp.com: a launcher on either matches.
    for (var h = host; h.indexOf(".") !== -1; h = h.slice(h.indexOf(".") + 1)) {
      if (root.webIcons[h] && root.hasIcon(root.webIcons[h])) return root.webIcons[h]
    }
    // No launcher: try the site's name as an icon (whatsapp, youtube, ...).
    var labels = host.split(".").slice(0, -1).filter(function(l) { return !/^(www|web|app|m|mobile)$/.test(l) })
    for (var i = labels.length - 1; i >= 0; i--) {
      if (root.hasIcon(labels[i])) return labels[i]
      if (i > 0 && root.hasIcon(labels[i] + "-" + labels[i - 1])) return labels[i] + "-" + labels[i - 1]
    }
    return ""
  }

  function entryIcon(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    return entry && root.hasIcon(entry.icon) ? entry.icon : ""
  }

  function iconFor(appId) {
    var icon = ""
    var host = root.webHostOf(appId)
    if (host) icon = root.webIconFor(host) || root.entryIcon(appId.split("-")[0])

    // Steam games run as steam_app_<id>; Steam installs steam_icon_<id>.
    var game = /^steam_app_(\d+)$/.exec(appId)
    if (!icon && game) icon = root.hasIcon("steam_icon_" + game[1]) ? "steam_icon_" + game[1] : "steam"

    if (!icon) icon = root.entryIcon(appId)

    // Omarchy's TUIs run in the terminal under app-ids like TUI.finder.
    if (!icon && /^(TUI\.|org\.omarchy\.)/.test(appId)) icon = root.entryIcon("foot")

    if (!icon) {
      // Last resorts: the app-id itself, its last reverse-DNS part, or its
      // first word (org.gnome.Nautilus -> nautilus, gimp-2.10 -> gimp).
      var lower = appId.toLowerCase()
      var candidates = [lower, lower.split(".").pop(), lower.split(/[-_ .]/)[0], lower.replace(/\.desktop$/, "")]
      for (var i = 0; i < candidates.length && !icon; i++) {
        if (root.hasIcon(candidates[i])) icon = candidates[i]
        else icon = root.entryIcon(candidates[i])
      }
    }
    return root.sourceOf(icon)
  }

  Process {
    id: webScan
    running: true
    command: ["bash", "-c",
      'for f in "${OMARCHY_PATH:-/usr/share/omarchy}"/applications/*.desktop /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop; do ' +
      '[ -f "$f" ] && awk \'/^Exec=/ && !e { e = $0 } /^Icon=/ && !i { i = substr($0, 6) } ' +
      'END { if (i != "" && match(e, /https?:\\/\\/[^\\/ "%]+/)) print substr(e, RSTART, RLENGTH) "\\t" i }\' "$f"; done']
    stdout: StdioCollector {
      onStreamFinished: {
        var next = ({})
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (parts.length < 2) continue
          next[parts[0].replace(/^https?:\/\//, "").toLowerCase()] = parts[1]
        }
        root.webIcons = next
      }
    }
  }

  // New launchers (a web app just installed) and new icons show up live.
  Connections {
    target: root.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { webScan.running = true }
  }

  // One icon per app on the workspace, in window order.
  function appsOn(workspace) {
    if (!workspace) return []
    var seen = {}
    var out = []
    var tops = workspace.toplevels.values
    for (var i = 0; i < tops.length; i++) {
      var id = root.appIdOf(tops[i])
      if (id === "" || seen[id]) continue
      seen[id] = true
      out.push(root.iconFor(id))
    }
    return out
  }

  FileView {
    id: layoutFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-displays/layout.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.layout = JSON.parse(text())
      } catch (e) {
        root.layout = ({})
      }
    }
    onLoadFailed: {
      root.layout = ({})
      retry.restart()
    }
  }

  // The bar can come up before displays-ctl has written layout.json, and a
  // missing file is not watched: try again until it shows up.
  Timer {
    id: retry
    interval: 1000
    onTriggered: layoutFile.reload()
  }

  // Backstop for the file watch: the layout settles shortly after a hotplug.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && /^monitor(added|removed)/.test(String(event.name))) relayout.restart()
    }
  }

  Timer {
    id: relayout
    interval: 2500
    onTriggered: layoutFile.reload()
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: row.implicitWidth + trailingGap
  implicitHeight: row.implicitHeight

  GridLayout {
    id: row
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length + 1
    columnSpacing: root.vertical ? 0 : Style.space(2)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Text {
      textFormat: Text.PlainText
      text: root.internalScreen ? "󰌢" : "󰍹"
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      Layout.alignment: Qt.AlignCenter
      Layout.leftMargin: root.vertical ? 0 : Style.space(4)
      Layout.rightMargin: root.vertical ? 0 : Style.space(2)
    }

    Repeater {
      model: root.workspaceIds()

      Item {
        id: cell
        required property int modelData

        readonly property var workspace: root.workspaceById(cell.modelData)
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === cell.modelData
        // Icons only on a horizontal bar; a vertical one keeps the numbers.
        readonly property var icons: root.vertical ? [] : root.appsOn(cell.workspace)
        readonly property real iconSize: Math.max(12, Math.round(root.barSize * 0.5))

        implicitWidth: root.vertical ? root.barSize : Math.max(Style.space(20), content.implicitWidth + Style.space(12))
        implicitHeight: root.barSize
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        opacity: cell.icons.length > 0 || cell.focused || (cell.workspace && cell.workspace.toplevels.values.length > 0) ? 1 : 0.5

        // The focused workspace sits on a soft pill, so its icons stay visible.
        Rectangle {
          anchors.fill: parent
          anchors.topMargin: Style.space(4)
          anchors.bottomMargin: Style.space(4)
          radius: Math.min(height / 2, Style.space(8))
          color: cell.focused ? Util.alpha(Color.accent, 0.22) : (cellMouse.containsMouse ? Util.alpha(root.foreground, 0.10) : "transparent")
          Behavior on color { ColorAnimation { duration: 120 } }
        }

        Row {
          id: content
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: cell.modelData === 10 ? "0" : String(cell.modelData)
            color: cell.focused ? Color.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: cell.focused
          }

          Repeater {
            model: cell.icons.slice(0, root.maxIcons)

            Image {
              required property string modelData
              anchors.verticalCenter: parent.verticalCenter
              width: cell.iconSize
              height: cell.iconSize
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              source: modelData
              asynchronous: true
              smooth: true
              mipmap: true
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: cell.icons.length > root.maxIcons
            textFormat: Text.PlainText
            text: "+" + (cell.icons.length - root.maxIcons)
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: cellMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.focusWorkspace(cell.modelData)
        }
      }
    }
  }
}
