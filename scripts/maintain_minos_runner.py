"""Inventory and explicitly retire fixed, investigation-owned build artifacts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess


TARGETS = (
    r".work\minos-source\build_hobl_msvc",
    r".work\minos-source\build_hobl_ninja",
    r".work\minos-source\build_hobl_clang_ninja",
    r".work\llvm-custom-39109264613\stock-source\build_hobl_clang_ninja",
    r".work\llvm-custom-39109264613\custom-source\build_hobl_clang_ninja",
    r".work\llvm-custom-39129486630\stock-source\build_hobl_clang_ninja",
    r".work\llvm-custom-39129486630\custom-source\build_hobl_clang_ninja",
    r".tools\llvm-custom-39109264613",
    r".tools\clang+llvm-23.1.3-aarch64-pc-windows-msvc.tar.zst",
    r".tools\cmake-4.1.1-windows-arm64.zip",
    r".tools\vs2022-arm64-prerequisite.exe",
)
PRESERVED = (
    "results",
    r".work\minos-study-38914616842",
    r".work\minos-runtime-38914616842",
    r".work\minos-runtime-diagnostic-38920209565",
    r".work\minos-first-38913335754",
    r".work\llvm-custom-39129486630\measurements",
    r".work\llvm-custom-39129486630\warmups",
    r".tools\clang+llvm-23.1.3-aarch64-pc-windows-msvc",
    r".tools\llvm-custom-39129486630",
    r".tools\cmake-4.1.1-windows-arm64",
)
INSTALLER = Path(r"D:\LLVM\LLVM-24.0.0-woa64_PGO_LTO.msi")
INSTALLER_SHA256 = "d02e9de11b93324340851191f758db182c8acee5235c820afce7a66b30caff36"


def tree_usage(root):
    totals = {}
    links = []
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=raise_error):
        path = Path(directory)
        for name in list(dirs):
            child = path / name
            if is_link(child):
                links.append(str(child.relative_to(root)))
                dirs.remove(name)
        size = 0
        for name in files:
            child = path / name
            if is_link(child):
                links.append(str(child.relative_to(root)))
            else:
                size += child.stat().st_size
        totals[path] = size
    for path in sorted(totals, key=lambda p: len(p.parts), reverse=True):
        if path != root:
            totals[path.parent] += totals[path]
    return totals, links


def raise_error(error):
    raise error


def is_link(path):
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def checked_target(repo, relative):
    if relative not in TARGETS:
        raise ValueError(f"Not an approved cleanup target: {relative}")
    path = repo / relative
    if not path.is_relative_to(repo) or path == repo:
        raise ValueError("Cleanup target must be below the checkout")
    current = repo
    for part in path.relative_to(repo).parts:
        current = current / part
        if current.exists() or current.is_symlink():
            if is_link(current):
                raise ValueError(f"Refusing filesystem link: {current}")
    if path.exists() and path.is_dir():
        if (path / ".git").exists():
            raise ValueError(f"Refusing repository root: {path}")
        _, links = tree_usage(path)
        if links:
            raise ValueError(f"Refusing linked contents in {path}: {links}")
    return path


def fingerprint(path, content=False):
    digest = hashlib.sha256()
    paths = [path] if path.is_file() else sorted(
        p for p in path.rglob("*") if p.is_file()
    )
    size = 0
    for entry in paths:
        info = entry.stat()
        size += info.st_size
        digest.update(str(entry.relative_to(path.parent)).encode("utf-8"))
        digest.update(f"\0{info.st_size}\0{info.st_mtime_ns}\0".encode())
        if content:
            with entry.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
    return {"bytes": size, "files": len(paths), "sha256": digest.hexdigest()}


def cleanup_plan(repo):
    plan = []
    tracked = subprocess.check_output(
        ["git", "-C", str(repo), "ls-files", "-z"]
    ).decode().split("\0")
    for relative in TARGETS:
        path = checked_target(repo, relative)
        prefix = relative.replace("\\", "/")
        if any(p == prefix or p.startswith(prefix + "/") for p in tracked):
            raise RuntimeError(f"Refusing tracked files: {relative}")
        plan.append({
            "path": relative,
            "exists": path.exists(),
            **(fingerprint(path) if path.exists() else {}),
        })
    digest = hashlib.sha256(
        json.dumps(plan, sort_keys=True).encode("utf-8")
    ).hexdigest()
    return {"targets": plan, "sha256": digest}


def protected_fingerprints(repo):
    result = {}
    for relative in PRESERVED:
        path = repo / relative
        if not path.is_dir() or is_link(path):
            raise RuntimeError(f"Missing preserved directory: {relative}")
        _, links = tree_usage(path)
        if links:
            raise RuntimeError(f"Links in preserved directory: {relative}")
        result[relative] = fingerprint(path, content=True)
    with INSTALLER.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != INSTALLER_SHA256:
        raise RuntimeError("Original custom MSI missing or changed")
    result["original_custom_msi_sha256"] = digest.hexdigest()
    return result


def apply_plan(repo, result, approved_sha256, output):
    if approved_sha256 != result["plan"]["sha256"]:
        raise RuntimeError("Cleanup plan changed or was not approved; inventory again")
    before = protected_fingerprints(repo)
    for entry in result["plan"]["targets"]:
        path = checked_target(repo, entry["path"])
        if not entry["exists"]:
            continue
        if fingerprint(path) != {
            key: entry[key] for key in ("bytes", "files", "sha256")
        }:
            raise RuntimeError(f"Target changed since preflight: {entry['path']}")
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        if path.exists():
            raise RuntimeError(f"Target remains after cleanup: {entry['path']}")
        result["deleted"].append(entry)
        output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    after = protected_fingerprints(repo)
    if before != after:
        raise RuntimeError("Preserved evidence or toolchain changed during cleanup")
    result["preserved_verified"] = after


def inventory(repo):
    totals, links = tree_usage(repo)
    entries = []
    for path, size in totals.items():
        relative = path.relative_to(repo)
        if len(relative.parts) <= 1 or (
            relative.parts[0] in (".work", ".tools") and len(relative.parts) <= 3
        ) or (
            path.name.startswith("build_hobl_") and len(relative.parts) == 4
        ):
            entries.append({"path": str(relative), "bytes": size})
    for folder in (repo / ".tools", repo / ".work"):
        if folder.exists():
            entries.extend(
                {"path": str(p.relative_to(repo)), "bytes": p.stat().st_size}
                for p in folder.iterdir() if p.is_file() and not is_link(p)
            )
    return {
        "disk": shutil.disk_usage(repo)._asdict(),
        "directories_and_top_level_files": sorted(
            entries, key=lambda entry: entry["bytes"], reverse=True
        ),
        "skipped_links": links,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--approved-plan-sha256", default="")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    expected = Path(
        r"D:\action-runner-OpenCV\_work\OpenCV-perf-tests\OpenCV-perf-tests"
    )
    if os.environ.get("RUNNER_NAME", "").upper() != "MARCPE-D4" or repo != expected:
        raise RuntimeError("Expected the dedicated MARCPE-D4 benchmark checkout")
    result = {"before": inventory(repo), "plan": cleanup_plan(repo), "deleted": []}
    output = repo / ".work" / f"maintenance-{os.environ['GITHUB_RUN_ID']}.json"
    try:
        if args.apply:
            apply_plan(repo, result, args.approved_plan_sha256, output)
            result["after"] = inventory(repo)
            result["free_bytes_gained"] = (
                result["after"]["disk"]["free"] - result["before"]["disk"]["free"]
            )
        result["status"] = "cleaned" if args.apply else "inventory_only"
    except Exception as error:
        result["status"] = "failed"
        result["error"] = str(error)
        raise
    finally:
        output.write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
