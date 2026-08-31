import QtQuick 2.15
import QtTest 1.3

TestCase {
  name: "PlainTextSecurity"

  readonly property string maliciousMarkup: "<b>literal</b><img src=\"file:///nonexistent-omachord-test\">"

  Text {
    id: sink
    textFormat: Text.PlainText
    text: maliciousMarkup
  }

  function test_markupRemainsLiteral() {
    compare(sink.textFormat, Text.PlainText)
    compare(sink.text, maliciousMarkup)
  }
}
