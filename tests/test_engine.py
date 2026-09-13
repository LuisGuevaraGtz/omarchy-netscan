#!/usr/bin/env python3
"""Unit tests for the netscan engine.

Runs entirely offline with fictional data: subprocess output is fed in via
fixtures or a stub `run_bounded`, and files are redirected to temporary
XDG config/state dirs. No arp-scan, nmap, or LAN access is required.

Run with:  python3 -m unittest discover -s tests -v
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.normpath(os.path.join(HERE, "..", "bin", "netscan-engine"))


def load_engine():
    # The engine has no .py extension, so build the loader explicitly.
    loader = SourceFileLoader("netscan_engine", ENGINE)
    spec = importlib.util.spec_from_loader("netscan_engine", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TmpXdgMixin:
    """Point XDG dirs at fresh temp dirs per test and reset the engine's
    *_home() caches afterwards."""

    def setUp(self):
        self._xdg_config = tempfile.mkdtemp(prefix="netscan-conf-")
        self._xdg_state = tempfile.mkdtemp(prefix="netscan-state-")
        self._env = mock.patch.dict(
            os.environ,
            {"XDG_CONFIG_HOME": self._xdg_config, "XDG_STATE_HOME": self._xdg_state},
            clear=False,
        )
        self._env.start()
        self.addCleanup(self._env.stop)

    def engine(self):
        return load_engine()

    def _with_nmap(self, e):
        """Report nmap as installed so run_bounded stubs get exercised.

        Without this, scan_ports/inspect_host bail out early with
        'nmap binary not found' on hosts (like CI runners) where nmap
        is absent -- testing the wrong branch while passing locally
        wherever nmap happens to be installed."""
        return mock.patch.object(
            e, "_trusted_bin", side_effect=lambda n: "/usr/bin/nmap" if n == "nmap" else None
        )

    def _with_bins(self, e, mapping):
        """Stub trusted-helper resolution: names in `mapping` resolve to
        the given absolute paths, everything else is 'not installed'."""
        return mock.patch.object(e, "_trusted_bin", side_effect=lambda n: mapping.get(n))


class TestSanitization(TmpXdgMixin, unittest.TestCase):
    def test_normalize_mac(self):
        e = self.engine()
        self.assertEqual(e.normalize_mac("AA-BB-CC-DD-EE-FF"), "aa:bb:cc:dd:ee:ff")
        self.assertEqual(e.normalize_mac("aa:bb:cc:dd:ee:ff"), "aa:bb:cc:dd:ee:ff")
        self.assertEqual(e.normalize_mac("aa:bb:cc"), "")
        self.assertEqual(e.normalize_mac(""), "")
        self.assertEqual(e.normalize_mac(None), "")

    def test_sanitize_alias(self):
        e = self.engine()
        self.assertEqual(e.sanitize_alias("  hello\t  world  "), "hello world")
        self.assertEqual(e.sanitize_alias("a\x01b"), "ab")
        self.assertEqual(e.sanitize_alias(None), "")
        long_alias = "x" * (2 * e.MAX_ALIAS_LEN)
        # clamp() appends a trailing ellipsis, so allow MAX+1.
        self.assertLessEqual(len(e.sanitize_alias(long_alias)), e.MAX_ALIAS_LEN + 1)

    def test_clamp(self):
        e = self.engine()

        def wrap(s, limit):
            self.assertEqual(e.clamp(s, limit), s)

        wrap("short", 100)
        out = e.clamp("x" * 20, 10)
        self.assertTrue(out.endswith("…"))
        self.assertLessEqual(len(out), 11)  # 10 chars + ellipsis
        self.assertEqual(e.clamp(None, 10), "")


class TestClassify(TmpXdgMixin, unittest.TestCase):
    def test_gateway_and_self(self):
        e = self.engine()
        icon, cat, gw, selfp = e.classify_device("192.168.1.1", "aa:bb", "ASUS", "192.168.1.1", "192.168.1.5")
        self.assertTrue(gw)
        self.assertFalse(selfp)
        icon, cat, gw, selfp = e.classify_device("192.168.1.5", "aa:bb", "ASUS", "192.168.1.1", "192.168.1.5")
        self.assertTrue(selfp)
        self.assertFalse(gw)

    def test_known_vendors(self):
        e = self.engine()
        cases = {
            "Apple, Inc.": "Phone",
            "Xiaomi Communications Co": "Phone",
            "Espressif Inc.": "Smart IoT",
            "ASUSTek COMPUTER INC.": "Computer",
        }
        for vendor, expected in cases.items():
            icon, cat, gw, selfp = e.classify_device("10.0.0.9", "aa:bb", vendor, "10.0.0.1", "10.0.0.2")
            self.assertIn(expected, cat, vendor)
            self.assertFalse(gw)
            self.assertFalse(selfp)

    def test_unknown_vendor_defaults_to_network_host(self):
        e = self.engine()
        icon, cat, gw, selfp = e.classify_device("10.0.0.9", "aa:bb", "Mystery Vendor LLC", "10.0.0.1", "10.0.0.2")
        self.assertEqual(cat, "Network Host")


class TestAliasStore(TmpXdgMixin, unittest.TestCase):
    def test_save_and_load_round_trip(self):
        e = self.engine()
        e.save_aliases({"aa:bb:cc:dd:ee:ff": "Samsung A56"})
        loaded = e.load_aliases()
        self.assertEqual(loaded, {"aa:bb:cc:dd:ee:ff": "Samsung A56"})

    def test_file_is_atomic_and_bounded(self):
        e = self.engine()
        e.save_aliases({"aa:bb:cc:dd:ee:ff": "n"})
        path = e.alias_path()
        self.assertTrue(os.path.exists(path))
        # Over-budget/corrupt file must be treated as empty, never trusted.
        with open(path, "w") as f:
            f.write("{not json")
        self.assertEqual(e.load_aliases(), {})

    def test_ignores_invalid_entries(self):
        e = self.engine()
        e.save_aliases({"not-a-mac": "junk", "aa:bb:cc:dd:ee:ff": "ok"})
        self.assertEqual(e.load_aliases(), {"aa:bb:cc:dd:ee:ff": "ok"})


class TestRunBounded(unittest.TestCase):
    def test_timeout_kills_process_group(self):
        e = load_engine()
        # A stubborn child that ignores SIGTERM and never exits on its own.
        out, truncated, timed_out = e.run_bounded(
            [sys.executable, "-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"],
            timeout=0.3,
        )
        self.assertTrue(timed_out)
        self.assertFalse(truncated)
        self.assertEqual(out, b"")

    def test_caps_stdout(self):
        e = load_engine()
        out, truncated, timed_out = e.run_bounded(
            [sys.executable, "-c", "print('x' * 200000)"],
            timeout=5,
            max_bytes=64 * 1024,
        )
        self.assertTrue(truncated)
        self.assertLessEqual(len(out), 64 * 1024)


class TestScanPortsParsing(TmpXdgMixin, unittest.TestCase):
    NMAP_TOP_FIXTURE = """\
Starting Nmap 7.94 ( https://nmap.org ) at 2026-09-11 10:00 UTC
Nmap scan report for 10.0.0.5
Host is up (0.0013s latency).
PORT    STATE SERVICE     VERSION
22/tcp  open  ssh
80/tcp  open  http        nginx
443/tcp open  https
9999/tcp open  unknown
Nmap done: 1 IP address (1 host up) scanned in 0.89 seconds
"""

    def test_parses_top_ports(self):
        e = self.engine()
        with self._with_nmap(e), mock.patch.object(e, "run_bounded", return_value=(self.NMAP_TOP_FIXTURE.encode(), False, False)):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.scan_ports("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["status"], "ok")
        self.assertTrue(res["hostUp"])
        self.assertEqual(res["portCount"], 4)
        self.assertEqual(res["ports"][0]["port"], "22/tcp")
        self.assertEqual(res["ports"][1]["service"], "http")
        self.assertEqual(res["ports"][1]["version"], "nginx")

    def test_rejects_bad_ip(self):
        e = self.engine()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            e.scan_ports("nonsense")
        self.assertEqual(json.loads(buf.getvalue())["status"], "error")

    def test_reports_missing_nmap(self):
        e = self.engine()
        with mock.patch.object(e, "_trusted_bin", return_value=None):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.scan_ports("10.0.0.5")
        self.assertEqual(json.loads(buf.getvalue())["status"], "error")


class TestInspectParsing(TmpXdgMixin, unittest.TestCase):
    NMAP_XML_FIXTURE = """\
<?xml version="1.0"?>
<nmaprun scanner="nmap" version="7.94">
  <runstats><finished time="0"/></runstats>
  <host starttime="0">
    <status state="up" reason="user-set"/>
    <times srtt="1250"/>
    <ports>
      <port protocol="tcp" portid="80">
        <state state="open" reason="syn-ack"/>
        <service name="http" product="nginx" version="1.24.0" extrainfo="deb1"/>
        <script id="http-title" output="Site title: Router Admin"/>
      </port>
      <port protocol="tcp" portid="443">
        <state state="open" reason="syn-ack"/>
        <service name="https" tunnel="ssl" product="nginx" version="1.24.0"/>
        <script id="ssl-cert" output="Subject: commonName=router.home/O=FakeCorp"/>
      </port>
      <port protocol="tcp" portid="1900">
        <state state="open" reason="syn-ack"/>
        <script id="upnp-info" output="Model: FakeRouter v2"/>
      </port>
    </ports>
    <hostscript>
      <script id="banner" output="Welcome to the printer"/>
    </hostscript>
  </host>
</nmaprun>
"""

    def test_parses_deep_scan(self):
        e = self.engine()
        with self._with_nmap(e), mock.patch.object(e, "run_bounded", return_value=(self.NMAP_XML_FIXTURE.encode(), False, False)):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.inspect_host("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["portCount"], 3)
        self.assertEqual(res["ports"][0]["service"], "http")
        self.assertEqual(res["ports"][0]["version"], "nginx 1.24.0 deb1")
        self.assertEqual(res["identity"]["httpTitle"], "Router Admin")
        self.assertEqual(res["identity"]["tlsCN"], "router.home")
        self.assertEqual(res["identity"]["upnpModel"], "Model: FakeRouter v2")

    def test_host_timed_out_reports_error(self):
        e = self.engine()
        xml = b"""<?xml version="1.0"?><nmaprun><host timedout="true">
          <status state="up"/><times srtt="123456"/><ports/></host></nmaprun>"""
        with self._with_nmap(e), mock.patch.object(e, "run_bounded", return_value=(xml, False, False)):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.inspect_host("10.0.0.5")
        self.assertEqual(json.loads(buf.getvalue())["status"], "error")

    def test_truncated_output_reports_error(self):
        e = self.engine()
        with self._with_nmap(e), mock.patch.object(e, "run_bounded", return_value=(b"partial", True, False)):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.inspect_host("10.0.0.5")
        self.assertEqual(json.loads(buf.getvalue())["status"], "error")


class TestIdentifyHost(TmpXdgMixin, unittest.TestCase):
    def _with_tools(self, e):
        """Force both resolver branches to be found so run_bounded stubs
        actually get exercised (getent/avahi may be absent on the host)."""
        return mock.patch.object(
            e,
            "_trusted_bin",
            side_effect=lambda n: {
                "getent": "/usr/bin/getent",
                "avahi-resolve-address": "/usr/bin/avahi-resolve-address",
            }.get(n),
        )

    def test_dns_then_mdns(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            if cmd[0].endswith("getent"):
                return b"10.0.0.5  router.home  router\n", False, False
            if cmd[0].endswith("avahi"):
                return b"10.0.0.5  printer.local\n", False, False
            return b"", False, False

        with self._with_tools(e), mock.patch.object(e, "run_bounded", side_effect=fake_run):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.identify_host("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["hostname"], "router.home")
        self.assertEqual(res["source"], "dns")

    def test_avahi_fallback(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            if cmd[0].endswith("getent"):
                return b"", False, False
            return b"10.0.0.5  printer.local\n", False, False

        with self._with_tools(e), mock.patch.object(e, "run_bounded", side_effect=fake_run):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.identify_host("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["hostname"], "printer.local")
        self.assertEqual(res["source"], "mdns")

    def test_hostname_is_sanitized(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            # A resolver that echoes the IP back (or any non-hostname) must
            # yield an empty hostname rather than the raw echo.
            return b"10.0.0.5  10.0.0.5\n", False, False

        with self._with_tools(e), mock.patch.object(e, "run_bounded", side_effect=fake_run):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.identify_host("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["hostname"], "")

    def test_control_chars_stripped_from_hostname(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            # Control characters must be stripped; the clean token survives.
            return b"10.0.0.5  evil\x01hostname\n", False, False

        with self._with_tools(e), mock.patch.object(e, "run_bounded", side_effect=fake_run):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.identify_host("10.0.0.5")
        res = json.loads(buf.getvalue())
        self.assertEqual(res["hostname"], "evilhostname")


class TestSnapshot(TmpXdgMixin, unittest.TestCase):
    FIXED_DEVICES = [
        {"ip": "192.168.1.1", "mac": "e4:77:27:60:64:ac", "vendor": "HUAWEI", "icon": "i",
         "category": "Router / Gateway", "isGateway": True, "isSelf": False, "extraIps": []},
        {"ip": "192.168.1.50", "mac": "dc:8b:28:4c:eb:8b", "vendor": "This Computer", "icon": "i",
         "category": "This Device", "isGateway": False, "isSelf": True, "extraIps": []},
    ]

    def _run(self, e, devices):
        def fake_discover():
            iface, gw, sub, local = "eth0", "192.168.1.1", "192.168.1.0/24", "192.168.1.50"
            return iface, gw, sub, local, devices

        with mock.patch.object(e, "_discover_devices", side_effect=fake_discover), \
             mock.patch.object(e, "_notify_new_devices") as notify:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.snapshot()
            return json.loads(buf.getvalue()), notify

    def test_first_run_reports_all_new(self):
        e = self.engine()
        res, notify = self._run(e, list(self.FIXED_DEVICES))
        self.assertEqual(res["status"], "ok")
        self.assertEqual(len(res["new"]), 2)
        notify.assert_called_once()

    def test_second_run_sees_no_new_devices(self):
        e = self.engine()
        self._run(e, list(self.FIXED_DEVICES))
        res, notify = self._run(e, list(self.FIXED_DEVICES))
        self.assertEqual(res["new"], [])
        notify.assert_called_once_with([])

    def test_brand_new_device_is_detected(self):
        e = self.engine()
        self._run(e, list(self.FIXED_DEVICES))
        extra = {"ip": "192.168.1.77", "mac": "aa:bb:cc:dd:ee:ff", "vendor": "Espressif",
                 "icon": "i", "category": "Smart IoT Device", "isGateway": False,
                 "isSelf": False, "extraIps": []}
        res, notify = self._run(e, list(self.FIXED_DEVICES) + [extra])
        self.assertEqual([d["mac"] for d in res["new"]], ["aa:bb:cc:dd:ee:ff"])
        self.assertEqual(res["known"], 2)

    def test_stale_devices_are_pruned(self):
        e = self.engine()
        self._run(e, list(self.FIXED_DEVICES))
        e.SNAPSHOT_MAX_AGE_DAYS = -1  # anything older than 0s is stale now
        res, _ = self._run(e, list(self.FIXED_DEVICES))
        self.assertEqual(res["new"], [])  # both devices are known, just pruned
        files = os.listdir(e.state_dir())
        self.assertEqual(len([f for f in files if f.startswith("snapshot-")]), 1)


class TestDiscoverParsing(TmpXdgMixin, unittest.TestCase):
    ARPSCAN_FIXTURE = """\
Interface: eth0, type: EN10MB, MAC: de:ad:be:ef:00:11, IPv4: 10.0.0.2
Starting arp-scan 1.10.0 with 256 hosts
10.0.0.1\te4:77:27:60:64:ac\tHUAWEI TECHNOLOGIES CO.,LTD
10.0.0.2\tde:ad:be:ef:00:11\t(Unknown: locally administered)
10.0.0.5\taa:bb:cc:dd:ee:ff\tApple, Inc.
3 packets received by filter, 0 packets dropped by kernel
Ending arp-scan 1.10.0
"""

    ROUTE_FIXTURE = """\
default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.2 metric 100
10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.2
"""

    NEIGH_FIXTURE = """\
10.0.0.9 dev eth0 lladdr 12:34:56:78:90:ab REACHABLE
"""

    def test_merges_arp_scan_with_neighbor_table(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            if cmd[0].endswith("arp-scan"):
                return self.ARPSCAN_FIXTURE.encode(), False, False
            if "route" in cmd:
                return self.ROUTE_FIXTURE.encode(), False, False
            if "neigh" in cmd:
                return self.NEIGH_FIXTURE.encode(), False, False
            return b"", False, False

        with self._with_bins(e, {"arp-scan": "/usr/bin/arp-scan", "ip": "/usr/bin/ip"}), \
             mock.patch.object(e, "run_bounded", side_effect=fake_run), \
             mock.patch.object(e, "_read_local_mac", return_value="de:ad:be:ef:00:11"):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.scan_network()
        res = json.loads(buf.getvalue())
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["gateway"], "10.0.0.1")
        self.assertEqual(res["localIp"], "10.0.0.2")
        self.assertEqual(res["deviceCount"], 4)
        ips = [d["ip"] for d in res["devices"]]
        self.assertIn("10.0.0.9", ips)  # neighbor-table host
        by_ip = {d["ip"]: d for d in res["devices"]}
        self.assertEqual(by_ip["10.0.0.1"]["vendor"], "HUAWEI TECHNOLOGIES CO.,LTD")
        self.assertTrue(by_ip["10.0.0.1"]["isGateway"])
        self.assertTrue(by_ip["10.0.0.2"]["isSelf"])

    def test_falls_back_without_arp_scan(self):
        e = self.engine()

        def fake_run(cmd, timeout, max_bytes):
            if "route" in cmd:
                return self.ROUTE_FIXTURE.encode(), False, False
            if "neigh" in cmd:
                return self.NEIGH_FIXTURE.encode(), False, False
            return b"", False, False

        with self._with_bins(e, {"ip": "/usr/bin/ip"}), \
             mock.patch.object(e, "run_bounded", side_effect=fake_run), \
             mock.patch.object(e, "_read_local_mac", return_value="de:ad:be:ef:00:11"):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                e.scan_network()
        res = json.loads(buf.getvalue())
        self.assertEqual(res["status"], "ok")
        self.assertIn("10.0.0.9", [d["ip"] for d in res["devices"]])


class TestTrustedBin(TmpXdgMixin, unittest.TestCase):
    def test_missing_binary_resolves_none(self):
        e = self.engine()
        self.assertIsNone(e._trusted_bin("definitely-not-a-real-binary-xyz"))

    def test_name_with_slash_is_rejected(self):
        e = self.engine()
        self.assertIsNone(e._trusted_bin("../bin/sh"))
        self.assertIsNone(e._trusted_bin("/usr/bin/sh"))

    def test_system_shell_resolves_to_trusted_path(self):
        # End-to-end acceptance with zero mocking: /bin/sh exists on any
        # normal Linux, is root-owned, and is not group/world-writable.
        e = self.engine()
        found = e._trusted_bin("sh")
        self.assertIsNotNone(found)
        self.assertTrue(os.path.isabs(found))
        self.assertIn(os.path.realpath(os.path.dirname(found)),
                      {os.path.realpath(d) for d in e._TRUSTED_BIN_DIRS})

    def test_symlink_to_trusted_binary_is_accepted(self):
        e = self.engine()
        target = e._trusted_bin("sh")
        if target is None:
            self.skipTest("no trusted sh on this host")
        link = os.path.join(tempfile.mkdtemp(prefix="netscan-link-"), "sh")
        os.symlink(target, link)
        self.assertTrue(e._is_trusted_exec(link))

    def test_symlink_escape_is_rejected(self):
        e = self.engine()
        d = tempfile.mkdtemp(prefix="netscan-escape-")
        target = os.path.join(d, "victim")
        with open(target, "w") as f:
            f.write("x")
        os.chmod(target, 0o755)
        link = os.path.join(d, "link")
        os.symlink(target, link)
        self.assertFalse(e._is_trusted_exec(link))

    def test_group_writable_file_is_rejected(self):
        e = self.engine()
        fd, path = tempfile.mkstemp(prefix="netscan-gw-")
        os.close(fd)
        os.chmod(path, 0o775)
        self.assertFalse(e._is_trusted_exec(path))

    def test_directory_and_missing_paths_are_rejected(self):
        e = self.engine()
        self.assertFalse(e._is_trusted_exec(tempfile.mkdtemp(prefix="netscan-dir-")))
        self.assertFalse(e._is_trusted_exec("/no/such/path/anywhere-xyz"))


class TestSanitizeEnv(TmpXdgMixin, unittest.TestCase):
    def test_drops_interpreter_startup_vars(self):
        e = self.engine()
        with mock.patch.dict(os.environ, {
            "PYTHONPATH": "/tmp/evil",
            "PYTHONHOME": "/tmp/evilhome",
            "PYTHONSTARTUP": "/tmp/evil/startup.py",
            "HOME": "/home/tester",
            "XDG_CONFIG_HOME": "/tmp/conf",
        }, clear=False):
            e._sanitize_env()
            self.assertNotIn("PYTHONPATH", os.environ)
            self.assertNotIn("PYTHONHOME", os.environ)
            self.assertNotIn("PYTHONSTARTUP", os.environ)
            self.assertEqual(os.environ["HOME"], "/home/tester")
            self.assertEqual(os.environ["XDG_CONFIG_HOME"], "/tmp/conf")
            self.assertEqual(os.environ["LC_ALL"], "C")
            self.assertTrue(os.environ["PATH"])

    def test_empty_path_gets_trusted_default_but_set_path_is_kept(self):
        e = self.engine()
        with mock.patch.dict(os.environ, {"PATH": ""}, clear=False):
            e._sanitize_env()
            self.assertEqual(os.environ["PATH"], e._TRUSTED_PATH)
        with mock.patch.dict(os.environ, {"PATH": "/custom/bin"}, clear=False):
            e._sanitize_env()
            self.assertEqual(os.environ["PATH"], "/custom/bin")


class TestCopyCommand(TmpXdgMixin, unittest.TestCase):
    def _run_copy(self, e, target):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            e.cmd_copy([target] if target is not None else [])
        return json.loads(buf.getvalue())

    def test_rejects_non_ip_target(self):
        e = self.engine()
        for bad in (None, "", "not-an-ip", "10.0.0.5; rm -rf ~", "-h", "router.home"):
            res = self._run_copy(e, bad)
            self.assertEqual(res["status"], "error", bad)

    def test_reports_missing_wl_copy(self):
        e = self.engine()
        with mock.patch.object(e, "_trusted_bin", return_value=None):
            res = self._run_copy(e, "10.0.0.5")
        self.assertEqual(res["status"], "error")

    def test_copies_valid_ip_through_trusted_binary(self):
        e = self.engine()
        seen = []

        def fake_run(cmd, timeout, max_bytes):
            seen.append(cmd)
            return b"", False, False

        with mock.patch.object(e, "_trusted_bin", return_value="/usr/bin/wl-copy"), \
             mock.patch.object(e, "run_bounded", side_effect=fake_run):
            res = self._run_copy(e, "10.0.0.5")
        self.assertEqual(res["status"], "ok")
        self.assertEqual(seen, [["/usr/bin/wl-copy", "--", "10.0.0.5"]])


class TestOpenCommand(TmpXdgMixin, unittest.TestCase):
    def _run_open(self, e, url):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            e.cmd_open([url] if url is not None else [])
        return json.loads(buf.getvalue())

    def test_rejects_non_device_urls(self):
        e = self.engine()
        for bad in (None, "", "file:///etc/passwd", "javascript:alert(1)",
                    "data:text/html,<b>x</b>", "http://router.home/",
                    "https://example.com:443/", "ftp://10.0.0.5/",
                    "--help", "http://10.0.0.5:99999999999999999999/"):
            res = self._run_open(e, bad)
            self.assertEqual(res["status"], "error", bad)

    def test_reports_missing_xdg_open(self):
        e = self.engine()
        with mock.patch.object(e, "_trusted_bin", return_value=None):
            res = self._run_open(e, "http://10.0.0.5/")
        self.assertEqual(res["status"], "error")

    def test_opens_valid_device_url_through_trusted_binary(self):
        e = self.engine()
        seen = []

        def fake_run(cmd, timeout, max_bytes):
            seen.append(cmd)
            return b"", False, False

        with mock.patch.object(e, "_trusted_bin", return_value="/usr/bin/xdg-open"), \
             mock.patch.object(e, "run_bounded", side_effect=fake_run):
            res = self._run_open(e, "https://10.0.0.5:443/")
        self.assertEqual(res["status"], "ok")
        self.assertEqual(seen, [["/usr/bin/xdg-open", "https://10.0.0.5:443/"]])


if __name__ == "__main__":
    unittest.main()