"""Validate and summarize the balanced fixed-vs-default Ninja wall-time study."""

import argparse
import json
from pathlib import Path
import statistics

from analyze_ninja_log import parse_log


def peak_concurrency(steps):
    events = []
    for step in steps:
        if step.end_ms > step.start_ms:
            events.extend(((step.start_ms, 1), (step.end_ms, -1)))
    active = peak = 0
    for _, change in sorted(events):
        active += change
        peak = max(peak, active)
    return peak


def group_stats(times):
    return {
        "count": len(times),
        "mean_seconds": statistics.mean(times),
        "median_seconds": statistics.median(times),
        "min_seconds": min(times),
        "max_seconds": max(times),
        "sample_stdev_seconds": statistics.stdev(times),
    }


def compare(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "study.json").read_text(encoding="utf-8-sig"))
    if "finished_at" not in manifest:
        raise ValueError("Study has not completed")
    if manifest["order"] != ["fixed", "default", "default", "fixed",
                             "default", "fixed", "fixed", "default"]:
        raise ValueError("Unexpected study ordering")
    records = []
    for path in directory.glob("*/metadata.json"):
        metadata = json.loads(path.read_text(encoding="utf-8-sig"))
        if metadata["status"] != "succeeded":
            raise ValueError(f"Unsuccessful study run: {path.parent.name}")
        records.append((path, metadata))
    records.sort(key=lambda item: item[1]["started_at"])
    if len(records) != 8:
        raise ValueError("Expected exactly eight completed study runs")
    reference = records[0][1]["setup"]
    rows = []
    previous_finish = None
    compile_counts = set()
    for index, ((path, metadata), condition) in enumerate(zip(records, manifest["order"]), 1):
        fixed = condition == "fixed"
        jobs = manifest["fixed_jobs"] if fixed else manifest["default_jobs"]
        args = ["--build", ".", "--config", "Release"]
        if fixed:
            args += ["--parallel", str(jobs)]
        if (metadata["generator"] != "Ninja" or metadata["profile"]
                or metadata["parallel"] != (jobs if fixed else 0)
                or metadata["build_arguments"] != args
                or metadata["validated_version"] != "4.10.0"
                or metadata["runner_sha256"] != manifest["runner_sha256"]):
            raise ValueError(f"Run settings do not match the study: {metadata['label']}")
        if metadata["setup"] != reference:
            raise ValueError("Setup/toolchain changed between runs")
        if previous_finish and metadata["started_at"] <= previous_finish:
            raise ValueError("Study runs overlapped")
        previous_finish = metadata["finished_at"]
        steps = parse_log(path.parent / "ninja_log.txt")
        compiles = sum(step.kind == "compile" for step in steps)
        compile_counts.add(compiles)
        peak = peak_concurrency(steps)
        if peak > jobs or compiles == 0:
            raise ValueError("Unexpected job concurrency or non-clean build")
        rows.append({
            "sequence": index, "condition": condition, "jobs": jobs,
            "directory": path.parent.name, "seconds": metadata["build_seconds"],
            "compile_commands": compiles, "unique_commands": len(steps),
            "observed_peak_commands": peak,
        })
    if len(compile_counts) != 1:
        raise ValueError("The number of compile commands changed between runs")
    fixed_stats = group_stats([r["seconds"] for r in rows if r["condition"] == "fixed"])
    default_stats = group_stats([r["seconds"] for r in rows if r["condition"] == "default"])
    pairs = []
    for index in range(0, len(rows), 2):
        pair = rows[index:index + 2]
        fixed = next(r for r in pair if r["condition"] == "fixed")
        default = next(r for r in pair if r["condition"] == "default")
        delta = default["seconds"] - fixed["seconds"]
        pairs.append({
            "pair": index // 2 + 1,
            "fixed_seconds": fixed["seconds"], "default_seconds": default["seconds"],
            "default_minus_fixed_seconds": delta,
            "default_time_change_percent": 100 * delta / fixed["seconds"],
        })
    return {
        "metric": "Clean-build wall time, not CPU time or energy efficiency",
        "fixed_jobs": manifest["fixed_jobs"], "default_jobs": manifest["default_jobs"],
        "order": manifest["order"], "fixed": fixed_stats, "default": default_stats,
        "default_median_time_change_percent": 100 * (
            default_stats["median_seconds"] / fixed_stats["median_seconds"] - 1),
        "default_faster_pairs": sum(p["default_minus_fixed_seconds"] < 0 for p in pairs),
        "fixed_faster_pairs": sum(p["default_minus_fixed_seconds"] > 0 for p in pairs),
        "paired_mean_default_minus_fixed_seconds": statistics.mean(
            p["default_minus_fixed_seconds"] for p in pairs),
        "runs": rows, "pairs": pairs,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.directory), indent=2))


if __name__ == "__main__":
    main()
