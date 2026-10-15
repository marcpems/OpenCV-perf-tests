from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from analyze_cpu_study import backend_functions, project_metadata, trace_identity


class CpuStudyTests(unittest.TestCase):
    def test_project_metadata_uses_release_and_removes_source_root(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "world.vcxproj"
            path.write_text("""<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
<ItemGroup>
<ClCompile Include="D:\\opencv\\modules\\core\\ordinary.cpp" />
<ClCompile Include="D:\\opencv\\modules\\core\\parallel.cpp">
<ObjectFileName>$(IntDir)/core/parallel.cpp.obj</ObjectFileName>
<PreprocessorDefinitions Condition="'$(Configuration)'=='Debug|ARM64'">DEBUG</PreprocessorDefinitions>
<PreprocessorDefinitions Condition="'$(Configuration)'=='Release|ARM64'">RELEASE</PreprocessorDefinitions>
</ClCompile>
</ItemGroup></Project>""", encoding="utf-8")
            result = project_metadata(path)
            self.assertEqual(result["compile_items"], 2)
            self.assertEqual(len(result["per_file_release_metadata"]), 1)
            item = result["per_file_release_metadata"][0]
            self.assertEqual(item["source"], "core/parallel.cpp")
            self.assertEqual(item["properties"]["PreprocessorDefinitions"], "RELEASE")

    def test_backend_functions_exclude_other_processes_and_modules(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "symbols.csv"
            path.write_text("header\ncl.exe (1),2000000,0,c2.dll!Map<A, B>\n"
                            "cl.exe (1),500000,0,c1xx.dll!unknown\n"
                            "external.exe (2),1000000,0,c2.dll!Private\n"
                            "Total Weight: 3500000\n", encoding="utf-8")
            result = backend_functions(path, lambda label: ("cl.exe", label == "cl.exe (1)"))
            self.assertEqual(result, {"c2.dll!Map<A, B>": 2})

    def test_trace_hash_uses_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.etl"
            path.write_bytes(b"abc")
            self.assertEqual(trace_identity(path), {
                "bytes": 3,
                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            })


if __name__ == "__main__":
    unittest.main()
