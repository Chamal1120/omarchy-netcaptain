import QtQuick
import qs.Commons
import "../Model.js" as Model

// Connection name and live rate, with the connection kind's icon.
Item {
  required property var panel

  implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

  component Label: PlainText { owner: panel }

  Label {
    id: heroIcon
    text: panel.active ? Model.kindIcon(panel.active.kind) : Model.BAR_ICON
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

    Label {
      width: parent.width
      text: panel.activeName !== "" ? panel.activeName : panel.strings.t("hero.disconnected")
      font.pixelSize: Style.font.title
      font.bold: true
      elide: Text.ElideRight
    }

    Label {
      width: parent.width
      text: (panel.summary && panel.summary.rate && panel.activeName !== ""
        ? panel.strings.t("hero.rate").arg(panel.rate(panel.summary.rate.rx)).arg(panel.rate(panel.summary.rate.tx))
        : panel.strings.t("hero.activeConnection")).toUpperCase()
      color: Qt.darker(panel.barForeground, 1.4)
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
      elide: Text.ElideRight
    }
  }
}
