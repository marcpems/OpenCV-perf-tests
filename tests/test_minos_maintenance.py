"""Checks for the bounded runner-maintenance plan."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "maintenance", Path(__file__).resolve().parents[1] / "scripts" / "maintain_minos_runner.py"
)
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


@unittest.skipUnless(os.name == "nt", "Dedicated Windows runner paths")
class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def test_inventory_counts_nested_files(self):
        child = self.root / "nested"
        child.mkdir()
        (child / "data").write_bytes(b"12345")
        totals, links = maintenance.tree_usage(child)
        self.assertEqual(totals[child], 5)
        self.assertEqual(links, [])

    def test_unapproved_or_broad_targets_rejected(self):
        for target in (".", ".work", ".tools", "..", "results"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                maintenance.checked_target(self.root, target)

    def test_repository_root_rejected(self):
        target = maintenance.TARGETS[0]
        path = self.root / target
        path.mkdir(parents=True)
        (path / ".git").mkdir()
        with self.assertRaises(ValueError):
            maintenance.checked_target(self.root, target)

    def test_reparse_point_rejected(self):
        target = maintenance.TARGETS[0]
        (self.root / target).mkdir(parents=True)
        with patch.object(maintenance, "is_link", return_value=True):
            with self.assertRaises(ValueError):
                maintenance.checked_target(self.root, target)

    def test_plan_changes_when_target_changes(self):
        target = self.root / maintenance.TARGETS[0]
        target.mkdir(parents=True)
        initial = maintenance.cleanup_plan(self.root)
        (target / "object.obj").write_bytes(b"build")
        changed = maintenance.cleanup_plan(self.root)
        self.assertNotEqual(initial["sha256"], changed["sha256"])
        self.assertEqual(changed["targets"][0]["bytes"], 5)

    def test_tracked_files_rejected(self):
        target = self.root / maintenance.TARGETS[0]
        target.mkdir(parents=True)
        source = target / "important.txt"
        source.write_text("retained")
        subprocess.run(["git", "-C", str(self.root), "add", str(source)], check=True)
        with self.assertRaises(RuntimeError):
            maintenance.cleanup_plan(self.root)

    def test_content_fingerprint_detects_changes(self):
        source = self.root / "result.json"
        source.write_text("original")
        before = maintenance.fingerprint(source, content=True)
        source.write_text("modified")
        self.assertNotEqual(before, maintenance.fingerprint(source, content=True))

    def test_apply_removes_only_planned_artifacts(self):
        directory = self.root / maintenance.TARGETS[0]
        directory.mkdir(parents=True)
        (directory / "object.obj").write_bytes(b"build")
        archive = self.root / maintenance.TARGETS[-1]
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"archive")
        retained = directory.parent / "retained.cpp"
        retained.write_text("source")
        result = {"plan": maintenance.cleanup_plan(self.root), "deleted": []}
        with patch.object(maintenance, "protected_fingerprints", return_value={"evidence": "same"}):
            maintenance.apply_plan(
                self.root, result, result["plan"]["sha256"], self.root / "audit.json"
            )
        self.assertFalse(directory.exists())
        self.assertFalse(archive.exists())
        self.assertEqual(retained.read_text(), "source")
        self.assertEqual(len(result["deleted"]), 2)
        self.assertTrue((self.root / ".git").is_dir())

    def test_apply_without_matching_approval_does_not_delete(self):
        target = self.root / maintenance.TARGETS[0]
        target.mkdir(parents=True)
        result = {"plan": maintenance.cleanup_plan(self.root), "deleted": []}
        with self.assertRaises(RuntimeError):
            maintenance.apply_plan(self.root, result, "wrong", self.root / "audit.json")
        self.assertTrue(target.exists())

    def test_apply_changed_target_does_not_delete(self):
        target = self.root / maintenance.TARGETS[0]
        target.mkdir(parents=True)
        result = {"plan": maintenance.cleanup_plan(self.root), "deleted": []}
        (target / "new.obj").write_bytes(b"new")
        with patch.object(maintenance, "protected_fingerprints", return_value={}):
            with self.assertRaises(RuntimeError):
                maintenance.apply_plan(
                    self.root, result, result["plan"]["sha256"], self.root / "audit.json"
                )
        self.assertTrue(target.exists())


if __name__ == "__main__":
    unittest.main()
