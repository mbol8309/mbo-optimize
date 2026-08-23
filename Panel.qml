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

  // ----- theme -------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color good: Color.accent
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----- state -------------------------------------------------------------
  property var state: ({})
  property var recommendations: []
  property var selected: ({})
  property int selectedCount: 0
  property bool scanning: false
  property var applied: ({})         // id -> status string
  property var applyOrder: []        // ids in the order they were submitted
  property string viewMode: "list"   // "list" | "results"

  readonly property string status: state.status || "idle"
  readonly property int pendingCount: state.pending_count || 0
  readonly property string lastScan: state.last_scan || ""
  readonly property string lastScanShort: {
    if (!lastScan) return "never"
    var d = new Date(lastScan)
    if (isNaN(d.getTime())) return lastScan
    return d.toLocaleDateString(Qt.locale(), "MMM d")
  }
  readonly property bool alarming: status === "pending" && pendingCount > 0
  readonly property int doneCount: {
    var n = 0
    for (var id in applied) {
      var s = applied[id]
      if (s === "ok" || s === "failed" || s === "partial" || s === "skipped") n++
    }
    return n
  }
  readonly property bool applyRunning: doneCount < applyOrder.length && applyOrder.length > 0

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // ----- actions -----------------------------------------------------------
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

  function applySelected() {
    if (selectedCount === 0) return
    var ids = Object.keys(selected)
    applyOrder = ids
    var marked = {}; for (var i = 0; i < ids.length; i++) marked[ids[i]] = "running"
    applied = marked
    viewMode = "results"
    applyProc.command = ["omarchy-optimize-apply", "apply", JSON.stringify(ids)]
    applyProc.running = true
  }

  function backToList() {
    viewMode = "list"
    applied = ({})
    applyOrder = []
  }

  function dismiss(id) {
    dismissProc.command = ["omarchy-optimize-state", "dismiss", id]
    dismissProc.running = true
  }

  // Helper: find a rec by id
  function recById(id) {
    for (var i = 0; i < recommendations.length; i++)
      if (recommendations[i].id === id) return recommendations[i]
    return null
  }

  // ----- IPC ---------------------------------------------------------------
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

  // ----- bar button --------------------------------------------------------
  visible: alarming || scanning
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: scanning ? "\uf110" : "\uf0e4"
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

  // ----- popup -------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(
      headerCol.implicitHeight + Style.space(8) + scrollArea.implicitHeight,
      Style.space(600))

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
        else if (t === "Enter") {
          if (root.viewMode === "results") root.backToList()
          else root.applySelected()
        }
        else if (t === "Escape" && root.viewMode === "results") root.backToList()
      }

      // --- Fixed header (never scrolls) ---
      Column {
        id: headerCol
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)
        z: 10

        PanelHero {
          width: parent.width
          title: "Optimize"
          meta: {
            if (scanning) return "Analyzing system with your agent…"
            if (viewMode === "results") {
              if (applyRunning) return "Executing " + doneCount + "/" + applyOrder.length + " actions…"
              return "Done — " + doneCount + " actions completed"
            }
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

        // --- Action bar (changes with mode) ---
        Row {
          width: parent.width
          spacing: Style.space(6)

          // List mode actions
          Button {
            text: "Scan"
            enabled: !scanning && viewMode === "list"
            visible: viewMode === "list"
            onClicked: root.scanNow()
          }
          Button {
            text: "Select all"
            enabled: recommendations.length > 0 && viewMode === "list"
            visible: viewMode === "list"
            onClicked: root.selectAll()
          }
          Button {
            text: "Clear"
            enabled: selectedCount > 0 && viewMode === "list"
            visible: viewMode === "list"
            onClicked: root.selectNone()
          }
          Button {
            text: "Execute (" + selectedCount + ")"
            enabled: selectedCount > 0 && !scanning && viewMode === "list"
            visible: viewMode === "list"
            onClicked: root.applySelected()
          }

          // Results mode actions
          Button {
            text: "← Back to list"
            visible: viewMode === "results" && !applyRunning
            onClicked: root.backToList()
          }
        }

        PanelSeparator {
          visible: viewMode === "results"
        }
      }

      // --- Scrollable content area ---
      Item {
        id: scrollArea
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: headerCol.bottom
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(8)
        implicitHeight: viewMode === "results" ? resultsColumn.implicitHeight : listColumn.implicitHeight

        // ===== RECOMMENDATIONS LIST (viewMode === "list") =====
        Flickable {
          id: listFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          visible: root.viewMode === "list"
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(10)

            PanelSectionHeader { text: "Recommendations" }

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

            Repeater {
              model: root.recommendations
              delegate: Rectangle {
                id: card
                width: listFlick.width
                height: cardCol.implicitHeight + Style.space(16)
                color: root.surface
                radius: Style.space(6)
                property var rec: modelData
                property bool checked: !!root.selected[rec.id]

                Column {
                  id: cardCol
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
                      z: 2
                    }
                    Text {
                      width: parent.width - cb.width - dismissBtn.implicitWidth - Style.space(16)
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
                        onClicked: function(mouse) { root.dismiss(rec.id); mouse.accepted = true }
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
                      text: rec.action || ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    visible: !!rec.command
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
              text: "Click ✕ to dismiss permanently (won't be recommended again). Right-click also dismisses. Actions needing sudo open a floating terminal."
            }
          }
        }

        // ===== RESULTS VIEW (viewMode === "results") =====
        Flickable {
          id: resultsFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: resultsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          visible: root.viewMode === "results"
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: resultsColumn
            width: resultsFlick.width
            spacing: Style.space(8)

            PanelSectionHeader { text: "Execution status" }

            Repeater {
              model: root.applyOrder
              delegate: Rectangle {
                id: resultCard
                width: resultsFlick.width
                height: resultCol.implicitHeight + Style.space(14)
                color: root.surface
                radius: Style.space(6)
                property string rid: modelData
                property var rec: root.recById(rid)
                property string st: root.applied[rid] || "pending"

                Column {
                  id: resultCol
                  anchors.left: parent.left; anchors.right: parent.right
                  anchors.margins: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    // Status icon
                    Text {
                      id: statusIcon
                      text: {
                        if (st === "running") return "\uf110"     // spinner
                        if (st === "ok") return "\uf00c"          // check
                        if (st === "failed") return "\uf00d"     // x
                        if (st === "partial") return "\uf12a"    // exclamation
                        if (st === "skipped") return "\uf04e"    // skip
                        return "\uf017"                          // clock (pending)
                      }
                      color: {
                        if (st === "ok") return root.good
                        if (st === "failed") return root.urgent
                        if (st === "partial") return root.urgent
                        if (st === "skipped") return root.dim
                        if (st === "running") return root.foreground
                        return root.dim
                      }
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      width: parent.width - statusIcon.width - Style.space(8)
                      text: rec ? (rec.title || rid) : rid
                      color: root.foreground
                      font.bold: true
                      font.family: root.fontFamily
                      wrapMode: Text.Wrap
                    }
                  }

                  Row {
                    spacing: Style.space(6)
                    Text {
                      text: {
                        if (st === "running") return "executing…"
                        if (st === "ok") return "completed"
                        if (st === "failed") return "failed"
                        if (st === "partial") return "partially done"
                        if (st === "skipped") return "skipped (suggest only)"
                        return "waiting…"
                      }
                      color: st === "ok" ? root.good
                             : (st === "failed" || st === "partial") ? root.urgent
                             : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    // Show savings for completed items
                    Text {
                      visible: (st === "ok" || st === "partial") && rec && rec.savings_gb
                      text: "≈ " + Number(rec.savings_gb).toFixed(1) + " GB freed"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  // Show the command that was/will be run
                  Text {
                    visible: !!rec && !!rec.command
                    width: parent.width
                    text: rec ? rec.command : ""
                    color: root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                    elide: Text.ElideRight
                  }

                  // For sudo actions, tell the user a terminal opened
                  Text {
                    visible: st === "running" && rec && rec.command && rec.command.indexOf("sudo") >= 0
                    width: parent.width
                    text: "→ A floating terminal opened for sudo password. Check your screen."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                  }
                }
              }
            }

            // Summary
            PanelSeparator {}
            Text {
              width: parent.width
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              text: {
                if (applyRunning) return "Executing actions… Some may open a floating terminal for sudo."
                var ok = 0, fail = 0, skip = 0, part = 0
                for (var id in applied) {
                  if (applied[id] === "ok") ok++
                  else if (applied[id] === "failed") fail++
                  else if (applied[id] === "skipped") skip++
                  else if (applied[id] === "partial") part++
                }
                return "Summary: " + ok + " done, " + part + " partial, " + fail + " failed, " + skip + " skipped."
              }
            }
          }
        }
      }
    }
  }

  // ----- processes ---------------------------------------------------------
  Process {
    id: stateProc
    command: ["omarchy-optimize-state", "read"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.state = JSON.parse(text) } catch (e) {} }
    }
  }
  Process {
    id: recsProc
    command: ["omarchy-optimize-state", "recommendations"]
    stdout: StdioCollector {
      onStreamFinished: { try { root.recommendations = JSON.parse(text) } catch (e) { root.recommendations = [] } }
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

  // ----- refresh cadence ---------------------------------------------------
  Timer { interval: 30000; running: root.opened; repeat: true; triggeredOnStart: true; onTriggered: { root.refreshState(); root.refreshRecs() } }
  Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshState() }
  Component.onCompleted: { root.refreshState(); root.refreshRecs() }
}
