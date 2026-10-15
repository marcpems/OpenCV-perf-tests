from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from analyze_build_etl import build_context, load_processes, sampled_rows, summarize


class EtlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write("trace-stats.txt", "Total # Lost Buffers : 0\nTotal # Lost Events : 0\n")
        self.write("cpu-accounting.json", json.dumps({"ProcessId": 10, "CpuSeconds": 1.5}))
        self.write("processes.csv", "header\n"
                   "100,2000100,Process,0,cmd.exe (10),1,1,abc,cmake --build . > build.log\n"
                   "200,1900100,Process,0,cl.exe (20),10,1,def,cl /c file.cpp\n"
                   "300,2000100,Process,0,unrelated.exe (30),1,1,ghi,other\n")
        self.write("cpu-precise.csv", "header\n100000,cmd.exe (10)\n1400000,cl.exe (20)\n"
                   "500000,unrelated.exe (30)\n")
        self.write("cpu-sampled.csv", "header\ncl.exe (20),1000000,0,c2.dll\n"
                   "cl.exe (20),400000,0,c1xx.dll\nunrelated.exe (30),500000,0,other.dll\n")

    def write(self, name, text):
        (self.root / name).write_text(text, encoding="utf-8")

    def append_process(self, text):
        with (self.root / "processes.csv").open("a", encoding="utf-8") as stream:
            stream.write(text + "\n")

    def test_cpu_units_range_and_nonbuild_exclusion(self):
        result = summarize(self.root)
        self.assertEqual(result["wall_seconds_from_etl"], 2)
        self.assertEqual(result["etl_cpu_seconds"], 1.5)
        self.assertEqual(result["etl_average_cores"], 0.75)
        self.assertEqual(result["build_process_instances"], 2)
        self.assertNotIn("unrelated.exe", json.dumps(result))
        self.assertEqual(result["sampled_cpu_seconds_by_executable_module"]["cl.exe"]["c2.dll"], 1)

    def test_reused_kernel_address_is_not_ancestry(self):
        self.append_process("300,1900000,Process,0,external.exe (40),1,1,def,outside")
        result = summarize(self.root)
        self.assertEqual(result["build_process_instances"], 2)

    def test_multiline_command_is_preserved(self):
        self.append_process("Write-Output 'command, with, commas'")
        processes = load_processes(self.root / "processes.csv")
        self.assertEqual(len(processes), 3)
        self.assertIn("\nWrite-Output", processes[-1]["command"])

    def test_quoted_build_argument_is_recognized(self):
        self.write("processes.csv", (self.root / "processes.csv").read_text().replace(
            "cmake --build .", 'cmake "--build" "."'))
        self.assertEqual(summarize(self.root)["build_process_instances"], 2)

    def test_reused_parent_pid_uses_lifetime(self):
        self.append_process("5,90,Process,0,cmd.exe (10),1,1,abc,old parent")
        self.append_process("20,80,Process,0,old.exe (50),10,1,def,old child")
        result = summarize(self.root)
        self.assertEqual(result["build_process_instances"], 2)

    def test_reused_label_across_boundary_is_rejected(self):
        self.write("processes.csv", (self.root / "processes.csv").read_text().replace(
            "200,1900100", "200,900000"))
        self.append_process("1000000,1800000,Process,0,cl.exe (20),1,1,def,outside")
        with self.assertRaisesRegex(ValueError, "PID reuse"):
            summarize(self.root)

    def test_reused_label_within_build_remains_counted(self):
        self.write("processes.csv", (self.root / "processes.csv").read_text().replace(
            "200,1900100", "200,900000"))
        self.append_process("1000000,1800000,Process,0,cl.exe (20),10,1,def,second compiler")
        self.assertEqual(summarize(self.root)["build_process_instances"], 3)

    def test_lost_or_missing_quality_information_is_rejected(self):
        for text in ("Total # Lost Buffers : 0\nTotal # Lost Events : 1\n", ""):
            self.write("trace-stats.txt", text)
            with self.assertRaisesRegex(ValueError, "lost events"):
                summarize(self.root)

    def test_symbols_with_commas_are_not_truncated(self):
        self.write("symbols.csv", "header\ncl.exe (20),1234567,0,c2.dll!Map<A, B>::Find\n"
                   "Total Weight: 1234567\n")
        self.assertEqual(list(sampled_rows(self.root / "symbols.csv")),
                         [("cl.exe (20)", 1.234567, "c2.dll!Map<A, B>::Find")])

    def test_root_requires_finite_lifetime(self):
        processes = load_processes(self.root / "processes.csv")
        processes[0]["end"] = float("inf")
        with self.assertRaisesRegex(ValueError, "finite"):
            build_context(processes, processes[0])

    def test_surviving_compiler_lifetime_is_clipped(self):
        self.write("processes.csv", (self.root / "processes.csv").read_text().replace(
            "200,1900100", "200,MAX"))
        result = summarize(self.root)
        self.assertEqual(result["post_compiler_tail_seconds"], 0)
        self.assertLessEqual(result["compiler_lifetime_span_seconds"], 2)


if __name__ == "__main__":
    unittest.main()
