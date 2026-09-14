import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget: a computer glyph plus the count of running VMs. Clicking opens the
// panel; a middle click re-reads virsh immediately instead of waiting for the
// next poll. The glyph/count light up in the accent color when any VM is on.
BarWidget {
  id: root
  moduleName: "vmaker.vms"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vmaker.vms") : null

  readonly property int onCount: service ? service.onCount : 0
  readonly property string tooltip: service ? service.summary : "Virtual machines"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "vmaker.vms"

    function status(): string {
      return root.service ? root.service.summary : "VM service is not running"
    }

    function refresh(): string {
      if (!root.service) return "unavailable"
      root.service.refresh()
      return "ok"
    }

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  readonly property real openPanelIndicatorWidth: root.vertical ? Style.bar.iconSlot : content.implicitWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : content.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: root.vertical ? (root.onCount > 0 ? 2 : 1) * Style.bar.iconSlot : -1
    horizontalMargin: 8.5
    tooltipText: root.tooltip
    active: root.onCount > 0
    activeColor: Color.accent
    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        if (root.service) root.service.refresh()
        return
      }
      root.togglePanel()
    }

    Row {
      id: content
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        text: "\uF108"
        color: root.onCount > 0 ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      Text {
        text: String(root.onCount)
        color: root.onCount > 0 ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Text {
        width: button.width
        height: Style.bar.iconSlot
        text: "\uF108"
        color: root.onCount > 0 ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        fontSizeMode: Text.Fit
        minimumPixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        width: button.width
        height: Style.bar.iconSlot
        text: String(root.onCount)
        color: root.onCount > 0 ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        fontSizeMode: Text.Fit
        minimumPixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
