"use strict";
const Vms = require("../lib/Vms.js");
const assert = require("assert");

function parse(text) {
  return Vms.parseList(text);
}

// Empty output (header + separator only).
assert.deepStrictEqual(parse(" Id   Name   State\n--------------------\n\n"), []);

// A running VM and a shut-off VM.
const basic = " Id   Name   State\n--------------------\n 1    foo    running\n -    bar    shut off\n";
const parsed = parse(basic);
assert.strictEqual(parsed.length, 2);
assert.deepStrictEqual(parsed[0], { id: "1", name: "foo", state: "running", on: true, kind: "on" });
assert.deepStrictEqual(parsed[1], { id: "-", name: "bar", state: "shut off", on: false, kind: "off" });

// Names with spaces, and a name that ends in a state word while off.
const spaced = " Id   Name   State\n--------------------\n 2    my vm  paused\n -    cool running  shut off\n 3    bar shut off  running\n";
const spacedParsed = parse(spaced);
assert.strictEqual(spacedParsed.length, 3);
assert.strictEqual(spacedParsed[0].name, "my vm");
assert.strictEqual(spacedParsed[0].state, "paused");
assert.strictEqual(spacedParsed[0].kind, "transition");
assert.strictEqual(spacedParsed[1].name, "cool running");
assert.strictEqual(spacedParsed[1].state, "shut off");
assert.strictEqual(spacedParsed[2].name, "bar shut off");
assert.strictEqual(spacedParsed[2].state, "running");
assert.strictEqual(spacedParsed[2].on, true);

// Multi-word states.
const multi = " Id   Name   State\n--------------------\n 4    vm1    in shutdown\n 5    vm2    pmsuspended\n";
const multiParsed = parse(multi);
assert.strictEqual(multiParsed[0].state, "in shutdown");
assert.strictEqual(multiParsed[0].on, true);
assert.strictEqual(multiParsed[1].state, "pmsuspended");

// isOn / stateKind.
assert.strictEqual(Vms.isOn("crashed"), true);
assert.strictEqual(Vms.isOn("shut off"), false);
assert.strictEqual(Vms.stateKind("crashed"), "error");
assert.strictEqual(Vms.stateKind("running"), "on");

console.log("all parser tests passed");
