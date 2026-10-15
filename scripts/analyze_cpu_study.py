"""Summarize this three-configuration CPU/ETL study without exporting machine-wide data."""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import re
import statistics
import xml.etree.ElementTree as ET

from analyze_build_etl import (
    PROCESS, build_context, load_processes, precise_cpu, sampled_rows, summarize, validate_trace,
)
from analyze_ninja_log import parse_log, summarize as summarize_ninja


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def trace_identity(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return {"bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def backend_functions(path, is_build):
    result = Counter()
    for label, seconds, symbol in sampled_rows(path):
        name, owned = is_build(label)
        if owned and name == "cl.exe" and symbol.startswith("c2.dll!"):
            result[symbol] += seconds
    return dict(result.most_common(30))


def configuration(metadata):
    return metadata["toolchain"] + "_" + metadata["generator"]


def full_trace(directory):
    result = summarize(directory)
    result["trace_identity"] = trace_identity(directory / "build.etl")
    processes = load_processes(directory / "processes.csv")
    root = next(p for p in processes if p["pid"] == result["job_accounting"]["ProcessId"]
                and [p["start"], p["end"]] == result["build_range_microseconds"])
    build_processes, is_build = build_context(processes, root)
    result["quarter_average_build_cores"] = [
        sum(precise_cpu(directory / f"cpu-quarter-{i}.csv", is_build).values())
        / (result["wall_seconds_from_etl"] / 4) for i in range(4)
    ]
    disk_lines = (directory / "disk-build.csv").read_text().splitlines()
    if disk_lines[0].strip() != "Disk  0":
        raise ValueError("This report expects a single disk; inspect the export layout")
    disk = [[float(v) for v in row] for row in csv.reader(disk_lines[2:]) if row]
    if not disk or any(len(row) != 5 for row in disk):
        raise ValueError("Unexpected disk export layout")
    start, end = result["build_range_microseconds"]
    if disk[0][0] != start or disk[-1][1] != end:
        raise ValueError("Disk export does not cover exactly the timed build")
    result["whole_machine_disk_0_usage_percent"] = {
        "mean": sum((r[1] - r[0]) * r[4] for r in disk) / (end - start),
        "max_one_second_bin": max(r[4] for r in disk),
    }
    if (directory / "cpu-functions.csv").is_file():
        result["backend_function_sample_seconds"] = backend_functions(
            directory / "cpu-functions.csv", is_build)
    if (directory / "ninja_log.txt").is_file():
        result["ninja"] = summarize_ninja(parse_log(directory / "ninja_log.txt"))
    else:
        compilers = [p for p in build_processes if p["name"] == "cl.exe"]
        long_batch = [p for p in compilers if p["end"] - p["start"] > (root["end"] - root["start"]) / 4]
        if long_batch:
            boundary = max(p["end"] for p in long_batch)
            links = [p for p in build_processes if p["name"] == "link.exe" and p["start"] > boundary]
            if links:
                next_link = min(links, key=lambda p: p["start"])
                tail = sorted((p for p in compilers if boundary < p["start"] < next_link["start"]),
                              key=lambda p: p["start"])
                if tail:
                    result["post_long_batch_compilations"] = {
                        "count": len(tail),
                        "start_seconds": (tail[0]["start"] - root["start"]) / 1e6,
                        "end_seconds": (tail[-1]["end"] - root["start"]) / 1e6,
                        "summed_process_lifetime_seconds": sum(p["end"] - p["start"] for p in tail) / 1e6,
                        "overlapping_adjacent_pairs": sum(a["end"] > b["start"] for a, b in zip(tail, tail[1:])),
                        "following_link_start_seconds": (next_link["start"] - root["start"]) / 1e6,
                        "following_link_end_seconds": (next_link["end"] - root["start"]) / 1e6,
                    }
    return result


def project_metadata(path):
    ns = {"m": "http://schemas.microsoft.com/developer/msbuild/2003"}
    files = ET.parse(path).getroot().findall("m:ItemGroup/m:ClCompile", ns)
    special = []
    for file in files:
        properties = {c.tag.split("}")[-1]: c.text for c in file
                      if "Condition" not in c.attrib or "'Release|" in c.attrib["Condition"]}
        if properties:
            source = file.attrib["Include"].replace("\\", "/")
            if "/modules/" not in source:
                raise ValueError("Expected an OpenCV modules source path")
            special.append({"source": source.split("/modules/", 1)[1], "properties": properties})
    return {"project_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "compile_items": len(files), "per_file_release_metadata": special}


def focused_units(directory):
    validate_trace(directory / "trace-stats.txt")
    processes = load_processes(directory / "processes.csv")
    threads = defaultdict(list)
    for row in csv.reader((directory / "cpu-threads.csv").read_text().splitlines()[1:]):
        if row:
            match = PROCESS.fullmatch(row[1].strip())
            if not match:
                raise ValueError("Invalid thread process label")
            threads[match[1].lower(), int(match[2])].append(float(row[0]) / 1e6)
    modules = defaultdict(Counter)
    for label, seconds, module in sampled_rows(directory / "cpu-sampled.csv"):
        match = PROCESS.fullmatch(label)
        if not match:
            raise ValueError("Invalid sampled process label")
        modules[match[1].lower(), int(match[2])][module] += seconds
    result = []
    for metadata_path in sorted(directory.glob("*/metadata.json")):
        metadata = read_json(metadata_path)
        accounting = metadata["accounting"]
        if accounting["ExitCode"] != 0:
            raise ValueError("Failed diagnostic compilation")
        roots = [p for p in processes if p["pid"] == accounting["ProcessId"]
                 and p["name"] == "cmd.exe"]
        if len(roots) != 1:
            raise ValueError("Focused root missing or ambiguous")
        children, is_build = build_context(processes, roots[0])
        compilers = [p for p in children if p["name"] in ("cl.exe", "clang++.exe")]
        if len(compilers) != 1:
            raise ValueError("Expected one compiler per focused case")
        compiler = compilers[0]
        key = compiler["name"], compiler["pid"]
        # Focused exports cover the whole eight-case trace. Reject reused compiler labels.
        if sum((p["name"], p["pid"]) == key for p in processes) != 1:
            raise ValueError("Focused compiler PID reused; re-export by case time range")
        row = {
            "source": metadata["source"], "toolchain": metadata["toolchain"],
            "wall_seconds": accounting["WallSeconds"], "cpu_seconds": accounting["CpuSeconds"],
            "compiler_etl_cpu_seconds": sum(threads[key]),
            "compiler_thread_cpu_seconds": sorted(threads[key], reverse=True),
            "sampled_module_cpu_seconds": dict(modules[key].most_common()),
            "compiler_sha256": metadata["compiler_sha256"],
        }
        if metadata["toolchain"] == "MSVC":
            text = (metadata_path.parent / "compile.log").read_text()
            row["phase_elapsed_seconds"] = dict(
                (dll, float(seconds)) for dll, seconds in
                re.findall(r"\\(c1xx|c2)\.dll\)=([0-9.]+)s", text))
            if set(row["phase_elapsed_seconds"]) != {"c1xx", "c2"}:
                raise ValueError("Missing /Bt+ frontend/backend times")
            row["backend_function_sample_seconds"] = backend_functions(
                directory / "cpu-functions.csv", is_build)
        else:
            trace = read_json(metadata_path.parent / "clang-time.json")
            row["phase_elapsed_seconds"] = {
                e["name"].removeprefix("Total "): e["dur"] / 1e6 for e in trace["traceEvents"]
                if e["name"] in ("Total Frontend", "Total Backend", "Total Optimizer", "Total CodeGenPasses")
            }
            if len(row["phase_elapsed_seconds"]) != 4:
                raise ValueError("Missing Clang phase totals")
        result.append(row)
    if not result:
        raise ValueError("No focused compilations")
    return {"trace_identity": trace_identity(directory / "units.etl"),
            "lost_events": 0, "lost_buffers": 0, "cases": result}


def study(measured, traces, units):
    groups = defaultdict(list)
    components, objects = defaultdict(list), defaultdict(list)
    for directory in sorted(measured.iterdir()):
        if not directory.is_dir():
            continue
        metadata = read_json(directory / "metadata.json")
        if (metadata["status"] != "succeeded" or metadata["validated_version"] != "4.10.0"
                or not metadata["measure_cpu"] or metadata["wpr_trace"] or metadata["profile"]):
            raise ValueError("Expected successful, untraced CPU-measured runs only")
        cpu = read_json(directory / "cpu-accounting.json")
        if cpu != metadata["cpu_accounting"] or abs(cpu["WallSeconds"] - metadata["build_seconds"]) > 0.0001:
            raise ValueError("CPU accounting does not match metadata")
        key = configuration(metadata)
        row = {"run": directory.name, "wall_seconds": cpu["WallSeconds"],
               "cpu_seconds": cpu["CpuSeconds"], "user_seconds": cpu["UserSeconds"],
               "kernel_seconds": cpu["KernelSeconds"], "average_cores": cpu["AverageCores"]}
        if metadata["generator"] == "Ninja":
            steps = parse_log(directory / "ninja_log.txt")
            row["ninja"] = summarize_ninja(steps)
            components[key].append(row["ninja"]["by_component_elapsed_seconds"])
            objects[key].append({s.outputs[0]: s.seconds for s in steps if s.kind == "compile"})
        groups[key].append(row)
    if set(groups) != {"MSVC_MSBuild", "MSVC_Ninja", "Clang_Ninja"}:
        raise ValueError("Expected the three original-MSVC/MSVC-Ninja/Clang-Ninja configurations")
    summary = {}
    for key, rows in groups.items():
        summary[key] = {"count": len(rows), "runs": rows, "medians": {
            field: statistics.median(row[field] for row in rows) for field in
            ("wall_seconds", "cpu_seconds", "user_seconds", "kernel_seconds", "average_cores")}}

    def gaps(data):
        a, b = data["MSVC_Ninja"], data["Clang_Ninja"]
        shared = set.intersection(*(set(row) for row in a + b))
        rows = [{"name": name, "msvc_mean_elapsed_seconds": statistics.mean(r[name] for r in a),
                 "clang_mean_elapsed_seconds": statistics.mean(r[name] for r in b)} for name in shared]
        for row in rows:
            row["difference_seconds"] = row["msvc_mean_elapsed_seconds"] - row["clang_mean_elapsed_seconds"]
        return sorted(rows, key=lambda r: r["difference_seconds"], reverse=True)

    traced = {}
    for directory in sorted(traces.iterdir()):
        if not directory.is_dir():
            continue
        metadata = read_json(directory / "metadata.json")
        if metadata["status"] != "succeeded" or not metadata["wpr_trace"]:
            raise ValueError("Expected successful traced run")
        key = configuration(metadata)
        if key in traced:
            raise ValueError("This report expects one diagnostic trace per configuration")
        traced[key] = full_trace(directory)
    if traced.keys() != groups.keys():
        raise ValueError("Missing configuration trace")
    return {"untraced": summary, "component_elapsed_gaps": gaps(components),
            "matched_object_elapsed_gaps": gaps(objects), "traced": traced,
            "focused": focused_units(units)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("measured", "traces", "units", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--msbuild-project", type=Path,
                        help="Current generated opencv_world.vcxproj; exports only per-file metadata")
    args = parser.parse_args()
    result = study(args.measured, args.traces, args.units)
    if args.msbuild_project:
        result["msbuild_project"] = project_metadata(args.msbuild_project)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
    print(f"Wrote build-only summary: {args.output}")


if __name__ == "__main__":
    main()
