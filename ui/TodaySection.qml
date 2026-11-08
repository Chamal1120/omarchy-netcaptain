import QtQuick
import qs.Commons

// Today's download and upload on the active connection, with the month so far.
Row {
  required property var panel

  spacing: Style.space(12)
  visible: panel.activeName !== ""

  StatTile {
    panel: parent.panel
    width: (parent.width - parent.spacing) / 2
    label: panel.strings.t("stat.downloadToday")
    value: panel.bytes(panel.todayActive.rx)
    detail: panel.strings.t("stat.thisMonth").arg(panel.bytes(panel.monthActive.rx))
    swatch: panel.downloadColor
  }
  StatTile {
    panel: parent.panel
    width: (parent.width - parent.spacing) / 2
    label: panel.strings.t("stat.uploadToday")
    value: panel.bytes(panel.todayActive.tx)
    detail: panel.strings.t("stat.thisMonth").arg(panel.bytes(panel.monthActive.tx))
    swatch: panel.uploadColor
  }
}
