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
            metadata.update(measure_cpu=True, wpr_trace=False, cpu_accounting={"CpuSeconds": 20})
            (run / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            (run / "cpu-accounting.json").write_text('{"CpuSeconds":20}', encoding="utf-8")
            cpu_summary = export(source, root / "cpu")
            self.assertEqual(cpu_summary["baseline"]["median_cpu_seconds"], 20)
            self.assertTrue((root / "cpu" / "sample" / "cpu-accounting.json").is_file())
            (run / "build.etl").write_bytes(b"private raw trace")
            (run / "build.binlog").write_bytes(b"private raw build events")
            self.assertFalse((root / "cpu" / "sample" / "build.etl").exists())
            self.assertFalse((root / "cpu" / "sample" / "build.binlog").exists())
            second = source / "traced"
            second.mkdir()
            metadata["wpr_trace"] = True
            (second / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            (second / "opencv_build_results.csv").write_text(metrics.read_text(), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Do not pool"):
                export(source, root / "mixed")
            metadata["wpr_trace"] = False
            metadata["binary_log"] = True
            (second / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Do not pool"):
                export(source, root / "mixed-binlog")
            (second / "metadata.json").unlink()
            (second / "opencv_build_results.csv").unlink()
            second.rmdir()
            metrics.write_text("scenario_runtime,11.00\nbuild_time,10.00\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Invalid HOBL"):
                export(source, root / "invalid")


if __name__ == "__main__":
    unittest.main()
