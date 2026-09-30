#!/usr/bin/env python3
"""download oracle. Pinned library; private file mirrors, cache and local DB only.
The sole nonempty commit is independently guarded by DOWNLOADONLY and no removals.
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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    args = parser.parse_args()
    if hashlib.sha256(args.library.read_bytes()).hexdigest() != json.loads((HERE / 'manifest.json').read_text())['library']['sha256']:
        parser.error('library does not match frozen reference')
    locale.setlocale(locale.LC_ALL, 'C')
    lib = c.CDLL(str(args.library.resolve()))
    def bind(name, result, *params):
        fn = getattr(lib, name); fn.restype = result; fn.argtypes = list(params); return fn
    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    addcache = bind('alpm_option_add_cachedir', c.c_int, c.c_void_p, c.c_char_p)
    register = bind('alpm_register_syncdb', c.c_void_p, c.c_void_p, c.c_char_p, c.c_int)
    addserver = bind('alpm_db_add_server', c.c_int, c.c_void_p, c.c_char_p)
    addlist = bind('alpm_list_add', ListPtr, ListPtr, c.c_void_p)
    free_list = bind('alpm_list_free', None, ListPtr)
    refresh = bind('alpm_db_update', c.c_int, c.c_void_p, ListPtr, c.c_int)
    usage = bind('alpm_db_set_usage', c.c_int, c.c_void_p, c.c_int)
    getpkg = bind('alpm_db_get_pkg', c.c_void_p, c.c_void_p, c.c_char_p)
    init = bind('alpm_trans_init', c.c_int, c.c_void_p, c.c_int)
    flags = bind('alpm_trans_get_flags', c.c_int, c.c_void_p)
    removals = bind('alpm_trans_get_remove', ListPtr, c.c_void_p)
    add = bind('alpm_add_pkg', c.c_int, c.c_void_p, c.c_void_p)
    prepare = bind('alpm_trans_prepare', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    commit = bind('alpm_trans_commit', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    finish = bind('alpm_trans_release', c.c_int, c.c_void_p)
    download_size = bind('alpm_pkg_download_size', c.c_int64, c.c_void_p)
    for name in ('downloadonly', 'digest-mismatch', 'required-signature', 'optional-signature', 'refresh-disabled', 'refresh-lock'):
        with tempfile.TemporaryDirectory(prefix='rlpm-download-oracle-') as tmp:
            base = Path(tmp); root = base/'root'; db = base/'db'; mirror = base/'mirror'; cache = base/'cache'
            for path in (root, db, mirror, cache): path.mkdir()
            payload = b'package' # Native DOWNLOADONLY checks integrity, not archive inventory.
            (mirror/'demo.pkg.tar.zst').write_bytes(payload)
            digest = hashlib.sha256(b'wrong' if name == 'digest-mismatch' else payload).hexdigest()
            desc = f'%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n%CSIZE%\n7\n\n%SHA256SUM%\n{digest}\n\n'.encode()
            with tarfile.open(mirror/'cachyos.db', 'w') as archive:
                entry = tarfile.TarInfo('demo-1-1/desc'); entry.size = len(desc); archive.addfile(entry, io.BytesIO(desc))
            err = c.c_int(); handle = initialize(str(root).encode(), str(db).encode(), c.byref(err)); assert handle
            try:
                assert addcache(handle, str(cache).encode()) == 0
                policy = 1 if name == 'required-signature' else 3 if name == 'optional-signature' else 0
                repo = register(handle, b'cachyos', policy); assert repo
                assert addserver(repo, mirror.as_uri().encode()) == 0
                repos = addlist(None, repo)
                try:
                    if name == 'refresh-disabled': assert usage(repo, 2) == 0
                    if name == 'refresh-lock': (db/'db.lck').touch()
                    result = {'name': name, 'refresh': refresh(handle, repos, 0)}
                    if name.startswith('refresh-'):
                        result['db_exists'] = (db/'sync/cachyos.db').exists()
                    else:
                        assert result['refresh'] == 0
                        result['unchanged'] = refresh(handle, repos, 0)
                        package = getpkg(repo, b'demo'); assert package
                        before = sorted((str(p.relative_to(db/'local')), hashlib.sha256(p.read_bytes()).hexdigest()) for p in (db/'local').rglob('*') if p.is_file())
                        assert init(handle, 1 << 9) == 0
                        assert add(handle, package) == 0
                        data = ListPtr(); assert prepare(handle, c.byref(data)) == 0
                        result['download_size'] = download_size(package)
                        assert flags(handle) & (1 << 9) and not removals(handle), 'refusing an installed-state commit'
                        result['commit'] = commit(handle, c.byref(data))
                        result['cached'] = (cache/'demo.pkg.tar.zst').exists()
                        after = sorted((str(p.relative_to(db/'local')), hashlib.sha256(p.read_bytes()).hexdigest()) for p in (db/'local').rglob('*') if p.is_file())
                        result['installed_unchanged'] = before == after
                        assert result['installed_unchanged']
                        assert finish(handle) == 0
                finally: free_list(repos)
                print(json.dumps(result, sort_keys=True))
            finally: assert release(handle) == 0

if __name__ == '__main__': main()
