#!/usr/bin/env python3
"""Optional database oracle. Pinned libalpm; private roots; no package operations."""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
from pathlib import Path
import sqlite3
import sys
import tarfile
import tempfile
sys.dont_write_bytecode = True
from record_metadata import List, ListPtr, FileList, isolated_capture

class Group(c.Structure):
    _fields_=[('name',c.c_char_p),('packages',ListPtr)]

def desc(name='demo', version='1-1', extra=''):
    return f'%NAME%\n{name}\n\n%VERSION%\n{version}\n\n'+extra

LOCAL = [
    dict(name='create', marker=None, entries=[]),
    dict(name='empty_marker', marker='', entries=[]),
    dict(name='old_version', marker='8\n', entries=[]),
    dict(name='trailing_version', marker=' 9junk\n', entries=[]),
    dict(name='missing_marker', marker=None, entries=[dict(path='demo-1-1', desc=desc())]),
    dict(name='missing_desc', marker='9\n', entries=[dict(path='demo-1-1')]),
    dict(name='mismatched_identity', marker='9\n', entries=[dict(path='demo-1-1', desc=desc('wrong','2-2','%DESC%\ntext\n\n'))]),
    dict(name='missing_identity', marker='9\n', entries=[dict(path='demo-1-1', desc='%DESC%\ntext\n\n')]),
    dict(name='duplicate', marker='9\n', entries=[dict(path='demo-1-1',desc=desc()),dict(path='demo-2-1',desc=desc('demo','2-1'))]),
    dict(name='invalid_directory', marker='9\n', entries=[dict(path='bad',desc=desc())]),
    dict(name='malformed_scalars', marker='9\n', entries=[dict(path='demo-1-1',desc=desc(extra='%SIZE%\nwrong\n\n%BUILDDATE%\nwrong\n\n%REASON%\nwrong\n\n'))]),
    dict(name='repeated_scalar', marker='9\n', entries=[dict(path='demo-1-1',desc=desc(extra='%DESC%\nfirst\n\n%DESC%\nlast\n\n'))]),
]
NORMAL = [
    dict(path='zeta-1-1/desc',contents=desc('zeta',extra='%DESC%\ntext editor\n\n%GROUPS%\neditors\ncommon\n\n%DEPENDS%\nvirtual>=3\n\n%OPTDEPENDS%\ndemo: docs\n\n')),
    dict(path='demo-1-1/desc',contents=desc(extra='%DESC%\nText utility\n\n%GROUPS%\nz-tools\ncommon\n\n%PROVIDES%\nvirtual=3\n\n%FILENAME%\ndemo.pkg.tar.zst\n\n')),
    dict(path='demo-1-1/files',contents='%FILES%\nz\netc/\netc/demo\n\n'),
]
SQL_COLUMNS=['name','version','filename','base','desc','groups','url','license','arch','builddate','packager','csize','isize','sha256sum','pgpsig','replaces','depends','optdepends','makedepends','checkdepends','conflicts','provides','files']
SQL_ROW=['demo','1-1','demo.pkg.tar.zst','demo-base','Text utility','z-tools,,common','https://example.invalid','MIT,BSD','x86_64_v3','123','Builder','42','4096','digest','AAEC','old<2','glibc>=2,libdemo.so=3-64','docs: manual','compiler','tester','old','virtual=3,plain','z,etc/,etc/demo']
SYNC = [
    dict(name='tar',entries=NORMAL),
    dict(name='mismatched_identity',entries=[dict(path='demo-1-1/desc',contents=desc('wrong','2-2','%DESC%\ntext\n\n'))]),
    dict(name='duplicate',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%DESC%\nfirst\n\n')),dict(path='demo-2-1/desc',contents=desc('demo','2-1','%DESC%\nlast\n\n'))]),
    dict(name='duplicate_groups',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%GROUPS%\ncommon\ncommon\n\n'))]),
    dict(name='files_without_desc',entries=[NORMAL[-1]]),
    dict(name='unknown_member',entries=[dict(path='demo-1-1/future',contents='data')]),
    dict(name='invalid_entry',entries=[dict(path='invalid/desc',contents=desc())]),
    dict(name='bad_filename',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%FILENAME%\n../bad\n\n'))]),
    dict(name='malformed_scalars',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%ISIZE%\nbad\n\n%BUILDDATE%\nbad\n\n'))]),
    dict(name='unterminated_list',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%GROUPS%\ncommon'))]),
    dict(name='unterminated_list_newline',entries=[dict(path='demo-1-1/desc',contents=desc(extra='%GROUPS%\ncommon\n'))]),
    dict(name='truncated',entries=NORMAL,truncate=520),
    dict(name='sqlite',entries=[],columns=SQL_COLUMNS,rows=[SQL_ROW]),
    dict(name='sqlite_missing_table',entries=[],columns=[],rows=[]),
    dict(name='sqlite_missing_identity',entries=[],columns=['desc'],rows=[['text']]),
    dict(name='sqlite_null_identity',entries=[],columns=['name','version'],rows=[[None,'1-1']]),
]
NEEDLES=[['TEXT'],['utility','common'],['^virtual$'],['^virtual=3$'],['^edit'],['^z-tools$'],['['],[],['absent','[']]

def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--library',required=True,type=Path)
    args=parser.parse_args(); digest=hashlib.sha256(args.library.read_bytes()).hexdigest()
    manifest=json.loads(Path(__file__).with_name('manifest.json').read_text())
    if digest!=manifest['library']['sha256']: parser.error('library does not match frozen reference')
    locale.setlocale(locale.LC_ALL,'C'); lib=c.CDLL(str(args.library.resolve()))
    libc=c.CDLL(None);libc.free.argtypes=[c.c_void_p]
    def bind(name,result,*args):
        f=getattr(lib,name);f.restype=result;f.argtypes=list(args);return f
    initialize=bind('alpm_initialize',c.c_void_p,c.c_char_p,c.c_char_p,c.POINTER(c.c_int))
    release=bind('alpm_release',c.c_int,c.c_void_p)
    errno=bind('alpm_errno',c.c_int,c.c_void_p)
    localdb=bind('alpm_get_localdb',c.c_void_p,c.c_void_p)
    register=bind('alpm_register_syncdb',c.c_void_p,c.c_void_p,c.c_char_p,c.c_int)
    getcache=bind('alpm_db_get_pkgcache',ListPtr,c.c_void_p)
    search=bind('alpm_db_search',c.c_int,c.c_void_p,ListPtr,c.POINTER(ListPtr))
    free_list=bind('alpm_list_free',None,ListPtr)
    def walk(head):
        while head:
            yield head.contents.data;head=head.contents.next
    def txt(pkg,field):
        value=bind('alpm_pkg_get_'+field,c.c_char_p,c.c_void_p)(pkg)
        return value.decode() if value is not None else None
    def snapshot(pkg):
        result={field:txt(pkg,field) for field in ('name','version','desc','installed_db','arch','filename')}
        result.update({field:bind('alpm_pkg_get_'+field,c.c_int64,c.c_void_p)(pkg) for field in ('isize','builddate')})
        result['groups']=[c.string_at(v).decode() for v in walk(bind('alpm_pkg_get_groups',ListPtr,c.c_void_p)(pkg))]
        files=bind('alpm_pkg_get_files',c.POINTER(FileList),c.c_void_p)(pkg).contents
        result['files']=[f.name.decode() for f in files.files[:files.count]]
        for field in ('requiredby','optionalfor'):
            head=bind('alpm_pkg_compute_'+field,ListPtr,c.c_void_p)(pkg)
            result[field]=[c.string_at(value).decode() for value in walk(head)]
            for value in walk(head):libc.free(value)
            free_list(head)
        return result
    result=dict(schema=1,library_sha256=digest,locale='C',local=[],sync=[])
    with tempfile.TemporaryDirectory(prefix='rlpm-database-reference-') as temp:
        for kind,cases in (('local',LOCAL),('sync',SYNC)):
            for index,case in enumerate(cases):
                base=Path(temp)/f'{kind}-{index}';base.mkdir();root=base/'root';root.mkdir();db=base/'db';db.mkdir()
                if kind=='local':
                    if case['marker'] is not None or case['entries']:
                        (db/'local').mkdir()
                        if case['marker'] is not None: (db/'local/ALPM_DB_VERSION').write_text(case['marker'])
                    for entry in case['entries']:
                        path=db/'local'/entry['path'];path.mkdir()
                        if 'desc' in entry:(path/'desc').write_text(entry['desc'])
                else:
                    (db/'sync').mkdir();path=db/'sync/test.db'
                    with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT) as archive:
                        entries=list(case['entries'])
                        if 'columns' in case:
                            sql=base/'input.sqlite';connection=sqlite3.connect(sql)
                            if case['columns']:
                                connection.execute('CREATE TABLE packages ('+','.join('"'+v+'" TEXT' for v in case['columns'])+')')
                                connection.executemany('INSERT INTO packages VALUES ('+','.join('?' for _ in case['columns'])+')',case['rows'])
                            else: connection.execute('CREATE TABLE different (value TEXT)')
                            connection.commit();connection.close()
                            entries.append(dict(path='pacman.db',contents=sql.read_bytes()))
                        for entry in entries:
                            data=entry['contents'];data=data.encode() if isinstance(data,str) else data
                            info=tarfile.TarInfo(entry['path']);info.size=len(data);archive.addfile(info,io.BytesIO(data))
                    if 'truncate' in case:path.write_bytes(path.read_bytes()[:case['truncate']])
                def capture():
                    error=c.c_int();handle=initialize(str(root).encode(),str(db).encode(),c.byref(error))
                    if not handle:return dict(success=False,error=error.value)
                    try:
                        database=localdb(handle) if kind=='local' else register(handle,b'test',0)
                        cache=getcache(database);error=errno(handle)
                        result=dict(success=error==0,error=error,packages=[snapshot(p) for p in walk(cache)])
                        if kind=='sync' and result['success']:
                            result['groups']=[]
                            for pointer in walk(bind('alpm_db_get_groupcache',ListPtr,c.c_void_p)(database)):
                                group=c.cast(pointer,c.POINTER(Group)).contents
                                result['groups'].append(dict(name=group.name.decode(),packages=[txt(pkg,'name') for pkg in walk(group.packages)]))
                            result['searches']=[]
                            for needles in NEEDLES:
                                strings=[c.create_string_buffer(s.encode()) for s in needles]
                                nodes=[List(c.cast(s,c.c_void_p),None,None) for s in strings]
                                for i in range(len(nodes)-1):nodes[i].next=c.pointer(nodes[i+1])
                                out=ListPtr();status=search(database,c.pointer(nodes[0]) if nodes else None,c.byref(out))
                                result['searches'].append(dict(patterns=needles,success=status==0,names=[txt(p,'name') for p in walk(out)]));free_list(out)
                            bind('alpm_db_set_usage',c.c_int,c.c_void_p,c.c_int)(database,0)
                            out=ListPtr();bad=c.create_string_buffer(b'[');node=List(c.cast(bad,c.c_void_p),None,None)
                            result['disabled_search_success']=search(database,c.pointer(node),c.byref(out))==0
                            result['disabled_exact_visible']=bool(bind('alpm_db_get_pkg',c.c_void_p,c.c_void_p,c.c_char_p)(database,b'demo'))
                            free_list(out)
                        return result
                    finally:assert release(handle)==0
                captured=isolated_capture(capture,False);captured.pop('full',None)
                result[kind].append(dict(case,result=captured))
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
