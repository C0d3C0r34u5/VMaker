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
  property double lastRefreshAt: 0
  property bool pendingRefresh: false
  property double busySince: 0

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
    if (root.busy) return false
    if (kind !== "start" && kind !== "shutdown" && kind !== "destroy") return false
    root.actionKind = kind
    root.actionVm = String(name)
    root.actionError = ""
    actionProc.exitCode = -1
    actionProc.stdoutDone = false
    actionProc.stdoutText = ""
    actionProc.command = []
    actionProc.command = [Vms.VIRSH_BINARY, "-c", Vms.VIRSH_URI, kind, String(name)]
    actionProc.running = true
    actionWatchdog.restart()
    return true
  }

  // ------------------------------------------------------------ refresh

  function refresh() {
    if (root.busy) { root.pendingRefresh = true; return }
    if (root.actionBusy) { root.pendingRefresh = true; return }
    // A queued refresh bypasses the debounce; it's an explicit user request.
    if (!root.pendingRefresh && Date.now() - root.lastRefreshAt < 500) return
    root.lastRefreshAt = Date.now()
    root.pendingRefresh = false
    root.busy = true
    root.busySince = Date.now()
    root.status = "loading"
    root.error = ""
    preflightProc.running = true
    preflightWatchdog.restart()
  }

  // Force a full refresh even if state appears stuck. Stops all watchdogs,
  // resets busy/action flags, clears errors, and runs the complete refresh
  // pipeline. Intended for manual recovery when the service is wedged.
  function forceRefresh() {
    listWatchdog.stop()
    listStuckTimer.stop()
    listStdoutFallback.stop()
    actionWatchdog.stop()
    actionStuckTimer.stop()
    viewerProbeWatchdog.stop()
    viewerPreflightWatchdog.stop()
    // Only kill processes that are actually still running; a stale one can
    // keep busy set forever.
    if (preflightProc.running) preflightProc.running = false
    if (listProc.running) listProc.running = false
    if (actionProc.running) actionProc.running = false
    if (viewerProbe.running) viewerProbe.running = false
    if (viewerPreflight.running) viewerPreflight.running = false
    if (viewerProc.running) viewerProc.running = false
    root.busy = false
    root.busySince = 0
    root.actionKind = ""
    root.actionVm = ""
    root.actionError = ""
    root.status = "loading"
    root.error = ""
    root.lastRefreshAt = 0
    root.pendingRefresh = false
    preflightProc.running = true
    preflightWatchdog.restart()
  }

  // Recover when preflightProc hangs: virsh can't be probed, so the refresh
  // pipeline can't start. Kill the probe, clear busy, and mark an error so the
  // panel stays usable instead of dead.
  function recoverStuckPreflight() {
    if (!root.busy) return
    preflightProc.running = false
    root.busy = false
    root.busySince = 0
    root.status = "error"
    root.error = "virsh preflight timed out"
    if (root.pendingRefresh) { root.pendingRefresh = false; root.refresh() }
  }

  // ------------------------------------------------------------ preflight

  // Cheap check that the virsh binary exists before we try to run it, so an
  // install that lacks QEMU/libvirt gets a clear "not installed" message
  // instead of a confusing "virsh timed out".
  Process {
    id: preflightProc
    command: ["/usr/bin/test", "-x", Vms.VIRSH_BINARY]

    onExited: function(code) {
      preflightWatchdog.stop()
      // The watchdog may have already recovered (cleared busy); don't double-handle.
      if (!root.busy) return
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

  Timer {
    id: preflightWatchdog
    interval: 5000
    repeat: false
    onTriggered: root.recoverStuckPreflight()
  }

  function startList() {
    listProc.exitCode = -1
    listProc.stdoutDone = false
    listProc.stdoutText = ""
    // Clear then re-set command to force Quickshell to re-execute even when
    // the virsh command string is identical to the previous run.
    listProc.command = []
    listProc.command = [Vms.VIRSH_BINARY, "-c", Vms.VIRSH_URI, "list", "--all"]
    listProc.running = true
    listWatchdog.restart()
    listStdoutFallback.start()
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
      if (listProc.exitCode !== -1) return
      listStuckTimer.restart()
    }
  }

  Timer {
    id: listWatchdog
    interval: Vms.LIST_TIMEOUT_MS
    repeat: false
    onTriggered: listProc.running = false
  }

  // Guards against the onRunningChanged / onExited ordering race: if the
  // process exits right as onRunningChanged fires, Qt.callLater could run
  // recoverStuckList after finishList already handled completion.
  Timer {
    id: listStuckTimer
    interval: 50
    repeat: false
    onTriggered: root.recoverStuckList()
  }

  // Safety net: busy must never stay true when no process is actually running.
  // If it does (e.g. a missed onExited / onStreamFinished), force-reset so the
  // panel stays refreshable. Auto-retries once via pendingRefresh.
  Timer {
    id: busyWatchdog
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (!root.busy) { root.busySince = 0; return }
      if (root.busySince === 0) root.busySince = Date.now()
      if (Date.now() - root.busySince > 12000 &&
          !preflightProc.running && !listProc.running && !actionProc.running &&
          !viewerProbe.running && !viewerPreflight.running && !viewerProc.running) {
        root.busy = false
        root.busySince = 0
        root.status = "error"
        root.error = "VM service refresh stuck — auto-reset"
        root.pendingRefresh = true
        root.refresh()
      }
    }
  }

  // Fallback: if virsh exits but its stdout never finishes, don't leave busy
  // set forever. Finish with whatever output we have (possibly empty).
  Timer {
    id: listStdoutFallback
    interval: 1000
    repeat: false
    onTriggered: {
      if (root.busy && listProc.exitCode !== -1 && !listProc.stdoutDone) {
        listProc.stdoutDone = true
        root.finishList()
      }
    }
  }

  function recoverStuckList() {
    if (!root.busy) return
    if (listProc.exitCode !== -1) return
    listWatchdog.stop()
    listStdoutFallback.stop()
    root.busy = false
    root.busySince = 0
    root.status = "error"
    root.error = "virsh timed out"
    if (root.pendingRefresh) { root.pendingRefresh = false; root.refresh() }
  }

  function finishList() {
    if (!root.busy) return
    if (listProc.exitCode === -1) return
    if (!listProc.stdoutDone) return
    listWatchdog.stop()
    listStdoutFallback.stop()
    root.busy = false
    var output = String(listProc.stdoutText || "").trim()
    if (listProc.exitCode === 0) {
      var parsed = Vms.parseList(output)
      // Only trust an empty result if the output looks like valid virsh output
      // (contains the header). Otherwise keep the last known-good list so a
      // flaky post-action virsh run can't wipe all VMs from the panel.
      if (parsed.length > 0 || output.indexOf("Id") !== -1) {
        root.vms = parsed
        root.status = "ok"
        root.error = ""
        root.lastUpdatedAt = Date.now()
      } else {
        root.status = "error"
        root.error = "virsh returned unexpected output"
      }
    } else {
      // Keep the last known-good list instead of wiping it on flaky output.
      root.status = "error"
      root.error = listProc.exitCode === 0
        ? "virsh returned no output"
        : Vms.describeListError(listProc.exitCode)
    }
    if (root.pendingRefresh) { root.pendingRefresh = false; root.refresh() }
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
      if (actionProc.exitCode !== -1) return
      actionStuckTimer.restart()
    }
  }

  Timer {
    id: actionWatchdog
    interval: Vms.ACTION_TIMEOUT_MS
    repeat: false
    onTriggered: actionProc.running = false
  }

  // Guards against the onRunningChanged / onExited ordering race: if the
  // process exits right as onRunningChanged fires, Qt.callLater could run
  // recoverStuckAction after finishAction already handled completion.
  Timer {
    id: actionStuckTimer
    interval: 50
    repeat: false
    onTriggered: root.recoverStuckAction()
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
    viewerProbeWatchdog.restart()
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

  Timer {
    id: viewerProbeWatchdog
    interval: Vms.LIST_TIMEOUT_MS
    repeat: false
    onTriggered: viewerProbe.running = false
  }

  Process {
    id: viewerPreflight
    property string vm: ""
    command: []

    onExited: function(code) {
      viewerPreflightWatchdog.stop()
      var name = viewerPreflight.vm
      viewerPreflight.vm = ""
      if (code !== 0 || name === "") return
      viewerProc.command = [Vms.VIRT_VIEWER_BINARY, "-c", Vms.VIRSH_URI, name]
      viewerProc.running = true
    }
  }

  Timer {
    id: viewerPreflightWatchdog
    interval: Vms.LIST_TIMEOUT_MS
    repeat: false
    onTriggered: viewerPreflight.running = false
  }

  Process {
    id: viewerProc
    command: []
  }

  function finishViewerProbe() {
    viewerProbeWatchdog.stop()
    if (viewerProbe.exitCode === -1) return
    if (!viewerProbe.stdoutDone) return
    var display = viewerProbe.stdoutText
    var name = viewerProbe.vm
    viewerProbe.vm = ""
    if (display === "" || name === "") return
    viewerPreflight.vm = name
    viewerPreflight.command = ["/usr/bin/test", "-x", Vms.VIRT_VIEWER_BINARY]
    viewerPreflight.running = true
    viewerPreflightWatchdog.restart()
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
