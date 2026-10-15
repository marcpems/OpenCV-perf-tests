from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from analyze_msbuild_tail import analyze, command_manifest, tracking_stacks


class MsbuildTailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.write("trace-stats.txt", "Start time (UTC) : 2026/10/15:14:00:00.0000000\n"
                   "Total # Lost Events : 0\nTotal # Lost Buffers : 0\n")
        self.write("cpu-accounting.json", json.dumps(
            {"ProcessId": 10, "WallSeconds": 5, "CpuSeconds": 2, "TotalProcesses": 3}))
        self.write("processes.csv", "header\n"
                   "0,5000000,Process,0,cmd.exe (10),1,1,abc,cmake --build .\n"
                   "100,4900000,Process,0,MSBuild.exe (11),10,1,def,MSBuild\n"
                   "2000000,3000000,Process,0,cl.exe (12),11,1,ghi,cl source.cpp\n")
        self.events = [
            self.event("ProjectStartedEventArgs", project_file=r"D:\opencv\modules\world\opencv_world.vcxproj"),
            self.event("TaskStartedEventArgs", timestamp="2026-10-15T15:00:01+01:00", name="CL"),
            self.event("TaskParameterEventArgs",
                       message="Task Parameter:\n    Sources=\n        D:\\opencv\\modules\\core\\alloc.cpp\n"),
            self.event("TaskFinishedEventArgs", timestamp="2026-10-15T15:00:04+01:00", succeeded=True),
        ]

    def event(self, kind, **kwargs):
        return dict(type=kind, node=1, project=2, target=3, task=4, **kwargs)

    def write(self, name, text):
        (self.root / name).write_text(text, encoding="utf-8")

    def run_analysis(self):
        self.write("msbuild-events.jsonl", "\n".join(json.dumps(e) for e in self.events))
        return analyze(self.root)

    def test_task_boundary_breakdown_and_timezone(self):
        result = self.run_analysis()
        tail = result["serial_tasks"]
        self.assertEqual(tail["span_seconds"], 3)
        self.assertEqual(tail["before_compiler_seconds"], 1)
        self.assertEqual(tail["compiler_wall_seconds"], 1)
        self.assertEqual(tail["after_compiler_seconds"], 1)
        self.assertEqual(result["world_tasks"][0]["sources"], ["core/alloc.cpp"])
        self.assertNotIn("D:\\opencv", json.dumps(result))

    def test_missing_source_metadata_is_not_silently_accepted(self):
        del self.events[2]
        with self.assertRaisesRegex(ValueError, "source metadata"):
            self.run_analysis()

    def test_failed_task_is_rejected(self):
        self.events[-1]["succeeded"] = False
        with self.assertRaisesRegex(ValueError, "Failed"):
            self.run_analysis()

    def test_wrong_clock_or_trace_is_rejected(self):
        self.events[1]["timestamp"] = "2026-10-15T15:00:06+01:00"
        with self.assertRaisesRegex(ValueError, "outside WPR"):
            self.run_analysis()

    def test_command_identity_includes_project_not_just_source(self):
        for name in ("project_a", "project_b"):
            path = self.root / name
            path.mkdir()
            (path / "CL.command.1.tlog").write_text("^D:\\source.cpp\n/c /D" + name, encoding="utf-16")
        self.assertEqual(len(command_manifest(self.root)), 2)
        probes = self.root / "CMakeFiles"
        probes.mkdir()
        (probes / "CL.command.1.tlog").write_text("^probe.c\n/c probe.c", encoding="utf-16")
        self.assertEqual(len(command_manifest(self.root)), 2)

    def test_cross_boundary_pid_reuse_requires_lifetime_export(self):
        with (self.root / "processes.csv").open("a") as stream:
            stream.write("3500000,4500000,Process,0,cl.exe (12),1,1,new,external compiler\n")
        self.write("cpu-precise.csv", "header\n2000000,cl.exe (12)\n")
        with self.assertRaisesRegex(ValueError, "requires a precise CPU export"):
            self.run_analysis()
        self.write("cpu-instance-12-2000000.csv", "header\n1000000,cl.exe (12)\n")
        self.assertEqual(self.run_analysis()["build_cpu_seconds_by_executable"], {"cl.exe": 1})

    def test_malformed_command_manifest_is_rejected(self):
        (self.root / "CL.command.1.tlog").write_text("^source.cpp\n", encoding="utf-16")
        with self.assertRaisesRegex(ValueError, "Malformed"):
            command_manifest(self.root)

    def test_only_selected_tracking_functions_are_exported(self):
        row = "<tr><td>{}</td><td>59</td><td>59.00%</td><td>2</td></tr>"
        tables = ["<table></table>"] * 6
        tables[3] = "<table><tr><th>function name</th></tr>" + row.format(
            "Module!CanonicalTrackedInputFiles.ConstructDependencyTable()") + row.format(
            "Other!UnrelatedPrivateFunction()") + "</table>"
        self.write("stacks.html", "".join(tables))
        result = tracking_stacks(self.root / "stacks.html")
        self.assertEqual(len(result), 1)
        self.assertEqual(next(iter(result.values()))["inclusive_samples"], 59)


if __name__ == "__main__":
    unittest.main()
