.pragma library

// Pure helpers for the network usage panel. Nothing here touches QML, so the
// test suite can load it under Node.

var BAR_ICON = String.fromCodePoint(0xF04E2)   // md-swap_vertical
var WIFI_ICON = String.fromCodePoint(0xF0928)  // md-wifi_strength_4
var ETHERNET_ICON = String.fromCodePoint(0xF0200) // md-ethernet
var MOBILE_ICON = String.fromCodePoint(0xF0127)   // md-signal_cellular_3
var OTHER_ICON = BAR_ICON
var HISTORY_ICON = String.fromCodePoint(0xF02DA)  // md-history
var EXPAND_ICON = String.fromCodePoint(0xF0140)   // md-chevron_down
var COLLAPSE_ICON = String.fromCodePoint(0xF0143) // md-chevron_up

var NAME_MAX = 64
var ROWS_MAX = 2000

function kindIcon(kind) {
  if (kind === "wifi") return WIFI_ICON
  if (kind === "ethernet") return ETHERNET_ICON
  if (kind === "mobile") return MOBILE_ICON
  return OTHER_ICON
}

function clampInterval(seconds) {
  var value = Math.round(Number(seconds))
  if (!isFinite(value)) return 60
  return Math.max(10, Math.min(3600, value))
}

function cleanName(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .slice(0, NAME_MAX)
}

// Long network names would push the scope chips off the panel.
function shortName(value, max) {
  var name = cleanName(value)
  return name.length > max ? name.slice(0, Math.max(1, max - 1)) + "…" : name
}

function count(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

// The collector's output, checked field by field. Anything malformed is
// dropped rather than trusted, and collections are capped.
function parseSummary(raw) {
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return null }
  if (!data || typeof data !== "object" || data.version !== 1) return null

  var isDay = /^\d{4}-\d{2}-\d{2}$/
  var isMonth = /^\d{4}-\d{2}$/
  var kinds = ["wifi", "ethernet", "mobile", "other"]

  function rows(list, key, pattern) {
    var out = []
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length && out.length < ROWS_MAX; i++) {
      var r = list[i]
      if (!r || typeof r !== "object" || !pattern.test(String(r[key]))) continue
      var row = { c: cleanName(r.c), k: kinds.indexOf(r.k) >= 0 ? r.k : "other", rx: count(r.rx), tx: count(r.tx) }
      row[key] = String(r[key])
      out.push(row)
    }
    return out
  }

  var active = null
  if (data.active && typeof data.active === "object" && data.active.connection) {
    active = {
      connection: cleanName(data.active.connection),
      iface: cleanName(data.active.iface),
      kind: kinds.indexOf(data.active.kind) >= 0 ? data.active.kind : "other"
    }
  }
  var rate = null
  if (data.rate && typeof data.rate === "object") rate = { rx: Number(data.rate.rx) || 0, tx: Number(data.rate.tx) || 0 }

  var limits = {}
  if (Array.isArray(data.limits)) {
    for (var j = 0; j < data.limits.length && j < ROWS_MAX; j++) {
      var l = data.limits[j]
      if (!l || typeof l !== "object" || !l.c) continue
      var cycleDay = Math.round(Number(l.cycleDay))
      limits[cleanName(l.c)] = {
        daily: count(l.daily) || 0,
        monthly: count(l.monthly) || 0,
        cycleDay: cycleDay >= 1 && cycleDay <= 31 ? cycleDay : 1,
        cycleStart: isDay.test(String(l.cycleStart)) ? String(l.cycleStart) : "",
        cycleEnd: isDay.test(String(l.cycleEnd)) ? String(l.cycleEnd) : "",
        cycleUsed: count(l.cycleUsed),
        cycles: parseCycles(l.cycles, isDay, kinds),
        stored: true
      }
    }
  }

  return {
    limits: limits,
    today: isDay.test(String(data.today)) ? String(data.today) : isoDay(new Date()),
    active: active,
    rate: rate,
    daily: rows(data.daily, "d", isDay),
    monthly: rows(data.monthly, "m", isMonth)
  }
}

function pad(n) { return n < 10 ? "0" + n : String(n) }
function isoDay(date) { return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) }
function isoMonth(date) { return date.getFullYear() + "-" + pad(date.getMonth() + 1) }

function parseDay(key) {
  var p = String(key).split("-")
  return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2] || 1))
}

// connection === "" means every connection.
function sumRows(rows, keyName, key, connection) {
  var total = { rx: 0, tx: 0 }
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r[keyName] !== key) continue
    if (connection !== "" && r.c !== connection) continue
    total.rx += r.rx
    total.tx += r.tx
  }
  return total
}

// One slot per day ending today, oldest first, with empty days kept so the
// chart reads as a calendar.
function daySeries(summary, connection, length) {
  var out = []
  if (!summary) return out
  var end = parseDay(summary.today)
  for (var i = length - 1; i >= 0; i--) {
    var date = new Date(end.getFullYear(), end.getMonth(), end.getDate() - i)
    var key = isoDay(date)
    var total = sumRows(summary.daily, "d", key, connection)
    out.push({ key: key, date: date, rx: total.rx, tx: total.tx })
  }
  return out
}

function monthSeries(summary, connection, length) {
  var out = []
  if (!summary) return out
  var end = parseDay(summary.today)
  for (var i = length - 1; i >= 0; i--) {
    var date = new Date(end.getFullYear(), end.getMonth() - i, 1)
    var key = isoMonth(date)
    var total = sumRows(summary.monthly, "m", key, connection)
    out.push({ key: key, date: date, rx: total.rx, tx: total.tx })
  }
  return out
}

function seriesMax(series) {
  var max = 0
  for (var i = 0; i < series.length; i++) max = Math.max(max, series[i].rx, series[i].tx)
  return max
}

function seriesTotal(series) {
  var total = { rx: 0, tx: 0 }
  for (var i = 0; i < series.length; i++) {
    total.rx += series[i].rx
    total.tx += series[i].tx
  }
  return total
}

// Per-connection totals for one day or month, biggest first.
function connectionTotals(rows, keyName, key, limit) {
  var byName = {}
  var list = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    if (r[keyName] !== key) continue
    if (!byName[r.c]) {
      byName[r.c] = { name: r.c, kind: r.k, rx: 0, tx: 0 }
      list.push(byName[r.c])
    }
    byName[r.c].rx += r.rx
    byName[r.c].tx += r.tx
  }
  list.sort(function(a, b) { return (b.rx + b.tx) - (a.rx + a.tx) })
  return list.slice(0, limit)
}

// Decimal units, the way carriers and ISPs count data caps.
function formatBytes(bytes, formatNumber) {
  var fmt = typeof formatNumber === "function" ? formatNumber : function(v, d) { return Number(v).toFixed(d) }
  var units = ["B", "kB", "MB", "GB", "TB"]
  var value = Math.max(0, Number(bytes) || 0)
  var unit = 0
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000
    unit++
  }
  var decimals = unit === 0 ? 0 : (value < 10 ? 2 : (value < 100 ? 1 : 0))
  return fmt(value, decimals) + " " + units[unit]
}

function formatRate(bytesPerSecond, formatNumber) {
  return formatBytes(bytesPerSecond, formatNumber) + "/s"
}

var LIMIT_MAX = 1e15

// "2 GB", "1.5gb", "500 MB", "750M", or a bare number of GB. Empty clears the
// limit (0); anything else unreadable is -1.
function parseLimit(text) {
  var value = String(text === undefined || text === null ? "" : text).trim().replace(",", ".")
  if (value === "") return 0
  var match = /^(\d+(?:\.\d+)?)\s*([kmgt]?)(?:i?b)?$/i.exec(value)
  if (!match) return -1
  var scale = { "": 1e9, k: 1e3, m: 1e6, g: 1e9, t: 1e12 }[match[2].toLowerCase()]
  var bytes = Math.round(parseFloat(match[1]) * scale)
  return bytes >= 1 && bytes <= LIMIT_MAX ? bytes : -1
}

// What a limit field shows for a stored limit: "2 GB", "1.5 GB", "500 MB".
function limitText(bytes) {
  if (!bytes) return ""
  var units = [[1e12, "TB"], [1e9, "GB"], [1e6, "MB"], [1e3, "kB"]]
  for (var i = 0; i < units.length; i++) {
    if (bytes >= units[i][0]) return String(Math.round(bytes / units[i][0] * 100) / 100) + " " + units[i][1]
  }
  return String(bytes) + " B"
}

var NO_LIMIT = { daily: 0, monthly: 0, cycleDay: 1, cycleStart: "", cycleEnd: "", cycleUsed: 0, cycles: [], stored: false }

var CYCLES_MAX = 24
var CYCLE_CONNECTIONS_MAX = 50

// Billing cycles from the collector, oldest first, each with its network's
// usage and every network's usage over the same dates.
function parseCycles(list, isDay, kinds) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length && out.length < CYCLES_MAX; i++) {
    var c = list[i]
    if (!c || typeof c !== "object" || !isDay.test(String(c.start)) || !isDay.test(String(c.end))) continue
    var connections = []
    if (Array.isArray(c.connections)) {
      for (var j = 0; j < c.connections.length && connections.length < CYCLE_CONNECTIONS_MAX; j++) {
        var r = c.connections[j]
        if (!r || typeof r !== "object" || !r.c) continue
        connections.push({ name: cleanName(r.c), kind: kinds.indexOf(r.k) >= 0 ? r.k : "other", rx: count(r.rx), tx: count(r.tx) })
      }
    }
    out.push({ start: String(c.start), end: String(c.end), rx: count(c.rx), tx: count(c.tx), connections: connections })
  }
  return out
}

// Chart slots for a network billed mid-month, in place of calendar months.
function cycleSeries(limitInfo) {
  var out = []
  var cycles = limitInfo && limitInfo.cycles ? limitInfo.cycles : []
  for (var i = 0; i < cycles.length; i++) {
    var c = cycles[i]
    out.push({ key: c.start, date: parseDay(c.start), endDate: parseDay(c.end), rx: c.rx, tx: c.tx, connections: c.connections })
  }
  return out
}

function topConnections(list, limit) {
  var sorted = (list || []).slice()
  sorted.sort(function(a, b) { return (b.rx + b.tx) - (a.rx + a.tx) })
  return sorted.slice(0, limit)
}

function limitFor(summary, connection) {
  if (!summary || !summary.limits || !connection) return NO_LIMIT
  return summary.limits[connection] || NO_LIMIT
}

// A billing day typed into the editor: 1-31, empty for the 1st, -1 if unreadable.
function parseCycleDay(text) {
  var value = String(text === undefined || text === null ? "" : text).trim()
  if (value === "") return 1
  if (!/^\d{1,2}$/.test(value)) return -1
  var day = Number(value)
  return day >= 1 && day <= 31 ? day : -1
}

// "ok" below 90%, "warning" from 90%, "exceeded" once the limit is reached.
function limitState(used, limit) {
  if (!limit) return "none"
  if (used >= limit) return "exceeded"
  if (used * 100 >= limit * 90) return "warning"
  return "ok"
}
