#!/usr/bin/env python3
"""Record Owner expectations from the pinned libalpm using private temporary roots.

Only initialization, read-only queries and in-memory option/registration changes
are used. libalpm may create local/ALPM_DB_VERSION inside the temporary database.
This tool is optional and is never executed by the Zig build.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import tempfile


class List(c.Structure):
    pass


ListPtr = c.POINTER(List)
List._fields_ = [("data", c.c_void_p), ("prev", ListPtr), ("next", ListPtr)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    args = parser.parse_args()
    identity = hashlib.sha256(args.library.read_bytes()).hexdigest()
    manifest = json.loads(Path(__file__).with_name("manifest.json").read_text())
    if identity != manifest["library"]["sha256"]:
        parser.error("library does not match the frozen reference manifest")
    lib = c.CDLL(str(args.library.resolve()))

    def bind(name, result, arguments):
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = arguments
        return function

    def string_list(pointer):
        result = []
        while pointer:
            result.append(c.string_at(pointer.contents.data).decode())
            pointer = pointer.contents.next
        return result

    initialize = bind("alpm_initialize", c.c_void_p, [c.c_char_p, c.c_char_p, c.POINTER(c.c_int)])
    release = bind("alpm_release", c.c_int, [c.c_void_p])
    register = bind("alpm_register_syncdb", c.c_void_p, [c.c_void_p, c.c_char_p, c.c_int])
    get_name = bind("alpm_db_get_name", c.c_char_p, [c.c_void_p])
    get_dbs = bind("alpm_get_syncdbs", ListPtr, [c.c_void_p])
    defaults = {}
    recorded = {"schema": 1, "library_sha256": identity, "capture": "record_owner.py; isolated temporary root and database", "defaults": defaults}
    with tempfile.TemporaryDirectory(prefix="rlpm-owner-reference-") as temporary:
        root = Path(temporary, "root"); root.mkdir()
        db = Path(temporary, "db"); db.mkdir()
        error = c.c_int()
        handle = initialize(str(root).encode(), str(db).encode(), c.byref(error))
        if not handle:
            raise RuntimeError(f"initialization failed: {error.value}")
        try:
            for name in ("parallel_downloads", "checkspace", "usesyslog", "disable_dl_timeout", "default_siglevel", "local_file_siglevel", "remote_file_siglevel"):
                defaults[name] = bind("alpm_option_get_" + name, c.c_int, [c.c_void_p])(handle)
            for name in ("root", "dbpath", "lockfile", "dbext", "gpgdir", "logfile", "sandboxuser"):
                value = bind("alpm_option_get_" + name, c.c_char_p, [c.c_void_p])(handle)
                defaults[name] = value.decode().replace(str(root), "$ROOT").replace(str(db), "$DB") if value is not None else None
            for name in ("cachedirs", "hookdirs", "architectures", "ignorepkgs", "ignoregroups", "noupgrades", "noextracts", "overwrite_files"):
                values = string_list(bind("alpm_option_get_" + name, ListPtr, [c.c_void_p])(handle))
                defaults[name] = [value.replace(str(root), "$ROOT") for value in values]
            core = register(handle, b"core", 1 << 30)
            assert core and register(handle, b"cachyos", 1 << 30)
            names = []
            pointer = get_dbs(handle)
            while pointer:
                names.append(get_name(pointer.contents.data).decode())
                pointer = pointer.contents.next
            recorded["repository_order"] = names
            recorded["rejected_registration_names"] = []
            for name in ("core", "local", "", "path/repo"):
                assert not register(handle, name.encode(), 1 << 30)
                recorded["rejected_registration_names"].append(name)
            add_server = bind("alpm_db_add_server", c.c_int, [c.c_void_p, c.c_char_p])
            for url in (b"https://first.invalid/core/", b"https://second.invalid/core//"):
                assert add_server(core, url) == 0
            recorded["servers_after_add"] = string_list(bind("alpm_db_get_servers", ListPtr, [c.c_void_p])(core))
            controls = ("disable_sandbox_filesystem", "disable_sandbox_syscalls", "disable_sandbox_network")
            setters = {name: bind("alpm_option_set_" + name, c.c_int, [c.c_void_p, c.c_ushort]) for name in controls}
            getters = {name: bind("alpm_option_get_" + name, c.c_int, [c.c_void_p]) for name in controls}
            recorded["sandbox_note"] = "The deprecated aggregate get/set functions are declared in the header but not exported by this binary. Global semantics are source-derived; the independent controls below were executed."
            recorded["sandbox"] = []
            for option, value in (("all", 1), ("network", 0), ("all", 0)):
                for name in controls if option == "all" else ("disable_sandbox_network",):
                    assert setters[name](handle, value) == 0
                recorded["sandbox"].append({"set": option, "value": bool(value), **{name: bool(fn(handle)) for name, fn in getters.items()}})
            recorded["initialization_creates_local_version_file"] = (db / "local/ALPM_DB_VERSION").exists()
        finally:
            assert release(handle) == 0
    print(json.dumps(recorded, indent=2))


if __name__ == "__main__":
    main()
