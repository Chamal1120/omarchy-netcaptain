import QtQuick
import qs.Commons
import qs.Commons as Commons

// One bar per day or month, filled to its share of the limit: the accent
// colour, turning urgent from 90%. No limit, no bars, just the axis and a hint.
Item {
  id: chart
  required property var panel

  implicitHeight: plotHeight + axisRow.implicitHeight + Style.space(4)
  readonly property real plotHeight: panel.chartLimited ? Style.space(96) : Style.space(36)
  readonly property real slotWidth: panel.series.length > 0 ? width / panel.series.length : 0

  component Label: PlainText { owner: panel }

  Label {
    anchors.centerIn: plot
    visible: !panel.chartLimited
    width: parent.width - Style.space(24)
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: panel.chartHint
    font.pixelSize: Style.font.bodySmall
    opacity: 0.6
  }

  Row {
    id: plot
    width: parent.width
    height: chart.plotHeight

    Repeater {
      model: chart.panel.series

      Item {
        id: slot
        required property var modelData
        required property int index
        width: chart.slotWidth
        height: plot.height
        readonly property bool current: index === chart.panel.currentIndex
        readonly property real percent: chart.panel.slotPercent(modelData)

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: 1
          anchors.rightMargin: 1
          radius: Style.space(4)
          color: Qt.rgba(chart.panel.barForeground.r, chart.panel.barForeground.g, chart.panel.barForeground.b,
                         slot.current ? 0.10 : (slotMouse.containsMouse ? 0.05 : 0))
        }

        // Track: the full height is 100% of the limit.
        Rectangle {
          visible: chart.panel.chartLimited
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(3)
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.max(3, chart.slotWidth * 0.45)
          height: parent.height - Style.space(6)
          radius: Math.min(width / 2, Style.space(3))
          color: Qt.rgba(chart.panel.barForeground.r, chart.panel.barForeground.g, chart.panel.barForeground.b, 0.08)

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            radius: parent.radius
            color: slot.percent >= 90 ? Commons.Color.urgent : chart.panel.downloadColor
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
          onEntered: chart.panel.selectedIndex = slot.index
          onClicked: chart.panel.selectedIndex = slot.index
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
      model: chart.panel.series
      Label {
        required property var modelData
        required property int index
        width: chart.slotWidth
        horizontalAlignment: Text.AlignHCenter
        text: chart.panel.slotLabel(modelData, false)
        font.pixelSize: Style.font.caption
        font.bold: index === chart.panel.currentIndex
        opacity: index === chart.panel.currentIndex ? 1 : 0.5
        elide: Text.ElideNone
        clip: true
      }
    }
  }
}
