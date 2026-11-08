import QtQuick
import qs.Commons

// A big number with a coloured swatch, a caption above and a detail below.
Column {
  required property var panel
  property string label: ""
  property string value: ""
  property string detail: ""
  property color swatch: panel.barForeground
  spacing: Style.space(2)

  component Label: PlainText { owner: panel }

  Row {
    spacing: Style.space(6)
    Rectangle {
      width: Style.space(8)
      height: width
      radius: width / 2
      color: swatch
      anchors.verticalCenter: parent.verticalCenter
    }
    Label {
      text: label.toUpperCase()
      color: Qt.darker(panel.barForeground, 1.4)
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }
  Label {
    text: value
    font.pixelSize: Style.font.displayLarge
    font.bold: true
  }
  Label {
    text: detail
    font.pixelSize: Style.font.caption
    opacity: 0.6
  }
}
