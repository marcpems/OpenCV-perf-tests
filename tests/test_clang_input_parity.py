import sys
import json
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from compare_clang_inputs import compare, normalized_commands


class ClangInputParityTests(unittest.TestCase):
    def test_roots_and_quotes_normalize(self):
        def record(root, tools):
            return [{"file": root + "/a.cpp", "output": "a.obj",
                     "command": f'"{tools}/bin/clang++.exe" -O3 -c {root}/a.cpp'}]
        self.assertEqual(normalized_commands(record("D:/a", "D:/llvm"), "D:/a", "D:/llvm"),
                         normalized_commands(record("D:/b", "D:/Program Files/llvm"), "D:/b", "D:/Program Files/llvm"))

    def test_different_flags_remain_different(self):
        a = [{"file": "a.cpp", "output": "a.obj", "command": "clang -O3 a.cpp"}]
        b = [{**a[0], "command": "clang -O2 a.cpp"}]
        self.assertNotEqual(normalized_commands(a, "D:/a", "D:/llvm"),
                            normalized_commands(b, "D:/a", "D:/llvm"))

    def test_no_compile_commands_rejected(self):
        with self.assertRaises(ValueError):
            normalized_commands([], "D:/a", "D:/llvm")

    def test_headers_and_commands_must_match(self):
        with tempfile.TemporaryDirectory() as temp:
            roots = [Path(temp) / name for name in ("stock", "custom")]
            for root in roots:
                build = root / "build_hobl_clang_ninja"
                (build / "opencv2").mkdir(parents=True)
                (build / "cvconfig.h").write_text("same")
                (build / "opencv2/opencv_modules.hpp").write_text("same")
                (build / "benchmark-setup.json").write_text(json.dumps({"llvm": {"root": "D:/llvm"}}))
                commands = [{"file": str(root / "a.cpp"), "output": "a.obj",
                             "command": f'clang -O3 -c "{root / "a.cpp"}"'}]
                (build / "comparison-commands.json").write_text(json.dumps(commands))
            self.assertEqual(compare(*roots)["source_compilations"], 1)
            (roots[1] / "build_hobl_clang_ninja/cvconfig.h").write_text("different")
            with self.assertRaisesRegex(ValueError, "Generated features differ"):
                compare(*roots)


if __name__ == "__main__":
    unittest.main()
