// Run with: node --test tests (from the plugin folder)
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
const Model = {}
vm.runInNewContext(source + "\nObject.assign(out, { parseSummary, daySeries, monthSeries, sumRows, connectionTotals, formatBytes, clampInterval, seriesMax, shortName, parseLimit, limitText, limitState, limitFor, parseCycleDay, cycleSeries, topConnections })", { out: Model, String, Math, Number, JSON, Array, Date, isFinite })

const raw = JSON.stringify({
  version: 1,
  today: "2026-11-08",
  active: { iface: "wlp2s0", connection: "Home", kind: "wifi" },
  rate: { rx: 10, tx: 2 },
  daily: [
    { d: "2026-11-08", c: "Home", k: "wifi", rx: 1000, tx: 100 },
    { d: "2026-11-08", c: "<img src=\"https://example.invalid/t\">", k: "wifi", rx: 5000, tx: 1 },
    { d: "2026-11-07", c: "Home", k: "wifi", rx: 300, tx: 30 },
    { d: "not-a-day", c: "Bad", k: "wifi", rx: 1, tx: 1 },
    { d: "2026-11-06", c: "Home", k: "evil", rx: -5, tx: "x" }
  ],
  monthly: [{ m: "2026-10", c: "Home", k: "wifi", rx: 7, tx: 8 }],
  limits: [{ c: "Home", daily: 2000000000, monthly: null, cycleDay: 15, cycleStart: "2026-10-15", cycleEnd: "2026-11-14", cycleUsed: 42,
    cycles: [{ start: "2026-09-15", end: "2026-10-14", rx: 5, tx: 6, connections: [{ c: "Home", k: "wifi", rx: 5, tx: 6 }] },
             { start: "bad", end: "2026-11-14" },
             { start: "2026-10-15", end: "2026-11-14", rx: 7, tx: 8,
               connections: [{ c: "Cafe", k: "wifi", rx: 1, tx: 1 }, { c: "Home", k: "wifi", rx: 7, tx: 8 }, { k: "wifi" }] }] }, { c: "Bad cycle", cycleDay: 99, cycleStart: "<b>" }, { c: "", daily: 5 }, "junk"]
})

test("parseSummary validates rows", () => {
  const s = Model.parseSummary(raw)
  assert.equal(s.daily.length, 4)
  const bad = s.daily.find(r => r.d === "2026-11-06")
  assert.deepEqual([bad.k, bad.rx, bad.tx], ["other", 0, 0])
  assert.equal(Model.parseSummary("nope"), null)
  assert.equal(Model.parseSummary("{\"version\":2}"), null)
})

test("markup-shaped names pass through as literal text", () => {
  const s = Model.parseSummary(raw)
  const top = Model.connectionTotals(s.daily, "d", "2026-11-08", 6)
  assert.equal(top[0].name, "<img src=\"https://example.invalid/t\">")
  assert.equal(top[1].name, "Home")
})

test("day series keeps empty days and scopes by connection", () => {
  const s = Model.parseSummary(raw)
  const days = Model.daySeries(s, "Home", 14)
  assert.equal(days.length, 14)
  assert.equal(days[13].key, "2026-11-08")
  assert.equal(days[0].key, "2026-10-26")
  assert.deepEqual([days[13].rx, days[12].rx, days[11].rx], [1000, 300, 0])
  assert.equal(Model.daySeries(s, "", 14)[13].rx, 6000)
})

test("month series crosses year boundaries", () => {
  const s = Model.parseSummary(raw)
  const months = Model.monthSeries(s, "", 12)
  assert.deepEqual([months[0].key, months[11].key], ["2025-12", "2026-11"])
  assert.equal(months[10].rx, 7)
})

test("formatBytes uses decimal units", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(999), "999 B")
  assert.equal(Model.formatBytes(1420000000), "1.42 GB")
  assert.equal(Model.formatBytes(45600000), "45.6 MB")
  assert.equal(Model.formatBytes(512000), "512 kB")
})

test("clampInterval", () => {
  assert.equal(Model.clampInterval(undefined), 60)
  assert.equal(Model.clampInterval(1), 10)
  assert.equal(Model.clampInterval(99999), 3600)
})

test("shortName trims long network names for chips", () => {
  assert.equal(Model.shortName("Home", 16), "Home")
  assert.equal(Model.shortName("A very long coffee shop network", 16), "A very long cof…")
})

test("parseLimit reads typed amounts", () => {
  assert.equal(Model.parseLimit(""), 0)
  assert.equal(Model.parseLimit("2"), 2e9)
  assert.equal(Model.parseLimit("1.5 GB"), 1.5e9)
  assert.equal(Model.parseLimit("1,5gb"), 1.5e9)
  assert.equal(Model.parseLimit("500 MB"), 5e8)
  assert.equal(Model.parseLimit("750M"), 7.5e8)
  assert.equal(Model.parseLimit("1 TB"), 1e12)
  for (const bad of ["abc", "-1 GB", "5 XB", "0", "1e3", "9999999 TB"]) assert.equal(Model.parseLimit(bad), -1, bad)
})

test("limitText round-trips through parseLimit", () => {
  for (const v of [2e9, 1.5e9, 5e8, 1e12]) assert.equal(Model.parseLimit(Model.limitText(v)), v)
  assert.equal(Model.limitText(0), "")
})

test("limit states match the collector's thresholds", () => {
  assert.equal(Model.limitState(5, 0), "none")
  assert.equal(Model.limitState(899, 1000), "ok")
  assert.equal(Model.limitState(900, 1000), "warning")
  assert.equal(Model.limitState(1000, 1000), "exceeded")
})

test("limits are parsed per network", () => {
  const s = Model.parseSummary(raw)
  const home = Model.limitFor(s, "Home")
  assert.deepEqual([home.daily, home.monthly, home.cycleDay, home.cycleStart, home.cycleEnd, home.cycleUsed, home.stored],
                   [2e9, 0, 15, "2026-10-15", "2026-11-14", 42, true])
  const bad = Model.limitFor(s, "Bad cycle")
  assert.deepEqual([bad.cycleDay, bad.cycleStart], [1, ""])
  const none = Model.limitFor(s, "Elsewhere")
  assert.deepEqual([none.monthly, none.cycleDay, none.stored], [0, 1, false])
})

test("parseCycleDay", () => {
  assert.equal(Model.parseCycleDay(""), 1)
  assert.equal(Model.parseCycleDay("15"), 15)
  assert.equal(Model.parseCycleDay(" 31 "), 31)
  for (const bad of ["0", "32", "1.5", "x", "-3", "123"]) assert.equal(Model.parseCycleDay(bad), -1, bad)
})

test("billing cycles become chart slots", () => {
  const s = Model.parseSummary(raw)
  const series = Model.cycleSeries(Model.limitFor(s, "Home"))
  assert.equal(series.length, 2)
  assert.deepEqual([series[1].key, series[1].rx, series[1].tx], ["2026-10-15", 7, 8])
  assert.equal(series[1].endDate.getDate(), 14)
  assert.equal(Model.topConnections(series[1].connections, 6).map(c => c.name).join(","), "Home,Cafe")
  assert.equal(Model.cycleSeries(Model.limitFor(s, "Elsewhere")).length, 0)
})
