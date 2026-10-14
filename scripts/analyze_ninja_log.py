"""Analyze one fresh Ninja v5/v6 log. Step elapsed time is NOT CPU time."""

import argparse
from collections import Counter
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import statistics


@dataclass
class Step:
    start_ms: int
    end_ms: int
    outputs: list[str] = field(default_factory=list)

    @property
    def seconds(self):
        return (self.end_ms - self.start_ms) / 1000

    @property
    def kind(self):
        if any(o.endswith((".obj", ".o")) for o in self.outputs):
            return "compile"
        if any(o.endswith((".dll", ".exe", ".lib")) for o in self.outputs):
            return "link/lib"
        return "other"

    @property
    def component(self):
        for output in self.outputs:
            match = re.search(r"modules/world/.*?/__/([^/]+)/", output)
            if match:
                return "opencv/" + match[1]
        match = re.match(r"(3rdparty/[^/]+|apps/[^/]+|modules/[^/]+)", self.outputs[0])
        return match[1] if match else "link/generated"


def parse_log(path):
    """Deduplicate multi-output commands using their timing and command hash.

    The runner removes historical .ninja_log before each build. Refuse appended
    runs (decreasing completion times), rather than treating them as one build.
    """
    steps = {}
    previous_end = -1
    with Path(path).open(encoding="utf-8-sig") as stream:
        if stream.readline().strip() not in ("# ninja log v5", "# ninja log v6"):
            raise ValueError("Expected a fresh Ninja v5 or v6 log")
        for number, line in enumerate(stream, start=2):
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 5:
                raise ValueError(f"Malformed Ninja row {number}")
            start, end = int(parts[0]), int(parts[1])
            if start < 0 or end < start:
                raise ValueError(f"Invalid timing on row {number}")
            if end < previous_end:
                raise ValueError("Historical/reordered log: use a fresh single-build log")
            previous_end = end
            key = (start, end, parts[4])
            step = steps.setdefault(key, Step(start, end))
            output = parts[3].replace("\\", "/")
            if output not in step.outputs:
                step.outputs.append(output)
    if not steps:
        raise ValueError("Ninja log contains no completed steps")
    return list(steps.values())


def summarize(steps):
    span = (max(s.end_ms for s in steps) - min(s.start_ms for s in steps)) / 1000
    if span <= 0:
        raise ValueError("No positive measured build interval")
    elapsed = sum(s.seconds for s in steps)
    components, kinds = Counter(), Counter()
    for step in steps:
        components[step.component] += step.seconds
        kinds[step.kind] += step.seconds
    compiles = [s for s in steps if s.kind == "compile"]
    if not compiles:
        raise ValueError("No compile steps: this is not a clean build log")
    finish_tail = (max(s.end_ms for s in steps) - max(s.end_ms for s in compiles)) / 1000
    return {
        "unique_steps": len(steps),
        "compile_steps": len(compiles),
        "log_span_seconds": round(span, 3),
        "summed_step_elapsed_seconds": round(elapsed, 3),
        "mean_concurrent_steps": round(elapsed / span, 3),
        "finish_tail_seconds": round(finish_tail, 3),
        "median_compile_elapsed_seconds": round(statistics.median(s.seconds for s in compiles), 3),
        "by_kind_elapsed_seconds": dict(kinds.most_common()),
        "by_component_elapsed_seconds": dict(components.most_common()),
        "slowest_steps": [
            {"seconds": s.seconds, "outputs": s.outputs, "start_seconds": s.start_ms / 1000}
            for s in sorted(steps, key=lambda s: s.seconds, reverse=True)[:20]
        ],
        "link_steps": [
            {"seconds": s.seconds, "outputs": s.outputs, "start_seconds": s.start_ms / 1000}
            for s in sorted(steps, key=lambda s: s.seconds, reverse=True) if s.kind == "link/lib"
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = summarize(parse_log(args.log))
    if args.json:
        print(json.dumps(result, indent=2))
        return
    print("Summed step elapsed time includes overlap/waiting; it is NOT CPU time.")
    for name in ("unique_steps", "compile_steps", "log_span_seconds",
                 "summed_step_elapsed_seconds", "mean_concurrent_steps", "finish_tail_seconds"):
        print(f"{name}: {result[name]}")
    total = result["summed_step_elapsed_seconds"]
    for section in ("by_kind_elapsed_seconds", "by_component_elapsed_seconds"):
        print(f"\n{section}:")
        for name, seconds in result[section].items():
            print(f"  {name:35s} {seconds:8.2f}s  {100 * seconds / total:5.1f}%")
    print("\nSlowest steps:")
    for step in result["slowest_steps"]:
        print(f"  {step['seconds']:6.2f}s  {'; '.join(step['outputs'])}")


if __name__ == "__main__":
    main()
