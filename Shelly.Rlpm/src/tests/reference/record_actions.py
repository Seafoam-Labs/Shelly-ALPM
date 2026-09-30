#!/usr/bin/env python3
"""Native hook and scriptlet oracle, invoked inside `unshare --user --map-root-user --mount`.
Only generated hooks/scripts and inert archives run, in private chroots. No host
hook directory, service manager, ldconfig, or installed package DB is used.
"""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
sys.dont_write_bytecode = True
from record_metadata import ListPtr
HERE = Path(__file__).parent
TRIGGER = '[Trigger]\nOperation=Install\nOperation=Upgrade\nType=Package\nTarget=*\n'
ACTION = '[Action]\nWhen=PreTransaction\n'
SCRIPT = '''printf 'source:%s\\n' "$#" >> /trace
pre_install() { printf 'pre_install:%s:%s\\n' "$#" "$1" >> /trace; }
post_install() { printf 'post_install:%s:%s\\n' "$#" "$1" >> /trace; }
pre_upgrade() { printf 'pre_upgrade:%s:%s:%s\\n' "$#" "$1" "$2" >> /trace; }
post_upgrade() { printf 'post_upgrade:%s:%s:%s\\n' "$#" "$1" "$2" >> /trace; }
'''
CASES = [
    dict(name='quoted-arguments', hook=TRIGGER + ACTION + '''Exec=/usr/bin/bash -c 'printf "<%s>\\n" "$@" >> /trace' argv0 'two words' "" x\\ y a"b"c "$literal"
'''),
    dict(name='hash-in-quotes', hook=TRIGGER + ACTION + "Exec=/usr/bin/bash -c 'printf x#y >> /trace'\n"),
    dict(name='exec-overridden', hook=TRIGGER + ACTION + "Exec=/missing\n[Action]\nExec=/usr/bin/bash -c 'printf good >> /trace'\n"),
    dict(name='needs-targets', hook=TRIGGER + ACTION + '''Exec=/usr/bin/bash -c 'while IFS= read -r target; do printf "%s\\n" "$target" >> /trace; done'
NeedsTargets=false
'''),
    dict(name='network-allowed', hook=TRIGGER + ACTION + "Exec=/usr/bin/bash -c 'printf allowed >> /trace'\nNetworkAccess=allowed\n"),
    dict(name='network-invalid', hook=TRIGGER + ACTION + 'Exec=/missing\nNetworkAccess=denied\n'),
    dict(name='abort-nonzero', hook=TRIGGER + ACTION + 'Exec=/usr/bin/bash -c "exit 3"\nAbortOnFail\n'),
    dict(name='nonfatal-nonzero', hook=TRIGGER + ACTION + 'Exec=/usr/bin/bash -c "exit 3"\n'),
    dict(name='post-nonzero', hook=TRIGGER + ACTION.replace('PreTransaction', 'PostTransaction') + 'Exec=/usr/bin/bash -c "exit 3"\nAbortOnFail\n'),
    dict(name='missing-dependency', hook=TRIGGER + ACTION + 'Exec=/missing\nDepends=absent>=2\nAbortOnFail\n'),
    dict(name='empty-mask', hook=''),
    dict(name='install-scriptlets', hook='', script=SCRIPT),
    dict(name='upgrade-scriptlets', hook='', script=SCRIPT, old_version='1-1'),
    dict(name='reinstall-scriptlets', hook='', script=SCRIPT, old_version='2-1'),
    dict(name='downgrade-scriptlets', hook='', script=SCRIPT, old_version='3-1'),
    dict(name='dbonly-scriptlets', hook='', script=SCRIPT, flags=1 << 6),
    dict(name='noscriptlet', hook='', script=SCRIPT, flags=1 << 10),
    dict(name='nohooks-malformed', hook='[Invalid]\n', script=SCRIPT, flags=1 << 7),
    dict(name='escaped-double-quotes', hook=TRIGGER + ACTION + '''Exec=/usr/bin/bash -c 'printf "<%s>\\n" "$@" >> /trace' argv0 "a\\zb" "a\\\"b"
'''),
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    args = parser.parse_args()
    digest = hashlib.sha256(args.library.read_bytes()).hexdigest()
    assert digest == json.loads((HERE / 'manifest.json').read_text())['library']['sha256']
    assert os.geteuid() == 0, 'run in an unprivileged user namespace'
    locale.setlocale(locale.LC_ALL, 'C')
    lib = c.CDLL(str(args.library.resolve()))
    def bind(name, result, *params):
        fn = getattr(lib, name); fn.restype = result; fn.argtypes = list(params); return fn
    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    init = bind('alpm_trans_init', c.c_int, c.c_void_p, c.c_int)
    load = bind('alpm_pkg_load', c.c_int, c.c_void_p, c.c_char_p, c.c_int, c.c_int, c.POINTER(c.c_void_p))
    add = bind('alpm_add_pkg', c.c_int, c.c_void_p, c.c_void_p)
    prepare = bind('alpm_trans_prepare', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    commit = bind('alpm_trans_commit', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    finish = bind('alpm_trans_release', c.c_int, c.c_void_p)
    getroot = bind('alpm_option_get_root', c.c_char_p, c.c_void_p)
    getdb = bind('alpm_option_get_dbpath', c.c_char_p, c.c_void_p)
    gethooks = bind('alpm_option_get_hookdirs', ListPtr, c.c_void_p)
    strerror = bind('alpm_strerror', c.c_char_p, c.c_int)
    errno = bind('alpm_errno', c.c_int, c.c_void_p)
    libs = [Path(word) for word in subprocess.check_output(['/usr/bin/ldd', '/usr/bin/bash'], text=True).split() if word.startswith('/')]
    rows = []
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix='rlpm-actions-oracle-') as temp:
            base = Path(temp).resolve(); root = base / 'root'; db = base / 'db'
            root.mkdir(); (db / 'local').mkdir(parents=True)
            (db / 'local/ALPM_DB_VERSION').write_text('9\n')
            for source in [Path('/usr/bin/bash'), *libs]:
                destination = root / str(source).lstrip('/')
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            hooks = root / 'usr/share/libalpm/hooks'; hooks.mkdir(parents=True)
            (hooks / 'fixture.hook').write_text(case['hook'])
            if old := case.get('old_version'):
                record = db / f'local/demo-{old}'; record.mkdir()
                (record / 'desc').write_text(f'%NAME%\ndemo\n\n%VERSION%\n{old}\n\n%REASON%\n0\n\n')
                (record / 'files').write_text('%FILES%\n\n')
                (record / 'install').write_text('pre_remove() { exit 99; }\n')
            pkg = base / 'fixture.pkg.tar'
            entries = {'.PKGINFO': 'pkgname = demo\npkgver = 2-1\narch = any\n'}
            if 'script' in case: entries['.INSTALL'] = case['script']
            with tarfile.open(pkg, 'w', format=tarfile.USTAR_FORMAT) as archive:
                for name, contents in entries.items():
                    assert name in ('.PKGINFO', '.INSTALL')
                    data = contents.encode(); entry = tarfile.TarInfo(name); entry.size = len(data); entry.mode = 0o644
                    archive.addfile(entry, io.BytesIO(data))
            err = c.c_int(); handle = initialize(str(root).encode(), str(db).encode(), c.byref(err)); assert handle, err.value
            started = False
            try:
                assert init(handle, case.get('flags', 0)) == 0; started = True
                package = c.c_void_p(); assert load(handle, str(pkg).encode(), 1, 0, c.byref(package)) == 0
                assert add(handle, package) == 0
                data = ListPtr(); assert prepare(handle, c.byref(data)) == 0
                # Immediately before commit, independently verify all effect roots.
                assert Path(getroot(handle).decode()).resolve() == root and Path(getdb(handle).decode()).resolve() == db
                assert base.name.startswith('rlpm-actions-oracle-') and root.parent == db.parent == base
                assert not any(p.is_symlink() for p in base.rglob('*'))
                cursor = gethooks(handle)
                while cursor:
                    assert Path(c.cast(cursor.contents.data, c.c_char_p).value.decode()).resolve() == hooks
                    cursor = cursor.contents.next
                assert not (root / 'usr/bin/ldconfig').exists()
                result = commit(handle, c.byref(data))
                rows.append(dict(**case, success=result == 0, error=strerror(errno(handle)).decode() if result else None,
                                 trace=(root / 'trace').read_text() if (root / 'trace').exists() else ''))
            finally:
                if started: finish(handle)
                release(handle)
    print(json.dumps(dict(library_sha256=digest, cases=rows), indent=2))

if __name__ == '__main__': main()
