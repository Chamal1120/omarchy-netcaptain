import QtQuick
import qs.Commons
import qs.Ui

// Daily and monthly (or billing-cycle) limits for the network on show, and
// the editor that sets them.
Column {
  required property var panel

  spacing: Style.space(10)
  visible: panel.limitNetwork !== ""

  Item {
    width: parent.width
    implicitHeight: Math.max(limitsHeader.implicitHeight, limitsButton.implicitHeight)

    PanelSectionHeader {
      id: limitsHeader
      anchors.left: parent.left
      anchors.right: limitsButton.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: panel.strings.t("limits.header").arg(panel.limitNetwork)
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      elide: Text.ElideRight
    }

    Button {
      id: limitsButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: !panel.editingLimits
      text: panel.limit.daily || panel.limit.monthly ? panel.strings.t("limits.edit") : panel.strings.t("limits.set")
      fontSize: Style.font.bodySmall
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      bordered: true
      onClicked: panel.editLimits()
    }
  }

  LimitRow {
    panel: parent.panel
    visible: !panel.editingLimits
    label: panel.strings.t("limits.today")
    used: panel.limitToday.rx + panel.limitToday.tx
    limitBytes: panel.limit.daily
  }

  LimitRow {
    panel: parent.panel
    visible: !panel.editingLimits
    label: panel.onCycle ? panel.strings.t("limits.cycle").arg(panel.cycleRange()) : panel.strings.t("limits.month")
    used: panel.limitMonthUsed
    limitBytes: panel.limit.monthly
  }

  LimitEditor {
    panel: parent.panel
    width: parent.width
    visible: panel.editingLimits
  }
}
