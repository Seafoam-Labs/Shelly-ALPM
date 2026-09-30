#!/usr/bin/env python3
"""Opt-in, read-only libalpm identity capture. Never imported by the Zig build."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path


def file_identity(path):
    return {"file": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--alpm-header", required=True, type=Path)
    parser.add_argument("--list-header", required=True, type=Path)
    args = parser.parse_args()
    library_path = args.library.resolve(strict=True)
    library = ctypes.CDLL(str(library_path))
    library.alpm_version.argtypes = []
    library.alpm_version.restype = ctypes.c_char_p
    library.alpm_capabilities.argtypes = []
    library.alpm_capabilities.restype = ctypes.c_int
    result = {
        "library": {
            **file_identity(library_path),
            "version": library.alpm_version().decode("ascii"),
            "capability_mask": library.alpm_capabilities(),
        },
        "alpm_header": file_identity(args.alpm_header),
        "list_header": file_identity(args.list_header),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
