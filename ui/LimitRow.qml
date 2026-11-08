import QtQuick
import qs.Commons
import qs.Commons as Commons
import "../Model.js" as Model

// One limit: "Today   1.3 GB of 2 GB · 65%" over a thin progress bar that
// turns urgent from 90%.
Column {
  required property var panel
  property string label: ""
  property real used: 0
  property real limitBytes: 0
  readonly property string limitState: Model.limitState(used, limitBytes)
  readonly property color tone: limitState === "warning" || limitState === "exceeded" ? Commons.Color.urgent : panel.downloadColor
  width: parent ? parent.width : 0
  spacing: Style.space(5)

  component Label: PlainText { owner: panel }

  Item {
    width: parent.width
    implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)
    Label {
      id: limitLabel
      anchors.left: parent.left
      text: label
      font.pixelSize: Style.font.bodySmall
    }
    Label {
      id: limitValue
      anchors.right: parent.right
      text: panel.limitLine(used, limitBytes)
      color: limitState === "exceeded" ? Commons.Color.urgent : panel.barForeground
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
    color: Qt.rgba(panel.barForeground.r, panel.barForeground.g, panel.barForeground.b, 0.12)

    Rectangle {
      height: parent.height
      radius: parent.radius
      color: tone
      width: limitBytes > 0 ? Math.max(parent.height, parent.width * Math.min(1, used / limitBytes)) : 0
      Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
    }
  }
}
