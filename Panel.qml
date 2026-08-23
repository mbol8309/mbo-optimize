import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "mbo.optimize"
  ipcTarget: "mbo.optimize"
  manageIpc: false

  // ----- theme (lifted off the host bar when present) ---------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color good: Color.accent
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----- state ------------------------------------------------------------
  // state.json is the single source of truth the bar reads; recommendations.json
  // holds the full list shown in the panel. Both live in
  // ~/.local/state/omarchy/optimize/ and are written by the bin scripts.
  property var state: ({})
  property var recommendations: []
  property var selected: ({})        // id -> true
  property int selectedCount: 0
  property bool scanning: false
  property var applied: ({})         // id -> status (running|ok|failed|partial|skipped)

  readonly property string status: state.status || "idle"      // idle|scanning|optimized|pending|error
  readonly property int pendingCount: state.pending_count || 0
  readonly property string lastScan: state.last_scan || ""
  readonly property string lastScanShort: {
    if (!lastScan) return "never"
    var d = new Date(lastScan)
    if (isNaN(d.getTime())) return lastScan
    return d.toLocaleDateString(Qt.locale(), "MMM d")
  }
  readonly property bool alarming: status === "pending" && pendingCount > 0

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // ----- actions ----------------------------------------------------------
  function refreshState() { if (!stateProc.running) stateProc.running = true }
  function refreshRecs()  { if (!recsProc.running)  recsProc.running  = true }

  function scanNow() {
    if (scanning) return
    scanning = true
    state = Object.assign({}, state, { status: "scanning" })
    scanProc.running = true
  }

  function toggleSelected(id) {
    var next = Object.assign({}, selected)
    if (next[id]) delete next[id]; else next[id] = true
    selected = next
    selectedCount = Object.keys(next).length
  }
  function selectAll() {
    var next = {}; for (var i = 0; i < recommendations.length; i++) next[recommendations[i].id] = true
    selected = next
    selectedCount = Object.keys(next).length
  }
  function selectNone() { selected = ({}); selectedCount = 0 }
  function clearApplied() { applied = ({}) }

  function applySelected() {
    if (selectedCount === 0) return
    var ids = Object.keys(selected)
    var marked = {}; for (var i = 0; i < ids.length; i++) marked[ids[i]] = "running"
    applied = marked
    applyProc.command = ["omarchy-optimize-apply", "apply", JSON.stringify(ids)]
    applyProc.running = true
  }

  function dismiss(id) {
    dismissProc.command = ["omarchy-optimize-state", "dismiss", id]
    dismissProc.running = true
  }

  // ----- IPC surface (omarchy-shell mbo.optimize <open|scan|apply|...>) --
  IpcHandler {
    target: "mbo.optimize"

    function open(): string { root.open(); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function scan(): string { root.scanNow(); return "ok" }
    function apply(): string { root.applySelected(); return "ok" }
    function applyIds(idsJson: string): string {
      var ids = JSON.parse(idsJson)
      var marked = {}; for (var i = 0; i < ids.length; i++) marked[ids[i]] = true
      selected = marked; root.applySelected(); return "ok"
    }
    function refresh(): string { root.refreshState(); root.refreshRecs(); return "ok" }
    function dismiss(id: string): string { root.dismiss(id); return "ok" }
  }

  // ----- bar button -------------------------------------------------------
  // Icon only appears when there is something to say (pending recs), so an
  // already-optimized machine stays quiet. The tooltip carries the at-a-glance
  // status the user hovers for.
  visible: alarming || scanning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: scanning ? "\uf110" : "\uf0e4"   // spinner-ish / tachometer
    active: root.alarming
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: {
      if (scanning) return "Optimize: scanning…"
      if (status === "optimized") return "Optimize: system is optimized (last " + lastScanShort + ")"
      if (status === "pending")   return "Optimize: " + pendingCount + " recommendation" + (pendingCount === 1 ? "" : "s") + " (last " + lastScanShort + ")"
      if (status === "error")     return "Optimize: last scan failed"
      return "Optimize"
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.scanNow()
      else root.toggle()
    }
  }

  // ----- popup ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.scanNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.scanNow()
        else if (t === "a" || t === "A") root.selectAll()
        else if (t === "n" || t === "N") root.selectNone()
        else if (t === "Enter") root.applySelected()
      }

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
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: "Optimize"
            meta: {
              if (scanning) return "Analyzing system with your agent…"
              if (status === "optimized") return "System is optimized · last scan " + lastScanShort
              if (status === "pending")   return pendingCount + " recommendation" + (pendingCount === 1 ? "" : "s") + " · last scan " + lastScanShort
              if (status === "error")     return "Last scan failed — retry from the toolbar"
              return "No scan yet"
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              OpticalGlyph { text: "\uf0e4"; color: root.alarming ? root.urgent : root.foreground }
            }
          }

          // ---------- Actions row ----------
          Row {
            width: parent.width
            spacing: Style.space(8)
            Button { text: "Scan now";     enabled: !scanning; onClicked: root.scanNow() }
            Button { text: "Select all";   enabled: recommendations.length > 0; onClicked: root.selectAll() }
            Button { text: "Clear";        enabled: selectedCount > 0; onClicked: root.selectNone() }
            Button {
              text: "Execute (" + selectedCount + ")"
              enabled: selectedCount > 0 && !scanning
              onClicked: root.applySelected()
            }
          }

          PanelSectionHeader { text: "Recommendations" }

          // ---------- Empty states ----------
          Text {
            width: parent.width
            visible: recommendations.length === 0 && !scanning
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            text: "Nothing to optimize right now. Run a scan to let your AI agent review disk usage and installed packages."
          }
          Text {
            visible: scanning
            color: root.dim
            font.family: root.fontFamily
            text: "Scanning…"
          }

          // ---------- Recommendation list ----------
          Repeater {
            model: root.recommendations
            delegate: Rectangle {
              id: card
              width: panelFlick.width
              height: row.implicitHeight + Style.space(16)
              color: root.surface
              radius: Style.space(6)
              property var rec: modelData
              property bool checked: !!root.selected[rec.id]
              property string appliedStatus: root.applied[rec.id] || ""

              Column {
                id: row
                anchors.left: parent.left; anchors.right: parent.right
                anchors.margins: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                Row {
                    width: parent.width
                    spacing: Style.space(8)
                    CheckBox {
                      id: cb
                      checked: card.checked
                      onToggled: root.toggleSelected(rec.id)
                      enabled: appliedStatus === ""
                      z: 2  // stay above the card MouseArea
                    }
                    Text {
                        width: parent.width - 40 - dismissBtn.implicitWidth - Style.space(8)
                        text: rec.title || rec.id
                        color: root.foreground
                        font.bold: true
                        font.family: root.fontFamily
                        wrapMode: Text.Wrap
                    }
                    Text {
                        id: dismissBtn
                        text: "\uf00d"
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                                root.dismiss(rec.id)
                                mouse.accepted = true
                            }
                            onPressed: function(mouse) { mouse.accepted = true }
                            hoverEnabled: true
                            onEntered: parent.color = root.urgent
                            onExited: parent.color = root.dim
                        }
                    }
                }
                Text {
                  width: parent.width
                  text: rec.rationale || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
                Row {
                  spacing: Style.space(6)
                  Text {
                    text: (rec.severity || "low").toUpperCase()
                    color: rec.severity === "high" ? root.urgent
                           : rec.severity === "medium" ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    visible: !!rec.savings_gb
                    text: "≈ " + Number(rec.savings_gb).toFixed(1) + " GB"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    text: {
                      if (appliedStatus === "running") return "applying…"
                      if (appliedStatus === "ok") return "done"
                      if (appliedStatus === "failed") return "failed"
                      return rec.action || ""
                    }
                    color: appliedStatus === "failed" ? root.urgent
                           : appliedStatus === "ok" ? root.good : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  visible: !!rec.command && appliedStatus === ""
                  width: parent.width
                  text: rec.command
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                  elide: Text.ElideRight
                }
              }
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.dismiss(rec.id)
                  else root.toggleSelected(rec.id)
                  mouse.accepted = true
                }
                onPressed: function(mouse) { mouse.accepted = true }
              }
            }
          }

          PanelSeparator {}
          Text {
            width: parent.width
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            text: "Click the ✕ on a card to dismiss it permanently — it won't be recommended again. Right-click also dismisses. Cloud/uninstall/delete actions open a terminal to confirm with sudo."
          }
        }
      }
    }
  }

  // ----- processes --------------------------------------------------------
  Process {
    id: stateProc
    command: ["omarchy-optimize-state", "read"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.state = JSON.parse(text) } catch (e) {}
      }
    }
  }
  Process {
    id: recsProc
    command: ["omarchy-optimize-state", "recommendations"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.recommendations = JSON.parse(text) } catch (e) { root.recommendations = [] }
      }
    }
  }
  Process {
    id: scanProc
    command: ["omarchy-optimize-analyze"]
    onExited: function(exitCode) {
      scanning = false
      root.refreshState()
      root.refreshRecs()
      if (exitCode !== 0) root.state = Object.assign({}, root.state, { status: "error" })
    }
  }
  Process {
    id: applyProc
    command: ["omarchy-optimize-apply"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text || "{}")
          var next = Object.assign({}, root.applied)
          for (var id in result) next[id] = result[id]
          root.applied = next
        } catch (e) {}
        root.refreshState()
        root.refreshRecs()
      }
    }
  }
  Process {
    id: dismissProc
    command: ["omarchy-optimize-state"]
    onExited: function() { root.refreshState(); root.refreshRecs() }
  }

  // ----- refresh cadence --------------------------------------------------
  // Poll state on open and every 30s so the bar reflects scans kicked off
  // by the systemd timer or by the user out-of-band.
  Timer { interval: 30000; running: root.opened; repeat: true; triggeredOnStart: true; onTriggered: { root.refreshState(); root.refreshRecs() } }
  Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshState() }
  Component.onCompleted: { root.refreshState(); root.refreshRecs() }
}
