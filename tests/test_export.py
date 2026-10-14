import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from export_results import FILES, export, redact


class ExportTests(unittest.TestCase):
    def test_redacts_raw_and_json_escaped_user_paths(self):
        path = r"C:\Users\example\AppData\Local\tool.exe"
        self.assertEqual(redact(path), r"<USERPROFILE>\AppData\Local\tool.exe")
        result = json.loads(redact(json.dumps({"path": path})))
        self.assertEqual(result["path"], r"<USERPROFILE>\AppData\Local\tool.exe")
        self.assertNotIn("example", redact("C:/Users/example/AppData/tool"))

    def test_failed_and_incomplete_runs_are_not_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "local"
            source.mkdir()
            for name, status in (("failed", "failed"), ("partial", "running")):
                run = source / name
                run.mkdir()
                (run / "metadata.json").write_text(json.dumps({"status": status}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "No successful"):
                export(source, Path(directory) / "public")
            self.assertFalse((Path(directory) / "public").exists())

    def test_rejects_overwriting_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "already exists"):
                export(Path(directory), Path(directory))

    def test_rejects_incomplete_study(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "local"
            source.mkdir()
            (source / "study.json").write_text('{"order": ["fixed"]}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "incomplete study"):
                export(source, root / "public")

    def test_successful_run_is_validated_and_aggregated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "local"
            run = source / "sample"
            run.mkdir(parents=True)
            for name in FILES:
                if name != "ninja_log.txt":
                    (run / name).write_text("artifact", encoding="utf-8")
            metadata = {
                "status": "succeeded", "validated_version": "4.10.0",
                "label": "baseline_1", "generator": "MSBuild",
                "build_seconds": 10.001, "clean_seconds": 1, "install_seconds": 2,
            }
            (run / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            metrics = run / "opencv_build_results.csv"
            metrics.write_text("scenario_runtime,10.00\nbuild_time,10.00\n", encoding="utf-8")
            summary = export(source, root / "public")
            self.assertEqual(summary["baseline"]["median_seconds"], 10.001)
            self.assertTrue((root / "public" / "sample" / "original_sha256.json").is_file())
            metrics.write_text("scenario_runtime,11.00\nbuild_time,10.00\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Invalid HOBL"):
                export(source, root / "invalid")


if __name__ == "__main__":
    unittest.main()
