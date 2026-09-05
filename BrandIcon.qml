import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Use the transparent monochrome artwork, with its stroke in the containing
// surface's text color. Recolor the SVG before decoding so this also works
// without GPU effects and never adds an opaque background tile.
Image {
  id: root

  property color foreground: Color.foreground
  readonly property bool lightForeground: 0.299 * foreground.r
    + 0.587 * foreground.g + 0.114 * foreground.b >= 0.5
  readonly property url artworkSource: lightForeground ? Qt.resolvedUrl("assets/omachord-white.svg")
    : Qt.resolvedUrl("assets/omachord-black.svg")
  readonly property string strokeColor: "rgb(" + Math.round(foreground.r * 255)
    + "," + Math.round(foreground.g * 255) + "," + Math.round(foreground.b * 255) + ")"
  property string artwork: ""

  source: artwork ? "data:image/svg+xml;utf8," + encodeURIComponent(artwork.replace(
    /stroke="#(?:ffffff|000000)"/, 'stroke="' + strokeColor + '" stroke-opacity="' + foreground.a + '"')) : ""
  fillMode: Image.PreserveAspectFit
  sourceSize.width: Math.ceil(width * Screen.devicePixelRatio)
  sourceSize.height: Math.ceil(height * Screen.devicePixelRatio)

  FileView {
    path: decodeURIComponent(root.artworkSource.toString().substring(7))
    onLoaded: root.artwork = text()
    onLoadFailed: root.artwork = ""
  }
}
