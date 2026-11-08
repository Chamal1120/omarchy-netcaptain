import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The expanded history: range and network pickers, a readout for the
// selected bar, the chart, the range total, and the networks behind it.
Column {
  required property var panel

  spacing: Style.space(14)
  visible: panel.historyOpen

  component Label: PlainText { owner: panel }

  // Days / months, and which network to follow.
  Item {
    width: parent.width
    implicitHeight: Math.max(rangeGroup.implicitHeight, scopeGroup.implicitHeight)

    ButtonGroup {
      id: rangeGroup
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      focusable: false
      spacing: Style.space(4)
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      fontSize: Style.font.bodySmall
      value: panel.range
      options: [
        { value: "days", label: panel.strings.t("range.days") },
        { value: "months", label: panel.cyclesAvailable ? panel.strings.t("range.cycles") : panel.strings.t("range.months") }
      ]
      onChanged: function(v) { panel.setRange(v) }
    }

    ButtonGroup {
      id: scopeGroup
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      focusable: false
      visible: panel.scopeOptions.length > 1
      spacing: Style.space(4)
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      fontSize: Style.font.bodySmall
      value: panel.scopeValue
      options: panel.scopeOptions
      onChanged: function(v) { panel.scope = v }
    }
  }

  // Readout for the selected bar.
  Item {
    width: parent.width
    implicitHeight: readoutLabel.implicitHeight

    Label {
      id: readoutLabel
      anchors.left: parent.left
      anchors.right: readoutValues.left
      anchors.rightMargin: Style.space(8)
      text: panel.slotLabel(panel.currentSlot, true)
        + (panel.chartLimited && panel.currentSlot
           ? " · " + panel.strings.t("chart.percent").arg(Commons.I18n.formatNumber(Math.floor(panel.slotPercent(panel.currentSlot)), 0))
           : "")
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Row {
      id: readoutValues
      anchors.right: parent.right
      spacing: Style.space(10)
      Label {
        text: "↓ " + panel.bytes(panel.currentSlot ? panel.currentSlot.rx : 0)
        color: panel.downloadColor
        font.pixelSize: Style.font.bodySmall
      }
      Label {
        text: "↑ " + panel.bytes(panel.currentSlot ? panel.currentSlot.tx : 0)
        font.pixelSize: Style.font.bodySmall
        opacity: 0.75
      }
    }
  }

  UsageChart {
    panel: parent.panel
    width: parent.width
  }

  // Total over the visible range.
  Item {
    width: parent.width
    implicitHeight: totalLabel.implicitHeight

    Label {
      id: totalLabel
      anchors.left: parent.left
      text: (panel.range === "days"
        ? panel.strings.tn("total.days", panel.dayCount).arg(Commons.I18n.formatNumber(panel.dayCount))
        : panel.cycleMode
        ? panel.strings.tn("total.cycles", panel.series.length).arg(Commons.I18n.formatNumber(panel.series.length))
        : panel.strings.tn("total.months", panel.monthCount).arg(Commons.I18n.formatNumber(panel.monthCount)))
        + " · " + (panel.scopeAll ? panel.strings.t("scope.all") : panel.scopeConnection)
      width: Math.max(0, parent.width - totalValues.implicitWidth - Style.space(10))
      elide: Text.ElideRight
      font.pixelSize: Style.font.caption
      opacity: 0.6
    }

    Label {
      id: totalValues
      anchors.right: parent.right
      text: "↓ " + panel.bytes(panel.seriesTotal.rx) + "   ↑ " + panel.bytes(panel.seriesTotal.tx)
      font.pixelSize: Style.font.caption
      opacity: 0.6
    }
  }

  PanelSeparator { foreground: panel.barForeground }

  ConnectionList {
    panel: parent.panel
    width: parent.width
  }
}
