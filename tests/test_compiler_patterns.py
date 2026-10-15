import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from prepare_compiler_patterns import DLS_ASSIGNMENTS, cached_dls, synthetic


class CompilerPatternTests(unittest.TestCase):
    def test_same_assignment_counts(self):
        self.assertEqual(synthetic("view", 512).count("    m.at("), 512)
        self.assertEqual(synthetic("cached", 512).count(" = values["), 512)
        self.assertIn("i < 512", synthetic("table", 512))
        self.assertEqual(synthetic("table", 512).count("    {"), 512)

    def test_invalid_pattern(self):
        for pattern, count in [("unknown", 1), ("view", 0)]:
            with self.assertRaises(ValueError):
                synthetic(pattern, count)

    def test_dls_rewrite_is_function_scoped(self):
        original = ("before\nMat dls::cayley_LS_M() {\n"
                    "    Mat M = Mat::zeros(120, 120, CV_64F);\n"
                    + "M.at<double>(0,1)=a[2];\n" * DLS_ASSIGNMENTS
                    + "return M;\n}\nMat dls::Hessian() { M.at<double>(0,1)=a[2]; }\n")
        changed, _, function = cached_dls(original)
        self.assertTrue(changed.startswith("before\n"))
        self.assertTrue(changed.endswith("Mat dls::Hessian() { M.at<double>(0,1)=a[2]; }\n"))
        self.assertEqual(function.count("m_data[0 * m_stride + 1]=a_data[2];"), DLS_ASSIGNMENTS)
        self.assertIn("const size_t m_stride = M.step1();", function)

    def test_dls_guard_rejects_changed_workload(self):
        with self.assertRaises(ValueError):
            cached_dls("Mat dls::cayley_LS_M() {}\nMat dls::Hessian() {}")


if __name__ == "__main__":
    unittest.main()
