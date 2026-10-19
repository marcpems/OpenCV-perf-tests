import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import collect_hobl_validation as collector


class HoblEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run = self.root / "run"
        self.run.mkdir()
        self.calls = [
            {"exit_code": 0}, {"exit_code": 0},
            {"exit_code": 0, "before_install": {"hash": "same"}, "after_install": {"hash": "same"}},
        ]
        self.write("cmake-calls.json", self.calls)
        (self.run / "opencv_build_results.csv").write_text(
            "scenario_runtime,120.25\nbuild_time,120.25\narchitecture,ARM64\n")

    def write(self, name, value):
        (self.run / name).write_text(json.dumps(value))

    def snapshot(self, machine="0xaa64"):
        with patch.object(collector, "command_manifest", return_value={"source": "flags"}), \
             patch.object(collector, "image_sections", return_value={"machine": machine}):
            collector.snapshot(self.root / "build", self.run)

    def test_snapshot_preserves_hobl_time_and_install_guard(self):
        self.snapshot()
        result = collector.read_json(self.run / "validation.json")
        self.assertEqual(result["build_seconds"], 120.25)
        self.assertTrue(result["install_preserved_outputs"])

    def test_changed_install_outputs_rejected(self):
        self.calls[2]["after_install"] = {"hash": "changed"}
        self.write("cmake-calls.json", self.calls)
        with self.assertRaisesRegex(ValueError, "Untimed install"):
            self.snapshot()

    def test_failed_command_rejected(self):
        self.calls[1]["exit_code"] = 1
        self.write("cmake-calls.json", self.calls)
        with self.assertRaisesRegex(ValueError, "successful CMake"):
            self.snapshot()

    def test_wrong_image_architecture_rejected(self):
        with self.assertRaisesRegex(ValueError, "native ARM64"):
            self.snapshot("0x8664")

    def test_mismatched_csv_timing_rejected(self):
        (self.run / "opencv_build_results.csv").write_text(
            "scenario_runtime,130\nbuild_time,120\narchitecture,ARM64\n")
        with self.assertRaisesRegex(ValueError, "timing"):
            self.snapshot()

    def test_incomplete_study_not_exported(self):
        (self.root / "study.json").write_text('{"status":"failed"}')
        with self.assertRaisesRegex(ValueError, "incomplete or failed"):
            collector.export(self.root, self.root / "export")
        self.assertFalse((self.root / "export").exists())


if __name__ == "__main__":
    unittest.main()
