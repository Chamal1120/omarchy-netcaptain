import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// The networks used on the selected day or month. Clicking one (or Enter on
// the keyboard cursor) makes the chart follow it.
Column {
  id: list
  required property var panel

  spacing: Style.space(8)

  component Label: PlainText { owner: panel }

  PanelSectionHeader {
    width: parent.width
    text: panel.strings.t("connections.header").arg(panel.slotLabel(panel.currentSlot, true))
    foreground: panel.barForeground
    fontFamily: panel.fontFamily
    elide: Text.ElideRight
  }

  Label {
    visible: panel.slotConnections.length === 0
    text: panel.strings.t("connections.none")
    font.pixelSize: Style.font.bodySmall
    opacity: 0.6
  }

  Repeater {
    model: list.panel.slotConnections

    Item {
      id: connectionRow
      required property var modelData
      required property int index
      width: list.width
      implicitHeight: Math.max(rowIcon.implicitHeight, rowName.implicitHeight) + Style.space(6)
      readonly property bool isActive: modelData.name === list.panel.activeName
      readonly property bool isShown: modelData.name === list.panel.scopeConnection

      // Shown network gets a steady tint; hover and keyboard cursor a lighter one.
      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -Style.space(6)
        anchors.rightMargin: -Style.space(6)
        radius: Style.space(4)
        color: Qt.rgba(list.panel.barForeground.r, list.panel.barForeground.g, list.panel.barForeground.b,
                       connectionRow.isShown ? 0.10
                       : (rowMouse.containsMouse || list.panel.rowCursor === connectionRow.index ? 0.05 : 0))
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: list.panel.rowCursor = connectionRow.index
        onClicked: list.panel.pinConnection(connectionRow.modelData.name)
      }

      Label {
        id: rowIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: Model.kindIcon(connectionRow.modelData.kind)
        font.pixelSize: Style.font.body
        opacity: connectionRow.isActive ? 1 : 0.6
      }

      Label {
        id: rowName
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: rowValues.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: connectionRow.modelData.name
        font.pixelSize: Style.font.bodySmall
        font.bold: connectionRow.isActive
        elide: Text.ElideRight
      }

      Row {
        id: rowValues
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(10)
        Label {
          text: "↓ " + list.panel.bytes(connectionRow.modelData.rx)
          color: list.panel.downloadColor
          font.pixelSize: Style.font.bodySmall
        }
        Label {
          text: "↑ " + list.panel.bytes(connectionRow.modelData.tx)
          font.pixelSize: Style.font.bodySmall
          opacity: 0.75
        }
      }
    }
  }
}
