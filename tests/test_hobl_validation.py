import json
import os
from pathlib import Path
import shutil
import subprocess
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


@unittest.skipUnless(os.name == "nt" and shutil.which("pwsh"), "Native Windows PowerShell")
class HoblForwardingTests(unittest.TestCase):
    def test_native_separator_and_exit_code_forwarding(self):
        wrapper = Path(__file__).resolve().parents[1] / "scripts" / "invoke_hobl_validation.ps1"
        with tempfile.TemporaryDirectory(prefix="hobl forwarding ") as temporary:
            root = Path(temporary)
            build = root / "build"
            (build / "bin" / "Release").mkdir(parents=True)
            (build / "bin" / "Release" / "opencv_world4100.dll").write_bytes(b"test fixture")
            cmake = root / "cmake.cmd"
            cmake.write_text("@echo off\necho %*\nexit /b 0\n")
            for shared in (False, True):
                with self.subTest(shared=shared):
                    output = root / str(shared)
                    output.mkdir()
                    script = root / "run.ps1"
                    properties = (
                        " -- /p:MultiProcCL=true /p:MultiProcMaxCount=20 "
                        "/p:EnforceProcessCountAcrossBuilds=true /nr:false"
                    ) if shared else ""
                    script.write_text(
                        'param([string]$logFile)\n'
                        f'cmake --build . --target clean --config Release{properties}\n'
                        'if ($LASTEXITCODE) { exit 1 }\n'
                        f'cmake --build . --config Release{properties}\n'
                        'if ($LASTEXITCODE) { exit 1 }\n'
                        f'cmake --build . --target INSTALL --config Release{properties}\n'
                        'if ($LASTEXITCODE) { exit 1 }\nexit 0\n'
                    )
                    result = subprocess.run(
                        ["pwsh", "-NoProfile", "-File", str(wrapper), "-Script", str(script),
                         "-CMake", str(cmake), "-Build", str(build), "-Output", str(output)],
                        text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    calls = collector.read_json(output / "cmake-calls.json")
                    self.assertEqual(len(calls), 3)
                    for call in calls:
                        self.assertEqual(call["arguments"].count("--"), int(shared))
                        if shared:
                            self.assertEqual(
                                call["arguments"][call["arguments"].index("--") + 1],
                                "/p:MultiProcCL=true",
                            )
                    if shared:
                        self.assertIn("-- /p:MultiProcCL=true", result.stdout)
            failed = root / "failed"
            failed.mkdir()
            cmake.write_text("@echo off\nexit /b 17\n")
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-File", str(wrapper), "-Script", str(script),
                 "-CMake", str(cmake), "-Build", str(build), "-Output", str(failed)],
                text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(collector.read_json(failed / "cmake-calls.json")[0]["exit_code"], 17)


if __name__ == "__main__":
    unittest.main()
