"""tests/mutate_logship.py: a mutant is KILLED only if its intended test PASSED on unmutated code and then
FAILED BY ASSERTION. A test that errors -- a bad path, Lua 5.3 spelling on the 5.2 interpreter, a missing
fixture -- is red without having caught anything; it used to count as a kill (W3 card "The mutation harness
counts an erroring test as a kill", found by W1, 2026-11-02). Such a mutant is now UNCHECKED, with the reason."""
import io, os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import mutate_logship as M  # noqa: E402  (it chdirs to the repo root on import)

OUT = """PASS  a passing test
FAIL  an assertion that failed
      ./tests\\test_x.lua:12: the count: expected 1, got 2
FAIL  a test that blew up
      ERROR ./tests\\test_x.lua:20: attempt to call a nil value (field 'diskReport')
LOAD FAIL tests.test_y: ./tests/test_y.lua:3: unexpected symbol

10 passed, 2 failed
"""


class ParseTest(unittest.TestCase):
    def test_each_test_gets_its_own_outcome(self):
        r = M.parse_results(OUT)
        self.assertEqual(r["a passing test"][0], "pass")
        self.assertEqual(r["an assertion that failed"][0], "assert")
        self.assertEqual(r["a test that blew up"][0], "error")
        self.assertIn("attempt to call a nil value", r["a test that blew up"][1])


class VerdictTest(unittest.TestCase):
    PASS = {"t": ("pass", "")}

    def test_green_before_and_failed_by_assertion_is_killed(self):
        self.assertEqual(M.verdict(self.PASS, {"t": ("assert", "x")}, "t")[0], "KILLED")

    def test_an_intended_test_that_errors_under_the_mutant_is_unchecked(self):
        v, why = M.verdict(self.PASS, {"t": ("error", "attempt to call a nil value")}, "t")
        self.assertEqual(v, "UNCHECKED")
        self.assertIn("errored", why)

    def test_an_intended_test_red_before_the_mutation_is_unchecked(self):
        for before in ("assert", "error"):
            v, why = M.verdict({"t": (before, "")}, {"t": ("assert", "")}, "t")
            self.assertEqual(v, "UNCHECKED")
            self.assertIn("before the mutation", why)

    def test_an_intended_test_that_does_not_exist_is_unchecked(self):
        v, why = M.verdict(self.PASS, {"t": ("assert", "")}, "no such test")
        self.assertEqual(v, "UNCHECKED")
        self.assertIn("no test named", why)

    def test_an_intended_test_that_stays_green_survives(self):
        self.assertEqual(M.verdict(self.PASS, {"t": ("pass", "")}, "t")[0], "SURVIVED")

    def test_an_intended_test_missing_under_the_mutant_is_unchecked(self):
        v, why = M.verdict(self.PASS, {}, "t")          # its file no longer loads, for one
        self.assertEqual(v, "UNCHECKED")
        self.assertIn("did not run", why)


class RunnerMarksErrorsTest(unittest.TestCase):
    """tests/run.lua itself must tell an assertion from an error, or the harness has nothing to read."""
    PROBE = os.path.join(ROOT, "tests", "tmp_runner_probe.lua")

    def setUp(self):
        with io.open(self.PROBE, "w", encoding="utf-8", newline="\n") as f:
            f.write('return {\n'
                    '  ["probe asserts"] = function(assert_eq) assert_eq(1, 2, "one is two") end,\n'
                    '  ["probe errors"] = function(assert_eq) local t = nil; return t.x end,\n'
                    '  ["probe passes"] = function(assert_eq) assert_eq(1, 1) end,\n'
                    '}\n')

    def tearDown(self):
        os.remove(self.PROBE)

    def test_the_runner_marks_an_error_and_not_an_assertion(self):
        r = subprocess.run(["lua", "tests/run.lua", "tests.tmp_runner_probe"], cwd=ROOT, capture_output=True, text=True)
        res = M.parse_results(r.stdout + r.stderr)
        self.assertEqual(res["probe asserts"][0], "assert")
        self.assertIn("one is two: expected 2, got 1", res["probe asserts"][1])
        self.assertEqual(res["probe errors"][0], "error")
        self.assertEqual(res["probe passes"][0], "pass")
        self.assertEqual(len(res), 3, "only the named module ran")


if __name__ == "__main__":
    unittest.main()
