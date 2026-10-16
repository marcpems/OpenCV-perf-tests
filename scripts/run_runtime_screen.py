"""Bounded, same-harness comparison of preserved Windows ARM64 OpenCV DLLs."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

MODULES = ("core", "imgproc", "calib3d", "features2d", "dnn")
VARIANTS = ("baseline", "shared", "llvm")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def catalog(text):
    suite = None
    rows = []
    for line in text.splitlines():
        if re.match(r"^\w.*\.$", line):
            suite = line[:-1]
        elif suite and line.startswith("  ") and "# GetParam() = " in line:
            name, params = line.strip().split("  # GetParam() = ", 1)
            rows.append({"name": suite + "." + name, "params": params})
    return rows


def choose(all_cases):
    chosen = {module: [] for module in MODULES}

    def exact(module, name):
        matches = [r for r in all_cases[module] if r["name"] == name]
        if len(matches) != 1:
            raise ValueError(f"Expected one case: {module} {name}: {matches}")
        if matches[0] not in chosen[module]:
            chosen[module].append(matches[0])

    def match(module, family, params):
        matches = [r for r in all_cases[module] if r["name"].startswith(family + "/")
                   and r["params"] == params]
        if len(matches) != 1:
            raise ValueError(f"Expected one parameter combination: {family} {params}")
        exact(module, matches[0]["name"])

    for op in ("add", "multiply", "absdiff"):
        for params in ("(640x480, 8UC1)", "(1280x720, 32FC1)", "(1920x1080, 8UC3)"):
            match("core", f"BinaryOpTest.{op}", params)
    for index in (1, 37):
        exact("core", f"Size_MatType_FlagsType_NzeroRows_dft.dft/{index}")
    for params in ("(640x480, 8UC1, NORM_L2)", "(1920x1080, 32FC1, NORM_L2)"):
        match("core", "Size_MatType_NormType_norm.norm", params)
    for kind in ("32f", "64f"):
        exact("core", f"VectorLength_phase{kind}.phase{kind}/2")
        exact("core", f"VectorLength_phase{kind}.phase{kind}/4")
    for index in (0, 4):
        exact("core", f"SvdTest_decompose.decompose/{index}")
    for index in (2, 6):
        exact("imgproc", f"MatInfo_Size_Size_resizeUpLinear.resizeUpLinear/{index}")
    for index in (4, 5, 16, 17):
        exact("imgproc", f"MatInfo_SizePair_resizeUpLinearNonExact.resizeUpLinearNonExact/{index}")
    for size in ("640x480", "1280x720"):
        match("imgproc", "Size_MatType_BorderType_gaussianBlur5x5.gaussianBlur5x5",
              f"({size}, 8UC1, BORDER_REFLECT101)")
    for size in ("640x480", "1920x1080"):
        for mode in ("COLOR_BGR2GRAY", "COLOR_BGR2HSV"):
            match("imgproc", "Size_CvtMode_cvtColor8u.cvtColor8u", f"({size}, {mode})")
    for index in (2, 3, 8, 9):
        exact("imgproc", f"Size_MatType_erode.erode/{index}")
    for index in (0, 1, 8, 9):
        exact("calib3d", f"PointsNum_Algo_solvePnP.solvePnP/{index}")
    exact("calib3d", "PointsNum_Algo_solvePnPSmallPoints.solvePnPSmallPoints/0")
    for index in (0, 1):
        exact("features2d", f"Norm_CrossCheck_batchDistance_Dest_32S.batchDistance_Dest_32S/{index}")
    for index in (2, 3):
        exact("features2d", f"Source_CrossCheck_batchDistance_L2.batchDistance_L2/{index}")
    for family, indices in (("Conv", (37, 47)), ("Conv_1x1", (0, 2)),
                            ("Conv_3x3S1D1", (0, 1)), ("Conv_Depthwise", (2, 3))):
        for index in indices:
            exact("dnn", f"{family}.conv/{index}")
    return chosen


def prepare(root, deadline, affinity, single_cpu, pin_main):
    if (root / "screen-study.json").exists():
        raise FileExistsError("Study already prepared")
    all_cases = {}
    for module in MODULES:
        source = root / "harness" / f"screen_{module}.exe"
        for variant in VARIANTS:
            shutil.copy2(source, root / variant / source.name)
        all_cases[module] = catalog((root / f"list_{module}.txt").read_text(encoding="utf-8-sig"))
    selected = choose(all_cases)
    for variant in VARIANTS:
        image = (root / variant / "opencv_world4100.dll").read_bytes()
        pe = int.from_bytes(image[60:64], "little")
        assert image[pe:pe + 4] == b"PE\0\0"
        assert int.from_bytes(image[pe + 4:pe + 6], "little") == 0xAA64
    frozen = {str(p.relative_to(root)): digest(p) for variant in VARIANTS
              for p in (root / variant).iterdir() if p.suffix in (".exe", ".dll", ".lib")}
    (root / "data" / "perf").mkdir(parents=True)
    study = {
        "status": "prepared", "started_at": dt.datetime.now().astimezone().isoformat(),
        "deadline": deadline, "variant_budget_seconds": 1800,
        "affinity_control": affinity,
        "single_cpu": single_cpu, "pin_main_thread": pin_main,
        "samples": 10, "threads": [1, 12], "selected": selected,
        "frozen_sha256": frozen, "runs": [],
        "notes": [
            "Same MSVC-built upstream test executables for all DLLs; measures library runtime, not differently compiled harnesses.",
            "Baseline and LLVM reused; shared-cap rebuilt because its earlier output was overwritten by baseline.",
            "Baseline-generated sanity records are a differential screen, not independent correctness proof.",
            "DNN upstream convolution tests use SANITY_CHECK_NOTHING; no inference-output equivalence claim.",
            "No model downloads, importer/startup, ORB, video I/O, GPU or DLS-internal runtime coverage.",
        ],
    }
    save(root, study)
    print("Selected", {m: len(c) for m, c in selected.items()})


def save(root, study):
    (root / "screen-study.json").write_text(json.dumps(study, indent=2))


def check_frozen(root, study):
    for relative, expected in study["frozen_sha256"].items():
        if digest(root / relative) != expected:
            raise RuntimeError(f"Frozen binary changed: {relative}")


def validate_cases(cases, selected, exit_code):
    names = {case.get("classname", "") + "." + case.get("name", "") for case in cases}
    if len(cases) != len(selected) or names != {case["name"] for case in selected}:
        raise RuntimeError("Executed cases differ from the selected suite")
    failures = sum(case.find("failure") is not None for case in cases)
    skips = sum(case.find("skipped") is not None or case.get("status") != "run" for case in cases)
    if exit_code not in (0, 1) or (exit_code == 1 and not failures):
        raise RuntimeError(f"Unexpected process exit {exit_code}")
    return failures, skips


def run_one(root, study, variant, module, threads, block, sanity=False):
    remaining = (dt.datetime.fromisoformat(study["deadline"]) -
                 dt.datetime.now().astimezone()).total_seconds()
    spent = sum(r["wall_seconds"] for r in study["runs"] if r["variant"] == variant)
    budget = min(study["variant_budget_seconds"] - spent, remaining)
    if budget < 10:
        raise TimeoutError("Study deadline or per-variant budget exhausted")
    label = f"{block}_{variant}_{threads}t_{module}"
    run_dir = root / "runs" / label
    run_dir.mkdir(parents=True)
    xml = run_dir / "results.xml"
    command = [str(root / variant / f"screen_{module}.exe"),
               "--gtest_filter=" + ":".join(r["name"] for r in study["selected"][module]),
               f"--perf_threads={threads}", f"--perf_min_samples={study['samples']}",
               f"--perf_force_samples={study['samples']}",
               "--perf_seed=809564", "--perf_strategy=simple",
               f"--gtest_output=xml:{xml}"]
    command.append("--perf_write_sanity=true" if sanity else "--perf_verify_sanity=true")
    env = os.environ.copy()
    env["OPENCV_TEST_DATA_PATH"] = str(root / "data")
    env["OPENCV_TEST_REQUIRE_DATA"] = "1"
    if study.get("affinity_control"):
        env["RUNTIME_AFFINITY"] = str(1 << study.get("single_cpu", 0)) if threads == 1 else "4095"
    else:
        env.pop("RUNTIME_AFFINITY", None)
    if study.get("pin_main_thread"):
        env["RUNTIME_MAIN_AFFINITY"] = str(1 << study["single_cpu"])
    else:
        env.pop("RUNTIME_MAIN_AFFINITY", None)
    started = dt.datetime.now().astimezone().isoformat()
    start = time.perf_counter()
    with (run_dir / "output.log").open("w", encoding="utf-8") as log:
        try:
            result = subprocess.run(command, cwd=run_dir, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=min(180, budget))
            exit_code = result.returncode
            timed_out = False
        except subprocess.TimeoutExpired:
            exit_code = None
            timed_out = True
    row = {"label": label, "variant": variant, "module": module, "threads": threads,
           "block": block, "sanity_generation": sanity, "started_at": started,
           "wall_seconds": time.perf_counter() - start, "exit_code": exit_code,
           "timed_out": timed_out, "command": command}
    study["runs"].append(row)
    save(root, study)
    if timed_out:
        raise TimeoutError(f"Timed out: {label}")
    output = (run_dir / "output.log").read_text()
    expected_dll = str(root / variant / "opencv_world4100.dll")
    if f"RUNTIME_DLL={expected_dll}" not in output or "RUNTIME_NATIVE_ARM64=1" not in output:
        raise RuntimeError(f"Loaded DLL/native audit failed: {label}")
    if f"RUNTIME_THREADS={threads}\n" not in output:
        raise RuntimeError(f"Thread-count audit failed: {label}")
    if study.get("affinity_control"):
        mask = 1 << study.get("single_cpu", 0) if threads == 1 else 4095
        if f"RUNTIME_AFFINITY={mask}\n" not in output or "RUNTIME_CPU_WARMUP=1\n" not in output:
            raise RuntimeError(f"Affinity/warm-up audit failed: {label}")
    if study.get("pin_main_thread"):
        if f"RUNTIME_MAIN_AFFINITY={1 << study['single_cpu']}\n" not in output:
            raise RuntimeError(f"Main-thread affinity audit failed: {label}")
    if not xml.exists():
        raise RuntimeError(f"No test results: {label}, exit {exit_code}")
    cases = ET.parse(xml).getroot().findall(".//testcase")
    row["failures"], row["skips"] = validate_cases(cases, study["selected"][module], exit_code)
    save(root, study)
    print(label, f"{row['wall_seconds']:.2f}s", f"failures={row['failures']} skips={row['skips']}", flush=True)


def execute(root, pilot):
    study = json.loads((root / "screen-study.json").read_text())
    expected_status = "prepared" if pilot else "pilot_complete"
    if study["status"] != expected_status:
        raise RuntimeError(f"Expected {expected_status}, found {study['status']}")
    check_frozen(root, study)
    study["status"] = "running"
    save(root, study)
    if pilot:
        for module in MODULES:
            run_one(root, study, "baseline", module, 1, "sanity", sanity=True)
        if any(r["failures"] or r["skips"] for r in study["runs"]):
            study["status"] = "pilot_failed"
            save(root, study)
            raise RuntimeError("Baseline sanity pilot contains failures or skips")
        study["sanity_sha256"] = {str(p.relative_to(root)): digest(p) for p in (root / "data").rglob("*.xml")}
        study["status"] = "pilot_complete"
    else:
        if not study.get("sanity_sha256"):
            raise RuntimeError("Generate and inspect baseline sanity data first")
        # Each variant occupies every order position twice across forward/reverse rotations.
        orders = [("baseline", "shared", "llvm"), ("shared", "llvm", "baseline"),
                  ("llvm", "baseline", "shared"), ("llvm", "shared", "baseline"),
                  ("baseline", "llvm", "shared"), ("shared", "baseline", "llvm")]
        study["samples"] = 20
        study["measurement_protocol"] = {
            "variant_orders": orders, "samples_per_case": 20,
            "thread_order_alternates": True, "rest_seconds_between_variants": 5,
            "runner_sha256": digest(Path(__file__)),
        }
        save(root, study)
        for block, order in enumerate(orders, 1):
            for variant in order:
                check_frozen(root, study)
                for threads in ((1, 12) if block % 2 else (12, 1)):
                    for module in MODULES:
                        run_one(root, study, variant, module, threads, f"b{block}")
                remaining = (dt.datetime.fromisoformat(study["deadline"]) -
                             dt.datetime.now().astimezone()).total_seconds()
                time.sleep(min(5, max(0, remaining)))
        for relative, expected in study["sanity_sha256"].items():
            if digest(root / relative) != expected:
                raise RuntimeError("Sanity reference changed during comparison")
        study["status"] = "completed_with_failures" if any(r.get("failures") or r.get("skips") for r in study["runs"]) else "succeeded"
    study["finished_at"] = dt.datetime.now().astimezone().isoformat()
    save(root, study)
    if study["status"] == "completed_with_failures":
        raise RuntimeError("Runtime screen completed with failures or skips; inspect recorded results")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("mode", choices=("prepare", "pilot", "run"))
    parser.add_argument("--deadline", help="Required for prepare: absolute ISO timestamp with UTC offset")
    parser.add_argument("--affinity", action="store_true", help="Pin 1-thread runs to --single-cpu, 12-thread runs to CPUs 0-11")
    parser.add_argument("--single-cpu", type=int, choices=range(12), default=0)
    parser.add_argument("--pin-main", action="store_true", help="Pin main thread after worker warm-up to --single-cpu")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.mode == "prepare":
        if not args.deadline or dt.datetime.fromisoformat(args.deadline).tzinfo is None:
            parser.error("prepare requires an absolute --deadline with timezone")
        if args.pin_main and not args.affinity:
            parser.error("--pin-main requires --affinity")
        prepare(root, args.deadline, args.affinity, args.single_cpu, args.pin_main)
    else:
        execute(root, args.mode == "pilot")


if __name__ == "__main__":
    main()
