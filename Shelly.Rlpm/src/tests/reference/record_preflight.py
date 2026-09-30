#!/usr/bin/env python3
"""Preflight oracle: inert generated packages in private disposable roots only.
Native commit is required to observe its private preflight/backup routines.
Hooks/scriptlets are disabled; packages contain only conf and root metadata.
"""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
from pathlib import Path
import sys
import tarfile
import tempfile
sys.dont_write_bytecode = True
from record_metadata import ListPtr
HERE = Path(__file__).parent

CASES = [
    dict(name='backup-unmodified', old='old', local='old', new='new', backup=True),
    dict(name='backup-local-edited', old='old', local='edited', new='old', backup=True),
    dict(name='backup-all-differ', old='old', local='edited', new='new', backup=True),
    dict(name='backup-local-equals-new', old='old', local='new', new='new', backup=True),
    dict(name='noupgrade-identical', old='old', local='old', new='old', backup=True, noupgrade=['conf']),
    dict(name='noupgrade-missing', old='old', new='new', backup=True, noupgrade=['conf']),
    dict(name='backup-removed-from-list', old='old', local='edited', new='new', oldbackup=True),
    dict(name='unowned', local='local', new='new'),
    dict(name='unowned-backup', local='local', new='new', backup=True),
    dict(name='overwrite', local='local', new='new', overwrite=['conf']),
    dict(name='overwrite-negated', local='local', new='new', overwrite=['*', '!conf']),
    dict(name='noextract-conflict', local='local', new='new', noextract=['conf'], noconflicts=True),
    dict(name='noextract', new='new', noextract=['conf']),
    dict(name='noextract-negated', new='new', noextract=['*', '!conf']),
    dict(name='preserve-existing-pacnew', old='old', local='edited', new='old', backup=True, pacnew='prior'),
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    args = parser.parse_args()
    sha = hashlib.sha256(args.library.read_bytes()).hexdigest()
    if sha != json.loads((HERE / 'manifest.json').read_text())['library']['sha256']:
        parser.error('library does not match frozen reference')
    locale.setlocale(locale.LC_ALL, 'C')
    lib = c.CDLL(str(args.library.resolve()))
    def bind(name, result, *params):
        fn = getattr(lib, name); fn.restype = result; fn.argtypes = list(params); return fn
    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    init = bind('alpm_trans_init', c.c_int, c.c_void_p, c.c_int)
    flags = bind('alpm_trans_get_flags', c.c_int, c.c_void_p)
    load = bind('alpm_pkg_load', c.c_int, c.c_void_p, c.c_char_p, c.c_int, c.c_int, c.POINTER(c.c_void_p))
    add = bind('alpm_add_pkg', c.c_int, c.c_void_p, c.c_void_p)
    prepare = bind('alpm_trans_prepare', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    commit = bind('alpm_trans_commit', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    finish = bind('alpm_trans_release', c.c_int, c.c_void_p)
    getroot = bind('alpm_option_get_root', c.c_char_p, c.c_void_p)
    getdb = bind('alpm_option_get_dbpath', c.c_char_p, c.c_void_p)
    strerror = bind('alpm_strerror', c.c_char_p, c.c_int)
    errno = bind('alpm_errno', c.c_int, c.c_void_p)
    rows = []
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix='rlpm-preflight-oracle-') as temp:
            base = Path(temp).resolve(); root = base / 'root'; db = base / 'db'
            root.mkdir(); (db / 'local').mkdir(parents=True)
            (db / 'local/ALPM_DB_VERSION').write_text('9\n')
            if 'old' in case:
                local = db / 'local/demo-1-1'; local.mkdir()
                (local / 'desc').write_text('%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%REASON%\n0\n\n')
                backup = 'conf\t' + hashlib.md5(case['old'].encode()).hexdigest() if case.get('backup') or case.get('oldbackup') else ''
                (local / 'files').write_text('%FILES%\nconf\n\n%BACKUP%\n' + backup + '\n\n')
            if 'local' in case: (root / 'conf').write_text(case['local'])
            if 'pacnew' in case: (root / 'conf.pacnew').write_text(case['pacnew'])
            pkg = base / 'fixture.pkg.tar'
            entries = {'.PKGINFO': 'pkgname = demo\npkgver = 2-1\narch = any\n' + ('backup = conf\n' if case.get('backup') else ''), 'conf': case['new']}
            with tarfile.open(pkg, 'w', format=tarfile.USTAR_FORMAT) as archive:
                for name, contents in entries.items():
                    assert name in ('.PKGINFO', 'conf')
                    data = contents.encode(); entry = tarfile.TarInfo(name); entry.size = len(data); entry.mode = 0o644
                    archive.addfile(entry, io.BytesIO(data))
            err = c.c_int(); handle = initialize(str(root).encode(), str(db).encode(), c.byref(err))
            assert handle, err.value
            started = False
            try:
                for option in ('noextract', 'noupgrade', 'overwrite'):
                    suffix = 'overwrite_file' if option == 'overwrite' else option
                    setter = bind('alpm_option_add_' + suffix, c.c_int, c.c_void_p, c.c_char_p)
                    for pattern in case.get(option, []): assert setter(handle, pattern.encode()) == 0
                mask = (1 << 7) | (1 << 10) | ((1 << 11) if case.get('noconflicts') else 0)
                assert init(handle, mask) == 0; started = True
                package = c.c_void_p()
                assert load(handle, str(pkg).encode(), 1, 0, c.byref(package)) == 0
                assert add(handle, package) == 0
                data = ListPtr(); assert prepare(handle, c.byref(data)) == 0
                # Independent guard immediately before the only mutation call.
                assert Path(getroot(handle).decode()).resolve() == root
                assert Path(getdb(handle).decode()).resolve() == db
                assert root.parent == db.parent == base and base.name.startswith('rlpm-preflight-oracle-')
                assert flags(handle) & ((1 << 7) | (1 << 10)) == (1 << 7) | (1 << 10)
                assert not any(p.is_symlink() for p in base.rglob('*'))
                result = commit(handle, c.byref(data))
                error = strerror(errno(handle)).decode() if result else None
                contents = {name: (root / name).read_text() if (root / name).exists() else None for name in ('conf', 'conf.pacnew', 'conf.pacsave')}
                inventory_path = db / 'local/demo-2-1/files'
                inventory = inventory_path.read_text() if inventory_path.exists() else None
                rows.append(dict(**case, error=error, contents=contents, inventory=inventory))
            finally:
                if started: assert finish(handle) == 0
                assert release(handle) == 0
    print(json.dumps(dict(library_sha256=sha, cases=rows), indent=2))

if __name__ == '__main__': main()
