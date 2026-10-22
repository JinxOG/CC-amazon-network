"""tools/logq.py: the two /logs traps must be caught, not repeated."""
import datetime, os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import logq

UTC = datetime.timezone.utc


def fake(pages):
    """pages: {day: {"matched": n, "lines": [...]}}"""
    calls = []
    def get(url):
        calls.append(url)
        day = url.split("/logs/")[1].split("?")[0]
        return pages.get(day, {"matched": 0, "lines": []})
    return get, calls


def L(ts, msg, source="server", seq=0):
    return {"ts": ts, "msg": msg, "source": source, "level": "INFO", "seq": seq}


class LogqTest(unittest.TestCase):
    def test_lines_come_back_sorted_even_when_the_server_does_not_sort(self):
        get, _ = fake({"2026-10-22": {"matched": 3, "lines": [
            L("2026-10-22T10:00:03Z", "c"), L("2026-10-22T10:00:01Z", "a"), L("2026-10-22T10:00:02Z", "b")]}})
        lines, trunc, _ = logq.query(datetime.datetime(2026, 10, 22, 9, tzinfo=UTC),
                                     datetime.datetime(2026, 10, 22, 11, tzinfo=UTC), get=get)
        self.assertEqual([l["msg"] for l in lines], ["a", "b", "c"])
        self.assertFalse(trunc)

    def test_a_short_page_is_flagged_truncated(self):
        get, _ = fake({"2026-10-22": {"matched": 9000, "lines": [L("2026-10-22T10:00:00Z", "x")]}})
        _, trunc, notes = logq.query(datetime.datetime(2026, 10, 22, 9, tzinfo=UTC),
                                     datetime.datetime(2026, 10, 22, 11, tzinfo=UTC), get=get)
        self.assertTrue(trunc)
        self.assertIn("9000", notes[0])

    def test_a_window_crossing_midnight_queries_both_days_and_clips_both_ends(self):
        get, calls = fake({
            "2026-10-21": {"matched": 2, "lines": [L("2026-10-21T22:00:00Z", "early"), L("2026-10-21T23:30:00Z", "in1")]},
            "2026-10-22": {"matched": 2, "lines": [L("2026-10-22T00:30:00Z", "in2"), L("2026-10-22T05:00:00Z", "late")]}})
        lines, _, _ = logq.query(datetime.datetime(2026, 10, 21, 23, tzinfo=UTC),
                                 datetime.datetime(2026, 10, 22, 1, tzinfo=UTC), get=get)
        self.assertEqual([l["msg"] for l in lines], ["in1", "in2"])
        self.assertEqual(len(calls), 2)
        self.assertIn("since=", calls[0])
        self.assertNotIn("since=", calls[1])

    def test_regex_and_exact_source_filter_after_the_server(self):
        get, _ = fake({"2026-10-22": {"matched": 3, "lines": [
            L("2026-10-22T10:00:00Z", "JOURNAL DISAGREES WITH GPS by 3", "node_183"),
            L("2026-10-22T10:00:01Z", "JOURNAL DISAGREES WITH GPS by 3", "node_1830"),
            L("2026-10-22T10:00:02Z", "Journal: agrees with GPS", "node_183")]}})
        lines, _, _ = logq.query(datetime.datetime(2026, 10, 22, 9, tzinfo=UTC),
                                 datetime.datetime(2026, 10, 22, 11, tzinfo=UTC),
                                 source="node_183", regex=r"DISAGREES WITH GPS by ([2-9]|\d\d)", get=get)
        self.assertEqual(len(lines), 1)

    def test_parse_ts_accepts_z_offset_and_naive(self):
        a = logq.parse_ts("2026-10-22T08:24:00Z")
        self.assertEqual(a, logq.parse_ts("2026-10-22T08:24:00+00:00"))
        self.assertEqual(a, logq.parse_ts("2026-10-22T08:24:00"))


if __name__ == "__main__":
    unittest.main()
