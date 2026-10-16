import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


def load(name):
    path = Path(__file__).resolve().parents[1] / "scripts" / (name + ".py")
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("run_runtime_screen")
analysis = load("analyze_runtime_screen")
topology = load("runtime_cpu_topology")


class RuntimeScreenTests(unittest.TestCase):
    def test_cpu_topology_chooses_first_highest_class_processor(self):
        data = bytearray()
        for cpu in range(20):
            record = bytearray(32)
            struct.pack_into("<II", record, 0, 32, 0)
            struct.pack_into("<IHBBBBBB", record, 8, 256 + cpu, 0, cpu, cpu,
                             0 if cpu < 10 else 10, 0, cpu // 10, 0)
            data.extend(record)
        rows = topology.parse_cpu_sets(data)
        self.assertEqual(topology.select_main_cpu(rows, 20), 10)
        with self.assertRaisesRegex(ValueError, "contiguous"):
            topology.select_main_cpu(rows, 12)
        with self.assertRaises(ValueError):
            topology.parse_cpu_sets(data[:-1])

    def make_study(self, root):
        study = {"status": "succeeded", "threads": [1],
                 "selected": {"core": [{"name": "BinaryOpTest.add/0"}]},
                 "frozen_sha256": {}, "runs": []}
        for variant, ticks in (("baseline", 10000), ("shared", 10020), ("llvm", 8000)):
            image = bytearray(512)
            struct.pack_into("<I", image, 60, 64)
            image[64:68] = b"PE\0\0"
            struct.pack_into("<HH", image, 68, 0xAA64, 1)
            struct.pack_into("<8sIIII", image, 88, b".text", 16, 0, 16, 256)
            dll = root / variant / "opencv_world4100.dll"
            dll.parent.mkdir()
            dll.write_bytes(image)
            study["frozen_sha256"][str(dll.relative_to(root))] = runner.digest(dll)
            for block in range(1, 7):
                label = f"b{block}_{variant}_1t_core"
                run = root / "runs" / label
                run.mkdir(parents=True)
                (run / "results.xml").write_text(
                    '<testsuites><testsuite><testcase classname="BinaryOpTest" name="add/0" '
                    'status="run" value_param="(640x480, 8UC1)"><properties>'
                    f'<property name="median" value="{ticks}"/>'
                    f'<property name="mean" value="{ticks}"/>'
                    '<property name="stddev" value="1"/>'
                    '<property name="frequency" value="1000000"/>'
                    '<property name="samples" value="20"/>'
                    '</properties></testcase></testsuite></testsuites>')
                study["runs"].append({"label": label, "variant": variant, "module": "core",
                                      "threads": 1, "block": f"b{block}",
                                      "sanity_generation": False, "wall_seconds": 0.5})
        runner.save(root, study)
        return study

    def test_catalog_ignores_diagnostics(self):
        text = "RUNTIME_THREADS=12\nBinaryOpTest.\n  add/0  # GetParam() = (640x480, 8UC1)\n"
        self.assertEqual(runner.catalog(text), [
            {"name": "BinaryOpTest.add/0", "params": "(640x480, 8UC1)"}])

    def test_selection_rejects_missing_case(self):
        with self.assertRaisesRegex(ValueError, "Expected one"):
            runner.choose({module: [] for module in runner.MODULES})

    def test_main_pinning_requires_process_affinity(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, runner.__file__, directory, "prepare", "--pin-main",
                 "--deadline", "2099-01-01T00:00:00+00:00"],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn("--pin-main requires --affinity", result.stderr)

    def test_cpu_outside_selected_processor_group_rejected(self):
        result = subprocess.run(
            [sys.executable, runner.__file__, ".", "prepare", "--single-cpu", "64"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)

    def test_affinity_supports_twelve_and_twenty_cpu_protocols(self):
        for count, cpu in ((12, 6), (20, 10)):
            study = {"threads": [1, count], "single_cpu": cpu}
            self.assertEqual(runner.requested_affinity(study, 1), 1 << cpu)
            self.assertEqual(runner.requested_affinity(study, count), (1 << count) - 1)

    def test_single_cpu_must_be_inside_parallel_mask(self):
        result = subprocess.run(
            [sys.executable, runner.__file__, ".", "prepare", "--single-cpu", "20",
             "--parallel-threads", "20", "--deadline", "2099-01-01T00:00:00+00:00"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--single-cpu must be below", result.stderr)

    def test_exact_case_identity_checked_not_only_count(self):
        cases = [ET.fromstring('<testcase classname="Wrong" name="case" status="run"/>')]
        with self.assertRaisesRegex(RuntimeError, "differ from the selected suite"):
            runner.validate_cases(cases, [{"name": "Expected.case"}], 0)

    def test_nonzero_exit_without_xml_failure_rejected(self):
        cases = [ET.fromstring('<testcase classname="Expected" name="case" status="run"/>')]
        with self.assertRaisesRegex(RuntimeError, "Unexpected process exit"):
            runner.validate_cases(cases, [{"name": "Expected.case"}], 1)
        self.assertEqual(runner.validate_cases(cases, [{"name": "Expected.case"}], 0), (0, 0))

    def test_case_failure_and_skip_counted(self):
        cases = [ET.fromstring('<testcase classname="Expected" name="case" status="run"><failure/></testcase>'),
                 ET.fromstring('<testcase classname="Expected" name="skip" status="notrun"/>')]
        self.assertEqual(runner.validate_cases(
            cases, [{"name": "Expected.case"}, {"name": "Expected.skip"}], 1), (1, 1))

    def test_expired_absolute_deadline_prevents_launch(self):
        study = {"deadline": "2000-01-01T00:00:00+00:00",
                 "variant_budget_seconds": 1800, "runs": []}
        with self.assertRaisesRegex(TimeoutError, "budget exhausted"):
            runner.run_one(Path("."), study, "baseline", "core", 1, "b1")

    def test_exhausted_variant_budget_prevents_launch(self):
        study = {"deadline": "2099-01-01T00:00:00+00:00",
                 "variant_budget_seconds": 1800,
                 "runs": [{"variant": "baseline", "wall_seconds": 1800}]}
        with self.assertRaisesRegex(TimeoutError, "budget exhausted"):
            runner.run_one(Path("."), study, "baseline", "core", 1, "b1")

    def test_frozen_binary_change_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "test.dll"
            path.write_bytes(b"original")
            study = {"frozen_sha256": {"test.dll": runner.digest(path)}}
            runner.check_frozen(root, study)
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "Frozen binary changed"):
                runner.check_frozen(root, study)

    def test_incomplete_analysis_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "screen-study.json").write_text('{"status":"running"}')
            with self.assertRaisesRegex(ValueError, "Incomplete study"):
                analysis.analyze(root)

    def test_analysis_converts_ticks_and_compares_balanced_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_study(root)
            summary = analysis.analyze(root)
            self.assertEqual(summary["measured_case_runs"], 18)
            self.assertTrue(summary["baseline_shared_text_identical"])
            comparison = summary["comparisons"][0]
            self.assertEqual(comparison["timings"]["baseline"]["median_ms"], 10)
            self.assertAlmostEqual(comparison["llvm"]["change_percent"], -20)
            self.assertEqual(comparison["llvm"]["faster_blocks"], 6)
            self.assertTrue(comparison["llvm"]["follow_up"])
            self.assertFalse(comparison["shared"]["follow_up"])

    def test_analysis_rejects_duplicate_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            study = self.make_study(root)
            study["runs"][0]["block"] = "b2"
            runner.save(root, study)
            with self.assertRaisesRegex(ValueError, "six distinct blocks"):
                analysis.analyze(root)

    def test_analysis_rejects_missing_thread_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            study = self.make_study(root)
            study["threads"] = [1, 12]
            runner.save(root, study)
            with self.assertRaisesRegex(ValueError, "do not match the selected suite"):
                analysis.analyze(root)

    def test_failed_case_excluded_from_comparison(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            study = self.make_study(root)
            xml = root / "runs" / study["runs"][0]["label"] / "results.xml"
            xml.write_text(xml.read_text().replace("</testcase>", '<failure message="sanity"/></testcase>'))
            summary = analysis.analyze(root)
            self.assertEqual(summary["failed_case_runs"], 1)
            self.assertFalse(summary["comparisons"][0]["valid"])
            self.assertEqual(summary["module_summaries"], [])


if __name__ == "__main__":
    unittest.main()
