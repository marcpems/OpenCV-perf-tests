"""Read Windows CPU-set topology and select a reproducible group-0 main CPU."""
import argparse
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import struct


def parse_cpu_sets(data):
    records = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError("Truncated CPU-set header")
        size, kind = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid CPU-set record size")
        if kind == 0:
            if size < 32:
                raise ValueError("Truncated CPU-set information")
            values = struct.unpack_from("<IHBBBBBB", data, offset + 8)
            records.append(dict(zip(
                ("cpu_set_id", "group", "logical_cpu", "core", "llc", "numa",
                 "efficiency_class", "flags"), values)))
        offset += size
    if not records:
        raise ValueError("No CPU-set information returned")
    return records


def select_main_cpu(records, count):
    if any(r["group"] != 0 for r in records):
        raise ValueError("This runtime protocol supports one processor group only")
    if sorted(r["logical_cpu"] for r in records) != list(range(count)):
        raise ValueError("Expected a contiguous processor set matching the parallel limit")
    best_class = max(r["efficiency_class"] for r in records)
    return min(r["logical_cpu"] for r in records if r["efficiency_class"] == best_class)


def read_cpu_sets():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    query = kernel.GetSystemCpuSetInformation
    query.argtypes = [ctypes.c_void_p, wintypes.ULONG, ctypes.POINTER(wintypes.ULONG),
                      wintypes.HANDLE, wintypes.ULONG]
    query.restype = wintypes.BOOL
    needed = wintypes.ULONG()
    ok = query(None, 0, ctypes.byref(needed), None, 0)
    if not ok and ctypes.get_last_error() != 122:
        raise ctypes.WinError(ctypes.get_last_error())
    if needed.value == 0:
        raise RuntimeError("CPU-set query returned no buffer size")
    buffer = ctypes.create_string_buffer(needed.value)
    if not query(buffer, len(buffer), ctypes.byref(needed), None, 0):
        raise ctypes.WinError(ctypes.get_last_error())
    return parse_cpu_sets(buffer.raw[:needed.value])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--cpus", type=int, required=True)
    args = parser.parse_args()
    records = read_cpu_sets()
    cpu = select_main_cpu(records, args.cpus)
    args.output.write_text(json.dumps(records, indent=2), encoding="utf-8")
    print(cpu)


if __name__ == "__main__":
    main()
