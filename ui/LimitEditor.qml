import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../Model.js" as Model

// Editor for a network's limits. Typed values like "2 GB", "500 MB"; empty
// means no limit. Fills itself from the stored limits each time it is shown.
Column {
  id: editor
  required property var panel

  spacing: Style.space(8)

  component Label: PlainText { owner: panel }

  onVisibleChanged: {
    if (!visible) return
    dailyField.text = Model.limitText(panel.limit.daily)
    monthlyField.text = Model.limitText(panel.limit.monthly)
    cycleField.text = String(panel.limit.cycleDay)
    dailyField.forceActiveFocus()
  }

  function save() { panel.saveLimits(dailyField.text, monthlyField.text, cycleField.text) }

  Row {
    width: parent.width
    spacing: Style.space(12)

    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(4)
      Label {
        text: panel.strings.t("limits.daily")
        font.pixelSize: Style.font.caption
        opacity: 0.7
      }
      TextField {
        id: dailyField
        width: parent.width
        placeholderText: panel.strings.t("limits.placeholder")
        foreground: panel.barForeground
        font.family: panel.fontFamily
        font.pixelSize: Style.font.bodySmall
        KeyNavigation.tab: monthlyField
        onAccepted: editor.save()
        Keys.onEscapePressed: panel.cancelLimits()
      }
    }

    Column {
      width: (parent.width - parent.spacing) / 2
      spacing: Style.space(4)
      Label {
        text: panel.strings.t("limits.monthly")
        font.pixelSize: Style.font.caption
        opacity: 0.7
      }
      TextField {
        id: monthlyField
        width: parent.width
        placeholderText: panel.strings.t("limits.placeholder")
        foreground: panel.barForeground
        font.family: panel.fontFamily
        font.pixelSize: Style.font.bodySmall
        KeyNavigation.tab: cycleField
        onAccepted: editor.save()
        Keys.onEscapePressed: panel.cancelLimits()
      }
    }
  }

  // The day the monthly limit resets, for plans that bill mid-month.
  Item {
    width: parent.width
    implicitHeight: cycleField.implicitHeight

    Label {
      id: cycleLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: panel.strings.t("limits.billingDay")
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
      foreground: panel.barForeground
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      KeyNavigation.tab: dailyField
      onAccepted: editor.save()
      Keys.onEscapePressed: panel.cancelLimits()
    }
    Label {
      anchors.left: cycleField.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: panel.strings.t("limits.billingDayHint")
      font.pixelSize: Style.font.caption
      opacity: 0.6
      elide: Text.ElideRight
    }
  }

  Label {
    width: parent.width
    wrapMode: Text.WordWrap
    text: panel.limitError !== "" ? panel.limitError : panel.strings.t("limits.hint")
    color: panel.limitError !== "" ? Commons.Color.urgent : panel.barForeground
    opacity: panel.limitError !== "" ? 1 : 0.6
    font.pixelSize: Style.font.caption
  }

  Row {
    anchors.right: parent.right
    spacing: Style.space(6)
    Button {
      text: panel.strings.t("limits.cancel")
      fontSize: Style.font.bodySmall
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      bordered: true
      onClicked: panel.cancelLimits()
    }
    Button {
      text: panel.strings.t("limits.save")
      fontSize: Style.font.bodySmall
      foreground: panel.barForeground
      fontFamily: panel.fontFamily
      bordered: true
      active: true
      onClicked: editor.save()
    }
  }
}
