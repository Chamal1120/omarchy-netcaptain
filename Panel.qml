import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

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

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

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

        // ---------- Hero: connection · live rate ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          PlainText {
            id: heroIcon
            text: root.active ? Model.kindIcon(root.active.kind) : Model.BAR_ICON
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              width: parent.width
              text: root.activeName !== "" ? root.activeName : strings.t("hero.disconnected")
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            PlainText {
              width: parent.width
              text: (root.summary && root.summary.rate && root.activeName !== ""
                ? strings.t("hero.rate").arg(root.rate(root.summary.rate.rx)).arg(root.rate(root.summary.rate.tx))
                : strings.t("hero.activeConnection")).toUpperCase()
              color: Qt.darker(root.barForeground, 1.4)
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        // ---------- Today on the active connection ----------
        Row {
          width: parent.width
          spacing: Style.space(12)
          visible: root.activeName !== ""

          StatTile {
            width: (parent.width - parent.spacing) / 2
            label: strings.t("stat.downloadToday")
            value: root.bytes(root.todayActive.rx)
            detail: strings.t("stat.thisMonth").arg(root.bytes(root.monthActive.rx))
            swatch: root.downloadColor
          }
          StatTile {
            width: (parent.width - parent.spacing) / 2
            label: strings.t("stat.uploadToday")
            value: root.bytes(root.todayActive.tx)
            detail: strings.t("stat.thisMonth").arg(root.bytes(root.monthActive.tx))
            swatch: root.uploadColor
          }
        }

        // ---------- Data limits ----------
        PanelSeparator { foreground: root.barForeground; visible: limitsSection.visible }

        Column {
          id: limitsSection
          width: parent.width
          spacing: Style.space(10)
          visible: root.limitNetwork !== ""

          Item {
            width: parent.width
            implicitHeight: Math.max(limitsHeader.implicitHeight, limitsButton.implicitHeight)

            PanelSectionHeader {
              id: limitsHeader
              anchors.left: parent.left
              anchors.right: limitsButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("limits.header").arg(root.limitNetwork)
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              elide: Text.ElideRight
            }

            Button {
              id: limitsButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.editingLimits
              text: root.limit.daily || root.limit.monthly ? strings.t("limits.edit") : strings.t("limits.set")
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              bordered: true
              onClicked: root.editLimits()
            }
          }

          LimitRow {
            visible: !root.editingLimits
            label: strings.t("limits.today")
            used: root.limitToday.rx + root.limitToday.tx
            limitBytes: root.limit.daily
          }

          LimitRow {
            visible: !root.editingLimits
            label: root.onCycle ? strings.t("limits.cycle").arg(root.cycleRange()) : strings.t("limits.month")
            used: root.limitMonthUsed
            limitBytes: root.limit.monthly
          }

          // Editor. Typed values like "2 GB", "500 MB"; empty means no limit.
          Column {
            id: limitEditor
            width: parent.width
            spacing: Style.space(8)
            visible: root.editingLimits

            onVisibleChanged: {
              if (!visible) return
              dailyField.text = Model.limitText(root.limit.daily)
              monthlyField.text = Model.limitText(root.limit.monthly)
              cycleField.text = String(root.limit.cycleDay)
              dailyField.forceActiveFocus()
            }

            function save() { root.saveLimits(dailyField.text, monthlyField.text, cycleField.text) }

            Row {
              width: parent.width
              spacing: Style.space(12)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)
                PlainText {
                  text: strings.t("limits.daily")
                  font.pixelSize: Style.font.caption
                  opacity: 0.7
                }
                TextField {
                  id: dailyField
                  width: parent.width
                  placeholderText: strings.t("limits.placeholder")
                  foreground: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  KeyNavigation.tab: monthlyField
                  onAccepted: limitEditor.save()
                  Keys.onEscapePressed: root.cancelLimits()
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(4)
                PlainText {
                  text: strings.t("limits.monthly")
                  font.pixelSize: Style.font.caption
                  opacity: 0.7
                }
                TextField {
                  id: monthlyField
                  width: parent.width
                  placeholderText: strings.t("limits.placeholder")
                  foreground: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  KeyNavigation.tab: cycleField
                  onAccepted: limitEditor.save()
                  Keys.onEscapePressed: root.cancelLimits()
                }
              }
            }

            // The day the monthly limit resets, for plans that bill mid-month.
            Item {
              width: parent.width
              implicitHeight: cycleField.implicitHeight

              PlainText {
                id: cycleLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("limits.billingDay")
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                id: cycleField
                anchors.left: cycleLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(48)
                maximumLength: 2
                horizontalAlignment: TextInput.AlignHCenter
                inputMethodHints: Qt.ImhDigitsOnly
                placeholderText: "1"
                foreground: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                KeyNavigation.tab: dailyField
                onAccepted: limitEditor.save()
                Keys.onEscapePressed: root.cancelLimits()
              }
              PlainText {
                anchors.left: cycleField.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("limits.billingDayHint")
                font.pixelSize: Style.font.caption
                opacity: 0.6
                elide: Text.ElideRight
              }
            }

            PlainText {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.limitError !== "" ? root.limitError : strings.t("limits.hint")
              color: root.limitError !== "" ? Commons.Color.urgent : root.barForeground
              opacity: root.limitError !== "" ? 1 : 0.6
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(6)
              Button {
                text: strings.t("limits.cancel")
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                bordered: true
                onClicked: root.cancelLimits()
              }
              Button {
                text: strings.t("limits.save")
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                bordered: true
                active: true
                onClicked: limitEditor.save()
              }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- History (collapsed by default) ----------
        // The chart and per-network breakdown are for browsing; the everyday
        // view stops at today's totals and limits.
        Item {
          id: historyToggle
          width: parent.width
          implicitHeight: historyLabel.implicitHeight + Style.space(8)

          Rectangle {
            anchors.fill: parent
            anchors.leftMargin: -Style.space(6)
            anchors.rightMargin: -Style.space(6)
            radius: Style.space(4)
            color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b,
                           historyMouse.containsMouse ? 0.06 : 0)
          }

          PlainText {
            id: historyIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.HISTORY_ICON
            font.pixelSize: Style.font.body
            opacity: 0.7
          }

          PanelSectionHeader {
            id: historyLabel
            anchors.left: historyIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: strings.t("history.title")
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          PlainText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.historyOpen ? Model.COLLAPSE_ICON : Model.EXPAND_ICON
            font.pixelSize: Style.font.body
            opacity: 0.7
          }

          MouseArea {
            id: historyMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleHistory()
          }
        }

        Column {
          id: historySection
          width: parent.width
          spacing: Style.space(14)
          visible: root.historyOpen

          // ---------- History ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(rangeGroup.implicitHeight, scopeGroup.implicitHeight)

            ButtonGroup {
              id: rangeGroup
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              focusable: false
              spacing: Style.space(4)
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.bodySmall
              value: root.range
              options: [
                { value: "days", label: strings.t("range.days") },
                { value: "months", label: root.cyclesAvailable ? strings.t("range.cycles") : strings.t("range.months") }
              ]
              onChanged: function(v) { root.setRange(v) }
            }

            ButtonGroup {
              id: scopeGroup
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              focusable: false
              visible: root.scopeOptions.length > 1
              spacing: Style.space(4)
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.bodySmall
              value: root.scopeValue
              options: root.scopeOptions
              onChanged: function(v) { root.scope = v }
            }
          }

          // Readout for the selected bar.
          Item {
            width: parent.width
            implicitHeight: readoutLabel.implicitHeight

            PlainText {
              id: readoutLabel
              anchors.left: parent.left
              anchors.right: readoutValues.left
              anchors.rightMargin: Style.space(8)
              text: root.slotLabel(root.currentSlot, true)
                + (root.chartLimited && root.currentSlot
                   ? " · " + strings.t("chart.percent").arg(Commons.I18n.formatNumber(Math.floor(root.slotPercent(root.currentSlot)), 0))
                   : "")
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
            }

            Row {
              id: readoutValues
              anchors.right: parent.right
              spacing: Style.space(10)
              PlainText {
                text: "↓ " + root.bytes(root.currentSlot ? root.currentSlot.rx : 0)
                color: root.downloadColor
                font.pixelSize: Style.font.bodySmall
              }
              PlainText {
                text: "↑ " + root.bytes(root.currentSlot ? root.currentSlot.tx : 0)
                font.pixelSize: Style.font.bodySmall
                opacity: 0.75
              }
            }
          }

          // One bar per day or month, filled to its share of the limit: the
          // accent colour, turning urgent from 90%. No limit, no bars.
          Item {
            id: chart
            width: parent.width
            implicitHeight: plotHeight + axisRow.implicitHeight + Style.space(4)
            readonly property real plotHeight: root.chartLimited ? Style.space(96) : Style.space(36)
            readonly property real slotWidth: root.series.length > 0 ? width / root.series.length : 0

            PlainText {
              anchors.centerIn: plot
              visible: !root.chartLimited
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: root.chartHint
              font.pixelSize: Style.font.bodySmall
              opacity: 0.6
            }

            Row {
              id: plot
              width: parent.width
              height: chart.plotHeight

              Repeater {
                model: root.series

                Item {
                  id: slot
                  required property var modelData
                  required property int index
                  width: chart.slotWidth
                  height: plot.height
                  readonly property bool current: index === root.currentIndex
                  readonly property real percent: root.slotPercent(modelData)

                  Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    anchors.rightMargin: 1
                    radius: Style.space(4)
                    color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b,
                                   parent.current ? 0.10 : (slotMouse.containsMouse ? 0.05 : 0))
                  }

                  // Track: the full height is 100% of the limit.
                  Rectangle {
                    id: track
                    visible: root.chartLimited
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(3)
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(3, chart.slotWidth * 0.45)
                    height: parent.height - Style.space(6)
                    radius: Math.min(width / 2, Style.space(3))
                    color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.08)

                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      radius: parent.radius
                      color: slot.percent >= 90 ? Commons.Color.urgent : root.downloadColor
                      height: slot.percent > 0 ? Math.max(2, parent.height * Math.min(100, slot.percent) / 100) : 0
                      Behavior on height {
                        NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
                      }
                    }
                  }

                  MouseArea {
                    id: slotMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selectedIndex = index
                    onClicked: root.selectedIndex = index
                  }
                }
              }
            }

            Row {
              id: axisRow
              anchors.top: plot.bottom
              anchors.topMargin: Style.space(4)
              width: parent.width

              Repeater {
                model: root.series
                PlainText {
                  required property var modelData
                  required property int index
                  width: chart.slotWidth
                  horizontalAlignment: Text.AlignHCenter
                  text: root.slotLabel(modelData, false)
                  font.pixelSize: Style.font.caption
                  font.bold: index === root.currentIndex
                  opacity: index === root.currentIndex ? 1 : 0.5
                  elide: Text.ElideNone
                  clip: true
                }
              }
            }
          }

          // Total over the visible range.
          Item {
            width: parent.width
            implicitHeight: totalLabel.implicitHeight

            PlainText {
              id: totalLabel
              anchors.left: parent.left
              text: (root.range === "days"
                ? strings.tn("total.days", root.dayCount).arg(Commons.I18n.formatNumber(root.dayCount))
                : root.cycleMode
                ? strings.tn("total.cycles", root.series.length).arg(Commons.I18n.formatNumber(root.series.length))
                : strings.tn("total.months", root.monthCount).arg(Commons.I18n.formatNumber(root.monthCount)))
                + " · " + (root.scopeAll ? strings.t("scope.all") : root.scopeConnection)
              width: Math.max(0, parent.width - totalValues.implicitWidth - Style.space(10))
              elide: Text.ElideRight
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }

            PlainText {
              id: totalValues
              anchors.right: parent.right
              text: "↓ " + root.bytes(root.seriesTotal.rx) + "   ↑ " + root.bytes(root.seriesTotal.tx)
              font.pixelSize: Style.font.caption
              opacity: 0.6
            }
          }

          PanelSeparator { foreground: root.barForeground }

          // ---------- Connections on the selected day / month ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: strings.t("connections.header").arg(root.slotLabel(root.currentSlot, true))
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              elide: Text.ElideRight
            }

            PlainText {
              visible: root.slotConnections.length === 0
              text: strings.t("connections.none")
              font.pixelSize: Style.font.bodySmall
              opacity: 0.6
            }

            Repeater {
              model: root.slotConnections

              Item {
                id: connectionRow
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: Math.max(rowIcon.implicitHeight, rowName.implicitHeight) + Style.space(6)
                readonly property bool isActive: modelData.name === root.activeName
                readonly property bool isShown: modelData.name === root.scopeConnection

                // Shown network gets a steady tint; hover and keyboard cursor a lighter one.
                Rectangle {
                  anchors.fill: parent
                  anchors.leftMargin: -Style.space(6)
                  anchors.rightMargin: -Style.space(6)
                  radius: Style.space(4)
                  color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b,
                                 connectionRow.isShown ? 0.10
                                 : (rowMouse.containsMouse || root.rowCursor === connectionRow.index ? 0.05 : 0))
                }

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.rowCursor = connectionRow.index
                  onClicked: root.pinConnection(connectionRow.modelData.name)
                }

                PlainText {
                  id: rowIcon
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.kindIcon(modelData.kind)
                  font.pixelSize: Style.font.body
                  opacity: parent.isActive ? 1 : 0.6
                }

                PlainText {
                  id: rowName
                  anchors.left: rowIcon.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: rowValues.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  font.pixelSize: Style.font.bodySmall
                  font.bold: parent.isActive
                  elide: Text.ElideRight
                }

                Row {
                  id: rowValues
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)
                  PlainText {
                    text: "↓ " + root.bytes(modelData.rx)
                    color: root.downloadColor
                    font.pixelSize: Style.font.bodySmall
                  }
                  PlainText {
                    text: "↑ " + root.bytes(modelData.tx)
                    font.pixelSize: Style.font.bodySmall
                    opacity: 0.75
                  }
                }
              }
            }
          }

        }

        PlainText {
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

  // Every text sink here shows connection names from the network, so none of
  // them may fall back to AutoText.
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.barForeground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
  }

  // One limit: "Today   1.3 GB of 2 GB · 65%" over a thin progress bar that
  // turns urgent from 90%.
  component LimitRow: Column {
    property string label: ""
    property real used: 0
    property real limitBytes: 0
    readonly property string limitState: Model.limitState(used, limitBytes)
    readonly property color tone: limitState === "warning" || limitState === "exceeded" ? Commons.Color.urgent : root.downloadColor
    width: parent ? parent.width : 0
    spacing: Style.space(5)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)
      PlainText {
        id: limitLabel
        anchors.left: parent.left
        text: label
        font.pixelSize: Style.font.bodySmall
      }
      PlainText {
        id: limitValue
        anchors.right: parent.right
        text: root.limitLine(used, limitBytes)
        color: limitState === "exceeded" ? Commons.Color.urgent : root.barForeground
        opacity: limitState === "none" ? 0.5 : 1
        font.pixelSize: Style.font.bodySmall
        font.bold: limitState === "warning" || limitState === "exceeded"
      }
    }

    Rectangle {
      visible: limitBytes > 0
      width: parent.width
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)

      Rectangle {
        height: parent.height
        radius: parent.radius
        color: tone
        width: limitBytes > 0 ? Math.max(parent.height, parent.width * Math.min(1, used / limitBytes)) : 0
        Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
      }
    }
  }

  component StatTile: Column {
    property string label: ""
    property string value: ""
    property string detail: ""
    property color swatch: root.barForeground
    spacing: Style.space(2)

    Row {
      spacing: Style.space(6)
      Rectangle {
        width: Style.space(8)
        height: width
        radius: width / 2
        color: swatch
        anchors.verticalCenter: parent.verticalCenter
      }
      PlainText {
        text: label.toUpperCase()
        color: Qt.darker(root.barForeground, 1.4)
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }
    }
    PlainText {
      text: value
      font.pixelSize: Style.font.displayLarge
      font.bold: true
    }
    PlainText {
      text: detail
      font.pixelSize: Style.font.caption
      opacity: 0.6
    }
  }
}
