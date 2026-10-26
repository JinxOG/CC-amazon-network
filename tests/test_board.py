"""tools/board.py: which cards count as carrying a VALIDATION block."""
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import board


class HasValidationTest(unittest.TestCase):
    def test_a_block_at_the_start_of_a_line_counts(self):
        self.assertTrue(board.has_validation("text\n\nVALIDATION\nCode: x\nWorked if: y"))

    def test_a_block_written_by_note_with_its_date_stamp_counts(self):
        # The 2026-10-26 miss: 15 of 18 blocks looked like this and were skipped.
        self.assertTrue(board.has_validation("luck.\n\n2026-10-22 16:24 UTC VALIDATION\nCode: x\nWorked if: y"))

    def test_prose_that_mentions_the_block_does_not_count(self):
        self.assertFalse(board.has_validation("write the VALIDATION block (section 4.2) on this card"))

    def test_a_block_without_worked_if_does_not_count(self):
        self.assertFalse(board.has_validation("VALIDATION\nCode: x\nFailed if: y"))


if __name__ == "__main__":
    unittest.main()
