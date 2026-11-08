import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The "History" row that expands and collapses the chart. The chart and
// per-network breakdown are for browsing; the everyday view stops at today's
// totals and limits.
Item {
  required property var panel

  implicitHeight: historyLabel.implicitHeight + Style.space(8)

  component Label: PlainText { owner: panel }

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: -Style.space(6)
    anchors.rightMargin: -Style.space(6)
    radius: Style.space(4)
    color: Qt.rgba(panel.barForeground.r, panel.barForeground.g, panel.barForeground.b,
                   historyMouse.containsMouse ? 0.06 : 0)
  }

  Label {
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
    text: panel.strings.t("history.title")
    foreground: panel.barForeground
    fontFamily: panel.fontFamily
  }

  Label {
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: panel.historyOpen ? Model.COLLAPSE_ICON : Model.EXPAND_ICON
    font.pixelSize: Style.font.body
    opacity: 0.7
  }

  MouseArea {
    id: historyMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: panel.toggleHistory()
  }
}
