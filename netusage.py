#!/usr/bin/env python3
"""Network data usage collector for the chamal.netusage Omarchy shell plugin.

Samples the kernel's per-interface byte counters, adds the difference since the
last sample to today's row for the connection each interface is on, and prints
a JSON summary for the bar widget.

    netusage.py collect [--no-notify]
        sample, warn about data limits, then print the summary
    netusage.py summary
        print the summary without sampling
    netusage.py set-limit <connection> <daily|monthly> <bytes|none>
        set or clear one of a network's limits, then print the summary
    netusage.py set-limits <connection> <daily bytes|none> <monthly bytes|none> [billing day]
        set or clear both at once; the billing day (1-31, default 1) is the day
        of the month the monthly limit resets

A limit counts download and upload together, the way carriers meter data. The
monthly limit runs over the network's billing cycle, which starts on its
billing day; in a month too short for that day it starts on the last day. A
notification goes out once when a day's or month's usage reaches 90% of its
limit, and once more when it passes the limit.

The database lives at $XDG_DATA_HOME/omarchy-netusage/usage.db unless
NETUSAGE_DB points somewhere else. Only Python's standard library is used.
"""

import calendar
import datetime
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

SYS_NET = os.environ.get("NETUSAGE_SYS_NET", "/sys/class/net")
PROC_ROUTE = os.environ.get("NETUSAGE_PROC_ROUTE", "/proc/net/route")
BOOT_ID = os.environ.get("NETUSAGE_BOOT_ID", "/proc/sys/kernel/random/boot_id")

NAME_MAX = 64
DAYS_KEPT_IN_SUMMARY = 31
MONTHS_KEPT_IN_SUMMARY = 12
# A single sample that claims more than this is a counter glitch, not traffic.
MAX_SAMPLE_BYTES = 10 * 1000 ** 4
MAX_LIMIT_BYTES = 1000 ** 5
ALERT_LEVELS = (90, 100)

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage (
  day        TEXT NOT NULL,
  connection TEXT NOT NULL,
  kind       TEXT NOT NULL,
  rx         INTEGER NOT NULL DEFAULT 0,
  tx         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, connection)
);
CREATE TABLE IF NOT EXISTS counters (
  iface   TEXT PRIMARY KEY,
  boot_id TEXT NOT NULL,
  rx      INTEGER NOT NULL,
  tx      INTEGER NOT NULL,
  sampled REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS limits (
  connection TEXT PRIMARY KEY,
  daily      INTEGER,
  monthly    INTEGER,
  cycle_day  INTEGER NOT NULL DEFAULT 1
);
-- One row per warning already sent, so each fires once per day or month.
CREATE TABLE IF NOT EXISTS alerts (
  connection TEXT NOT NULL,
  scope      TEXT NOT NULL,
  period     TEXT NOT NULL,
  level      INTEGER NOT NULL,
  PRIMARY KEY (connection, scope, period, level)
);
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""


def db_path():
    override = os.environ.get("NETUSAGE_DB")
    if override:
        return override
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "omarchy-netusage", "usage.db")


def clean_name(value):
    """Connection names come from the network; keep them short and printable."""
    value = re.sub(r"[\x00-\x1f\x7f]", "", str(value or "")).strip()
    return value[:NAME_MAX]


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def read_int(path):
    try:
        return int(read_text(path))
    except ValueError:
        return None


def physical_interfaces():
    """Interfaces backed by hardware. Bridges, veths, docker and VPN tunnels are
    skipped: their traffic is already counted on the physical link under them."""
    try:
        names = sorted(os.listdir(SYS_NET))
    except OSError:
        return []
    found = []
    for name in names:
        if name == "lo":
            continue
        base = os.path.join(SYS_NET, name)
        if not os.path.exists(os.path.join(base, "device")):
            continue
        found.append(name)
    return found


def interface_kind(iface, nm_type=""):
    if os.path.isdir(os.path.join(SYS_NET, iface, "wireless")) or nm_type == "wifi":
        return "wifi"
    if nm_type in ("gsm", "cdma", "modem"):
        return "mobile"
    if nm_type == "ethernet" or iface.startswith(("en", "eth")):
        return "ethernet"
    return "other"


def split_nmcli(line):
    """nmcli -t escapes ':' and '\\' inside fields with a backslash."""
    fields, current, escaped = [], [], False
    for char in line:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    fields.append("".join(current))
    return fields


def nm_devices():
    """DEVICE -> (type, connection name) for connected NetworkManager devices."""
    try:
        out = subprocess.run(
            ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"],
            capture_output=True, text=True, timeout=5, check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    devices = {}
    for line in out.splitlines():
        fields = split_nmcli(line)
        if len(fields) < 4:
            continue
        device, nm_type, state, connection = fields[:4]
        if not state.startswith("connected"):
            continue
        devices[device] = (nm_type, clean_name(connection))
    return devices


def default_route_interface():
    """The interface carrying the default route with the lowest metric."""
    best, best_metric = "", None
    for line in read_text(PROC_ROUTE).splitlines()[1:]:
        parts = line.split()
        if len(parts) < 8:
            continue
        iface, destination, mask = parts[0], parts[1], parts[7]
        if destination != "00000000" or mask != "00000000":
            continue
        try:
            metric = int(parts[6])
        except ValueError:
            continue
        if best_metric is None or metric < best_metric:
            best, best_metric = iface, metric
    return best


def open_db(path):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA)
    # Databases from 0.2 have no billing day yet.
    columns = [row[1] for row in conn.execute("PRAGMA table_info(limits)")]
    if "cycle_day" not in columns:
        conn.execute("ALTER TABLE limits ADD COLUMN cycle_day INTEGER NOT NULL DEFAULT 1")
    return conn


def cycle_start_in(year, month, cycle_day):
    return datetime.date(year, month, min(cycle_day, calendar.monthrange(year, month)[1]))


def billing_cycle(today, cycle_day):
    """(first day, day after the last) of the billing cycle holding `today`."""
    today = datetime.date.fromisoformat(today) if isinstance(today, str) else today
    cycle_day = max(1, min(31, int(cycle_day or 1)))
    start = cycle_start_in(today.year, today.month, cycle_day)
    if today < start:
        year, month = (today.year, today.month - 1) if today.month > 1 else (today.year - 1, 12)
        start = cycle_start_in(year, month, cycle_day)
    year, month = (start.year, start.month + 1) if start.month < 12 else (start.year + 1, 1)
    return start, cycle_start_in(year, month, cycle_day)


def cycle_period(today, cycle_day):
    """The key warnings are recorded under: the calendar month for day 1, as
    0.2 did, otherwise the date the cycle started."""
    start, _ = billing_cycle(today, cycle_day)
    return start.isoformat()[:7] if int(cycle_day or 1) == 1 else start.isoformat()


def recent_cycles(conn, connection, today, cycle_day, count):
    """The last `count` billing cycles, oldest first, each with the network's
    own usage and every network's usage over the same dates."""
    cycles = []
    start, end = billing_cycle(today, cycle_day)
    for _ in range(count):
        totals = conn.execute(
            "SELECT connection, max(kind), sum(rx), sum(tx) FROM usage WHERE day >= ? AND day < ? "
            "GROUP BY connection ORDER BY connection",
            (start.isoformat(), end.isoformat()),
        ).fetchall()
        own = next((row for row in totals if row[0] == connection), None)
        cycles.append({
            "start": start.isoformat(),
            "end": (end - datetime.timedelta(days=1)).isoformat(),
            "rx": own[2] if own else 0,
            "tx": own[3] if own else 0,
            "connections": [{"c": c, "k": k, "rx": rx, "tx": tx} for c, k, rx, tx in totals],
        })
        end = start
        start, _ = billing_cycle(start - datetime.timedelta(days=1), cycle_day)
    cycles.reverse()
    return cycles


def cycle_usage(conn, connection, today, cycle_day):
    start, end = billing_cycle(today, cycle_day)
    return conn.execute(
        "SELECT coalesce(sum(rx + tx), 0) FROM usage WHERE connection = ? AND day >= ? AND day < ?",
        (connection, start.isoformat(), end.isoformat()),
    ).fetchone()[0]


def counter_delta(current, previous, same_boot):
    """Bytes moved since the previous reading of one counter.

    A new boot or a counter that went backwards (driver reload, adapter
    replugged) restarted from zero, so everything it holds is new."""
    if previous is None:
        return 0
    if not same_boot or current < previous:
        return current
    return current - previous


def due_alerts(conn, today):
    """Thresholds crossed and not yet announced. Records them as sent, so this
    must run inside the collector's transaction: a second collector (another
    monitor's bar) then finds them taken and stays quiet."""
    due = []
    for connection, daily, monthly, cycle_day in conn.execute(
        "SELECT connection, daily, monthly, cycle_day FROM limits WHERE daily IS NOT NULL OR monthly IS NOT NULL"
    ).fetchall():
        for scope, limit in (("daily", daily), ("monthly", monthly)):
            if not limit:
                continue
            if scope == "daily":
                period = today
                used = conn.execute(
                    "SELECT coalesce(sum(rx + tx), 0) FROM usage WHERE connection = ? AND day = ?",
                    (connection, today),
                ).fetchone()[0]
            else:
                period = cycle_period(today, cycle_day)
                used = cycle_usage(conn, connection, today, cycle_day)
            crossed = [level for level in ALERT_LEVELS if used * 100 >= limit * level]
            if not crossed:
                continue
            level = crossed[-1]
            fresh = False
            for each in crossed:
                cursor = conn.execute(
                    "INSERT OR IGNORE INTO alerts (connection, scope, period, level) VALUES (?, ?, ?, ?)",
                    (connection, scope, period, each),
                )
                fresh = fresh or (cursor.rowcount > 0 and each == level)
            # Jumping straight past 100% sends only the "exceeded" warning.
            if fresh:
                due.append({"connection": connection, "scope": scope, "level": level, "used": used,
                            "limit": limit, "cycle_day": cycle_day})
    return due


def format_bytes(value):
    units = ["B", "kB", "MB", "GB", "TB", "PB"]
    value, unit = float(max(0, value)), 0
    while value >= 1000 and unit < len(units) - 1:
        value, unit = value / 1000, unit + 1
    decimals = 0 if unit == 0 else (2 if value < 10 else (1 if value < 100 else 0))
    return "%.*f %s" % (decimals, value, units[unit])


def alert_message(alert):
    if alert["scope"] == "daily":
        period = "Today's"
    elif int(alert.get("cycle_day") or 1) == 1:
        period = "This month's"
    else:
        period = "This billing cycle's"
    used, limit = format_bytes(alert["used"]), format_bytes(alert["limit"])
    if alert["level"] >= 100:
        return ("Data limit exceeded on %s" % alert["connection"],
                "%s usage is %s, over the %s limit." % (period, used, limit))
    return ("90%% of data limit used on %s" % alert["connection"],
            "%s usage is %s of %s." % (period, used, limit))


def send_notifications(alerts):
    for alert in alerts:
        headline, body = alert_message(alert)
        urgency = "critical" if alert["level"] >= 100 else "normal"
        # argv only, never a shell: the connection name is network-supplied.
        for command in (
            ["omarchy-notification-send", "--app-name", "Network Usage", "-g", "\U000f04e2",
             "-u", urgency, headline, body],
            ["notify-send", "-a", "Network Usage", "-u", urgency, headline, body],
        ):
            try:
                result = subprocess.run(command, capture_output=True, timeout=10, check=False)
            except (OSError, subprocess.SubprocessError):
                continue
            if result.returncode == 0:
                break


def parse_limit(value):
    """A limit in bytes, or None for no limit. Raises ValueError otherwise."""
    if value in ("", "none", "0"):
        return None
    try:
        amount = int(value)
    except ValueError:
        raise ValueError("limit must be a whole number of bytes or 'none'") from None
    if amount <= 0 or amount > MAX_LIMIT_BYTES:
        raise ValueError("limit must be between 1 byte and 1 PB")
    return amount


def parse_cycle_day(value):
    try:
        day = int(value)
    except (TypeError, ValueError):
        raise ValueError("billing day must be a number from 1 to 31") from None
    if not 1 <= day <= 31:
        raise ValueError("billing day must be a number from 1 to 31")
    return day


def set_cycle_day(conn, connection, value):
    """Move a network's billing day. Only a network with a limit keeps one."""
    connection = clean_name(connection)
    day = parse_cycle_day(value)
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT cycle_day FROM limits WHERE connection = ?", (connection,)).fetchone()
        if row and row[0] != day:
            conn.execute("UPDATE limits SET cycle_day = ? WHERE connection = ?", (day, connection))
            # The cycle moved, so its warnings start over.
            conn.execute("DELETE FROM alerts WHERE connection = ? AND scope = 'monthly'", (connection,))
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def set_limit(conn, connection, scope, value):
    connection = clean_name(connection)
    if not connection:
        raise ValueError("connection name is empty")
    if scope not in ("daily", "monthly"):
        raise ValueError("scope must be daily or monthly")
    amount = parse_limit(value)
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT %s FROM limits WHERE connection = ?" % scope, (connection,)).fetchone()
        if (row[0] if row else None) == amount:
            conn.execute("COMMIT")
            return  # unchanged: keep the warnings already sent
        conn.execute("INSERT OR IGNORE INTO limits (connection) VALUES (?)", (connection,))
        conn.execute("UPDATE limits SET %s = ? WHERE connection = ?" % scope, (amount, connection))
        conn.execute("DELETE FROM limits WHERE daily IS NULL AND monthly IS NULL")
        # A changed limit gets fresh warnings against the new value.
        conn.execute("DELETE FROM alerts WHERE connection = ? AND scope = ?", (connection, scope))
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise


def collect(conn, now=None, today=None, devices=None):
    now = time.time() if now is None else now
    today = today or datetime.date.today().isoformat()
    devices = nm_devices() if devices is None else devices
    boot_id = read_text(BOOT_ID)
    rates = {}

    conn.execute("BEGIN IMMEDIATE")
    try:
        for iface in physical_interfaces():
            stats = os.path.join(SYS_NET, iface, "statistics")
            rx, tx = read_int(os.path.join(stats, "rx_bytes")), read_int(os.path.join(stats, "tx_bytes"))
            if rx is None or tx is None:
                continue

            row = conn.execute(
                "SELECT boot_id, rx, tx, sampled FROM counters WHERE iface = ?", (iface,)
            ).fetchone()
            conn.execute(
                "INSERT INTO counters (iface, boot_id, rx, tx, sampled) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(iface) DO UPDATE SET boot_id = excluded.boot_id, rx = excluded.rx, "
                "tx = excluded.tx, sampled = excluded.sampled",
                (iface, boot_id, rx, tx, now),
            )
            if row is None:
                continue  # first sighting: this is the baseline

            same_boot = row[0] == boot_id
            d_rx = counter_delta(rx, row[1], same_boot)
            d_tx = counter_delta(tx, row[2], same_boot)
            if d_rx > MAX_SAMPLE_BYTES or d_tx > MAX_SAMPLE_BYTES:
                continue

            elapsed = now - row[3]
            if same_boot and 0 < elapsed <= 3600:
                rates[iface] = {"rx": d_rx / elapsed, "tx": d_tx / elapsed}

            if iface not in devices or (d_rx == 0 and d_tx == 0):
                continue  # disconnected interfaces only carry link chatter
            nm_type, connection = devices[iface]
            connection = connection or iface
            conn.execute(
                "INSERT INTO usage (day, connection, kind, rx, tx) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(day, connection) DO UPDATE SET rx = rx + excluded.rx, "
                "tx = tx + excluded.tx, kind = excluded.kind",
                (today, connection, interface_kind(iface, nm_type), d_rx, d_tx),
            )

        conn.execute(
            "INSERT INTO meta (key, value) VALUES ('rates', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (json.dumps(rates),),
        )
        alerts = due_alerts(conn, today)
        conn.execute("COMMIT")
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    return alerts


def active_connection(devices=None):
    iface = default_route_interface()
    if not iface:
        return None
    devices = nm_devices() if devices is None else devices
    nm_type, connection = devices.get(iface, ("", ""))
    return {
        "iface": clean_name(iface),
        "connection": connection or clean_name(iface),
        "kind": interface_kind(iface, nm_type),
    }


def summary(conn, today=None, devices=None):
    today_date = datetime.date.fromisoformat(today) if today else datetime.date.today()
    first_day = (today_date - datetime.timedelta(days=DAYS_KEPT_IN_SUMMARY - 1)).isoformat()
    year, month = today_date.year, today_date.month - (MONTHS_KEPT_IN_SUMMARY - 1)
    while month < 1:
        year, month = year - 1, month + 12
    first_month = "%04d-%02d" % (year, month)

    daily = [
        {"d": d, "c": c, "k": k, "rx": rx, "tx": tx}
        for d, c, k, rx, tx in conn.execute(
            "SELECT day, connection, kind, rx, tx FROM usage WHERE day >= ? ORDER BY day, connection",
            (first_day,),
        )
    ]
    monthly = [
        {"m": m, "c": c, "k": k, "rx": rx, "tx": tx}
        for m, c, k, rx, tx in conn.execute(
            "SELECT substr(day, 1, 7) AS m, connection, max(kind), sum(rx), sum(tx) FROM usage "
            "WHERE substr(day, 1, 7) >= ? GROUP BY m, connection ORDER BY m, connection",
            (first_month,),
        )
    ]
    row = conn.execute("SELECT value FROM meta WHERE key = 'rates'").fetchone()
    try:
        rates = json.loads(row[0]) if row else {}
    except ValueError:
        rates = {}

    limits = []
    # Distinct names: `daily` and `monthly` above are the usage lists.
    for c, daily_limit, monthly_limit, cycle_day in conn.execute(
        "SELECT connection, daily, monthly, cycle_day FROM limits ORDER BY connection"
    ).fetchall():
        start, end = billing_cycle(today_date, cycle_day)
        limits.append({
            "c": c, "daily": daily_limit, "monthly": monthly_limit, "cycleDay": cycle_day,
            # The cycle's last day is inclusive here, for display.
            "cycleStart": start.isoformat(),
            "cycleEnd": (end - datetime.timedelta(days=1)).isoformat(),
            "cycleUsed": cycle_usage(conn, c, today_date.isoformat(), cycle_day),
            # Calendar months already cover a billing day of 1.
            "cycles": recent_cycles(conn, c, today_date, cycle_day, MONTHS_KEPT_IN_SUMMARY) if cycle_day != 1 else [],
        })

    active = active_connection(devices)
    rate = rates.get(active["iface"]) if active else None
    return {
        "version": 1,
        "today": today_date.isoformat(),
        "active": active,
        "rate": rate,
        "daily": daily,
        "monthly": monthly,
        "limits": limits,
    }


USAGE = ("usage: netusage.py collect [--no-notify] | summary"
         " | set-limit <connection> <daily|monthly> <bytes|none>"
         " | set-limits <connection> <daily bytes|none> <monthly bytes|none> [billing day]")


def main(argv):
    args = argv[1:] or ["summary"]
    command = args[0]
    if command not in ("collect", "summary", "set-limit", "set-limits"):
        print(USAGE, file=sys.stderr)
        return 2
    if (command == "set-limit" and len(args) != 4) or (command == "set-limits" and len(args) not in (4, 5)):
        print(USAGE, file=sys.stderr)
        return 2
    conn = open_db(db_path())
    try:
        alerts = []
        devices = nm_devices()
        if command == "collect":
            alerts = collect(conn, devices=devices)
        elif command in ("set-limit", "set-limits"):
            try:
                if command == "set-limit":
                    set_limit(conn, args[1], args[2], args[3])
                else:
                    # Validate both before writing either.
                    for value in args[2:4]:
                        parse_limit(value)
                    cycle_day = parse_cycle_day(args[4]) if len(args) == 5 else None
                    set_limit(conn, args[1], "daily", args[2])
                    set_limit(conn, args[1], "monthly", args[3])
                    if cycle_day is not None:
                        set_cycle_day(conn, args[1], cycle_day)
            except ValueError as error:
                print("netusage: %s" % error, file=sys.stderr)
                return 2
        print(json.dumps(summary(conn, devices=devices), separators=(",", ":")))
        sys.stdout.flush()  # the panel updates before the notification goes out
        if alerts and "--no-notify" not in args:
            send_notifications(alerts)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
