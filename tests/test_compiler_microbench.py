import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from analyze_compiler_microbench import analyze, phases


class CompilerMicrobenchTests(unittest.TestCase):
    def test_warmup_is_excluded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            labels = ["msvc_0", "msvc_1", "msvc_2"]
            (root / "study.json").write_text(json.dumps({
                "status": "succeeded", "finished_at": "done", "sources": ["x.cpp"],
                "variants": ["msvc"], "repetitions": 2, "runs": labels,
            }))
            for i, label in enumerate(labels):
                directory = root / label
                directory.mkdir()
                (directory / "metadata.json").write_text(json.dumps({
                    "label": label, "source": "x.cpp", "variant": "msvc", "warmup": i == 0,
                    "accounting": {"ExitCode": 0, "WallSeconds": [100, 2, 4][i],
                                   "CpuSeconds": [100, 6, 8][i], "UserSeconds": 5, "KernelSeconds": 1},
                }))
            result = analyze(root)
            self.assertEqual(result["summary"][0]["median_wall_seconds"], 3)
            self.assertEqual(result["summary"][0]["median_cpu_seconds"], 7)
            self.assertEqual(len(result["measurements"]), 3)

    def test_incomplete_study_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "study.json").write_text('{"status": "running"}')
            with self.assertRaises(ValueError):
                analyze(root)

    def test_missing_instrumentation_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "compile.log").write_text("nothing")
            with self.assertRaises(ValueError):
                phases(root, {"variant": "msvc", "phase_timing": True})


if __name__ == "__main__":
    unittest.main()
