import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from analyze_ninja_log import Step
from compare_parallelism import compare, peak_concurrency


class ParallelismTests(unittest.TestCase):
    def test_peak_handles_simultaneous_end_start_and_zero_duration(self):
        self.assertEqual(peak_concurrency([
            Step(0, 10), Step(5, 10), Step(10, 20), Step(10, 10),
        ]), 2)

    def make_study(self, root):
        order = ["fixed", "default", "default", "fixed",
                 "default", "fixed", "fixed", "default"]
        manifest = {
            "order": order, "fixed_jobs": 12, "default_jobs": 14,
            "runner_sha256": "runner", "finished_at": "2026-01-01T23:00:00+00:00",
        }
        (root / "study.json").write_text(json.dumps(manifest), encoding="utf-8")
        for index, condition in enumerate(order):
            run = root / f"run{index}"
            run.mkdir()
            fixed = condition == "fixed"
            args = ["--build", ".", "--config", "Release"]
            if fixed:
                args += ["--parallel", "12"]
            metadata = {
                "status": "succeeded", "setup": {"compiler_sha256": "same"},
                "generator": "Ninja", "profile": False, "label": f"run{index}",
                "parallel": 12 if fixed else 0, "build_arguments": args,
                "validated_version": "4.10.0", "runner_sha256": "runner",
                "started_at": f"2026-01-01T{index:02}:00:00+00:00",
                "finished_at": f"2026-01-01T{index:02}:10:00+00:00",
                "build_seconds": 100 if fixed else 90,
            }
            (run / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            (run / "ninja_log.txt").write_text(
                "# ninja log v6\n0\t1000\t0\ta.obj\tabc\n", encoding="utf-8")

    def test_balanced_study_reports_direction_correctly(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_study(root)
            result = compare(root)
            self.assertAlmostEqual(result["default_median_time_change_percent"], -10)
            self.assertEqual(result["default_faster_pairs"], 4)
            self.assertEqual(result["paired_mean_default_minus_fixed_seconds"], -10)

    def test_rejects_changed_settings_and_incomplete_study(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_study(root)
            path = root / "run1" / "metadata.json"
            metadata = json.loads(path.read_text())
            metadata["parallel"] = 14
            path.write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "settings"):
                compare(root)
            manifest = json.loads((root / "study.json").read_text())
            del manifest["finished_at"]
            (root / "study.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not completed"):
                compare(root)

    def test_rejects_toolchain_changes_and_missing_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_study(root)
            path = root / "run7" / "metadata.json"
            metadata = json.loads(path.read_text())
            metadata["setup"]["compiler_sha256"] = "different"
            path.write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "toolchain changed"):
                compare(root)
            path.unlink()
            with self.assertRaisesRegex(ValueError, "exactly eight"):
                compare(root)


if __name__ == "__main__":
    unittest.main()
