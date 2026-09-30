#!/usr/bin/env python3
"""transaction oracle: pinned library, disposable roots, no nonempty commit or downloads.

Records native lifecycle errors, lock visibility/mode and prepare event order.
The commit guard independently inspects both native target lists first.
"""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
import re
import sys
import tarfile
import tempfile
from pathlib import Path
sys.dont_write_bytecode = True
from record_metadata import ListPtr
HERE = Path(__file__).parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    args = parser.parse_args()
    digest = hashlib.sha256(args.library.read_bytes()).hexdigest()
    if digest != json.loads((HERE / 'manifest.json').read_text())['library']['sha256']:
        parser.error('library does not match the frozen reference')
    locale.setlocale(locale.LC_ALL, 'C')
    lib = c.CDLL(str(args.library.resolve()))
    def bind(name, result, *arguments):
        fn = getattr(lib, name); fn.restype = result; fn.argtypes = list(arguments); return fn
    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    errno = bind('alpm_errno', c.c_int, c.c_void_p)
    init = bind('alpm_trans_init', c.c_int, c.c_void_p, c.c_int)
    prepare = bind('alpm_trans_prepare', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    commit = bind('alpm_trans_commit', c.c_int, c.c_void_p, c.POINTER(ListPtr))
    trans_release = bind('alpm_trans_release', c.c_int, c.c_void_p)
    interrupt = bind('alpm_trans_interrupt', c.c_int, c.c_void_p)
    unlock = bind('alpm_unlock', c.c_int, c.c_void_p)
    getadd = bind('alpm_trans_get_add', ListPtr, c.c_void_p)
    getremove = bind('alpm_trans_get_remove', ListPtr, c.c_void_p)
    local = bind('alpm_get_localdb', c.c_void_p, c.c_void_p)
    pkg = bind('alpm_db_get_pkg', c.c_void_p, c.c_void_p, c.c_char_p)
    remove = bind('alpm_remove_pkg', c.c_int, c.c_void_p, c.c_void_p)
    add = bind('alpm_add_pkg', c.c_int, c.c_void_p, c.c_void_p)
    load = bind('alpm_pkg_load', c.c_int, c.c_void_p, c.c_char_p, c.c_int, c.c_int, c.POINTER(c.c_void_p))
    free_pkg = bind('alpm_pkg_free', c.c_int, c.c_void_p)
    event_fn = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p)
    question_fn = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p)
    header = (HERE / 'downstream-alpm.h').read_text()
    errors = re.findall(r'\b(ALPM_ERR_\w+)\s*(?:=\s*0)?\s*[,\n]', header.split('typedef enum _alpm_errno_t {', 1)[1].split('}', 1)[0])
    events = re.findall(r'\b(ALPM_EVENT_\w+)\s*(?:=\s*1)?\s*[,\n]', header.split('typedef enum _alpm_event_type_t {', 1)[1].split('}', 1)[0])
    cases = [
        dict(name='empty', actions=['prepare', 'commit', 'release', 'init', 'init', 'interrupt', 'prepare', 'commit', 'release', 'release']),
        dict(name='remove', actions=['init', 'remove', 'remove', 'prepare', 'prepare', 'interrupt', 'release']),
        dict(name='remove-nodeps', flags=1, actions=['init', 'remove', 'prepare', 'release']),
        dict(name='remove-nolock', flags=1 << 17, actions=['init', 'remove', 'prepare', 'commit', 'release']),
        dict(name='unneeded-empty', flags=1 << 15, dependent=True, actions=['init', 'remove', 'prepare', 'commit', 'release']),
        dict(name='unneeded-empty-nolock', flags=(1 << 15) | (1 << 17), dependent=True, actions=['init', 'remove', 'prepare', 'commit', 'release']),
        dict(name='remove-unsatisfied', dependent=True, actions=['init', 'remove', 'prepare', 'release']),
        dict(name='archive-needed-empty', flags=1 << 13, same=True, actions=['init', 'archive', 'prepare', 'commit', 'release']),
        dict(name='archive', actions=['init', 'archive', 'prepare', 'release']),
        dict(name='archive-nodeps', flags=1, actions=['init', 'archive', 'prepare', 'release']),
        dict(name='archive-noconflicts', flags=1 << 11, actions=['init', 'archive', 'prepare', 'release']),
        dict(name='archive-both', flags=1 | (1 << 11), actions=['init', 'archive', 'prepare', 'release']),
        dict(name='archive-unsatisfied', missing=True, actions=['init', 'archive', 'prepare', 'release']),
        dict(name='archive-skipped', missing=True, skip=True, actions=['init', 'archive', 'prepare', 'commit', 'release']),
        dict(name='explicit-unlock', actions=['unlock', 'init', 'unlock', 'release']),
        dict(name='lock-contention', actions=['init', 'compete', 'release', 'compete']),
    ]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='rlpm-transaction-oracle-') as directory:
            base = Path(directory); root = base / 'root'; db = base / 'db'; root.mkdir(); (db / 'local/demo-1-1').mkdir(parents=True)
            (db / 'local/ALPM_DB_VERSION').write_text('9\n')
            (db / 'local/demo-1-1/desc').write_text('%NAME%\ndemo\n\n%VERSION%\n1-1\n\n%REASON%\n0\n\n')
            if case.get('dependent'):
                (db / 'local/dependent-1-1').mkdir()
                (db / 'local/dependent-1-1/desc').write_text('%NAME%\ndependent\n\n%VERSION%\n1-1\n\n%DEPENDS%\ndemo\n\n')
            archive_path = base / 'archive.pkg.tar'
            with tarfile.open(archive_path, 'w') as archive:
                contents = (('pkgname = demo\n' if case.get('same') else 'pkgname = archive\n') + 'pkgver = 1-1\narch = any\n' + ('depend = absent\n' if case.get('missing') else '')).encode()
                entry = tarfile.TarInfo('.PKGINFO'); entry.size = len(contents); archive.addfile(entry, io.BytesIO(contents))
            error = c.c_int(); handle = initialize(str(root).encode(), str(db).encode(), c.byref(error)); assert handle
            active = False; trace = []; emitted = []
            @event_fn
            def event(_, ptr): emitted.append(events[c.cast(ptr, c.POINTER(c.c_int))[0] - 1])
            @question_fn
            def question(_, ptr):
                values = c.cast(ptr, c.POINTER(c.c_int))
                if values[0] == 16: values[1] = int(case.get('skip', False))
            bind('alpm_option_set_eventcb', c.c_int, c.c_void_p, event_fn, c.c_void_p)(handle, event, None)
            bind('alpm_option_set_questioncb', c.c_int, c.c_void_p, question_fn, c.c_void_p)(handle, question, None)
            try:
                for action in case['actions']:
                    emitted.clear(); data = ListPtr()
                    if action == 'init':
                        result = init(handle, case.get('flags', 0)); active = active or result == 0
                    elif action == 'prepare': result = prepare(handle, c.byref(data))
                    elif action == 'commit':
                        # NOLOCK is rejected before native commit could mutate.
                        assert case.get('flags', 0) & (1 << 17) or (not getadd(handle) and not getremove(handle)), (case['name'], trace)
                        result = commit(handle, c.byref(data))
                    elif action == 'release':
                        result = trans_release(handle)
                        if result == 0: active = False
                    elif action == 'interrupt': result = interrupt(handle)
                    elif action == 'unlock': result = unlock(handle)
                    elif action == 'remove': result = remove(handle, pkg(local(handle), b'demo'))
                    elif action == 'archive':
                        loaded = c.c_void_p(); assert load(handle, str(archive_path).encode(), 1, 0, c.byref(loaded)) == 0
                        result = add(handle, loaded)
                        node = getadd(handle)
                        transferred = False
                        while node:
                            transferred = transferred or node.contents.data == loaded.value
                            node = node.contents.next
                        if not transferred: free_pkg(loaded)
                    elif action == 'compete':
                        competitor = initialize(str(root).encode(), str(db).encode(), c.byref(error)); assert competitor
                        result = init(competitor, 0); native_error = errors[errno(competitor)] if result else None
                        if result == 0: assert trans_release(competitor) == 0
                        assert release(competitor) == 0
                    else: raise AssertionError(action)
                    if data:
                        assert errors[errno(handle)] == 'ALPM_ERR_UNSATISFIED_DEPS'
                        node = data
                        while node:
                            bind('alpm_depmissing_free', None, c.c_void_p)(node.contents.data); node = node.contents.next
                        bind('alpm_list_free', None, ListPtr)(data)
                    lock = db / 'db.lck'
                    trace.append(dict(action=action, error=(native_error if action == 'compete' else errors[errno(handle)]) if result else None,
                                      events=list(emitted), locked=lock.exists(), mode=(lock.stat().st_mode & 0o777) if lock.exists() else None,
                                      size=lock.stat().st_size if lock.exists() else None))
            finally:
                if active: assert trans_release(handle) == 0
                assert release(handle) == 0
            case['trace'] = trace
    print(json.dumps(dict(library_sha256=digest, cases=cases), indent=2))


if __name__ == '__main__': main()
