"""Repeat the two failed Minos descriptor cases without replacing the original screen."""
import argparse
import copy
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

from export_results import redact
from run_runtime_screen import check_frozen, digest, run_one, save


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_run_id")
    args = parser.parse_args()
    if not args.source_run_id.isdecimal() or os.environ.get("RUNNER_NAME", "").upper() != "MARCPE-D4":
        parser.error("Expected a numeric source run ID on MARCPE-D4")
    repo = Path(__file__).resolve().parent.parent
    source = repo / ".work" / f"minos-runtime-{args.source_run_id}"
    name = f"minos-runtime-diagnostic-{os.environ['GITHUB_RUN_ID']}"
    root, public = repo / ".work" / name, repo / "results" / name
    if root.exists() or public.exists():
        raise FileExistsError("Diagnostic destination already exists")
    original = json.loads((source / "screen-study.json").read_text())
    check_frozen(source, original)
    study = copy.deepcopy(original)
    names = {
        "Source_CrossCheck_batchDistance_L2.batchDistance_L2/3",
        "Norm_CrossCheck_batchDistance_Dest_32S.batchDistance_Dest_32S/1",
    }
    study["selected"] = {"features2d": [c for c in original["selected"]["features2d"] if c["name"] in names]}
    if len(study["selected"]["features2d"]) != 2 or study["threads"] != [1, 20]:
        raise ValueError("Unexpected original case catalog or thread configuration")
    root.mkdir(parents=True)
    for variant in ("baseline", "shared", "llvm"):
        shutil.copytree(source / variant, root / variant)
    shutil.copytree(source / "data", root / "data")
    study.update(
        status="running", runs=[], kind="separate_descriptor_correctness_diagnostic",
        original_run_id=args.source_run_id,
        original_study_sha256=digest(source / "screen-study.json"),
        started_at=dt.datetime.now().astimezone().isoformat(),
        deadline=(dt.datetime.now().astimezone() + dt.timedelta(minutes=8)).isoformat(),
        measurement_protocol={"rounds": 10, "samples_per_case": 20,
                              "purpose": "Reproduction of output-check failures, not replacement performance estimates"},
    )
    save(root, study)
    for block in range(10):
        order = ("baseline", "shared", "llvm")
        order = order[block % 3:] + order[:block % 3]
        for variant in order:
            for threads in ([1, 20] if block % 2 == 0 else [20, 1]):
                check_frozen(root, study)
                run_one(root, study, variant, "features2d", threads, f"diag{block + 1:02}")
                save(root, study)
    failures = []
    for run in study["runs"]:
        xml = root / "runs" / run["label"] / "results.xml"
        for case in ET.parse(xml).findall(".//testcase"):
            for failure in case.findall("failure"):
                failures.append({"label": run["label"], "variant": run["variant"],
                                 "threads": run["threads"], "name": case.get("classname") + "." + case.get("name"),
                                 "message": failure.get("message")})
    for relative, expected in study["sanity_sha256"].items():
        if digest(root / relative) != expected:
            raise RuntimeError("Original sanity reference changed")
    check_frozen(source, original)
    if digest(source / "screen-study.json") != study["original_study_sha256"]:
        raise RuntimeError("Original study was modified")
    study["status"] = "completed_with_failures" if failures else "succeeded"
    study["finished_at"] = dt.datetime.now().astimezone().isoformat()
    save(root, study)
    report = {"status": study["status"], "case_executions": 120, "failures": failures,
              "interpretation": "Separate repeatability diagnostic; preserves the original failed screen. A clean repeat would not invalidate an earlier failure."}
    (root / "summary.json").write_text(json.dumps(report, indent=2))
    files = [root / "summary.json", root / "screen-study.json", Path(__file__)]
    files += list((root / "runs").glob("*/*.xml")) + list((root / "runs").glob("*/*.log"))
    for path in files:
        relative = path.relative_to(root) if path.is_relative_to(root) else Path(path.name)
        target = public / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(redact(path.read_text(encoding="utf-8-sig")), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
