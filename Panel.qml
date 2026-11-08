import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "ui"

// Network data usage: an icon in the bar, and a popup with today's download
// and upload on the active connection, a day/month history chart, and the
// per-connection breakdown for whichever bar of the chart is selected.
//
// netcaptain.py (next to this file) samples the kernel's byte counters into a
// SQLite database every `refreshIntervalSec` seconds and answers with a JSON
// summary. Sampling only happens while the shell runs; traffic in between is
// picked up by the next sample on the same boot.
Panel {
  id: root
  moduleName: "omarchy-netcaptain"
  ipcTarget: "omarchy-netcaptain"

  Commons.Translations { id: translations; directory: Qt.resolvedUrl("i18n") }

  // Shared with the components in ui/, which all take this Panel as `panel`.
  readonly property var strings: translations
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int intervalSec: Model.clampInterval(setting("refreshIntervalSec", 60))
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("netcaptain.py")).replace(/^file:\/\//, ""))

  property var summary: null
  property string error: ""
  property string range: "days"      // "days" | "months"
  property string scope: "active"    // "active" | "all" | "pinned"
  property string pinnedName: ""     // the network picked from the connections list
  property int selectedIndex: -1     // -1 follows the newest slot
  property int rowCursor: -1         // keyboard cursor in the connections list
  // Stays as left while the shell runs; a restart starts collapsed again.
  property bool historyOpen: false

  readonly property int dayCount: 14
  readonly property int monthCount: 12

  readonly property var active: summary ? summary.active : null
  readonly property string activeName: active ? active.connection : ""
  // The network the chart and totals follow; "" means all of them, which is
  // also where "This network" falls back to while disconnected.
  readonly property string scopeConnection: scope === "pinned" ? pinnedName
    : (scope === "active" ? activeName : "")
  readonly property bool scopeAll: scopeConnection === ""
  readonly property var scopeOptions: {
    var options = []
    if (activeName !== "") options.push({ value: "active", label: strings.t("scope.active") })
    options.push({ value: "all", label: strings.t("scope.all") })
    if (pinnedName !== "" && pinnedName !== activeName)
      options.push({ value: "pinned", label: Model.shortName(pinnedName, 16), tooltip: pinnedName })
    return options
  }
  readonly property string scopeValue: scope === "active" && activeName === "" ? "all" : scope

  readonly property var todayActive: summary && activeName !== ""
    ? Model.sumRows(summary.daily, "d", summary.today, activeName) : ({ rx: 0, tx: 0 })
  readonly property var monthActive: summary && activeName !== ""
    ? Model.sumRows(summary.monthly, "m", summary.today.slice(0, 7), activeName) : ({ rx: 0, tx: 0 })

  // Months become billing cycles for one network billed mid-month.
  readonly property bool cyclesAvailable: !scopeAll && chartLimitInfo.cycles.length > 0
  readonly property bool cycleMode: range === "months" && cyclesAvailable
  readonly property var series: range === "days"
    ? Model.daySeries(summary, scopeConnection, dayCount)
    : (cycleMode ? Model.cycleSeries(chartLimitInfo) : Model.monthSeries(summary, scopeConnection, monthCount))
  readonly property var seriesTotal: Model.seriesTotal(series)
  readonly property int currentIndex: series.length === 0 ? -1
    : (selectedIndex < 0 || selectedIndex >= series.length ? series.length - 1 : selectedIndex)
  readonly property var currentSlot: currentIndex >= 0 ? series[currentIndex] : null
  readonly property var slotConnections: currentSlot && currentSlot.connections
    ? Model.topConnections(currentSlot.connections, 6)
    : summary && currentSlot
    ? Model.connectionTotals(range === "days" ? summary.daily : summary.monthly,
                             range === "days" ? "d" : "m", currentSlot.key, 6)
    : []

  // Limits follow the network the chart shows, or the active one under All.
  readonly property string limitNetwork: scopeConnection !== "" ? scopeConnection : activeName
  readonly property var limit: Model.limitFor(summary, limitNetwork)
  readonly property var limitToday: summary && limitNetwork !== ""
    ? Model.sumRows(summary.daily, "d", summary.today, limitNetwork) : ({ rx: 0, tx: 0 })
  // A network with limits has its billing cycle worked out by the collector;
  // without them the monthly row is just the calendar month.
  readonly property bool onCycle: limit.stored && limit.cycleDay !== 1 && limit.cycleStart !== ""
  readonly property real limitMonthUsed: limit.stored ? limit.cycleUsed : limitMonth.rx + limitMonth.tx
  readonly property var limitMonth: summary && limitNetwork !== ""
    ? Model.sumRows(summary.monthly, "m", summary.today.slice(0, 7), limitNetwork) : ({ rx: 0, tx: 0 })
  readonly property bool notifyLimits: setting("notifyLimits", true) !== false
  property bool editingLimits: false
  property string limitError: ""

  // The chart measures each day against the shown network's daily limit and
  // each month against its monthly one. All networks together have no single
  // limit, so that view, like a network without one, shows labels only.
  readonly property var chartLimitInfo: Model.limitFor(summary, scopeConnection)
  readonly property real chartLimit: scopeAll ? 0
    : (range === "days" ? chartLimitInfo.daily : chartLimitInfo.monthly)
  readonly property bool chartLimited: chartLimit > 0
  readonly property string chartHint: scopeAll ? strings.t("chart.pickNetwork")
    : (range === "days" ? strings.t("chart.noDailyLimit") : strings.t("chart.noMonthlyLimit"))

  function slotPercent(slot) {
    return slot && chartLimited ? (slot.rx + slot.tx) * 100 / chartLimit : 0
  }

  readonly property color downloadColor: Commons.Color.accent
  readonly property color uploadColor: Qt.rgba(barForeground.r, barForeground.g, barForeground.b, 0.5)

  function bytes(n) { return Model.formatBytes(n, Commons.I18n.formatNumber) }
  function rate(n) { return Model.formatRate(n, Commons.I18n.formatNumber) }

  function slotLabel(slot, long) {
    if (!slot) return ""
    var locale = Qt.locale(Commons.I18n.formatLocale)
    if (range === "days") return locale.toString(slot.date, long ? "dddd d MMMM" : "d")
    // A cycle is named by the month it starts in; the readout spells out its dates.
    if (slot.endDate) return long
      ? strings.t("limits.range").arg(locale.toString(slot.date, "d MMM")).arg(locale.toString(slot.endDate, "d MMM yyyy"))
      : locale.toString(slot.date, "MMM")
    return locale.toString(slot.date, long ? "MMMM yyyy" : "MMM")
  }

  function setRange(next) {
    if (next === range) return
    range = next
    selectedIndex = -1
  }

  // Collapsing returns to the active network, so the compact view always
  // describes the connection in use.
  function toggleHistory() {
    historyOpen = !historyOpen
    if (historyOpen) return
    scope = "active"
    selectedIndex = -1
    rowCursor = -1
  }

  // Cycles through the chips the scope group is showing.
  function toggleScope() {
    var options = scopeOptions
    for (var i = 0; i < options.length; i++) {
      if (options[i].value === scopeValue) {
        scope = options[(i + 1) % options.length].value
        return
      }
    }
    scope = options[0].value
  }

  // Follow one network's history, connected or not. Picking the network
  // already shown goes back to all of them.
  function pinConnection(name) {
    if (name === "") return
    if (name === scopeConnection) { scope = "all"; return }
    if (name === activeName) { scope = "active"; return }
    pinnedName = name
    scope = "pinned"
  }

  function moveRow(delta) {
    var count = slotConnections.length
    if (count === 0) { rowCursor = -1; return }
    rowCursor = rowCursor < 0 ? (delta > 0 ? 0 : count - 1) : Math.max(0, Math.min(count - 1, rowCursor + delta))
  }

  onSlotConnectionsChanged: if (rowCursor >= slotConnections.length) rowCursor = slotConnections.length - 1

  function moveSelection(delta) {
    if (series.length === 0) return
    selectedIndex = Math.max(0, Math.min(series.length - 1, currentIndex + delta))
  }

  function refresh() {
    if (collectProc.running) return
    var command = ["python3", "-I", root.scriptPath, "collect"]
    if (!root.notifyLimits) command.push("--no-notify")
    collectProc.command = command
    collectProc.running = true
  }

  function applyOutput(text) {
    var parsed = Model.parseSummary(text)
    if (parsed) {
      root.summary = parsed
      root.error = ""
    }
  }

  function reportError(text) {
    var message = String(text || "").trim()
    if (message === "") return
    console.warn("omarchy-netcaptain", message.slice(0, 500))
    root.error = message.split("\n").pop().slice(0, 200)
  }

  function editLimits() {
    if (root.limitNetwork === "") return
    root.limitError = ""
    root.editingLimits = true
  }

  function cancelLimits() {
    root.limitError = ""
    root.editingLimits = false
  }

  // Empty fields clear a limit. Everything is checked before anything is saved.
  function saveLimits(dailyText, monthlyText, cycleText) {
    var daily = Model.parseLimit(dailyText)
    var monthly = Model.parseLimit(monthlyText)
    var cycleDay = Model.parseCycleDay(cycleText)
    if (daily < 0 || monthly < 0) {
      root.limitError = strings.t("limits.invalid")
      return
    }
    if (cycleDay < 0) {
      root.limitError = strings.t("limits.invalidCycle")
      return
    }
    if (limitProc.running || root.limitNetwork === "") return
    limitProc.command = ["python3", "-I", root.scriptPath, "set-limits", root.limitNetwork,
                         daily > 0 ? String(daily) : "none", monthly > 0 ? String(monthly) : "none",
                         String(cycleDay)]
    limitProc.running = true
    root.cancelLimits()
  }

  // "15 Nov – 14 Dec" for the cycle the monthly limit is counting.
  function cycleRange() {
    var locale = Qt.locale(Commons.I18n.formatLocale)
    var start = Model.parseDay(root.limit.cycleStart)
    var end = Model.parseDay(root.limit.cycleEnd)
    return strings.t("limits.range").arg(locale.toString(start, "d MMM")).arg(locale.toString(end, "d MMM"))
  }

  function limitLine(used, limitBytes) {
    if (!limitBytes) return strings.t("limits.none")
    var percent = Commons.I18n.formatNumber(Math.floor(used * 100 / limitBytes), 0)
    if (used > limitBytes)
      return strings.t("limits.over").arg(root.bytes(used - limitBytes)).arg(root.bytes(limitBytes))
    return strings.t("limits.of").arg(root.bytes(used)).arg(root.bytes(limitBytes)).arg(percent)
  }

  onOpenedChanged: {
    if (!opened) { cancelLimits(); return }
    selectedIndex = -1
    rowCursor = -1
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: collectProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyOutput(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.reportError(text) }
  }

  Process {
    id: limitProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyOutput(text) }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.reportError(text) }
  }

  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.BAR_ICON
    tooltipText: root.opened || !root.summary ? ""
      : strings.t("tooltip.today").arg(root.bytes(root.todayActive.rx)).arg(root.bytes(root.todayActive.tx))
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      // The limit fields need their keys while editing.
      blocked: root.editingLimits
      onMoveRequested: function(dx, dy) {
        if (!root.historyOpen) return
        if (dx !== 0) root.moveSelection(dx)
        else if (dy !== 0) root.moveRow(dy)
      }
      onActivateRequested: {
        if (!root.historyOpen) { root.toggleHistory(); return }
        if (root.rowCursor >= 0 && root.rowCursor < root.slotConnections.length)
          root.pinConnection(root.slotConnections[root.rowCursor].name)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // Chart keys open History first, so they never act on hidden controls.
        if ((t === "d" || t === "m" || t === "a") && !root.historyOpen) root.toggleHistory()
        if (t === "h") root.toggleHistory()
        else if (t === "d") root.setRange("days")
        else if (t === "m") root.setRange("months")
        else if (t === "a") root.toggleScope()
        else if (t === "r") root.refresh()
        else if (t === "l") root.editLimits()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        HeroSection { panel: root; width: parent.width }
        TodaySection { panel: root; width: parent.width }

        PanelSeparator { foreground: root.barForeground; visible: limits.visible }
        LimitsSection { id: limits; panel: root; width: parent.width }

        PanelSeparator { foreground: root.barForeground }
        HistoryToggle { panel: root; width: parent.width }
        HistorySection { panel: root; width: parent.width }

        PlainText {
          owner: root
          visible: root.error !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.error
          color: Commons.Color.urgent
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
