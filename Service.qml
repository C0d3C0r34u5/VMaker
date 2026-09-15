import QtQuick
import Quickshell
import Quickshell.Io
import "lib/Vms.js" as Vms

// VM service: the single source of truth for VM state, shared by the bar
// widget, the panel, and the IPC surface so they can never disagree.
//
// It polls `virsh -c qemu:///system list --all` and runs start/shutdown/destroy
// on demand. One list request and one action run at a time, by construction.
Item {
  id: root

  // Injected by omarchy-shell's generic service loader.
  property var shell: null

  // ------------------------------------------------------------ list state

  property var vms: []
  // "idle" | "loading" | "ok" | "error"
  property string status: "idle"
  property string error: ""
  property bool busy: false
  property bool virshMissing: false
  property double lastUpdatedAt: 0

  readonly property int totalCount: vms.length

  readonly property int onCount: {
    var n = 0
    for (var i = 0; i < vms.length; i++) if (vms[i].on) n++
    return n
  }

  readonly property var onNames: {
    var names = []
    for (var i = 0; i < vms.length; i++) if (vms[i].on) names.push(vms[i].name)
    return names
  }

  readonly property string summary: {
    if (root.status === "error") return "VMs: " + root.error
    if (root.totalCount === 0) return "No VMs defined"
    var head = root.onCount + " of " + root.totalCount + " running"
    if (root.onCount > 0) head += ": " + root.onNames.join(", ")
    return head
  }

  // ------------------------------------------------------------ actions

  // "" | "start" | "shutdown" | "destroy"
  property string actionKind: ""
  property string actionVm: ""
  property string actionError: ""
  readonly property bool actionBusy: actionKind !== ""

  function start(name) { return runAction("start", name) }
  function shutdown(name) { return runAction("shutdown", name) }
  function destroy(name) { return runAction("destroy", name) }

  function runAction(kind, name) {
    if (root.actionBusy) return false
    if (kind !== "start" && kind !== "shutdown" && kind !== "destroy") return false
    root.actionKind = kind
    root.actionVm = String(name)
    root.actionError = ""
    actionProc.exitCode = -1
    actionProc.stdoutDone = false
    actionProc.stdoutText = ""
    actionProc.command = [Vms.VIRSH_BINARY, "-c", Vms.VIRSH_URI, kind, String(name)]
    actionProc.running = true
    actionWatchdog.restart()
    return true
  }

  // ------------------------------------------------------------ refresh

  function refresh() {
    if (root.busy) return
    root.busy = true
    root.status = "loading"
    root.error = ""
    preflightProc.running = true
  }

  // ------------------------------------------------------------ preflight

  // Cheap check that the virsh binary exists before we try to run it, so an
  // install that lacks QEMU/libvirt gets a clear "not installed" message
  // instead of a confusing "virsh timed out".
  Process {
    id: preflightProc
    command: ["/usr/bin/test", "-x", Vms.VIRSH_BINARY]

    onExited: function(code) {
      if (code !== 0) {
        root.virshMissing = true
        root.busy = false
        root.status = "error"
        root.error = Vms.ERROR_LIBVIRT_MISSING
        return
      }
      root.virshMissing = false
      root.startList()
    }
  }

  function startList() {
    listProc.exitCode = -1
    listProc.stdoutDone = false
    listProc.stdoutText = ""
    listProc.running = true
    listWatchdog.restart()
  }

  // ------------------------------------------------------------ list process

  Process {
    id: listProc
    property int exitCode: -1
    property bool stdoutDone: false
    property string stdoutText: ""
    command: [Vms.VIRSH_BINARY, "-c", Vms.VIRSH_URI, "list", "--all"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        listProc.stdoutText = String(text || "")
        listProc.stdoutDone = true
        root.finishList()
      }
    }

    onExited: function(code) {
      listProc.exitCode = code
      root.finishList()
    }

    onRunningChanged: {
      if (running) return
      if (!root.busy) return
      Qt.callLater(root.recoverStuckList)
    }
  }

  Timer {
    id: listWatchdog
    interval: Vms.LIST_TIMEOUT_MS
    repeat: false
    onTriggered: listProc.running = false
  }

  function recoverStuckList() {
    if (!root.busy) return
    if (listProc.exitCode !== -1) return
    listWatchdog.stop()
    root.busy = false
    root.status = "error"
    root.error = "virsh timed out"
  }

  function finishList() {
    if (!root.busy) return
    if (listProc.exitCode === -1) return
    if (!listProc.stdoutDone) return
    listWatchdog.stop()
    root.busy = false
    if (listProc.exitCode === 0) {
      root.vms = Vms.parseList(listProc.stdoutText)
      root.status = "ok"
      root.error = ""
      root.lastUpdatedAt = Date.now()
    } else {
      root.status = "error"
      root.error = Vms.describeListError(listProc.exitCode)
    }
  }

  // ------------------------------------------------------------ action process

  Process {
    id: actionProc
    property int exitCode: -1
    property bool stdoutDone: false
    property string stdoutText: ""
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        actionProc.stdoutText = String(text || "")
        actionProc.stdoutDone = true
        root.finishAction()
      }
    }

    onExited: function(code) {
      actionProc.exitCode = code
      root.finishAction()
    }

    onRunningChanged: {
      if (running) return
      if (!root.actionBusy) return
      Qt.callLater(root.recoverStuckAction)
    }
  }

  Timer {
    id: actionWatchdog
    interval: Vms.ACTION_TIMEOUT_MS
    repeat: false
    onTriggered: actionProc.running = false
  }

  function recoverStuckAction() {
    if (!root.actionBusy) return
    if (actionProc.exitCode !== -1) return
    actionWatchdog.stop()
    var kind = root.actionKind
    root.actionError = "virsh " + kind + " timed out"
    root.actionKind = ""
    root.actionVm = ""
    root.refresh()
  }

  function finishAction() {
    if (!root.actionBusy) return
    if (actionProc.exitCode === -1) return
    if (!actionProc.stdoutDone) return
    actionWatchdog.stop()
    var kind = root.actionKind
    var code = actionProc.exitCode
    var vm = root.actionVm
    root.actionError = code === 0 ? "" : Vms.describeActionError(kind, code)
    root.actionKind = ""
    root.actionVm = ""
    if (kind === "start" && code === 0 && vm !== "") root.openViewer(vm)
    root.refresh()
  }

  // ------------------------------------------------------------ viewer

  // Launch virt-viewer for a VM after a successful start, so the guest console
  // pops up automatically instead of starting headless. We only open a window
  // when the domain actually has a graphics device (headless VMs have nothing
  // to show) and virt-viewer is installed.
  function openViewer(name) {
    viewerProbe.stdoutText = ""
    viewerProbe.stdoutDone = false
    viewerProbe.exitCode = -1
    viewerProbe.vm = String(name)
    viewerProbe.command = [Vms.VIRSH_BINARY, "-c", Vms.VIRSH_URI, "domdisplay", String(name)]
    viewerProbe.running = true
  }

  // Ask libvirt which display a running domain exposes (spice://..., vnc://...).
  // Empty output = no graphics device, so there is nothing to show.
  Process {
    id: viewerProbe
    property string vm: ""
    property int exitCode: -1
    property bool stdoutDone: false
    property string stdoutText: ""
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        viewerProbe.stdoutText = String(text || "").trim()
        viewerProbe.stdoutDone = true
        root.finishViewerProbe()
      }
    }

    onExited: function(code) {
      viewerProbe.exitCode = code
      root.finishViewerProbe()
    }
  }

  function finishViewerProbe() {
    if (viewerProbe.exitCode === -1) return
    if (!viewerProbe.stdoutDone) return
    var display = viewerProbe.stdoutText
    var name = viewerProbe.vm
    viewerProbe.vm = ""
    if (display === "" || name === "") return
    viewerPreflight.vm = name
    viewerPreflight.command = ["/usr/bin/test", "-x", Vms.VIRT_VIEWER_BINARY]
    viewerPreflight.running = true
  }

  Process {
    id: viewerPreflight
    property string vm: ""
    command: []

    onExited: function(code) {
      var name = viewerPreflight.vm
      viewerPreflight.vm = ""
      if (code !== 0 || name === "") return
      viewerProc.command = [Vms.VIRT_VIEWER_BINARY, "-c", Vms.VIRSH_URI, name]
      viewerProc.running = true
    }
  }

  Process {
    id: viewerProc
    command: []
  }

  // ------------------------------------------------------------ scheduling

  Timer {
    id: firstTimer
    interval: 1500
    repeat: false
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: Vms.POLL_INTERVAL_MS
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
