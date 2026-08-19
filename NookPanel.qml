import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for a nook: is it reachable, how is it doing, and what
// is attached here right now. Every number comes from one `nook status --json`
// over a reused SSH connection, so the poll is a single round trip.
Panel {
  id: root
  moduleName: "io.github.achevalier-dev.nook"
  ipcTarget: "io.github.achevalier-dev.nook"

  property bool reachable: false
  property bool everAnswered: false
  property string host: "nook"
  property string uptime: ""
  property real temp: 0
  property real load: 0
  property real diskUsed: 0
  property real diskSize: 0
  property real diskAvail: 0
  property int containers: 0
  property string transport: ""
  property int attachedElsewhere: 0

  // Local facts, asked separately: whether *this* machine holds the folder and
  // the drive. The nook can only count connections, not name them.
  property bool folderMounted: false
  property string driveDevice: ""
  property string driveMount: ""

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property int pollSeconds: Math.max(15, setting("pollSeconds", 60))
  readonly property int warnTemp: setting("warnTemp", 70)
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // omarchy renders these itself, so the font is guaranteed to have them.
  readonly property string glyph: reachable ? "󰋊" : "󰅛"

  readonly property bool driveHere: driveDevice !== ""

  readonly property string stateText: {
    if (!reachable) return everAnswered ? "Unreachable" : "Not adopted"
    if (driveHere) return "Drive attached here"
    if (attachedElsewhere > 0) return "Drive held elsewhere"
    return uptime ? "Up " + uptime : "Reachable"
  }

  function human(bytes) {
    if (!bytes) return "0"
    var units = ["B", "K", "M", "G", "T"]
    var i = 0
    var value = bytes
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
    return (value >= 10 ? Math.round(value) : value.toFixed(1)) + units[i]
  }

  // Rows are built from what is true right now: offering "Eject" while nothing
  // is attached is worse than offering nothing.
  readonly property var actions: {
    var list = []
    if (!reachable) {
      list.push({key: "doctor", label: "Troubleshoot…"})
      return list
    }
    list.push(folderMounted ? {key: "open", label: "Open ~/nook"} : {key: "mount", label: "Mount shared folder"})
    if (folderMounted) list.push({key: "umount", label: "Unmount shared folder"})
    if (driveHere) list.push({key: "eject", label: "Eject drive"})
    else if (attachedElsewhere > 0) list.push({key: "held", label: "Drive is attached elsewhere", disabled: true})
    else list.push({key: "attach", label: "Attach drive"})
    list.push({key: "containers", label: "Containers…"})
    list.push({key: "shell", label: "Shell on the nook"})
    return list
  }

  function runAction(key) {
    if (key === "held") return
    close()
    if (!bar) return
    if (key === "mount") bar.run("nook mount")
    else if (key === "umount") bar.run("nook umount")
    else if (key === "open") bar.run("xdg-open \"$HOME/nook\"")
    else if (key === "attach") bar.run("omarchy-launch-floating-terminal-with-presentation nook attach")
    else if (key === "eject") bar.run("omarchy-launch-floating-terminal-with-presentation nook eject")
    else if (key === "containers") bar.run("omarchy-menu summon nook.containers")
    else if (key === "shell") bar.run("omarchy-launch-floating-terminal nook ssh")
    else if (key === "doctor") bar.run("omarchy-launch-floating-terminal-with-presentation nook doctor")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function clampCursor() {
    var count = actions.length
    cursorIndex = count === 0 ? 0 : Math.max(0, Math.min(cursorIndex, count - 1))
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.collected = ""
    statusProc.running = true
    localProc.collected = ""
    localProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      refresh()
    }
  }

  // ── the nook's own answer ───────────────────────────────────────────────────
  Process {
    id: statusProc
    property string collected: ""
    // BatchMode and a short timeout matter more than the data does: a bar widget
    // that blocks on a password prompt or a dead route freezes the bar.
    command: ["bash", "-c", "timeout 8 nook status --json 2>/dev/null"]
    running: true
    stdout: SplitParser {
      onRead: function (data) { statusProc.collected += String(data) }
    }
    onExited: function (code) {
      var text = statusProc.collected.trim()
      if (code !== 0 || text === "") {
        root.reachable = false
        return
      }
      try {
        var info = JSON.parse(text)
        root.host = info.name || "nook"
        root.uptime = info.uptime || ""
        root.temp = info.temp || 0
        root.load = info.load || 0
        root.diskUsed = info.disk ? info.disk.used : 0
        root.diskSize = info.disk ? info.disk.size : 0
        root.diskAvail = info.disk ? info.disk.avail : 0
        root.containers = info.containers || 0
        root.transport = info.transport || ""
        root.attachedElsewhere = info.attached || 0
        root.reachable = true
        root.everAnswered = true
      } catch (e) {
        root.reachable = false
      }
    }
  }

  // ── what this machine holds ─────────────────────────────────────────────────
  Process {
    id: localProc
    property string collected: ""
    command: ["bash", "-c",
      "mountpoint -q \"$HOME/nook\" && echo folder; "
      + "dev=$(nook disk --local 2>/dev/null | awk '/^disk / && $2 != \"not\" { print $2 }'); "
      + "[[ -n $dev ]] && echo \"drive $dev $(findmnt -nro TARGET --source \"$dev\" 2>/dev/null)\"; true"]
    running: true
    stdout: SplitParser {
      onRead: function (data) { localProc.collected += String(data) + "\n" }
    }
    onExited: {
      var lines = localProc.collected.split("\n")
      root.folderMounted = false
      root.driveDevice = ""
      root.driveMount = ""
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].trim().split(/\s+/)
        if (parts[0] === "folder") root.folderMounted = true
        else if (parts[0] === "drive") {
          root.driveDevice = parts[1] || ""
          root.driveMount = parts[2] || ""
        }
      }
      root.clampCursor()
    }
  }

  // A poll rather than a subscription: there is no event to listen for on the
  // far side of an SSH connection, and once a minute is cheap over ControlMaster.
  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Attaching or ejecting takes a few seconds and the panel is usually closed by
  // then, so re-check shortly after the user acts rather than waiting a minute.
  Timer {
    id: settle
    interval: 4000
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    dimmed: !root.reachable
    tooltipText: root.reachable
      ? root.host + " · " + root.stateText + (root.temp > 0 ? " · " + Math.round(root.temp) + "°C" : "")
      : "nook is not answering"

    onPressed: function (b) {
      if (b === Qt.RightButton) {
        root.runAction(root.driveHere ? "eject" : "attach")
        settle.restart()
      } else if (b === Qt.MiddleButton) {
        root.runAction(root.folderMounted ? "open" : "mount")
        settle.restart()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        root.cursorIndex += dy
        root.clampCursor()
      }
      onActivateRequested: {
        var action = root.actions[root.cursorIndex]
        if (action) {
          root.runAction(action.key)
          settle.restart()
        }
      }
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: root.host
            meta: root.stateText
            detail: root.reachable && root.temp > 0 ? Math.round(root.temp) + "°C" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.reachable ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                text: root.glyph
                color: root.reachable && root.temp >= root.warnTemp ? "#e0af68" : (root.reachable ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            visible: !root.reachable
            text: root.everAnswered
              ? "The nook stopped answering. It is either asleep, off the tailnet, or the SSH connection went stale — Troubleshoot says which."
              : "No nook adopted on this machine yet. Run `nook adopt` in a terminal once, and this panel fills in."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            visible: root.reachable
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "NOOK"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: [
                {label: "disk", value: root.human(root.diskUsed) + " of " + root.human(root.diskSize) + " · " + root.human(root.diskAvail) + " free"},
                {label: "load", value: root.load.toFixed(2)},
                {label: "containers", value: String(root.containers)},
                {label: "drive", value: root.transport + (root.driveHere
                  ? " · attached here" + (root.driveMount ? " at " + root.driveMount : "")
                  : (root.attachedElsewhere > 0 ? " · held by another machine" : " · free"))}
              ]

              Item {
                id: statRow
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(20)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: statRow.modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: statRow.modelData.value
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.actions

              Rectangle {
                id: actionRow
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: Style.space(32)
                radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                color: root.cursorActive && root.cursorIndex === index && !actionRow.modelData.disabled
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : "transparent"

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  text: actionRow.modelData.label
                  color: actionRow.modelData.disabled ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: actionRow.modelData.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
                  onEntered: {
                    root.cursorActive = true
                    root.cursorIndex = actionRow.index
                  }
                  onClicked: {
                    root.runAction(actionRow.modelData.key)
                    settle.restart()
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: "↑↓ move · enter run · esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
