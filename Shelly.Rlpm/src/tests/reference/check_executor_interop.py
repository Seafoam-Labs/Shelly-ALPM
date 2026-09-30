#!/usr/bin/env python3
"""Alternate pinned libalpm and RLPM commits in one disposable database.
The driver is a test-only executable requiring a generated private-root marker.
No host package databases, hooks, scriptlets, downloads or service managers run.
"""
import argparse
import ctypes as c
import hashlib
import io
import json
import os
import re
import stat
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
sys.dont_write_bytecode = True
from record_metadata import ListPtr
HERE = Path(__file__).parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--driver', required=True, type=Path)
    parser.add_argument('--library', default='/usr/lib/libalpm.so', type=Path)
    args = parser.parse_args()
    assert os.geteuid() == 0, 'run in an unprivileged user namespace'
    assert hashlib.sha256(args.library.read_bytes()).hexdigest() == json.loads((HERE / 'manifest.json').read_text())['library']['sha256']
    lib = c.CDLL(str(args.library.resolve()))
    def bind(name, result, *params):
        fn = getattr(lib, name); fn.restype = result; fn.argtypes = list(params); return fn
    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    init = bind('alpm_trans_init', c.c_int, c.c_void_p, c.c_int)
    finish = bind('alpm_trans_release', c.c_int, c.c_void_p)
    load = bind('alpm_pkg_load', c.c_int, c.c_void_p, c.c_char_p, c.c_int, c.c_int, c.POINTER(c.c_void_p))
    add = bind('alpm_add_pkg', c.c_int, c.c_void_p, c.c_void_p)
    prepare = bind('alpm_trans_prepare', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    commit = bind('alpm_trans_commit', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    getlocal = bind('alpm_get_localdb', c.c_void_p, c.c_void_p)
    getpkg = bind('alpm_db_get_pkg', c.c_void_p, c.c_void_p, c.c_char_p)
    remove = bind('alpm_remove_pkg', c.c_int, c.c_void_p, c.c_void_p)
    version = bind('alpm_pkg_get_version', c.c_char_p, c.c_void_p)
    getroot = bind('alpm_option_get_root', c.c_char_p, c.c_void_p)
    getdb = bind('alpm_option_get_dbpath', c.c_char_p, c.c_void_p)
    initial_states = {}
    for first in ('rlpm', 'native'):
        with tempfile.TemporaryDirectory(prefix='rlpm-executor-interop-', dir='/tmp') as temp:
            base = Path(temp).resolve(); root = base / 'root'; db = base / 'db'
            root.mkdir(); (db / 'local').mkdir(parents=True)
            (base / '.fixture').write_text('disposable RLPM executor interoperability\n')
            (db / 'local/ALPM_DB_VERSION').write_text('9\n')
            archives = {}
            for ver in ('1-1', '2-1', '3-1'):
                path = base / f'demo-{ver}.pkg.tar'; archives[ver] = path
                entries = {'.PKGINFO': f'pkgname = demo\npkgver = {ver}\narch = any\npkgdesc = interoperable\nbackup = conf\nsize = 32\ngroup = fixture\nlicense = MIT\nxdata = pkgtype=pkg\n', '.INSTALL': 'post_install() { :; }\n', '.CHANGELOG': 'fixture changelog\n', 'conf': ver, 'payload': 'attribute payload', '.MTREE': '#mtree\n./conf type=file\n./payload type=file\n./hard type=file\n./absolute type=link link=/payload\n./pipe type=fifo\n'}
                with tarfile.open(path, 'w', format=tarfile.PAX_FORMAT) as tar:
                    for name, text in entries.items():
                        data = text.encode(); entry = tarfile.TarInfo(name); entry.size = len(data); entry.mode = 0o644; entry.mtime = 123456789
                        if name == 'payload':
                            entry.mode = 0o4751
                            entry.pax_headers = {'SCHILY.xattr.user.rlpm': 'fixture-value'}
                        tar.addfile(entry, io.BytesIO(data))
                    entry = tarfile.TarInfo('hard'); entry.type = tarfile.LNKTYPE; entry.linkname = 'payload'; entry.mode = 0o644; tar.addfile(entry)
                    entry = tarfile.TarInfo('absolute'); entry.type = tarfile.SYMTYPE; entry.linkname = '/payload'; entry.mtime = 12345; tar.addfile(entry)
                    entry = tarfile.TarInfo('pipe'); entry.type = tarfile.FIFOTYPE; entry.mode = 0o620; tar.addfile(entry)
            def native(archive, expected):
                err = c.c_int(); handle = initialize(str(root).encode(), str(db).encode(), c.byref(err)); assert handle, err.value
                try:
                    current = getpkg(getlocal(handle), b'demo')
                    if expected: assert current and version(current).decode() == expected
                    assert init(handle, (1 << 7) | (1 << 10)) == 0
                    try:
                        if archive:
                            package = c.c_void_p(); assert load(handle, str(archive).encode(), 1, 0, c.byref(package)) == 0
                            assert add(handle, package) == 0
                        else: assert current and remove(handle, current) == 0
                        result = ListPtr(); assert prepare(handle, c.byref(result)) == 0
                        assert Path(getroot(handle).decode()).resolve() == root and Path(getdb(handle).decode()).resolve() == db
                        assert base.parent == Path('/tmp') and base.name.startswith('rlpm-executor-interop-')
                        assert commit(handle, c.byref(result)) == 0
                    finally: assert finish(handle) == 0
                finally: assert release(handle) == 0
            def rlpm(action, ver):
                subprocess.run([str(args.driver.resolve()), str(base), action, str(archives[ver]), ver], check=True)
            if first == 'rlpm': rlpm('install', '1-1')
            else: native(archives['1-1'], None)
            rlpm('query', '1-1')
            records = {p.name: re.sub(r'(%INSTALLDATE%\n)\d+', r'\g<1><time>', p.read_text()) for p in (db / 'local/demo-1-1').iterdir()}
            attributes = {}
            for name in ('conf', 'payload', 'hard', 'absolute', 'pipe'):
                path = root / name; st = path.lstat()
                attributes[name] = dict(mode=st.st_mode, uid=st.st_uid, gid=st.st_gid, mtime=st.st_mtime_ns,
                    link=os.readlink(path) if stat.S_ISLNK(st.st_mode) else None,
                    xattrs={key: os.getxattr(path, key, follow_symlinks=False).hex() for key in os.listxattr(path, follow_symlinks=False)})
            assert (root / 'hard').stat().st_ino == (root / 'payload').stat().st_ino
            initial_states[first] = dict(records=records, attributes=attributes)
            (root / 'conf').write_text('user changes')
            if first == 'rlpm': native(archives['2-1'], '1-1')
            else: rlpm('install', '2-1')
            assert (root / 'conf').read_text() == 'user changes'
            assert (root / 'conf.pacnew').read_text() == '2-1'
            rlpm('query', '2-1')
            if first == 'rlpm': rlpm('install', '3-1')
            else: native(archives['3-1'], '2-1')
            rlpm('query', '3-1')
            rlpm('install', '1-1') # downgrade an independently read record
            native(None, '1-1')
            assert not (root / 'conf').exists() and (root / 'conf.pacsave').read_text() == 'user changes'
            assert sorted(p.name for p in (db / 'local').iterdir()) == ['ALPM_DB_VERSION']
    assert initial_states['rlpm'] == initial_states['native'], json.dumps(initial_states, indent=2)
    print('Executor interoperability: native → RLPM → native and RLPM → native → RLPM passed')
if __name__ == '__main__': main()
