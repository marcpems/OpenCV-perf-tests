"""Collect exact-script evidence and summarize only completed HOBL measurements."""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import statistics

from analyze_msbuild_tail import command_manifest
from analyze_runtime_screen import image_sections
from export_results import redact


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def snapshot(build, run):
    commands = command_manifest(build)
    calls = read_json(run / "cmake-calls.json")
    if len(calls) != 3 or any(c["exit_code"] != 0 for c in calls):
        raise ValueError("Expected three successful CMake calls")
    with (run / "opencv_build_results.csv").open(encoding="utf-8-sig") as stream:
        metrics = dict(csv.reader(stream))
    if set(metrics) != {"scenario_runtime", "build_time", "architecture"}:
        raise ValueError("Unexpected HOBL CSV fields")
    if metrics["scenario_runtime"] != metrics["build_time"] or float(metrics["build_time"]) <= 0:
        raise ValueError("Invalid HOBL build timing")
    if metrics["architecture"] != "ARM64":
        raise ValueError("Expected ARM64 HOBL result")
    image = image_sections(build / "bin" / "Release" / "opencv_world4100.dll")
    if image["machine"] != "0xaa64":
        raise ValueError("Expected native ARM64 output")
    source = run / "command-manifest.json"
    source.write_text(json.dumps(commands, sort_keys=True, indent=2), encoding="utf-8")
    result = {
        "build_seconds": float(metrics["build_time"]),
        "compile_command_records": len(commands),
        "commands_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "image": image,
        "install_preserved_outputs": calls[2]["before_install"] == calls[2]["after_install"],
    }
    if not result["install_preserved_outputs"]:
        raise ValueError("Untimed install changed compilation outputs")
    (run / "validation.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


def export(root, destination):
    study = read_json(root / "study.json")
    if study["status"] != "succeeded":
        raise ValueError("Cannot export an incomplete or failed study as successful")
    runs = {}
    command_hashes = set()
    text_hashes = set()
    for label in study["completed_labels"]:
        record = read_json(root / "runs" / label / "validation.json")
        command_hashes.add(record["commands_sha256"])
        text_hashes.add(record["image"]["sections"][".text"]["sha256"])
        if not label.endswith("_warmup"):
            variant = label.split("_")[0]
            runs.setdefault(variant, []).append({"label": label, **record})
    if len(command_hashes) != 1:
        raise ValueError("Compilation command manifests differ between runs")
    if any(len(runs.get(v, [])) != 4 for v in ("baseline", "shared")):
        raise ValueError("Expected four measured observations per variant")
    summary = {}
    for variant, observations in runs.items():
        times = [r["build_seconds"] for r in observations]
        summary[variant] = {
            "count": len(times), "median_seconds": statistics.median(times),
            "min_seconds": min(times), "max_seconds": max(times), "runs": observations,
        }
    summary["wall_saving_percent"] = (
        1 - summary["shared"]["median_seconds"] / summary["baseline"]["median_seconds"]
    ) * 100
    summary["compilation_commands_identical"] = True
    summary["text_sections_identical"] = len(text_hashes) == 1
    destination.mkdir(parents=True, exist_ok=False)
    for name in ("study.json", "provenance.json", "configure.log", "smoke.log"):
        text = (root / name).read_text(encoding="utf-8-sig")
        (destination / name).write_text(redact(text), encoding="utf-8")
    for label in study["completed_labels"]:
        output = destination / label
        output.mkdir()
        for path in (root / "runs" / label).iterdir():
            if path.suffix not in (".json", ".csv", ".trace", ".log", ".txt"):
                raise ValueError(f"Unexpected non-text evidence: {path.name}")
            output.joinpath(path.name).write_text(
                redact(path.read_text(encoding="utf-8-sig")), encoding="utf-8"
            )
    (destination / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("snapshot", "export"))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.operation == "snapshot":
        snapshot(args.source, args.destination)
    else:
        export(args.source, args.destination)
