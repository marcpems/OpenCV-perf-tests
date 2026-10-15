"""Correlate local MSBuild binlog events with WPR process lifetimes; export build-only data."""

import argparse
from collections import defaultdict
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
from pathlib import Path
import re

from analyze_build_etl import BUILD_COMMAND, PROCESS, build_context, load_processes, precise_cpu, validate_trace


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def trace_start(directory):
    text = (directory / "trace-stats.txt").read_text(encoding="utf-8-sig")
    match = re.search(r"Start time \(UTC\)\s*:\s*(\d+/\d+/\d+):([0-9:.]+)", text)
    if not match:
        raise ValueError("Missing trace start clock")
    return datetime.fromisoformat(match[1].replace("/", "-") + "T" + match[2]).replace(tzinfo=timezone.utc)


def world_tasks(directory):
    with (directory / "msbuild-events.jsonl").open(encoding="utf-8-sig") as stream:
        return parse_world_tasks(stream)


def parse_world_tasks(stream):
    projects, tasks = {}, {}
    for line in stream:
        event = json.loads(line)
        project_key = event["node"], event["project"]
        task_key = project_key + (event["task"],)
        if event["type"] == "ProjectStartedEventArgs":
            projects[project_key] = event["project_file"]
        if (event["type"] == "TaskStartedEventArgs"
                and event.get("name") in ("CL", "MultiToolTask")
                and projects.get(project_key, "").replace("\\", "/").endswith("/opencv_world.vcxproj")):
            tasks[task_key] = {
                "name": event["name"], "start": event["timestamp"],
                "sources": [], "command_times": [],
            }
        if task_key not in tasks:
            continue
        task = tasks[task_key]
        if event["type"] == "TaskFinishedEventArgs":
            if not event["succeeded"]:
                raise ValueError("Failed compiler task")
            task["end"] = event["timestamp"]
        if event["type"] == "TaskCommandLineEventArgs":
            task["command_times"].append(event["timestamp"])
        if event["type"] == "TaskParameterEventArgs" and re.match(
                r"Task Parameter:\s+Sources=", event["message"]):
            sources = re.findall(r"^ {8}([A-Za-z]:[\\/].*\.(?:cpp|cc|c))\s*$", event["message"], re.MULTILINE)
            for source in sources:
                source = source.replace("\\", "/")
                if "/modules/" not in source:
                    raise ValueError("Unexpected world-library source")
                task["sources"].append(source.split("/modules/", 1)[1])
    if not tasks or any("end" not in t or not t["sources"] for t in tasks.values()):
        raise ValueError("Missing world task lifetime or source metadata")
    return list(tasks.values())


def ambiguous_labels(processes, root, children):
    owned_keys = {p["key"] for p in children}
    labels = defaultdict(set)
    for process in processes:
        if process["start"] < root["end"] and process["end"] > root["start"]:
            labels[process["name"], process["pid"]].add(process["key"] in owned_keys)
    return {key for key, membership in labels.items() if len(membership) > 1}


def full_cpu(directory, processes, root, children, owned):
    ambiguous = ambiguous_labels(processes, root, children)

    def label_key(label):
        match = PROCESS.fullmatch(label.strip())
        if not match:
            raise ValueError("Malformed CPU label")
        return match[1].lower(), int(match[2])

    def unambiguous(label):
        name, pid = label_key(label)
        return (name, False) if (name, pid) in ambiguous else owned(label)

    result = precise_cpu(directory / "cpu-precise.csv", unambiguous)
    for process in children:
        key = process["name"], process["pid"]
        if key not in ambiguous:
            continue
        path = directory / f"cpu-instance-{process['pid']}-{process['start']}.csv"
        if not path.is_file():
            raise ValueError(f"PID reuse requires a precise CPU export for this owned lifetime: {path.name}")
        part = precise_cpu(path, lambda label: (key[0], label_key(label) == key))
        if key[0] not in part:
            raise ValueError("Owned process missing from lifetime CPU export")
        result.update(part)
    return result


def analyze(directory):
    directory = Path(directory)
    validate_trace(directory / "trace-stats.txt")
    accounting = read_json(directory / "cpu-accounting.json")
    processes = load_processes(directory / "processes.csv")
    roots = [p for p in processes if p["pid"] == accounting["ProcessId"]
             and BUILD_COMMAND.search(p["command"])]
    if len(roots) != 1:
        raise ValueError("Missing or ambiguous build root")
    root = roots[0]
    children, owned = build_context(processes, root)
    compilers = [p for p in children if p["name"] == "cl.exe"]
    start = trace_start(directory)

    def microseconds(timestamp):
        return round((datetime.fromisoformat(timestamp) - start).total_seconds() * 1e6)

    tasks = world_tasks(directory)
    rows = []
    for task in tasks:
        lo, hi = microseconds(task["start"]), microseconds(task["end"])
        if not root["start"] <= lo < hi <= root["end"]:
            raise ValueError("Binlog task is outside WPR build lifetime")
        active = [p for p in compilers if lo <= p["start"] < hi]
        if not active or any(p["end"] > hi for p in active):
            raise ValueError("Compiler lifetime does not fit task")
        row = {
            "task": task["name"], "source_count": len(task["sources"]), "sources": task["sources"],
            "start_seconds": (lo - root["start"]) / 1e6,
            "end_seconds": (hi - root["start"]) / 1e6, "task_seconds": (hi - lo) / 1e6,
            "compiler_processes": len(active),
        }
        if len(task["sources"]) == 1:
            if len(active) != 1:
                raise ValueError("Expected one compiler for single-file task")
            compiler = active[0]
            row.update(
                before_compiler_seconds=(compiler["start"] - lo) / 1e6,
                compiler_wall_seconds=(compiler["end"] - compiler["start"]) / 1e6,
                after_compiler_seconds=(hi - compiler["end"]) / 1e6,
            )
        rows.append(row)
    result = {
        "wall_seconds": accounting["WallSeconds"], "cpu_seconds": accounting["CpuSeconds"],
        "total_processes": accounting["TotalProcesses"],
        "build_range_microseconds": [root["start"], root["end"]],
        "world_tasks": rows,
        "lost_events": 0, "lost_buffers": 0,
    }
    if (directory / "cpu-precise.csv").is_file():
        result["build_cpu_seconds_by_executable"] = dict(
            full_cpu(directory, processes, root, children, owned).most_common())
    if (directory / "cpu-tail.csv").is_file():
        result["tail_cpu_seconds_by_executable"] = dict(
            precise_cpu(directory / "cpu-tail.csv", owned).most_common())
    result["build_process_counts"] = dict(
        (name, sum(p["name"] == name for p in children)) for name in sorted({p["name"] for p in children}))
    singles = [r for r in rows if r["source_count"] == 1]
    if singles:
        result["serial_tasks"] = {
            "count": len(singles),
            "span_seconds": singles[-1]["end_seconds"] - singles[0]["start_seconds"],
            "before_compiler_seconds": sum(r["before_compiler_seconds"] for r in singles),
            "compiler_wall_seconds": sum(r["compiler_wall_seconds"] for r in singles),
            "after_compiler_seconds": sum(r["after_compiler_seconds"] for r in singles),
            "between_tasks_seconds": sum(b["start_seconds"] - a["end_seconds"]
                                         for a, b in zip(singles, singles[1:])),
            "trace_range_microseconds": [
                round(root["start"] + singles[0]["start_seconds"] * 1e6),
                round(root["start"] + singles[-1]["end_seconds"] * 1e6),
            ],
        }
    return result


def command_manifest(directory):
    result = {}
    for path in Path(directory).glob("**/CL.command.1.tlog"):
        if path.relative_to(directory).parts[0] == "CMakeFiles":
            continue
        lines = path.read_text(encoding="utf-16").splitlines()
        if len(lines) % 2:
            raise ValueError("Malformed compiler command tlog")
        for i in range(0, len(lines), 2):
            if not lines[i].startswith("^"):
                raise ValueError("Missing command source marker")
            key = str(path.relative_to(directory)) + "|" + lines[i]
            if key in result:
                raise ValueError("Duplicate compiler command identity")
            result[key] = lines[i + 1]
    if not result:
        raise ValueError("No compiler command tlogs")
    return result


class StackTables(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tables, self.row, self.cell = [], None, None

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self.tables.append([])
        elif tag == "tr":
            self.row = []
        elif tag in ("td", "th"):
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.tables[-1].append(self.row)
            self.row = None


def tracking_stacks(path):
    parser = StackTables()
    parser.feed(path.read_text(encoding="utf-8-sig"))
    if len(parser.tables) != 6 or parser.tables[3][0][0] != "function name":
        raise ValueError("Unexpected xperf stack table format")
    functions = {}
    for row in parser.tables[3][1:]:
        if any(name in row[0] for name in (
                "CanonicalTrackedInputFiles.ConstructDependencyTable",
                "CanonicalTrackedInputFiles.SaveTlog",
                "CanonicalTrackedOutputFiles.ConstructOutputTable",
                "System.IO.StreamReader.ReadLine", "FileTracker.FileIsExcludedFromDependencies",
                "ToolTask.Execute()", "ToolTask.ExecuteTool(")):
            functions[row[0]] = {"inclusive_samples": int(row[1]),
                                 "percent_of_msbuild_samples": float(row[2].rstrip("%")),
                                 "exclusive_samples": int(row[3])}
    if not functions:
        raise ValueError("No resolved tracking functions")
    return functions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--tracking-stacks", type=Path)
    args = parser.parse_args()
    result = analyze(args.directory)
    if args.tracking_stacks:
        result["msbuild_tail_profile_stacks"] = tracking_stacks(args.tracking_stacks)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
    print(f"Wrote build-only task analysis: {args.output}")


if __name__ == "__main__":
    main()
