"""Export compiler microbench measurements, not objects, source copies or raw traces."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import statistics
import struct

from export_results import redact


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def phases(directory, metadata):
    if not metadata.get("phase_timing"):
        return {}
    if metadata["variant"].startswith("msvc"):
        text = (directory / "compile.log").read_text(encoding="utf-8-sig")
        values = dict((name, float(value)) for name, value in
                      re.findall(r"\\(c1xx|c2)\.dll\)=([0-9.]+)s", text))
        if set(values) != {"c1xx", "c2"}:
            raise ValueError(f"Missing MSVC phase times: {directory}")
    else:
        trace = read_json(directory / "clang-time.json")
        names = {"Total Frontend", "Total Backend", "Total Optimizer", "Total CodeGenPasses"}
        values = {e["name"].removeprefix("Total "): e["dur"] / 1e6
                  for e in trace["traceEvents"] if e["name"] in names}
        if len(values) != 4:
            raise ValueError(f"Missing Clang phase times: {directory}")
    return values


def symbol_section_bytes(path, prefix):
    data = path.read_bytes()
    big = data[:4] == b"\0\0\xff\xff"
    if big:
        header, entry = 56, 20
        pointer, count = struct.unpack_from("<II", data, 48)
    else:
        header, entry = 20 + struct.unpack_from("<H", data, 16)[0], 18
        pointer, count = struct.unpack_from("<II", data, 8)
    strings = pointer + count * entry
    index = 0
    found = []
    while index < count:
        offset = pointer + index * entry
        name = data[offset:offset + 8]
        if name[:4] == b"\0" * 4:
            at = strings + struct.unpack_from("<I", name, 4)[0]
            name = data[at:data.index(b"\0", at)]
        else:
            name = name.rstrip(b"\0")
        section = struct.unpack_from("<i" if big else "<h", data, offset + 12)[0]
        if name.startswith(prefix.encode()) and section > 0:
            section_header = header + (section - 1) * 40
            found.append(struct.unpack_from("<I", data, section_header + 16)[0])
        index += 1 + data[offset + entry - 1]
    if len(found) != 1:
        raise ValueError(f"Expected exactly one symbol section for {prefix}: {path}")
    return found[0]


def analyze(source):
    manifest = read_json(source / "study.json")
    if manifest["status"] != "succeeded" or "finished_at" not in manifest:
        raise ValueError("Cannot export an incomplete or failed study")
    expected = len(manifest["variants"]) * (manifest["repetitions"] + 1)
    if "copies" not in manifest:
        expected *= len(manifest["sources"])
    if len(manifest["runs"]) != expected or len(set(manifest["runs"])) != expected:
        raise ValueError("Study run count or labels do not match the protocol")
    rows, groups = [], defaultdict(list)
    for label in manifest["runs"]:
        directory = source / label
        metadata = read_json(directory / "metadata.json")
        if metadata["label"] != label or metadata["accounting"]["ExitCode"] != 0:
            raise ValueError(f"Invalid compiler run: {label}")
        if "object_sha256" in metadata:
            obj = directory / "unit.obj"
            if hashlib.sha256(obj.read_bytes()).hexdigest() != metadata["object_sha256"].lower():
                raise ValueError(f"Object changed after measurement: {label}")
        metadata["phase_elapsed_seconds"] = phases(directory, metadata)
        rows.append(metadata)
        if metadata["warmup"]:
            continue
        case = (Path(metadata["source_override"]).name if metadata.get("source_override")
                else metadata.get("source", "compiler-only batch"))
        groups[(case, metadata["variant"])].append(metadata)
    summary = []
    for (case, variant), measurements in sorted(groups.items()):
        if len(measurements) != manifest["repetitions"]:
            raise ValueError(f"Missing repetitions: {case}/{variant}")
        metrics = [r["accounting"] for r in measurements]
        phase_names = set.intersection(*(set(r["phase_elapsed_seconds"]) for r in measurements))
        summary.append({
            "case": case, "variant": variant, "count": len(metrics),
            "median_wall_seconds": statistics.median(r["WallSeconds"] for r in metrics),
            "min_wall_seconds": min(r["WallSeconds"] for r in metrics),
            "max_wall_seconds": max(r["WallSeconds"] for r in metrics),
            "median_cpu_seconds": statistics.median(r["CpuSeconds"] for r in metrics),
            "median_user_seconds": statistics.median(r["UserSeconds"] for r in metrics),
            "median_kernel_seconds": statistics.median(r["KernelSeconds"] for r in metrics),
            "median_phase_elapsed_seconds": {
                name: statistics.median(r["phase_elapsed_seconds"][name] for r in measurements)
                for name in sorted(phase_names)
            },
        })
    return {"study": manifest, "summary": summary, "measurements": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.destination.exists():
        raise ValueError("Choose a fresh export directory")
    result = analyze(args.source)
    args.destination.mkdir(parents=True)
    for name, data in result.items():
        (args.destination / f"{name}.json").write_text(
            redact(json.dumps(data, indent=2)), encoding="utf-8")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
