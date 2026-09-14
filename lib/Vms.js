// VM list parsing and helpers for the vmaker.vms plugin.
//
// Pure and I/O-free: imported by Service.qml and required by tests/vms.test.js.
// Nothing here runs a process or reads the clock; Service.qml owns the virsh
// subprocesses and hands their output to parseList.

var VIRSH_BINARY = "/usr/bin/virsh"
var VIRSH_URI = "qemu:///system"

var LIST_TIMEOUT_MS = 10000
var ACTION_TIMEOUT_MS = 120000
var POLL_INTERVAL_MS = 30000

// libvirt domain states virsh can print, longest first so a trailing-state
// match prefers the multi-word forms ("in shutdown", "shut off") over any
// shorter state that happens to be a suffix.
var DOMAIN_STATES = [
  "in shutdown",
  "pmsuspended",
  "shut off",
  "running",
  "paused",
  "blocked",
  "crashed",
  "dying",
  "idle"
]

// "on" = the domain is powered on in some form (running, paused, crashed, ...).
// Only "shut off" means the guest is off and can be started.
function isOn(state) {
  return state !== "shut off"
}

// Coarse category for coloring the state in the panel.
function stateKind(state) {
  if (state === "running" || state === "idle") return "on"
  if (state === "shut off") return "off"
  if (state === "crashed") return "error"
  return "transition"
}

// Parse the output of `virsh list --all` into [{id, name, state, on, kind}].
//
// Header (" Id   Name   State"), the dashed separator, and blank lines are
// skipped. Each data row ends with the state, which virsh always places in the
// final column, so the state is matched as a trailing suffix of the line and
// the name is everything between the leading Id column and that state.
function parseList(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var trimmed = lines[i].replace(/\r$/, "").trim()
    if (trimmed === "") continue
    var first = trimmed.split(/\s+/)[0]
    if (first === "Id") continue
    if (/^-+$/.test(trimmed)) continue
    var entry = parseRow(trimmed)
    if (entry) out.push(entry)
  }
  return out
}

function parseRow(line) {
  var state = matchState(line)
  if (!state) return null
  var rest = line.slice(0, line.length - state.length).trim()
  var idPart = rest.split(/\s+/)[0] || ""
  var name = rest.slice(idPart.length).trim()
  if (!name) return null
  return {
    id: idPart,
    name: name,
    state: state,
    on: isOn(state),
    kind: stateKind(state)
  }
}

function matchState(line) {
  for (var i = 0; i < DOMAIN_STATES.length; i++) {
    var s = DOMAIN_STATES[i]
    if (line.length >= s.length && line.slice(line.length - s.length) === s) {
      return s
    }
  }
  return ""
}

function describeListError(code) {
  return "virsh list failed (exit " + code + ")"
}

function describeActionError(kind, code) {
  return "virsh " + kind + " failed (exit " + code + ")"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    VIRSH_BINARY: VIRSH_BINARY,
    VIRSH_URI: VIRSH_URI,
    LIST_TIMEOUT_MS: LIST_TIMEOUT_MS,
    ACTION_TIMEOUT_MS: ACTION_TIMEOUT_MS,
    POLL_INTERVAL_MS: POLL_INTERVAL_MS,
    DOMAIN_STATES: DOMAIN_STATES,
    isOn: isOn,
    stateKind: stateKind,
    parseList: parseList,
    parseRow: parseRow,
    matchState: matchState,
    describeListError: describeListError,
    describeActionError: describeActionError
  }
}
