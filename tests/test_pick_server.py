#!/usr/bin/python3
"""Tests for vpn-pick-server: avoided cities, skipping a server whose tunnel died,
and keeping Proton's connect-at-startup pinned to a server that works.

Fake servers and a fake TCP check stand in for Proton's list and the network;
the last test runs the real ranking against the cached server list.

  python3 -I tests/test_pick_server.py [path/to/vpn-pick-server]
  python3 -m pytest -q -p no:cacheprovider tests/test_pick_server.py
"""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.dont_write_bytecode = True
# Script under test: VPN_PICK_SERVER, a path given on the command line (see __main__),
# or ../vpn-pick-server next to this file.
SUT = os.environ.get("VPN_PICK_SERVER") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, "vpn-pick-server")


def load():
    loader = importlib.machinery.SourceFileLoader("vpn_pick_server", SUT)
    spec = importlib.util.spec_from_loader("vpn_pick_server", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def srv(name, city, score, ip):
    return SimpleNamespace(name=name, city=city, load=30, score=score, exit_country="US",
                           physical_servers=[SimpleNamespace(entry_ip=ip, enabled=True)])


# Ranked the way Proton might rank them from one location: the nearest city (Alpha) first.
SERVERS = [
    srv("US-AA#566", "Alpha", 1.67, "192.0.2.8"),
    srv("US-AA#475", "Alpha", 1.68, "192.0.2.5"),
    srv("US-BB#16", "Bravo", 1.80, "198.51.100.2"),
    srv("US-BB#2", "Bravo", 1.80, "198.51.100.2"),   # same box as US-BB#16
    srv("US-CC#26", "Charlie", 1.84, "203.0.113.2"),
    srv("US-DD#23", "Delta", 1.86, "203.0.113.130"),
]


class PickTest(unittest.TestCase):
    def setUp(self):
        self.m = load()
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.m.APP_CONFIG = os.path.join(d, "app-config.json")
        self.m.AVOID_FILE = os.path.join(d, "vpn-avoid")
        self.m.PIN_FILE = os.path.join(d, "state", "pinned")
        self.m.PREFER_FILE = os.path.join(d, "vpn-prefer")
        self.servers = list(SERVERS)
        self.dead_ips = set()
        self.checked = []
        self.m.ranked_servers = self.fake_ranked
        self.m.server_answers = self.fake_answers
        self.m.log = lambda msg: None
        self.startup("US")

    def tearDown(self):
        self.tmp.cleanup()

    # -- fakes ---------------------------------------------------------------
    def fake_ranked(self, target, fallback_country=None):
        ranked = sorted(self.servers, key=lambda s: s.score)
        if "#" in target:
            pinned = [s for s in ranked if s.name == target]
            if not pinned:
                if fallback_country is None:
                    raise KeyError(target)
                return ranked
            ranked = pinned + [s for s in ranked if s.name != target]
        return ranked

    def fake_answers(self, server):
        self.checked.append(server.name)
        return all(p.entry_ip not in self.dead_ips for p in server.physical_servers)

    # -- helpers -------------------------------------------------------------
    def startup(self, value):
        with open(self.m.APP_CONFIG, "w") as f:
            json.dump({"tray_pinned_servers": [], "connect_at_app_startup": value,
                       "start_app_minimized": True}, f, indent=4)

    def get_startup(self):
        with open(self.m.APP_CONFIG) as f:
            return json.load(f)["connect_at_app_startup"]

    def avoid(self, *cities):
        with open(self.m.AVOID_FILE, "w") as f:
            f.write("# cities to stay off\n" + "".join(c + "\n" for c in cities))

    def prefer(self, *cidrs):
        with open(self.m.PREFER_FILE, "w") as f:
            f.write("# ranges to try first\n" + "".join(c + "\n" for c in cidrs))

    def pin_record(self):
        with open(self.m.PIN_FILE) as f:
            return f.read().rstrip("\n").split("\t")

    # -- old behaviour, unchanged ---------------------------------------------
    def test_no_avoid_list_keeps_app_choice(self):
        self.assertEqual(self.m.pick(), "keep US-AA#566")

    def test_no_avoid_list_dead_choice_uses_next_one_time(self):
        self.dead_ips.add("192.0.2.8")
        self.assertEqual(self.m.pick(), "use US-AA#475 US-AA#566")

    def test_everything_dead(self):
        self.dead_ips.update(p.entry_ip for s in SERVERS for p in s.physical_servers)
        self.assertEqual(self.m.pick(), "none -")

    # -- avoid list -------------------------------------------------------------
    def test_avoided_city_skipped_without_checking_it(self):
        self.avoid("Alpha")
        self.assertEqual(self.m.pick(), "use US-BB#16 US-AA#566")
        self.assertFalse([n for n in self.checked if n.startswith("US-GA")])

    def test_avoid_list_is_case_insensitive_and_ignores_comments(self):
        self.avoid("  alpha  ", "", "# Bravo")
        self.assertEqual(self.m.pick(), "use US-BB#16 US-AA#566")

    def test_many_avoided_servers_dont_crowd_out_the_rest(self):
        self.avoid("Alpha")
        self.servers = [srv(f"US-AA#{i}", "Alpha", 1.0 + i / 1000, f"192.0.2.{i % 250}")
                        for i in range(200)] + SERVERS
        self.assertEqual(self.m.pick(), "use US-BB#16 US-AA#0")

    # -- skip (tunnel died on this server) ----------------------------------------
    def test_skip_also_skips_servers_on_the_same_box(self):
        self.avoid("Alpha")
        self.startup("US-BB#16")
        self.assertEqual(self.m.pick(skip="US-BB#16"), "use US-CC#26 US-BB#16")
        self.assertNotIn("US-BB#2", self.checked)

    def test_skip_unknown_server_is_harmless(self):
        self.assertEqual(self.m.pick(skip="US-ZZ#1"), "keep US-AA#566")

    # -- pinned (managed) mode ----------------------------------------------------
    def test_manage_then_first_pick_pins_best_non_avoided(self):
        self.avoid("Alpha")
        self.assertEqual(self.m.manage("US"), 0)
        self.assertEqual(self.get_startup(), "US")          # manage alone changes nothing in Proton
        self.assertEqual(self.m.pick(), "pin US-BB#16 US")

    def test_pinned_server_that_answers_is_kept(self):
        self.avoid("Alpha")
        self.m.manage("US")
        self.assertEqual(self.m.set_pin("US-BB#16", expect="US"), 0)
        self.assertEqual(self.m.pick(), "keep US-BB#16")

    def test_dead_pinned_server_is_replaced(self):
        self.avoid("Alpha")
        self.m.manage("US")
        self.m.set_pin("US-BB#16", expect="US")
        self.dead_ips.add("198.51.100.2")
        self.assertEqual(self.m.pick(), "pin US-CC#26 US-BB#16")

    def test_skipped_pinned_server_is_replaced(self):
        self.avoid("Alpha")
        self.m.manage("US")
        self.m.set_pin("US-BB#16", expect="US")
        self.assertEqual(self.m.pick(skip="US-BB#16"), "pin US-CC#26 US-BB#16")

    def test_pinned_server_gone_from_list_falls_back_to_country(self):
        self.avoid("Alpha")
        self.m.manage("US")
        self.m.set_pin("US-BB#99", expect="US")
        self.assertEqual(self.m.pick(), "pin US-BB#16 US-BB#99")

    def test_set_pin_records_country_and_server(self):
        self.m.manage("US")
        self.assertEqual(self.m.set_pin("US-BB#16", expect="US"), 0)
        self.assertEqual(self.get_startup(), "US-BB#16")
        self.assertEqual(self.pin_record(), ["US", "US-BB#16"])

    def test_set_pin_refuses_when_setting_changed_meanwhile(self):
        self.m.manage("US")
        self.startup("US-EE#1")
        self.assertEqual(self.m.set_pin("US-BB#16", expect="US"), 1)
        self.assertEqual(self.get_startup(), "US-EE#1")
        self.assertEqual(self.pin_record(), ["US", "US"])

    def test_user_changed_setting_is_not_managed(self):
        self.avoid("Alpha")
        self.m.manage("US")
        self.m.set_pin("US-BB#16", expect="US")
        self.startup("US-DD#23")                          # the user picked their own server
        self.dead_ips.add("203.0.113.130")
        self.assertEqual(self.m.pick(), "use US-BB#16 US-DD#23")   # one time only, not pin

    def test_unpin_puts_country_back(self):
        self.m.manage("US")
        self.m.set_pin("US-BB#16", expect="US")
        self.assertEqual(self.m.unpin(), 0)
        self.assertEqual(self.get_startup(), "US")
        self.assertFalse(os.path.exists(self.m.PIN_FILE))

    def test_unpin_leaves_a_user_choice_alone(self):
        self.m.manage("US")
        self.m.set_pin("US-BB#16", expect="US")
        self.startup("US-DD#23")
        self.m.unpin()
        self.assertEqual(self.get_startup(), "US-DD#23")
        self.assertFalse(os.path.exists(self.m.PIN_FILE))

    def test_manage_refuses_when_startup_is_off(self):
        self.startup(None)
        self.assertEqual(self.m.manage("US"), 1)
        self.assertFalse(os.path.exists(self.m.PIN_FILE))


    # -- prefer list ------------------------------------------------------------
    def test_preferred_range_beats_better_ranked_server(self):
        self.prefer("203.0.113.128/25")
        self.assertEqual(self.m.pick(), "use US-DD#23 US-AA#566")

    def test_preferred_range_dead_falls_back_to_normal_order(self):
        self.prefer("203.0.113.128/25")
        self.dead_ips = {"203.0.113.130"}
        self.assertEqual(self.m.pick(), "keep US-AA#566")

    def test_preferred_choice_is_kept(self):
        self.prefer("192.0.2.0/24")
        self.assertEqual(self.m.pick(), "keep US-AA#566")

    def test_prefer_pins_in_pinned_mode(self):
        self.prefer("203.0.113.0/25")
        self.m.write_pin("US", "US")
        self.assertEqual(self.m.pick(), "pin US-CC#26 US")

    def test_avoid_still_beats_prefer(self):
        self.prefer("192.0.2.0/24", "203.0.113.128/25")
        self.avoid("Alpha")
        self.assertEqual(self.m.pick(), "use US-DD#23 US-AA#566")

    def test_bad_prefer_line_ignored(self):
        self.prefer("not-a-cidr")
        self.assertEqual(self.m.pick(), "keep US-AA#566")


def _have_proton_app():
    try:
        import proton.vpn.session  # noqa: F401  (the Proton app's own library)
    except ImportError:
        return False
    return os.path.exists(os.path.expanduser("~/.cache/Proton/VPN/serverlist.json"))


@unittest.skipUnless(_have_proton_app(), "no Proton VPN app libraries or cached server list")
class RealServerListTest(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def test_country_ranking(self):
        ranked = self.m.ranked_servers("US")
        self.assertGreater(len(ranked), 100)
        self.assertTrue(all(s.exit_country == "US" for s in ranked[:50]))

    def test_pinned_server_first(self):
        name = self.m.ranked_servers("US")[40].name
        self.assertEqual(self.m.ranked_servers(name, "US")[0].name, name)

    def test_unknown_pinned_server_falls_back(self):
        ranked = self.m.ranked_servers("US-ZZ#99999", "US")
        self.assertEqual(ranked[0].name, self.m.ranked_servers("US")[0].name)

    def test_landmarks_are_entry_ips_in_different_cities(self):
        ips = self.m.landmarks()
        self.assertEqual(len(ips), 3)
        self.assertEqual(len(set(ips)), 3)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SUT = sys.argv.pop(1)
    unittest.main(verbosity=1)
