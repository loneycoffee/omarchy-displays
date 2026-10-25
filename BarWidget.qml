import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// Bar entry and popup for the Displays plugin. Two quiet sections:
//
//   Display mode  resolution and refresh rate dropdowns, applied on change
//   Workspaces    each screen with a tile per workspace showing its apps' icons
//
// Everything goes through bin/displays-ctl; this only renders its state.
// Summon from a keybinding with:  omarchy-shell shell toggle displays
Panel {
  id: root

  moduleName: "displays"

  readonly property string ctl: Qt.resolvedUrl("bin/displays-ctl").toString().replace(/^file:\/\//, "")

  property var monitors: []
  property string primaryChoice: "auto"
  property string selectedName: ""

  readonly property var enabledMonitors: root.monitors.filter(function(m) { return m.enabled })
  readonly property bool multi: root.enabledMonitors.length > 1
  readonly property var mainMonitor: {
    for (var i = 0; i < root.monitors.length; i++) {
      if (root.monitors[i].primary) return root.monitors[i]
    }
    return null
  }
  // The screen the mode sections tune; the main screen unless picked.
  readonly property var selected: {
    var list = root.enabledMonitors
    for (var i = 0; i < list.length; i++) {
      if (list[i].name === root.selectedName) return list[i]
    }
    return root.mainMonitor && root.mainMonitor.enabled ? root.mainMonitor : (list.length > 0 ? list[0] : null)
  }
  // Workspace order: the main screen (1-5) first, screens that are off last.
  readonly property var orderedMonitors: root.monitors.slice().sort(function(a, b) {
    var ka = a.workspaces.length > 0 ? a.workspaces[0] : 99
    var kb = b.workspaces.length > 0 ? b.workspaces[0] : 99
    return ka - kb
  })
  readonly property bool anyOverride: root.monitors.some(function(m) { return m.overridden })

  // Seconds left before a custom mode being tried goes back on its own.
  property int trialLeft: 0
  property string lastError: ""

  readonly property color fg: Color.popups.text
  readonly property color dim: Util.alpha(fg, 0.62)
  readonly property color faint: Util.alpha(fg, 0.38)
  // Glass themes make popups see-through; over a white page that leaves the
  // text unreadable, so this panel and its dropdowns sit on a near-solid fill.
  readonly property color solidBackground: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.96)
  readonly property string fontFamily: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
  readonly property var appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null

  function ratesFor(resolution) {
    var modes = root.selected ? root.selected.modes : []
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].resolution === resolution) return modes[i].rates
    }
    return []
  }

  function currentMode() {
    if (!root.selected) return ""
    var rates = root.ratesFor(root.selected.resolution)
    for (var i = 0; i < rates.length; i++) {
      if (rates[i].hz === root.selected.hz) return rates[i].mode
    }
    return ""
  }

  // Switching resolution keeps the current rate when the screen reports it
  // there, else takes its fastest reported rate; custom rates only when it
  // reports none at that resolution.
  function rateForResolution(resolution) {
    var rates = root.ratesFor(resolution)
    var i
    for (i = 0; i < rates.length; i++) {
      if (!rates[i].custom && root.selected && rates[i].hz === root.selected.hz) return rates[i].mode
    }
    for (i = 0; i < rates.length; i++) {
      if (!rates[i].custom) return rates[i].mode
    }
    return rates.length > 0 ? rates[0].mode : ""
  }

  function pretty(resolution) {
    return String(resolution).replace("x", "×")
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function runCtl(args) {
    if (actionProc.running) return
    actionProc.command = [root.ctl].concat(args)
    actionProc.running = true
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function focusWorkspace(id) {
    focusProc.command = ["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + id + "\" })"]
    focusProc.running = true
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) refresh()

  Process {
    id: stateProc
    command: [root.ctl, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.monitors = parsed.monitors || []
          root.primaryChoice = parsed.primary || "auto"
        } catch (e) {
          root.monitors = []
        }
        root.trialLeft = root.selected ? root.selected.trial : 0
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message === "") return
        console.warn("displays: " + message)
        // "displays-ctl: HDMI-A-1 refused 1920x1080@144" -> "HDMI-A-1 refused ..."
        root.lastError = message.replace(/^displays-ctl:\s*/, "")
        errorClear.restart()
      }
    }
    onRunningChanged: if (!running) root.refresh()
  }

  Timer {
    id: errorClear
    interval: 6000
    onTriggered: root.lastError = ""
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.trialLeft > 0
    onTriggered: {
      root.trialLeft -= 1
      // displays-ctl has put the old mode back by now.
      if (root.trialLeft <= 0) trialDone.restart()
    }
  }

  Timer {
    id: trialDone
    interval: 1500
    onTriggered: root.refresh()
  }

  Process { id: focusProc }

  // The service rearranges workspaces after a hotplug; catch up once it is done.
  Connections {
    target: Quickshell
    function onScreensChanged() { refreshDelay.restart() }
  }

  Timer {
    id: refreshDelay
    interval: 2500
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.anyOverride ? "󰊗" : "󰍺"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(view.implicitHeight, Style.space(760))

    Rectangle {
      anchors.fill: parent
      anchors.margins: -panel.padding
      radius: Style.cornerRadius
      color: root.solidBackground
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: view.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: view
          width: flick.width
          spacing: Style.space(14)

          // ---------- Title ----------
          Text {
            textFormat: Text.PlainText
            text: "Displays"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          ButtonGroup {
            visible: root.multi
            options: root.enabledMonitors.map(function(m) {
              return { value: m.name, label: (m.internal ? "󰌢  " : "󰍹  ") + m.label }
            })
            value: root.selected ? root.selected.name : ""
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onChanged: function(value) { root.selectedName = value }
          }

          // ---------- Display mode ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.selected !== null

            PanelSeparator { foreground: root.fg }

            Item {
              width: parent.width
              height: Math.max(modeHeader.implicitHeight, normalLink.implicitHeight)

              PanelSectionHeader {
                id: modeHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "DISPLAY MODE"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              LinkButton {
                id: normalLink
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !!root.selected && root.selected.overridden
                text: "Back to normal"
                onClicked: root.runCtl(["normal", root.selected.name])
              }
            }

            // A custom mode being tried: keep it, or it goes back on its own.
            Rectangle {
              visible: root.trialLeft > 0
              width: parent.width
              height: trialRow.implicitHeight + Style.space(16)
              radius: Math.min(Style.cornerRadius, Style.space(8))
              color: Util.alpha(Color.accent, 0.12)
              border.width: Style.normalBorderWidth
              border.color: Util.alpha(Color.accent, 0.45)

              Item {
                id: trialRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                implicitHeight: Math.max(trialText.implicitHeight, trialButtons.implicitHeight)

                Column {
                  id: trialText
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    text: "Keep this mode?"
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Going back in " + root.trialLeft + " s"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  id: trialButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  LinkButton {
                    text: "Go back"
                    onClicked: root.runCtl(["undo", root.selected.name])
                  }

                  Button {
                    text: "Keep"
                    selected: true
                    foreground: root.fg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    verticalPadding: Style.spacing.xxs
                    horizontalPadding: Style.spacing.md
                    onClicked: {
                      root.trialLeft = 0
                      root.runCtl(["keep", root.selected.name])
                    }
                  }
                }
              }
            }

            SettingRow {
              label: "Resolution"

              Dropdown {
                width: parent.width
                showLabel: false
                value: root.selected ? root.selected.resolution : ""
                options: (root.selected ? root.selected.modes : []).map(function(m) {
                  var note = m.resolution === root.selected.normalResolution ? "   normal" : (m.custom ? "   custom" : "")
                  return { value: m.resolution, label: root.pretty(m.resolution) + note }
                })
                foreground: root.fg
                background: root.solidBackground
                fontFamily: root.fontFamily
                onChanged: function(value) {
                  if (value === root.selected.resolution) return
                  var mode = root.rateForResolution(value)
                  if (mode !== "") root.runCtl(["mode", root.selected.name, mode])
                }
              }
            }

            SettingRow {
              label: "Refresh rate"

              Dropdown {
                width: parent.width
                showLabel: false
                value: root.currentMode()
                options: root.ratesFor(root.selected ? root.selected.resolution : "").map(function(r) {
                  return { value: r.mode, label: r.hz + " Hz" + (r.custom ? "   custom" : "") }
                })
                foreground: root.fg
                background: root.solidBackground
                fontFamily: root.fontFamily
                onChanged: function(value) { if (value !== root.currentMode()) root.runCtl(["mode", root.selected.name, value]) }
              }
            }

            SettingRow {
              label: "Scale"

              Dropdown {
                width: parent.width
                showLabel: false
                value: root.selected ? String(root.selected.scale) : ""
                options: (root.selected ? root.selected.scales : []).map(function(s) {
                  return { value: String(s), label: Math.round(s * 100) + " %" }
                })
                foreground: root.fg
                background: root.solidBackground
                fontFamily: root.fontFamily
                onChanged: function(value) { if (value !== String(root.selected.scale)) root.runCtl(["scale", root.selected.name, value]) }
              }
            }

            Text {
              visible: root.lastError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.lastError
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.lastError === "" && root.trialLeft === 0
              width: parent.width
              textFormat: Text.PlainText
              text: "Custom modes are built for the screen; if it shows black, it comes back by itself after 15 s. Scale is saved in monitors.lua."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Workspaces ----------
          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.fg }

            Item {
              width: parent.width
              height: Math.max(wsHeader.implicitHeight, autoLink.implicitHeight)

              PanelSectionHeader {
                id: wsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "WORKSPACES"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              LinkButton {
                id: autoLink
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.multi && root.primaryChoice !== "auto"
                text: "Back to auto"
                tooltipText: "The plugged-in screen becomes the main one again"
                onClicked: root.runCtl(["primary", "auto"])
              }
            }

            Repeater {
              model: root.orderedMonitors

              ScreenWorkspaces {
                required property var modelData
                width: view.width
                monitor: modelData
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(2)
          }
        }
      }
    }
  }

  // A small text button for secondary actions, so sections stay calm.
  component LinkButton: Button {
    foreground: root.dim
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    verticalPadding: Style.spacing.xxs
    horizontalPadding: Style.spacing.sm
  }

  // Label on the left, control on the right half.
  component SettingRow: Item {
    id: settingRow
    property string label: ""
    default property alias control: slot.data

    width: parent ? parent.width : 0
    height: Math.max(rowLabel.implicitHeight, slot.childrenRect.height)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.round(settingRow.width * 0.56)
      height: childrenRect.height
    }
  }

  // One screen: its name and main-screen marker, then a tile per workspace.
  component ScreenWorkspaces: Column {
    id: screen
    required property var monitor

    readonly property bool isMain: screen.monitor.primary && root.multi

    spacing: Style.space(6)
    opacity: screen.monitor.enabled ? 1 : 0.45

    Item {
      width: parent.width
      height: Math.max(screenName.implicitHeight, screenActions.implicitHeight)

      Row {
        id: screenName
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: screen.monitor.internal ? "󰌢" : "󰍹"
          color: screen.isMain ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: screen.monitor.label
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: screen.isMain
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          visible: screen.isMain || !screen.monitor.enabled
          text: screen.monitor.enabled ? "main" : "off"
          color: screen.monitor.enabled ? Color.accent : root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: screenActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        LinkButton {
          visible: root.multi && screen.monitor.enabled && !screen.isMain
          text: "Make main"
          onClicked: root.runCtl(["primary", screen.monitor.name])
        }

        // Never offered on the last screen that is on.
        LinkButton {
          visible: screen.monitor.enabled ? root.multi : true
          text: screen.monitor.enabled ? "Turn off" : "Turn on"
          onClicked: root.runCtl(["power", screen.monitor.name, screen.monitor.enabled ? "off" : "on"])
        }
      }
    }

    Grid {
      id: tiles
      visible: screen.monitor.enabled && screen.monitor.workspaces.length > 0
      width: parent.width
      columns: 5
      spacing: Style.space(6)

      readonly property real tileWidth: (width - spacing * (columns - 1)) / columns

      Repeater {
        model: screen.monitor.workspaces

        WorkspaceTile {
          required property int modelData
          width: tiles.tileWidth
          wsId: modelData
        }
      }
    }
  }

  // A workspace: its number, and the icons of the apps open on it.
  component WorkspaceTile: Rectangle {
    id: tile
    property int wsId: 0

    readonly property var workspace: root.workspaceById(tile.wsId)
    readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === tile.wsId
    readonly property var icons: root.appsOn(tile.workspace)
    readonly property int maxIcons: 3

    height: Style.space(46)
    radius: Math.min(Style.cornerRadius, Style.space(8))
    color: tile.focused ? Util.alpha(Color.accent, 0.14)
      : tileHover.hovered ? Util.alpha(root.fg, 0.09)
      : Util.alpha(root.fg, 0.04)
    border.width: Style.normalBorderWidth
    border.color: tile.focused ? Color.accent : Util.alpha(root.fg, 0.10)

    Behavior on color { ColorAnimation { duration: 120 } }

    HoverHandler { id: tileHover }

    Text {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.leftMargin: Style.space(6)
      anchors.topMargin: Style.space(4)
      textFormat: Text.PlainText
      text: tile.wsId === 10 ? "0" : String(tile.wsId)
      color: tile.focused ? Color.accent : (tile.icons.length > 0 ? root.fg : root.faint)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: tile.focused
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(6)
      spacing: Style.space(3)

      Repeater {
        model: tile.icons.slice(0, tile.maxIcons)

        Image {
          required property string modelData
          width: Style.space(16)
          height: Style.space(16)
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
        visible: tile.icons.length > tile.maxIcons
        textFormat: Text.PlainText
        text: "+" + (tile.icons.length - tile.maxIcons)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.focusWorkspace(tile.wsId)
    }
  }
}
