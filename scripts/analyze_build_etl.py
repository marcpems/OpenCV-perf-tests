"""Analyze xperf CPU exports, restricting accounting to the recorded build tree."""

import argparse
from collections import Counter, defaultdict
import csv
import json
from pathlib import Path
import re

PROCESS = re.compile(r"^\s*(.*?)\s+\(\s*(\d+)\)$")


def load_processes(path):
    result = []
    for line in path.read_text(encoding="utf-8-sig").splitlines()[1:]:
        if not line.strip():
            continue
        if not re.match(r"^\s*(?:MIN|\d+),", line):
            if not result:
                raise ValueError("Command continuation without a process row")
            result[-1]["command"] += "\n" + line
            continue
        fields = line.split(",", 8)
        if len(fields) != 9:
            raise ValueError("Malformed xperf process row")
        start, end, _, _, label, parent, _, key, command = [f.strip() for f in fields]
        match = PROCESS.fullmatch(label)
        if not match:
            raise ValueError(f"Invalid process label: {label}")
        result.append({
            "start": float("-inf") if start == "MIN" else int(start),
            "end": float("inf") if end == "MAX" else int(end),
            "name": match[1].lower(), "pid": int(match[2]), "parent": int(parent),
            "key": (key, start, end, int(match[2])), "command": command,
        })
    return result


def validate_trace(path):
    stats = path.read_text(encoding="utf-8-sig")
    for kind in ("Buffers", "Events"):
        found = re.search(rf"Total # Lost {kind}\s*:\s*(\d+)", stats)
        if not found or int(found[1]):
            raise ValueError("Missing trace quality data or lost events")


def build_context(processes, root):
    if not 0 <= root["start"] < root["end"] < float("inf"):
        raise ValueError("Build root must have a finite positive lifetime")
    by_pid = defaultdict(list)
    for process in processes:
        by_pid[process["pid"]].append(process)
    descendants = {root["key"]}
    changed = True
    while changed:
        changed = False
        for process in processes:
            if process["key"] in descendants or not root["start"] <= process["start"] <= root["end"]:
                continue
            parents = [p for p in by_pid[process["parent"]]
                       if p["start"] <= process["start"] <= p["end"]]
            if parents and max(parents, key=lambda p: p["start"])["key"] in descendants:
                descendants.add(process["key"])
                changed = True
    labels = defaultdict(set)
    build_processes = []
    for p in processes:
        if p["start"] <= root["end"] and p["end"] >= root["start"]:
            labels[p["name"], p["pid"]].add(p["key"] in descendants)
        if p["key"] in descendants:
            build_processes.append(p)

    def is_build(label):
        match = PROCESS.fullmatch(label.strip())
        if not match:
            raise ValueError(f"Invalid CPU process label: {label}")
        key = (match[1].lower(), int(match[2]))
        membership = labels.get(key, {False})
        if len(membership) > 1:
            raise ValueError("PID reuse crosses the build boundary; cannot aggregate safely")
        return key[0], True in membership

    return build_processes, is_build


def precise_cpu(path, is_build):
    cpu = Counter()
    for row in csv.reader(path.read_text(encoding="utf-8-sig").splitlines()[1:]):
        if len(row) < 2:
            continue
        name, owned = is_build(row[1])
        if owned:
            cpu[name] += float(row[0]) / 1e6
    return cpu


def sampled_rows(path):
    for line in path.read_text(encoding="utf-8-sig").splitlines()[1:]:
        if not line.strip() or re.fullmatch(r"Total Weight:\s*\d+", line.strip()):
            continue
        # Demangled C++ symbols contain unquoted commas.
        label, weight, _, symbol = line.split(",", 3)
        yield label.strip(), float(weight) / 1e6, symbol.strip()


def summarize(directory):
    directory = Path(directory)
    accounting = json.loads((directory / "cpu-accounting.json").read_text(encoding="utf-8-sig"))
    validate_trace(directory / "trace-stats.txt")
    processes = load_processes(directory / "processes.csv")
    roots = [p for p in processes if p["pid"] == accounting["ProcessId"]
             and " --build " in p["command"] and "build.log" in p["command"]]
    if len(roots) != 1:
        raise ValueError("Build root is missing or ambiguous")
    root = roots[0]
    build_processes, is_build = build_context(processes, root)
    cpu = precise_cpu(directory / "cpu-precise.csv", is_build)
    if not sum(cpu.values()) > 0:
        raise ValueError("No build CPU in the precise export")
    modules = defaultdict(Counter)
    for label, seconds, module in sampled_rows(directory / "cpu-sampled.csv"):
        name, owned = is_build(label)
        if owned:
            modules[name][module.lower()] += seconds
    wall = (root["end"] - root["start"]) / 1e6
    compiler_names = {"cl.exe", "clang.exe", "clang++.exe"}
    compiler_processes = [p for p in build_processes if p["name"] in compiler_names]
    if not compiler_processes:
        raise ValueError("No compiler processes in build tree")
    events = []
    for p in compiler_processes:
        events.extend(((max(root["start"], p["start"]), 1), (min(root["end"], p["end"]), -1)))
    active, previous = 0, root["start"]
    lifetime_buckets = Counter()
    for time, delta in sorted(events):
        lifetime_buckets[active] += (time - previous) / 1e6
        active += delta
        previous = time
    lifetime_buckets[active] += (root["end"] - previous) / 1e6
    return {
        "wall_seconds_from_etl": wall, "job_accounting": accounting,
        "etl_cpu_seconds": sum(cpu.values()), "etl_average_cores": sum(cpu.values()) / wall,
        "job_minus_etl_cpu_percent": 100 * (accounting["CpuSeconds"] / sum(cpu.values()) - 1),
        "build_process_instances": len(build_processes),
        "build_process_counts": dict(Counter(p["name"] for p in build_processes).most_common()),
        "cpu_seconds_by_build_executable": dict(cpu.most_common()),
        "sampled_cpu_seconds_by_executable_module": {
            name: dict(counter.most_common()) for name, counter in modules.items()},
        "compiler_process_lifetime_concurrency_seconds": dict(sorted(lifetime_buckets.items())),
        "compiler_lifetime_span_seconds": (
            min(root["end"], max(p["end"] for p in compiler_processes))
            - min(p["start"] for p in compiler_processes)) / 1e6,
        "post_compiler_tail_seconds": (
            root["end"] - min(root["end"], max(p["end"] for p in compiler_processes))) / 1e6,
        "build_range_microseconds": [root["start"], root["end"]],
        "lost_events": 0, "lost_buffers": 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory), indent=2))


if __name__ == "__main__":
    main()
