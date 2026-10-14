import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "analysis", Path(__file__).resolve().parents[1] / "scripts" / "analyze_ninja_log.py"
)
analysis = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = analysis
SPEC.loader.exec_module(analysis)


class NinjaAnalysisTests(unittest.TestCase):
    def parse(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ninja_log.txt"
            path.write_text(content, encoding="utf-8")
            return analysis.parse_log(path)

    def test_multi_output_link_is_counted_once(self):
        steps = self.parse(
            "# ninja log v5\n"
            "0\t1000\t0\tmodules/world/CMakeFiles/opencv_world.dir/__/dnn/net.cpp.obj\tabc\n"
            "0\t2000\t0\tother.obj\tdef\n"
            "2000\t3000\t0\tbin/world.dll\t123\n"
            "2000\t3000\t0\tlib/world.lib\t123\n"
        )
        result = analysis.summarize(steps)
        self.assertEqual(result["unique_steps"], 3)
        self.assertEqual(result["compile_steps"], 2)
        self.assertEqual(result["summed_step_elapsed_seconds"], 4)
        self.assertEqual(result["log_span_seconds"], 3)
        self.assertEqual(result["by_component_elapsed_seconds"]["opencv/dnn"], 1)
        self.assertEqual(result["by_kind_elapsed_seconds"]["link/lib"], 1)
        self.assertEqual(result["finish_tail_seconds"], 1)
        self.assertEqual(result["mean_concurrent_steps"], 1.333)

    def test_same_times_different_commands_remain_distinct(self):
        steps = self.parse("# ninja log v5\n0\t1000\t0\ta.obj\tabc\n0\t1000\t0\tb.obj\tdef\n")
        self.assertEqual(len(steps), 2)

    def test_v6_uses_the_same_timing_columns(self):
        steps = self.parse("# ninja log v6\n10\t1010\t8136995802666653\ta.obj\tabc\n")
        self.assertEqual(steps[0].seconds, 1)

    def test_rejects_historical_log(self):
        with self.assertRaisesRegex(ValueError, "Historical"):
            self.parse("# ninja log v5\n0\t2000\t0\ta.obj\tabc\n0\t1000\t0\tb.obj\tdef\n")

    def test_rejects_empty_malformed_negative_and_non_compile_logs(self):
        for content in ("", "# ninja log v5\n", "# ninja log v5\nbad\n",
                        "# ninja log v5\n10\t5\t0\ta.obj\tabc\n"):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.parse(content)
        with self.assertRaisesRegex(ValueError, "No compile"):
            analysis.summarize(self.parse("# ninja log v5\n0\t1000\t0\ta.dll\tabc\n"))


if __name__ == "__main__":
    unittest.main()
