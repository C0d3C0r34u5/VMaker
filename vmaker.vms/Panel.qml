import QtQuick
import qs.Ui
import qs.Commons

// Popup for the VMs bar widget: one row per VM with its state and start/stop
// controls, plus a refresh row. It renders the service, which is the single
// source of truth shared with the bar and the IPC surface.
Panel {
  id: root
  moduleName: "vmaker.vms"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vmaker.vms") : null

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(root.contentForeground, 1.4)
  readonly property color faint: Qt.rgba(root.contentForeground.r, root.contentForeground.g,
    root.contentForeground.b, 0.12)
  readonly property color onColor: Color.accent
  readonly property color warnColor: Color.urgent

  // Keyboard cursor: 0 is the refresh row, 1..N are the VM rows.
  property int cursor: 0
  readonly property int cursorCount: 1 + (root.service ? root.service.vms.length : 0)
  onCursorCountChanged: if (root.cursor >= root.cursorCount && root.cursorCount > 0)
    root.cursor = root.cursorCount - 1

  readonly property string statusLabel: {
    if (!root.service) return "Loading"
    if (root.service.status === "error") return "Unavailable"
    if (root.service.totalCount === 0) return "No VMs"
    return root.service.onCount + " of " + root.service.totalCount + " running"
  }

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function moveCursor(dy) {
    if (dy === 0 || root.cursorCount === 0) return
    root.cursor = (root.cursor + dy + root.cursorCount) % root.cursorCount
  }

  function scrollBy(dy) {
    if (!panelScroll || panelScroll.contentHeight <= panelScroll.height) return
    panelScroll.contentY = Math.max(0, Math.min(panelScroll.contentHeight - panelScroll.height,
      panelScroll.contentY + dy))
  }

  function activateCursor() {
    if (!root.service) return
    if (root.cursor === 0) { root.service.refresh(); return }
    var vm = root.service.vms[root.cursor - 1]
    if (vm) activateVm(vm)
  }

  function activateVm(vm) {
    if (!root.service || root.service.actionBusy || !vm) return
    if (vm.on) root.service.shutdown(vm.name)
    else root.service.start(vm.name)
  }

  function forceVm(vm) {
    if (!root.service || root.service.actionBusy || !vm || !vm.on) return
    root.service.destroy(vm.name)
  }

  function stateColor(vm) {
    if (!vm) return root.dim
    if (vm.kind === "on") return root.onColor
    if (vm.kind === "error") return root.warnColor
    return root.dim
  }

  component VmRow: BorderSurface {
    id: row
    required property var modelData

    readonly property var vm: row.modelData
    readonly property bool hot: mouse.containsMouse || root.cursor === row.cursorIndex

    property int cursorIndex: -1

    width: parent ? parent.width : 0
    implicitHeight: Math.max(nameText.implicitHeight, stateText.implicitHeight) + Style.space(6) * 2
    radius: Style.cornerRadius
    color: row.hot ? Style.hoverFillFor(root.contentForeground, root.onColor) : "transparent"
    borderSpec: row.hot
      ? Border.controlSpec("hover-cursor", root.contentForeground, root.onColor)
      : Border.none()

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (row.cursorIndex >= 0) root.cursor = row.cursorIndex
      onClicked: root.activateVm(row.vm)
    }

    Text {
      id: nameText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: stateText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: String(row.vm.name || "")
      color: root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: stateText
      textFormat: Text.PlainText
      anchors.right: actionGroup.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: String(row.vm.state || "")
      color: root.stateColor(row.vm)
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      id: actionGroup
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: row.vm.on ? "\uF0425" : "\uF040A"
        tooltipText: row.vm.on ? "Shut down " + row.vm.name : "Start " + row.vm.name
        foreground: root.contentForeground
        enabled: root.service ? !root.service.actionBusy : false
        onClicked: root.activateVm(row.vm)
      }

      PanelActionButton {
        visible: row.vm.on
        iconText: "\uF0156"
        tooltipText: "Force stop " + row.vm.name
        foreground: root.contentForeground
        hoverColor: root.warnColor
        enabled: root.service ? !root.service.actionBusy : false
        onClicked: root.forceVm(row.vm)
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0) root.scrollBy(dx * Style.space(24))
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: {
        if (root.cursor > 0) {
          var vm = root.service ? root.service.vms[root.cursor - 1] : null
          if (vm) root.forceVm(vm)
        }
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") { if (root.service) root.service.refresh() }
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelScroll.width
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            title: "VMs"
            meta: root.statusLabel
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                width: Style.font.display
                height: Style.font.display
                text: "\uF108"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // Refresh row (cursor 0).
          BorderSurface {
            id: refreshRow
            width: parent.width
            implicitHeight: Math.max(refreshLabel.implicitHeight, Style.space(22)) + Style.space(6) * 2
            radius: Style.cornerRadius
            readonly property bool hot: refreshMouse.containsMouse || root.cursor === 0
            color: hot ? Style.hoverFillFor(root.contentForeground, root.onColor) : "transparent"
            borderSpec: hot
              ? Border.controlSpec("hover-cursor", root.contentForeground, root.onColor)
              : Border.none()

            MouseArea {
              id: refreshMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.cursor = 0
              onClicked: if (root.service) root.service.refresh()
            }

            Text {
              id: refreshLabel
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: refreshHint.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "Refresh"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              id: refreshHint
              textFormat: Text.PlainText
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.service && root.service.busy ? "loading" : ""
              color: root.dim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uF0450"
              tooltipText: "Re-read virsh"
              foreground: root.contentForeground
              enabled: root.service ? !root.service.busy : false
              onClicked: if (root.service) root.service.refresh()
            }
          }

          // VM rows (cursor 1..N).
          Repeater {
            model: root.service ? root.service.vms : []

            VmRow {
              required property var modelData
              cursorIndex: index + 1
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.service && root.service.status === "ok" && root.service.totalCount === 0
            text: "No VMs defined."
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.service && root.service.status === "error"
            text: root.service ? root.service.error : ""
            color: root.warnColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.service && root.service.actionError !== ""
            text: root.service ? root.service.actionError : ""
            color: root.warnColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
