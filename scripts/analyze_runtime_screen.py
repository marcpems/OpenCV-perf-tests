"""Summarize bounded upstream runtime tests without asserting equivalence."""
import argparse
from collections import defaultdict
import json
import hashlib
import math
from pathlib import Path
import statistics
import struct
import xml.etree.ElementTree as ET
from export_results import redact
from run_runtime_screen import check_frozen


def image_sections(path):
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 60)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE image: {path}")
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    table = pe + 24 + optional_size
    sections = {}
    for index in range(count):
        name, _, _, size, offset = struct.unpack_from("<8sIIII", data, table + index * 40)
        if offset + size > len(data):
            raise ValueError(f"Invalid PE section bounds: {path}")
        sections[name.rstrip(b"\0").decode("ascii")] = {
            "raw_bytes": size, "sha256": hashlib.sha256(data[offset:offset + size]).hexdigest()}
    return {"sha256": hashlib.sha256(data).hexdigest(), "machine": hex(machine), "sections": sections}


def analyze(root):
    study = json.loads((root / "screen-study.json").read_text())
    if study["status"] not in ("succeeded", "completed_with_failures"):
        raise ValueError(f"Incomplete study: {study['status']}")
    check_frozen(root, study)
    measurements = []
    groups = defaultdict(list)
    for run in study["runs"]:
        if run["sanity_generation"]:
            continue
        tree = ET.parse(root / "runs" / run["label"] / "results.xml").getroot()
        for case in tree.findall(".//testcase"):
            props = {p.get("name"): p.get("value") for p in case.findall("./properties/property")}
            name = case.get("classname") + "." + case.get("name")
            failed = case.find("failure") is not None
            skipped = case.find("skipped") is not None or case.get("status") != "run"
            frequency = float(props["frequency"]) if "frequency" in props else None
            row = {
                "variant": run["variant"], "module": run["module"], "threads": run["threads"],
                "block": run["block"], "name": name, "params": case.get("value_param"),
                "failed": failed, "skipped": skipped,
                "median_ms": float(props["median"]) / frequency * 1000 if frequency else None,
                "mean_ms": float(props["mean"]) / frequency * 1000 if frequency else None,
                "stddev_ms": float(props["stddev"]) / frequency * 1000 if frequency else None,
                "samples": int(props["samples"]) if "samples" in props else None,
                "outliers": int(props.get("outliers", 0)),
            }
            measurements.append(row)
            groups[(run["module"], run["threads"], name)].append(row)
    expected_groups = {(module, threads, case["name"])
                       for module, cases in study["selected"].items()
                       for threads in study["threads"] for case in cases}
    if set(groups) != expected_groups:
        raise ValueError("Measured case/thread groups do not match the selected suite")
    comparisons = []
    for (module, threads, name), rows in groups.items():
        by_variant = {v: sorted([r for r in rows if r["variant"] == v], key=lambda r: r["block"])
                      for v in ("baseline", "shared", "llvm")}
        if any(len(r) != 6 or {o["block"] for o in r} != {f"b{i}" for i in range(1, 7)}
               for r in by_variant.values()):
            raise ValueError(f"Expected six distinct blocks per variant: {name}")
        if any(r["failed"] or r["skipped"] or r["median_ms"] is None for r in rows):
            comparisons.append({"module": module, "threads": threads, "name": name,
                                "valid": False, "reason": "Failure, skip or missing timing"})
            continue
        stats = {}
        for variant, observations in by_variant.items():
            times = [r["median_ms"] for r in observations]
            stats[variant] = {"median_ms": statistics.median(times), "min_ms": min(times),
                              "max_ms": max(times), "observations_ms": times}
        item = {"module": module, "threads": threads, "name": name, "params": rows[0]["params"],
                "valid": True, "timings": stats}
        baseline = stats["baseline"]["median_ms"]
        for variant in ("shared", "llvm"):
            ratio = stats[variant]["median_ms"] / baseline
            pairs = [candidate["median_ms"] / control["median_ms"]
                     for candidate, control in zip(by_variant[variant], by_variant["baseline"])]
            slower = sum(r > 1 for r in pairs)
            faster = sum(r < 1 for r in pairs)
            item[variant] = {
                "ratio_to_baseline": ratio, "change_percent": (ratio - 1) * 100,
                "paired_ratios": pairs, "slower_blocks": slower, "faster_blocks": faster,
                "tiny_case": baseline < 0.05,
                "follow_up": abs(ratio - 1) >= 0.10 and max(slower, faster) >= 5,
            }
        comparisons.append(item)
    modules = []
    for module in ("core", "imgproc", "calib3d", "features2d", "dnn"):
        for threads in study["threads"]:
            cases = [c for c in comparisons if c["module"] == module and c["threads"] == threads and c["valid"]]
            if not cases:
                continue
            row = {"module": module, "threads": threads, "cases": len(cases)}
            for variant in ("shared", "llvm"):
                ratio = math.exp(statistics.mean(math.log(c[variant]["ratio_to_baseline"]) for c in cases))
                row[variant + "_geomean_ratio"] = ratio
            modules.append(row)
    summary = {
        "status": study["status"], "selected_cases": sum(len(c) for c in study["selected"].values()),
        "placement": {"affinity_control": study.get("affinity_control", False),
                      "single_cpu": study.get("single_cpu", 0),
                      "pin_main_thread": study.get("pin_main_thread", False)},
        "measured_case_runs": len(measurements), "failed_case_runs": sum(r["failed"] for r in measurements),
        "skipped_case_runs": sum(r["skipped"] for r in measurements),
        "variant_process_wall_seconds": {
            v: sum(r["wall_seconds"] for r in study["runs"] if r["variant"] == v)
            for v in ("baseline", "shared", "llvm")},
        "module_summaries": modules, "comparisons": comparisons,
        "interpretation": "Positive change means slower than baseline. Module geometric means weight selected cases equally, not an application workload. Follow-up flags are heuristic, not significance tests or equivalence certification.",
    }
    summary["images"] = {variant: image_sections(root / variant / "opencv_world4100.dll")
                         for variant in ("baseline", "shared", "llvm")}
    summary["baseline_shared_text_identical"] = (
        summary["images"]["baseline"]["sections"][".text"] ==
        summary["images"]["shared"]["sections"][".text"])
    (root / "measurements.json").write_text(json.dumps(measurements, indent=2))
    (root / "summary.json").write_text(json.dumps(summary, indent=2))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--export", type=Path, help="Fresh public destination for text evidence only")
    args = parser.parse_args()
    summary = analyze(args.root)
    if args.export:
        args.export.mkdir(parents=True, exist_ok=False)
        files = [args.root / name for name in ("screen-study.json", "measurements.json", "summary.json")]
        files += [args.root / name for name in ("cpu-topology.json", "thread-affinity-audit.json",
                                               "provenance.json", "measured-runner.py")
                  if (args.root / name).is_file()]
        files += [args.root / variant / name
                  for variant in ("baseline", "shared", "llvm")
                  for name in ("benchmark-setup.json", "version.txt")]
        files += list((args.root / "runs").glob("*/*.xml"))
        files += list((args.root / "runs").glob("*/*.log"))
        files += list((args.root / "data" / "perf").glob("*.xml"))
        for source in files:
            target = args.export / source.relative_to(args.root)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(redact(source.read_text(encoding="utf-8-sig")), encoding="utf-8")
    print({k: summary[k] for k in ("status", "selected_cases", "measured_case_runs", "failed_case_runs",
                                  "skipped_case_runs", "variant_process_wall_seconds")})
    for row in summary["module_summaries"]:
        print(row["module"], row["threads"], "threads",
              "shared", f"{(row['shared_geomean_ratio'] - 1) * 100:+.1f}%",
              "llvm", f"{(row['llvm_geomean_ratio'] - 1) * 100:+.1f}%")
    print("FOLLOW-UP CANDIDATES:")
    for c in summary["comparisons"]:
        if c["valid"] and c["llvm"]["follow_up"]:
            print(c["module"], c["threads"], c["name"], c["params"],
                  f"llvm {c['llvm']['change_percent']:+.1f}%",
                  f"baseline={c['timings']['baseline']['median_ms']:.4f}ms",
                  f"pairs faster/slower={c['llvm']['faster_blocks']}/{c['llvm']['slower_blocks']}")


if __name__ == "__main__":
    main()
