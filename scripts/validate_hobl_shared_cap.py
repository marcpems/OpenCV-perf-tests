"""Exercise HOBL host deployment without RPC, prep installers or DUT access."""

import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock, patch


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        core = types.ModuleType("core")
        app = types.ModuleType("core.app_scenario")
        self.base_setup = Mock()
        app.Scenario = type("Scenario", (), {"setUp": self.base_setup})
        core.app_scenario = app
        params = types.ModuleType("core.parameters")
        params.Params = type("Params", (), {
            "setDefault": staticmethod(lambda *args: None),
            "get": staticmethod(lambda group, key: {"platform": "Windows", "loops": "2"}[key]),
        })
        spec = importlib.util.spec_from_file_location(
            "opencv_build", ROOT / "scenarios/windows/opencv_build/opencv_build.py")
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {
            "core": core, "core.app_scenario": app, "core.parameters": params,
        }):
            spec.loader.exec_module(self.module)
        self.scenario = self.module.OpencvBuild()
        self.scenario.dut_exec_path = r"Q:\hobl_bin"
        self.scenario.result_dir = "results"
        for name in ("_upload", "_call", "_copy_data_from_remote", "createPrepStatusControlFile"):
            setattr(self.scenario, name, Mock())
        self.scenario.checkPrepStatus = Mock(return_value=False)

    def setup(self):
        with patch.object(self.module, "core", types.SimpleNamespace(
            app_scenario=types.SimpleNamespace(Scenario=types.SimpleNamespace(setUp=self.base_setup))
        )):
            self.scenario.setUp()

    def test_cached_prep_refreshes_only_run_script(self):
        self.setup()
        self.scenario._upload.assert_called_once_with(
            r"scenarios\windows\opencv_build\opencv_build_resources\opencv_build_run.ps1",
            r"Q:\hobl_bin\opencv_build_resources", check_modified=False)
        self.scenario._call.assert_not_called()
        self.scenario.createPrepStatusControlFile.assert_not_called()
        self.base_setup.assert_called_once()

    def test_fresh_prep_keeps_existing_lifecycle(self):
        self.scenario.checkPrepStatus.return_value = True
        self.setup()
        self.scenario._upload.assert_called_once_with(
            r"scenarios\windows\opencv_build\opencv_build_resources", r"Q:\hobl_bin")
        self.scenario._call.assert_called_once_with(
            ["pwsh", r"Q:\hobl_bin\opencv_build_resources\opencv_build_prep.ps1"])
        self.scenario.createPrepStatusControlFile.assert_called_once_with("7")
        self.scenario._copy_data_from_remote.assert_called_once_with("results")

    def test_upload_failure_prevents_measurement(self):
        self.scenario._upload.side_effect = RuntimeError("upload failed")
        with self.assertRaisesRegex(RuntimeError, "upload failed"):
            self.setup()
        self.base_setup.assert_not_called()
        self.scenario._call.assert_not_called()

    def test_prep_failure_collects_logs_without_success_marker(self):
        self.scenario.checkPrepStatus.return_value = True
        self.scenario._call.side_effect = RuntimeError("prep failed")
        with self.assertRaisesRegex(RuntimeError, "prep failed"):
            self.setup()
        self.scenario._copy_data_from_remote.assert_called_once_with("results")
        self.scenario.createPrepStatusControlFile.assert_not_called()
        self.base_setup.assert_not_called()

    def test_repeat_iterations_refresh_cached_script(self):
        self.setup()
        self.setup()
        self.assertEqual(self.scenario._upload.call_count, 2)
        self.scenario._call.assert_not_called()

    def test_loop_count_and_timeout_unchanged(self):
        self.setup()
        self.scenario.runTest()
        self.assertEqual(self.scenario._call.call_count, 2)
        for call in self.scenario._call.call_args_list:
            self.assertEqual(call.kwargs, {"timeout": 3600})
            self.assertIn("opencv_build_run.ps1 -startTime ", call.args[0][1])


if __name__ == "__main__":
    ROOT = Path(sys.argv.pop(1)).resolve()
    unittest.main()
