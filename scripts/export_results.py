"""Export successful local runs with user-profile paths redacted; aggregate repeated variants."""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import statistics

from analyze_ninja_log import parse_log, summarize

FILES = (
    "metadata.json", "opencv_build_results.csv", "opencv_build_results.trace",
    "build.log", "clean.log", "install.log", "configure.log", "CMakeCache.txt",
    "opencv_version.txt", "opencv_build_info.txt", "ninja_log.txt",
)


def redact(text):
    # Match raw paths and JSON-escaped paths; retain tool versions and timings.
    return re.sub(
        r"[A-Za-z]:[/\\]+Users[/\\]+[^/\\\r\n\";]+",
        "<USERPROFILE>",
        text,
        flags=re.IGNORECASE,
    )


def export(source, destination):
    if destination.exists():
        raise ValueError("Destination already exists; choose a new snapshot directory")
    study_file = source / "study.json"
    study = None
    if study_file.is_file():
        study = json.loads(study_file.read_text(encoding="utf-8-sig"))
        if "finished_at" not in study:
            raise ValueError("Cannot export an incomplete study")
    runs = []
    measurement_modes = set()
    for directory in sorted(source.iterdir()):
        metadata_file = directory / "metadata.json"
        if not directory.is_dir() or not metadata_file.is_file():
            continue
        metadata = json.loads(metadata_file.read_text(encoding="utf-8-sig"))
        if metadata["status"] != "succeeded":
            continue
        if metadata["validated_version"] != "4.10.0":
            raise ValueError(f"Unexpected OpenCV version: {directory}")
        with (directory / "opencv_build_results.csv").open(encoding="utf-8-sig") as stream:
            metrics = dict(csv.reader(stream))
        if metrics["scenario_runtime"] != metrics["build_time"]:
            raise ValueError(f"Invalid HOBL timing semantics: {directory}")
        if abs(float(metrics["build_time"]) - metadata["build_seconds"]) > 0.006:
            raise ValueError(f"CSV/metadata time mismatch: {directory}")
        runs.append((directory, metadata))
        measurement_modes.add((metadata.get("profile", False),
                               metadata.get("measure_cpu", False),
                               metadata.get("wpr_trace", False)))
    if not runs:
        raise ValueError("No successful validated runs to export")
    if study and len(runs) != len(study["order"]):
        raise ValueError("Study run count does not match its manifest")
    if len(measurement_modes) != 1:
        raise ValueError("Do not pool different measurement/profiling modes in one snapshot")
    destination.mkdir(parents=True)
    groups = {}
    for directory, metadata in runs:
        output = destination / directory.name
        output.mkdir()
        hashes = {}
        names = FILES + (("cpu-accounting.json",) if metadata.get("measure_cpu") else ())
        for name in names:
            path = directory / name
            if not path.exists():
                if name == "ninja_log.txt" and metadata["generator"] != "Ninja":
                    continue
                raise ValueError(f"Missing run artifact: {path}")
            hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            if name == "cpu-accounting.json":
                accounting = json.loads(path.read_text(encoding="utf-8-sig"))
                if accounting != metadata["cpu_accounting"]:
                    raise ValueError("CPU artifact does not match run metadata")
            text = redact(path.read_text(encoding="utf-8-sig"))
            (output / name).write_text(text, encoding="utf-8")
        (output / "original_sha256.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
        if metadata["generator"] == "Ninja":
            analysis = summarize(parse_log(directory / "ninja_log.txt"))
            (output / "analysis.json").write_text(json.dumps(analysis, indent=2), encoding="utf-8")
        group = re.sub(r"_\d+$", "", metadata["label"])
        groups.setdefault(group, []).append({
            "directory": directory.name,
            "build_seconds": metadata["build_seconds"],
            "clean_seconds": metadata["clean_seconds"],
            "install_seconds": metadata["install_seconds"],
        })
    report = {}
    for group, values in groups.items():
        times = [v["build_seconds"] for v in values]
        report[group] = {
            "count": len(times), "median_seconds": statistics.median(times),
            "min_seconds": min(times), "max_seconds": max(times), "runs": values,
        }
    (destination / "summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    if study:
        (destination / "study.json").write_text(
            redact(json.dumps(study, indent=2)), encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(export(args.source, args.destination), indent=2))


if __name__ == "__main__":
    main()
