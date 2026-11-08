"""Run with: python3 -I -m unittest discover -s tests (from the plugin folder)."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def load_module(env):
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("netusage", os.path.join(ROOT, "netusage.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSystem:
    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        base = self.dir.name
        self.net = os.path.join(base, "net")
        self.route = os.path.join(base, "route")
        self.boot = os.path.join(base, "boot_id")
        os.makedirs(self.net)
        self.set_boot("boot-a")
        self.set_route("wlan0")
        self.mod = load_module({
            "NETUSAGE_SYS_NET": self.net,
            "NETUSAGE_PROC_ROUTE": self.route,
            "NETUSAGE_BOOT_ID": self.boot,
        })
        self.conn = self.mod.open_db(os.path.join(base, "usage.db"))

    def add_iface(self, name, physical=True, wireless=False):
        path = os.path.join(self.net, name)
        os.makedirs(os.path.join(path, "statistics"))
        if physical:
            os.makedirs(os.path.join(path, "device"))
        if wireless:
            os.makedirs(os.path.join(path, "wireless"))
        self.set_counters(name, 0, 0)

    def set_counters(self, name, rx, tx):
        stats = os.path.join(self.net, name, "statistics")
        for key, value in (("rx_bytes", rx), ("tx_bytes", tx)):
            with open(os.path.join(stats, key), "w") as handle:
                handle.write(str(value))

    def set_boot(self, value):
        with open(self.boot, "w") as handle:
            handle.write(value)

    def set_route(self, iface):
        with open(self.route, "w") as handle:
            handle.write("Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n")
            handle.write("%s\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\n" % iface)

    def usage(self):
        return self.conn.execute("SELECT day, connection, kind, rx, tx FROM usage ORDER BY day, connection").fetchall()


WIFI = {"wlan0": ("wifi", "Home")}


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.sys = FakeSystem()
        self.sys.add_iface("wlan0", wireless=True)

    def tearDown(self):
        self.sys.conn.close()
        self.sys.dir.cleanup()

    def collect(self, day="2026-11-08", now=1000.0, devices=WIFI):
        self.sys.mod.collect(self.sys.conn, now=now, today=day, devices=devices)

    def test_first_sample_is_only_a_baseline(self):
        self.sys.set_counters("wlan0", 5000, 700)
        self.collect()
        self.assertEqual(self.sys.usage(), [])

    def test_deltas_accumulate_per_day_and_connection(self):
        self.sys.set_counters("wlan0", 1000, 100)
        self.collect(now=1000)
        self.sys.set_counters("wlan0", 4000, 600)
        self.collect(now=1060)
        self.sys.set_counters("wlan0", 9000, 800)
        self.collect(now=1120, day="2026-11-09")
        self.assertEqual(self.sys.usage(), [
            ("2026-11-08", "Home", "wifi", 3000, 500),
            ("2026-11-09", "Home", "wifi", 5000, 200),
        ])

    def test_reboot_counts_everything_since_boot(self):
        self.sys.set_counters("wlan0", 90000, 9000)
        self.collect(now=1000)
        self.sys.set_boot("boot-b")
        self.sys.set_counters("wlan0", 300, 40)
        self.collect(now=2000)
        self.assertEqual(self.sys.usage(), [("2026-11-08", "Home", "wifi", 300, 40)])

    def test_counter_reset_on_same_boot(self):
        self.sys.set_counters("wlan0", 90000, 9000)
        self.collect(now=1000)
        self.sys.set_counters("wlan0", 500, 9100)
        self.collect(now=1060)
        self.assertEqual(self.sys.usage(), [("2026-11-08", "Home", "wifi", 500, 100)])

    def test_virtual_interfaces_are_ignored(self):
        self.sys.add_iface("docker0", physical=False)
        self.sys.set_counters("docker0", 0, 0)
        self.collect(now=1000, devices={"docker0": ("bridge", "docker0")})
        self.sys.set_counters("docker0", 99999, 99999)
        self.collect(now=1060, devices={"docker0": ("bridge", "docker0")})
        self.assertEqual(self.sys.usage(), [])

    def test_disconnected_traffic_is_not_attributed(self):
        self.collect(now=1000, devices={})
        self.sys.set_counters("wlan0", 300, 300)
        self.collect(now=1060, devices={})
        self.assertEqual(self.sys.usage(), [])

    def test_two_collectors_do_not_double_count(self):
        self.collect(now=1000)
        self.sys.set_counters("wlan0", 1000, 1000)
        self.collect(now=1060)
        self.collect(now=1061)  # a second bar on another monitor
        self.assertEqual(self.sys.usage(), [("2026-11-08", "Home", "wifi", 1000, 1000)])

    def test_summary_shape_and_window(self):
        self.collect(now=1000, day="2026-09-01")
        self.sys.set_counters("wlan0", 10, 20)
        self.collect(now=1060, day="2026-09-01")
        self.sys.set_counters("wlan0", 110, 220)
        self.collect(now=1120, day="2026-11-08")
        data = self.sys.mod.summary(self.sys.conn, today="2026-11-08", devices=WIFI)
        json.dumps(data)
        self.assertEqual(data["active"], {"iface": "wlan0", "connection": "Home", "kind": "wifi"})
        self.assertEqual([r["d"] for r in data["daily"]], ["2026-11-08"])  # Sept is outside 31 days
        self.assertEqual([(r["m"], r["rx"], r["tx"]) for r in data["monthly"]],
                         [("2026-09", 10, 20), ("2026-11", 100, 200)])
        self.assertAlmostEqual(data["rate"]["rx"], 100 / 60)


class LimitTest(unittest.TestCase):
    def setUp(self):
        self.sys = FakeSystem()
        self.sys.add_iface("wlan0", wireless=True)
        self.mod = self.sys.mod
        self.mod.collect(self.sys.conn, now=1000, today="2026-11-08", devices=WIFI)
        self.rx = 0
        self.now = 1000

    def tearDown(self):
        self.sys.conn.close()
        self.sys.dir.cleanup()

    def use(self, amount, day="2026-11-08"):
        self.rx += amount
        self.now += 60
        self.sys.set_counters("wlan0", self.rx, 0)
        return [(a["scope"], a["level"]) for a in
                self.mod.collect(self.sys.conn, now=self.now, today=day, devices=WIFI)]

    def test_warns_at_90_then_exceeded_once_each(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(800), [])
        self.assertEqual(self.use(100), [("daily", 90)])
        self.assertEqual(self.use(50), [])
        self.assertEqual(self.use(100), [("daily", 100)])
        self.assertEqual(self.use(500), [])

    def test_jumping_past_the_limit_sends_only_exceeded(self):
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "1000")
        self.assertEqual(self.use(5000), [("monthly", 100)])
        self.assertEqual(self.use(10), [])

    def test_daily_warnings_reset_each_day(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(950), [("daily", 90)])
        self.assertEqual(self.use(950, day="2026-11-09"), [("daily", 90)])

    def test_changing_a_limit_rearms_its_warnings(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(950), [("daily", 90)])
        self.mod.set_limit(self.sys.conn, "Home", "daily", "2000")
        self.assertEqual(self.use(900), [("daily", 90)])

    def test_saving_an_unchanged_limit_keeps_warnings_quiet(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(950), [("daily", 90)])
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(1), [])

    def test_reaching_the_limit_exactly_counts_as_exceeded(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.assertEqual(self.use(1000), [("daily", 100)])

    def test_other_networks_limits_do_not_fire(self):
        self.mod.set_limit(self.sys.conn, "Phone hotspot", "daily", "100")
        self.assertEqual(self.use(5000), [])

    def test_clearing_and_validation(self):
        self.mod.set_limit(self.sys.conn, "Home", "daily", "1000")
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "5000")
        self.mod.set_limit(self.sys.conn, "Home", "daily", "none")
        data = self.mod.summary(self.sys.conn, today="2026-11-08", devices=WIFI)
        self.assertEqual([(r["c"], r["daily"], r["monthly"]) for r in data["limits"]], [("Home", None, 5000)])
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "")
        self.assertEqual(self.mod.summary(self.sys.conn, today="2026-11-08", devices=WIFI)["limits"], [])
        for bad in ("-5", "abc", str(10 ** 16)):
            with self.assertRaises(ValueError):
                self.mod.set_limit(self.sys.conn, "Home", "daily", bad)
        with self.assertRaises(ValueError):
            self.mod.set_limit(self.sys.conn, "Home", "weekly", "5")

    def test_monthly_limit_follows_the_billing_cycle(self):
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "1000")
        self.mod.set_cycle_day(self.sys.conn, "Home", 15)
        self.assertEqual(self.use(950, day="2026-11-14"), [("monthly", 90)])
        # The 15th starts a new cycle: the earlier 950 no longer counts.
        self.assertEqual(self.use(500, day="2026-11-15"), [])
        self.assertEqual(self.use(450, day="2026-12-14"), [("monthly", 90)])
        data = self.mod.summary(self.sys.conn, today="2026-12-14", devices=WIFI)
        row = data["limits"][0]
        self.assertEqual((row["cycleStart"], row["cycleEnd"], row["cycleUsed"]), ("2026-11-15", "2026-12-14", 950))

    def test_summary_lists_recent_billing_cycles(self):
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "1000")
        self.mod.set_cycle_day(self.sys.conn, "Home", 15)
        self.use(100, day="2026-10-20")
        self.use(200, day="2026-11-14")
        self.use(400, day="2026-11-15")
        other = {"wlan0": ("wifi", "Cafe")}
        self.rx += 50
        self.now += 60
        self.sys.set_counters("wlan0", self.rx, 0)
        self.mod.collect(self.sys.conn, now=self.now, today="2026-11-20", devices=other)
        row = self.mod.summary(self.sys.conn, today="2026-11-20", devices=WIFI)["limits"][0]
        cycles = row["cycles"]
        self.assertEqual(len(cycles), 12)
        self.assertEqual((cycles[0]["start"], cycles[0]["end"]), ("2025-12-15", "2026-01-14"))
        self.assertEqual([(c["start"], c["end"], c["rx"]) for c in cycles[-2:]],
                         [("2026-10-15", "2026-11-14", 300), ("2026-11-15", "2026-12-14", 400)])
        self.assertEqual([(c["c"], c["rx"]) for c in cycles[-1]["connections"]], [("Cafe", 50), ("Home", 400)])

    def test_usage_survives_setting_limits(self):
        # Regression: the limits loop once overwrote the usage lists, so the
        # popup showed zero usage as soon as any network had a limit.
        self.use(1234)
        for cycle_day in (1, 8):
            self.mod.set_limit(self.sys.conn, "Home", "daily", "1000000000")
            self.mod.set_limit(self.sys.conn, "Home", "monthly", "30000000000")
            self.mod.set_cycle_day(self.sys.conn, "Home", cycle_day)
            data = self.mod.summary(self.sys.conn, today="2026-11-08", devices=WIFI)
            self.assertEqual([(r["d"], r["rx"]) for r in data["daily"]], [("2026-11-08", 1234)])
            self.assertEqual([(r["m"], r["rx"]) for r in data["monthly"]], [("2026-11", 1234)])
            self.assertEqual(data["limits"][0]["daily"], 1000000000)

    def test_billing_day_one_sends_no_cycles(self):
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "1000")
        self.assertEqual(self.mod.summary(self.sys.conn, today="2026-11-20", devices=WIFI)["limits"][0]["cycles"], [])

    def test_moving_the_billing_day_rearms_monthly_warnings(self):
        self.mod.set_limit(self.sys.conn, "Home", "monthly", "1000")
        self.assertEqual(self.use(950), [("monthly", 90)])
        self.mod.set_cycle_day(self.sys.conn, "Home", 1)  # unchanged
        self.assertEqual(self.use(1), [])
        self.mod.set_cycle_day(self.sys.conn, "Home", 5)
        self.assertEqual(self.use(1), [("monthly", 90)])

    def test_billing_cycle_dates(self):
        cycle = lambda today, day: tuple(d.isoformat() for d in self.mod.billing_cycle(today, day))
        self.assertEqual(cycle("2026-11-08", 1), ("2026-11-01", "2026-12-01"))
        self.assertEqual(cycle("2026-11-08", 15), ("2026-10-15", "2026-11-15"))
        self.assertEqual(cycle("2026-11-15", 15), ("2026-11-15", "2026-12-15"))
        self.assertEqual(cycle("2026-01-10", 15), ("2025-12-15", "2026-01-15"))
        # Day 31 in short months starts on the month's last day.
        self.assertEqual(cycle("2027-02-28", 31), ("2027-02-28", "2027-03-31"))
        self.assertEqual(cycle("2027-02-27", 31), ("2027-01-31", "2027-02-28"))
        self.assertEqual(cycle("2028-02-29", 30), ("2028-02-29", "2028-03-30"))
        self.assertEqual(self.mod.cycle_period("2026-11-08", 1), "2026-11")
        self.assertEqual(self.mod.cycle_period("2026-11-08", 15), "2026-10-15")

    def test_old_databases_gain_a_billing_day(self):
        path = os.path.join(self.sys.dir.name, "old.db")
        import sqlite3
        old = sqlite3.connect(path)
        old.execute("CREATE TABLE limits (connection TEXT PRIMARY KEY, daily INTEGER, monthly INTEGER)")
        old.execute("INSERT INTO limits VALUES ('Home', NULL, 5)")
        old.commit()
        old.close()
        conn = self.mod.open_db(path)
        self.assertEqual(conn.execute("SELECT cycle_day FROM limits").fetchone()[0], 1)
        conn.close()

    def test_messages(self):
        head, body = self.mod.alert_message({"connection": "Home", "scope": "monthly", "level": 100, "used": 51200000000, "limit": 50000000000})
        self.assertEqual(head, "Data limit exceeded on Home")
        self.assertEqual(body, "This month's usage is 51.2 GB, over the 50.0 GB limit.")
        head, body = self.mod.alert_message({"connection": "Home", "scope": "daily", "level": 90, "used": 1850000000, "limit": 2000000000})
        self.assertEqual(head, "90% of data limit used on Home")
        self.assertEqual(body, "Today's usage is 1.85 GB of 2.00 GB.")
        _, body = self.mod.alert_message({"connection": "Home", "scope": "monthly", "level": 90, "used": 9, "limit": 10, "cycle_day": 15})
        self.assertEqual(body, "This billing cycle's usage is 9 B of 10 B.")


class CommandLineTest(unittest.TestCase):
    """The commands the panel runs, end to end against a scratch database."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.env = dict(os.environ, NETUSAGE_DB=os.path.join(self.dir.name, "usage.db"))

    def tearDown(self):
        self.dir.cleanup()

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", os.path.join(ROOT, "netusage.py"), *args],
                              capture_output=True, text=True, env=self.env, timeout=30)

    def limits(self):
        result = self.run_cli("summary")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["limits"]

    def test_set_limits_saves_both(self):
        result = self.run_cli("set-limits", "Home", "2000000000", "none")
        self.assertEqual(result.returncode, 0, result.stderr)
        (row,) = json.loads(result.stdout)["limits"]
        self.assertEqual((row["c"], row["daily"], row["monthly"], row["cycleDay"]), ("Home", 2000000000, None, 1))

    def test_set_limits_takes_a_billing_day(self):
        result = self.run_cli("set-limits", "Home", "none", "50000000000", "15")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["limits"][0]["cycleDay"], 15)
        for bad in ("0", "32", "x"):
            self.assertEqual(self.run_cli("set-limits", "Home", "none", "5", bad).returncode, 2, bad)
        self.assertEqual(self.limits()[0]["cycleDay"], 15)

    def test_set_limits_writes_nothing_when_either_is_invalid(self):
        for bad in (("5", "-3"), ("abc", "none"), ("5", "1e3"), ("5", "5", "40")):
            result = self.run_cli("set-limits", "Home", *bad)
            self.assertEqual(result.returncode, 2, bad)
            self.assertIn("netusage:", result.stderr)
        self.assertEqual(self.limits(), [])

    def test_unknown_command(self):
        self.assertEqual(self.run_cli("bogus").returncode, 2)
        self.assertEqual(self.run_cli("set-limits", "Home").returncode, 2)


class ParsingTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_module({})

    def test_nmcli_escapes(self):
        self.assertEqual(self.mod.split_nmcli(r"wlan0:wifi:connected:Cafe\: 5G \\ Guest"),
                         ["wlan0", "wifi", "connected", r"Cafe: 5G \ Guest"])

    def test_names_are_bounded_and_printable(self):
        self.assertEqual(self.mod.clean_name("a\x1b[31mb\n" + "x" * 100), ("a[31mb" + "x" * 100)[:64])


class MarkupSafetyTest(unittest.TestCase):
    """Connection names are attacker-controlled (anyone can name an SSID), so
    no Text in the panel may run in AutoText mode."""

    def test_every_text_sink_is_plain(self):
        with open(os.path.join(ROOT, "Panel.qml")) as handle:
            qml = handle.read()
        bare = [m.start() for m in re.finditer(r"(?<![\w.])Text\s*\{", qml)]
        self.assertEqual(len(bare), 1, "only the PlainText component may declare Text")
        self.assertIn("component PlainText: Text {\n    textFormat: Text.PlainText", qml)
        self.assertNotIn("RichText", qml)
        self.assertNotIn("StyledText", qml)


if __name__ == "__main__":
    unittest.main()
