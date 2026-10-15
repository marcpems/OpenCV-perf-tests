"""Validate the matched VS 2026 old/new SDK study and report build wall times."""

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import statistics
import xml.etree.ElementTree as ET

from compare_parallelism import group_stats

BASELINE = "MSVC2026"
LATEST = "MSVC2026Latest"
ORDER = [BASELINE, LATEST, LATEST, BASELINE, LATEST, BASELINE, BASELINE, LATEST]


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def inventory(build):
    build = Path(build).resolve()
    source = build.parent

    def normalize(text):
        return text.replace("/", "\\").lower().replace(
            str(build).lower(), "<build>").replace(str(source).lower(), "<source>")

    projects = ET.parse(build / "OpenCV.slnx").findall(".//Project")
    sources, settings = [], []
    for entry in projects:
        relative = entry.attrib["Path"].replace("/", "\\")
        project = build / relative
        tree = ET.parse(project)
        for item in tree.findall(".//{*}ClCompile"):
            if "Include" in item.attrib:
                path = (project.parent / item.attrib["Include"]).resolve()
                sources.append(normalize(relative + ":" + str(path)))
        for group in tree.findall(".//{*}ItemDefinitionGroup"):
            if "Release|" in group.attrib.get("Condition", ""):
                compiler = group.find("{*}ClCompile")
                if compiler is not None:
                    settings.append(normalize(relative + ":" + ET.tostring(compiler, encoding="unicode")))

    def digest(items):
        return hashlib.sha256(json.dumps(sorted(items)).encode()).hexdigest()

    if not projects or not sources or not settings:
        raise ValueError("Missing solution projects, compile sources or Release settings")
    return {
        "projects": len(projects), "compile_source_entries": len(sources),
        "source_multiset_sha256": digest(sources),
        "release_compile_settings_sha256": digest(settings),
    }


def compare(directory):
    directory = Path(directory)
    manifest = read_json(directory / "study.json")
    if "finished_at" not in manifest:
        raise ValueError("Study has not completed")
    if manifest["order"] != ORDER or manifest["generator"] != "MSBuild" or manifest["parallel"] != 0:
        raise ValueError("Expected the eight-run default-worker SDK study")
    records = [(path.parent.name, read_json(path)) for path in directory.glob("*/metadata.json")]
    records.sort(key=lambda item: datetime.fromisoformat(item[1]["started_at"]))
    if len(records) != len(ORDER):
        raise ValueError("Expected exactly eight runs")
    setups, rows = {}, []
    environment = None
    previous_finish = None
    for index, ((name, run), condition) in enumerate(zip(records, ORDER), 1):
        if (run["status"] != "succeeded" or run["toolchain"] != condition
                or run["generator"] != "MSBuild" or run["profile"] or run["parallel"] != 0
                or run["build_arguments"] != ["--build", ".", "--config", "Release"]
                or run["validated_version"] != "4.10.0"
                or run["runner_sha256"] != manifest["runner_sha256"]):
            raise ValueError(f"Run settings differ from the study: {name}")
        start = datetime.fromisoformat(run["started_at"])
        finish = datetime.fromisoformat(run["finished_at"])
        if finish <= start or (previous_finish and start <= previous_finish):
            raise ValueError("Invalid or overlapping run intervals")
        rest = (start - previous_finish).total_seconds() if previous_finish else None
        previous_finish = finish
        current_environment = {key: run.get(key) for key in (
            "cpu", "memory_gib", "os", "power_scheme", "tool_installation", "sdk_installation")}
        if environment is not None and environment != current_environment:
            raise ValueError("Recorded machine or installation environment changed")
        environment = current_environment
        setup = run["setup"]
        if condition in setups and setup != setups[condition]:
            raise ValueError("Setup changed within an SDK condition")
        setups[condition] = setup
        rows.append({"sequence": index, "condition": condition, "directory": name,
                     "build_seconds": run["build_seconds"], "seconds_since_previous_finish": rest})
    for key in ("hobl_commit", "opencv_commit", "config_sha256", "compiler",
                "compiler_sha256", "compiler_id", "compiler_version", "compiler_frontend",
                "architecture", "cmake", "cmake_version", "cmake_sha256",
                "build_engine", "visual_studio"):
        if setups[BASELINE][key] != setups[LATEST][key]:
            raise ValueError(f"Non-SDK component differs: {key}")
    expected_versions = {BASELINE: "10.0.26100.0", LATEST: "10.0.28000.0"}
    for condition, setup in setups.items():
        sdk = setup["windows_sdk"]
        properties = sdk["evaluated_properties"]
        if (sdk["target_version"] != expected_versions[condition]
                or properties["WindowsTargetPlatformVersion"] != sdk["target_version"]
                or properties["UCRTVersion"] != sdk["target_version"]):
            raise ValueError("SDK/UCRT selection does not match the condition")
    groups = {condition: group_stats([r["build_seconds"] for r in rows if r["condition"] == condition])
              for condition in (BASELINE, LATEST)}
    pairs = []
    for index in range(0, len(rows), 2):
        pair = {row["condition"]: row["build_seconds"] for row in rows[index:index + 2]}
        pairs.append({"pair": index // 2 + 1, "baseline_seconds": pair[BASELINE],
                      "latest_seconds": pair[LATEST],
                      "latest_minus_baseline_seconds": pair[LATEST] - pair[BASELINE]})
    return {
        "metric": "Clean Release build wall seconds; clean and install excluded",
        "order": ORDER, "groups": groups, "runs": rows, "pairs": pairs,
        "latest_median_time_change_percent": 100 * (
            groups[LATEST]["median_seconds"] / groups[BASELINE]["median_seconds"] - 1),
        "latest_faster_pairs": sum(pair["latest_minus_baseline_seconds"] < 0 for pair in pairs),
        "paired_mean_latest_minus_baseline_seconds": statistics.mean(
            pair["latest_minus_baseline_seconds"] for pair in pairs),
        "sdk_releases": {condition: setup["windows_sdk"]["release_version"]
                         for condition, setup in setups.items()},
        "recovery": manifest.get("recovery"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--source-root", type=Path)
    args = parser.parse_args()
    result = compare(args.directory)
    if args.source_root:
        baseline = inventory(args.source_root / "build_hobl_msvc2026")
        latest = inventory(args.source_root / "build_hobl_msvc2026_latest")
        if baseline != latest:
            raise ValueError("Solution sources or Release compile settings differ")
        result["matching_workload"] = baseline
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
