"""Inventory investigation-owned files without following filesystem links."""

import json
import os
from pathlib import Path
import shutil
import stat


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


def inventory(repo):
    totals, links = tree_usage(repo)
    entries = []
    for path, size in totals.items():
        relative = path.relative_to(repo)
        if len(relative.parts) <= 1 or (
            relative.parts[0] in (".work", ".tools") and len(relative.parts) <= 3
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
    repo = Path(__file__).resolve().parent.parent
    expected = Path(
        r"D:\action-runner-OpenCV\_work\OpenCV-perf-tests\OpenCV-perf-tests"
    )
    if os.environ.get("RUNNER_NAME", "").upper() != "MARCPE-D4" or repo != expected:
        raise RuntimeError("Expected the dedicated MARCPE-D4 benchmark checkout")
    result = inventory(repo)
    output = repo / ".work" / f"maintenance-{os.environ['GITHUB_RUN_ID']}.json"
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
