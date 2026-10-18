"""Require matched generated features and compile commands before comparing LLVM packages."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def normalized_commands(commands, source, tools):
    result = []
    for item in commands:
        if not re.search(r"\.(?:c|cc|cpp|cxx|s)$", item["file"], re.IGNORECASE):
            continue
        values = []
        for field in ("file", "output", "command"):
            value = item[field].replace("\\", "/")
            value = value.replace(str(source).replace("\\", "/"), "<SOURCE>")
            value = value.replace(str(tools).replace("\\", "/"), "<LLVM>")
            values.append(value.replace('"', "").strip())
        result.append(tuple(values))
    if not result:
        raise ValueError("No source compilation commands found")
    return sorted(result)


def compare(stock, custom):
    entries = []
    for root in (stock, custom):
        build = root / "build_hobl_clang_ninja"
        receipt = json.loads((build / "benchmark-setup.json").read_text(encoding="utf-8-sig"))
        commands = json.loads((build / "comparison-commands.json").read_text(encoding="utf-8-sig"))
        entries.append(normalized_commands(commands, root, receipt["llvm"]["root"]))
    if entries[0] != entries[1]:
        only_stock = sorted(set(entries[0]) - set(entries[1]))
        only_custom = sorted(set(entries[1]) - set(entries[0]))
        raise ValueError(f"Compile inputs/flags differ: stock={only_stock[:2]}, custom={only_custom[:2]}")
    headers = {}
    for name in ("cvconfig.h", "opencv2/opencv_modules.hpp"):
        hashes = [hashlib.sha256((root / "build_hobl_clang_ninja" / name).read_bytes()).hexdigest()
                  for root in (stock, custom)]
        if hashes[0] != hashes[1]:
            raise ValueError(f"Generated features differ: {name}")
        headers[name] = hashes[0]
    return {"source_compilations": len(entries[0]), "normalized_commands_equal": True,
            "feature_headers_sha256": headers,
            "caveat": "Identical requested flags do not guarantee identical semantics across compiler versions."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stock", type=Path)
    parser.add_argument("custom", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compare(args.stock, args.custom)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
