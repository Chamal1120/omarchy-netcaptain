import QtQuick
import qs.Commons
import qs.Commons as Commons

// Every text sink in the popup shows connection names from the network, so
// none of them may fall back to AutoText. Set `owner` to the Panel to pick up
// the bar's colour and font.
Text {
  property var owner: null
  textFormat: Text.PlainText
  color: owner ? owner.barForeground : Commons.Color.foreground
  font.family: owner ? owner.fontFamily : Style.font.family
}
