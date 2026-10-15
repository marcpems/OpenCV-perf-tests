import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from compare_sdk import BASELINE, LATEST, ORDER, compare, inventory


class SDKComparisonTests(unittest.TestCase):
    def test_inventory_normalizes_build_paths_but_detects_workload_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            builds = [root / "old", root / "new"]
            for build in builds:
                build.mkdir()
                (build / "OpenCV.slnx").write_text(
                    '<Solution><Project Path="test.vcxproj"/></Solution>', encoding="utf-8")
                (build / "test.vcxproj").write_text(
                    '<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">'
                    f'<ItemGroup><ClCompile Include="{build}\\generated.cpp"/></ItemGroup>'
                    '<ItemDefinitionGroup Condition="Release|ARM64">'
                    '<ClCompile><Optimization>MaxSpeed</Optimization></ClCompile>'
                    '</ItemDefinitionGroup></Project>', encoding="utf-8")
            self.assertEqual(inventory(builds[0]), inventory(builds[1]))
            project = builds[1] / "test.vcxproj"
            project.write_text(project.read_text().replace("MaxSpeed", "Disabled"), encoding="utf-8")
            self.assertNotEqual(inventory(builds[0]), inventory(builds[1]))
            project.write_text(project.read_text().replace("generated.cpp", "other.cpp"), encoding="utf-8")
            self.assertNotEqual(inventory(builds[0])["source_multiset_sha256"],
                                inventory(builds[1])["source_multiset_sha256"])

    def make_study(self, root):
        (root / "study.json").write_text(json.dumps({
            "order": ORDER, "generator": "MSBuild", "parallel": 0,
            "finished_at": "2026-01-01T10:00:00+00:00", "runner_sha256": "runner",
        }), encoding="utf-8")
        shared = dict.fromkeys((
            "hobl_commit", "opencv_commit", "config_sha256", "compiler", "compiler_sha256",
            "compiler_id", "compiler_version", "compiler_frontend", "architecture",
            "cmake", "cmake_version", "cmake_sha256", "build_engine", "visual_studio",
        ), "same")
        for index, condition in enumerate(ORDER):
            target = "10.0.26100.0" if condition == BASELINE else "10.0.28000.0"
            setup = dict(shared, windows_sdk={
                "target_version": target, "release_version": target,
                "evaluated_properties": {"WindowsTargetPlatformVersion": target, "UCRTVersion": target},
            })
            path = root / f"run{index}"
            path.mkdir()
            (path / "metadata.json").write_text(json.dumps({
                "status": "succeeded", "toolchain": condition, "generator": "MSBuild",
                "profile": False, "parallel": 0, "validated_version": "4.10.0",
                "build_arguments": ["--build", ".", "--config", "Release"],
                "runner_sha256": "runner", "setup": setup,
                "started_at": f"2026-01-01T{index:02}:00:00+00:00",
                "finished_at": f"2026-01-01T{index:02}:10:00+00:00",
                "build_seconds": 100 if condition == BASELINE else 90,
            }), encoding="utf-8")

    def test_reports_direction_and_balanced_pairs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_study(root)
            report = compare(root)
            self.assertAlmostEqual(report["latest_median_time_change_percent"], -10)
            self.assertEqual(report["latest_faster_pairs"], 4)
            self.assertEqual(report["groups"][LATEST]["count"], 4)

    def test_rejects_incomplete_or_missing_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.make_study(root)
            (root / "run7" / "metadata.json").unlink()
            with self.assertRaisesRegex(ValueError, "exactly eight"):
                compare(root)
            manifest = json.loads((root / "study.json").read_text())
            del manifest["finished_at"]
            (root / "study.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not completed"):
                compare(root)

    def test_rejects_compiler_drift_and_wrong_ucrt(self):
        for field in ("compiler_sha256", "UCRTVersion"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.make_study(root)
                for index, condition in enumerate(ORDER):
                    if condition != LATEST:
                        continue
                    path = root / f"run{index}" / "metadata.json"
                    run = json.loads(path.read_text())
                    target = run["setup"] if field == "compiler_sha256" else run["setup"]["windows_sdk"]["evaluated_properties"]
                    target[field] = "different"
                    path.write_text(json.dumps(run), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "Non-SDK component|SDK/UCRT"):
                    compare(root)

    def test_rejects_profiled_and_overlapping_runs(self):
        for field, value in (("profile", True), ("started_at", "2026-01-01T00:05:00+00:00")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.make_study(root)
                path = root / "run1" / "metadata.json"
                run = json.loads(path.read_text())
                run[field] = value
                path.write_text(json.dumps(run), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "settings|overlapping"):
                    compare(root)


if __name__ == "__main__":
    unittest.main()
