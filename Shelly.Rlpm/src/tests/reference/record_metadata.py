#!/usr/bin/env python3
"""Optional metadata oracle: pinned libalpm, private temporary roots, no package operations."""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
import os
import resource
from pathlib import Path
import tarfile
import tempfile

class List(c.Structure):
    pass
ListPtr = c.POINTER(List)
List._fields_ = [('data', c.c_void_p), ('prev', ListPtr), ('next', ListPtr)]
class Dependency(c.Structure):
    _fields_ = [('name', c.c_char_p), ('version', c.c_char_p), ('description', c.c_char_p), ('name_hash', c.c_ulong), ('mod', c.c_int)]
class File(c.Structure):
    _fields_ = [('name', c.c_char_p), ('size', c.c_int64), ('mode', c.c_uint)]
class FileList(c.Structure):
    _fields_ = [('count', c.c_size_t), ('files', c.POINTER(File))]
class Backup(c.Structure):
    _fields_ = [('name', c.c_char_p), ('hash', c.c_char_p)]

RELATIONS = ['', 'foo', 'foo=1', 'foo>=1', 'foo<=1', 'foo>1', 'foo<1', 'foo>1<2', 'foo=', 'foo>=alpha:1.0', 'foo=1.0-', 'foo==1', '=1', 'foo: ordinary description', 'foo>=1:2: optional description', 'foo: ', 'libfoo.so=3-64', 'foo<1>=2', 'foo>=1<=2', 'foo = 1', 'foo=+1:1.0', 'foo=1_0:1.0', ': description', 'foo=>1', 'foo=18446744073709551616:1.0']
MTREE = '#mtree\n./.INSTALL type=file mode=644 size=5\n./usr type=dir mode=755\n./usr/bin type=dir mode=755\n./usr/bin/from-mtree type=file mode=755 size=42\n'
BASE = 'pkgname = demo\npkgver = 2:1.0-1\npkgdesc = demo package\nsize = 4096\nbackup = etc/demo.conf\nprovides = virtual=3\nprovides = plain\nprovides = ranged>=10\nprovides = libdemo.so=3-64\ndepend = unusual>=alpha:1.0: explanation\nxdata = pkgtype=pkg\n'
def entry(path, contents='', kind='file', target=None):
    result = dict(path=path, contents=contents, kind=kind)
    if target is not None:
        result['target'] = target
    return result

CASES = [
    dict(name='plain', entries=[entry('.PKGINFO',BASE),entry('.INSTALL','shell'),entry('.CHANGELOG','history\n'),entry('usr',kind='directory'),entry('usr/bin/demo','binary'),entry('usr/bin/link',kind='symlink',target='demo'),entry('usr/bin/hard',kind='hardlink',target='usr/bin/demo')]),
    dict(name='mtree', entries=[entry('.PKGINFO',BASE),entry('.MTREE',MTREE),entry('usr/bin/actual','payload')]),
    dict(name='duplicate_pkginfo', entries=[entry('.PKGINFO',BASE),entry('.PKGINFO','pkgname = replacement\npkgver = 3-1\n'),entry('payload','end')]),
    dict(name='duplicate_scalars', entries=[entry('.PKGINFO',BASE+'pkgdesc = second\n'),entry('payload')]),
    dict(name='unusual_version', entries=[entry('.PKGINFO','pkgname = demo\npkgver = alpha:1.0-\n'),entry('payload')]),
    dict(name='missing_release', entries=[entry('.PKGINFO','pkgname = demo\npkgver = 1.0\n')]),
    dict(name='malformed_line', entries=[entry('.PKGINFO',BASE+'not a key/value line\n'),entry('payload')]),
    dict(name='empty_relation', entries=[entry('.PKGINFO',BASE+'depend = broken>=\n'),entry('payload')]),
    dict(name='invalid_name', entries=[entry('.PKGINFO','pkgname = .invalid\npkgver = 1-1\n')]),
    dict(name='multiple_hyphens', entries=[entry('.PKGINFO','pkgname = demo\npkgver = 1-beta-1\n')]),
    dict(name='invalid_mtree', entries=[entry('.PKGINFO',BASE),entry('.MTREE','invalid mtree bytes'),entry('actual','payload')]),
    dict(name='duplicate_mtree', entries=[entry('.PKGINFO',BASE),entry('.MTREE',MTREE),entry('.MTREE','invalid mtree bytes'),entry('actual','payload')]),
    dict(name='whitespace', entries=[entry('.PKGINFO',BASE+'pkgdesc =  spaced description  \n'),entry('payload')]),
    dict(name='pkginfo_symlink', entries=[entry('.PKGINFO',kind='symlink',target='unread')]),
    dict(name='pkginfo_hardlink', entries=[entry('.PKGINFO',kind='hardlink',target='unread')]),
    dict(name='truncated_payload', entries=[entry('.PKGINFO',BASE),entry('first','ok'),entry('second','x'*1024)], truncate=2562),
    dict(name='truncated', entries=[entry('.PKGINFO',BASE)], truncate=520),
    dict(name='duplicate_changelog', entries=[entry('.PKGINFO',BASE),entry('.CHANGELOG','first'),entry('.CHANGELOG','second'),entry('payload')]),
]

def isolated_capture(function, full):
    # Malformed reference inputs can crash native code. The parent owns all
    # temporary files and can still clean up and record the failing signal.
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        try:
            payload = json.dumps(function()).encode()
            with os.fdopen(write_fd, 'wb') as stream:
                stream.write(payload)
            os._exit(0)
        except BaseException:
            os._exit(1)
    os.close(write_fd)
    with os.fdopen(read_fd, 'rb') as stream:
        payload = stream.read()
    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        return dict(full=full, success=False, reference_signal=os.WTERMSIG(status))
    if os.waitstatus_to_exitcode(status) != 0:
        raise RuntimeError('reference worker failed')
    return json.loads(payload)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',required=True,type=Path)
    args=parser.parse_args()
    digest=hashlib.sha256(args.library.read_bytes()).hexdigest()
    manifest=json.loads(Path(__file__).with_name('manifest.json').read_text())
    if digest != manifest['library']['sha256']:
        parser.error('library does not match frozen reference')
    locale.setlocale(locale.LC_ALL,'C')
    lib=c.CDLL(str(args.library.resolve()))
    libc=c.CDLL(None)
    libc.free.argtypes=[c.c_void_p]
    def bind(name,result,args):
        f=getattr(lib,name); f.restype=result; f.argtypes=args; return f
    def text(value):
        return value.decode() if value is not None else None
    parse=bind('alpm_dep_from_string',c.POINTER(Dependency),[c.c_char_p])
    format_dep=bind('alpm_dep_compute_string',c.c_void_p,[c.POINTER(Dependency)])
    free_dep=bind('alpm_dep_free',None,[c.POINTER(Dependency)])
    def relation(value):
        dep=parse(value.encode()); assert dep
        formatted=format_dep(dep); assert formatted
        try:
            return dict(input=value,name=text(dep.contents.name),version=text(dep.contents.version),description=text(dep.contents.description),mod=dep.contents.mod,formatted=c.string_at(formatted).decode())
        finally:
            libc.free(formatted); free_dep(dep)
    result=dict(schema=1,library_sha256=digest,locale='C',relations=[relation(v) for v in RELATIONS])
    compare=bind('alpm_pkg_vercmp',c.c_int,[c.c_char_p,c.c_char_p])
    bytepairs=[(b'1\xffa',b'1.a'),(b'1\xc3\xa9',b'1..'),(b'\xff',b''),(b'\x80',b'\xff'),(b'1\x80',b'1'),(b'1\t2',b'1.2'),(b'1\n2',b'1..2'),(b'\xc3\xa9:1',b'1'),(b'1.\xff2',b'1..2')]
    result['byte_versions']=[dict(a=a.hex(),b=b.hex(),sign=(compare(a,b)>0)-(compare(a,b)<0)) for a,b in bytepairs]
    decode=bind('alpm_decode_signature',c.c_int,[c.c_char_p,c.POINTER(c.c_void_p),c.POINTER(c.c_size_t)])
    result['signatures']=[]
    for encoded in ('AAECA/8=', 'AA EC A/8=\n', 'AAECA/8', 'not!base64', '', '='):
        pointer=c.c_void_p(); length=c.c_size_t(); status=decode(encoded.encode(),c.byref(pointer),c.byref(length))
        result['signatures'].append(dict(encoded=encoded,success=status==0,decoded=c.string_at(pointer,length.value).hex() if status==0 else None))
        libc.free(pointer)
    initialize=bind('alpm_initialize',c.c_void_p,[c.c_char_p,c.c_char_p,c.POINTER(c.c_int)])
    release=bind('alpm_release',c.c_int,[c.c_void_p])
    load=bind('alpm_pkg_load',c.c_int,[c.c_void_p,c.c_char_p,c.c_int,c.c_int,c.POINTER(c.c_void_p)])
    free_pkg=bind('alpm_pkg_free',c.c_int,[c.c_void_p])
    find=bind('alpm_find_satisfier',c.c_void_p,[ListPtr,c.c_char_p])
    get_files=bind('alpm_pkg_get_files',c.POINTER(FileList),[c.c_void_p])
    get_backup=bind('alpm_pkg_get_backup',ListPtr,[c.c_void_p])
    result['archives']=[]
    with tempfile.TemporaryDirectory(prefix='rlpm-metadata-reference-') as temporary:
        base=Path(temporary); root=base/'root'; db=base/'db'; root.mkdir(); db.mkdir()
        err=c.c_int(); handle=initialize(str(root).encode(),str(db).encode(),c.byref(err)); assert handle
        try:
            for case in CASES:
                path=base/(case['name']+'.tar')
                with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT) as archive:
                    for item in case['entries']:
                        info=tarfile.TarInfo(item['path']); info.mode=0o755 if item['kind']=='directory' else 0o644
                        data=item['contents'].encode(); info.size=len(data)
                        if item['kind']=='directory': info.type=tarfile.DIRTYPE
                        elif item['kind']=='symlink': info.type=tarfile.SYMTYPE; info.linkname=item['target']
                        elif item['kind']=='hardlink': info.type=tarfile.LNKTYPE; info.linkname=item['target']
                        archive.addfile(info,io.BytesIO(data))
                if 'truncate' in case:
                    path.write_bytes(path.read_bytes()[:case['truncate']])
                case=dict(case,results=[])
                for full in (False,True):
                    def capture():
                        pkg=c.c_void_p(); status=load(handle,str(path).encode(),int(full),0,c.byref(pkg))
                        record=dict(full=full,success=status==0)
                        if status==0:
                            try:
                                for field in ('name','version','desc','installed_db'):
                                    record[field]=text(bind('alpm_pkg_get_'+field,c.c_char_p,[c.c_void_p])(pkg))
                                for field in ('origin','validation','reason'):
                                    record[field]=bind('alpm_pkg_get_'+field,c.c_int,[c.c_void_p])(pkg)
                                record['scriptlet']=bool(bind('alpm_pkg_has_scriptlet',c.c_int,[c.c_void_p])(pkg))
                                files=get_files(pkg).contents
                                record['files']=[dict(name=text(f.name),size=f.size,mode=f.mode) for f in files.files[:files.count]]
                                backups=[]; pointer=get_backup(pkg)
                                while pointer:
                                    value=c.cast(pointer.contents.data,c.POINTER(Backup)).contents
                                    backups.append(dict(name=text(value.name),hash=text(value.hash))); pointer=pointer.contents.next
                                record['backups']=backups
                                if case['name']=='plain' and full:
                                    singleton=List(pkg,None,None)
                                    expectations=['demo','demo=2:1.0','demo>2:1.0-1','virtual>=3','virtual>3','plain','plain=2:1.0-1','ranged','ranged>=1','libdemo.so=3-64','libdemo.so=3-32','absent','virtual=: description']
                                    record['satisfaction']=[dict(requirement=s,matched=bool(find(c.pointer(singleton),s.encode()))) for s in expectations]
                            finally:
                                assert free_pkg(pkg)==0
                        return record
                    record=isolated_capture(capture,full)
                    if "satisfaction" in record:
                        result["satisfaction"]=record.pop("satisfaction")
                    case['results'].append(record)
                result['archives'].append(case)
            local_desc = '%NAME%\nlocal-demo\n\n%VERSION%\n2:1.0-1\n\n%INSTALLED_DB%\nremoved-cachyos-repo\n\n%SIZE%\n4096\n\n%VALIDATION%\nmd5\nsha256\npgp\n\n%DEPENDS%\nfoo>1<2: explanation\n\n'
            local_files = '%FILES%\nzeta\netc/\netc/demo.conf\n\n%BACKUP%\netc/demo.conf\t0123456789abcdef0123456789abcdef\n\n'
            local_dir = db / 'local/local-demo-2:1.0-1'
            local_dir.mkdir()
            (local_dir/'desc').write_text(local_desc)
            (local_dir/'files').write_text(local_files)
            reason_inputs = ('0','1','2','9','bogus')
            for value in reason_inputs:
                directory=db / ('local/reason-'+value+'-1-1'); directory.mkdir()
                (directory/'desc').write_text('%NAME%\nreason-'+value+'\n\n%VERSION%\n1-1\n\n%REASON%\n'+value+'\n')
            local_db = bind('alpm_get_localdb',c.c_void_p,[c.c_void_p])(handle)
            local_pkg = bind('alpm_db_get_pkg',c.c_void_p,[c.c_void_p,c.c_char_p])(local_db,b'local-demo')
            assert local_pkg
            result['reasons']=[]
            for value in reason_inputs:
                pkg=bind('alpm_db_get_pkg',c.c_void_p,[c.c_void_p,c.c_char_p])(local_db,('reason-'+value).encode()); assert pkg
                result['reasons'].append(dict(input=value,reason=bind('alpm_pkg_get_reason',c.c_int,[c.c_void_p])(pkg)))
            files = get_files(local_pkg).contents
            backup = c.cast(get_backup(local_pkg).contents.data,c.POINTER(Backup)).contents
            result['local_metadata'] = dict(desc=local_desc,files_input=local_files,
                installed_db=text(bind('alpm_pkg_get_installed_db',c.c_char_p,[c.c_void_p])(local_pkg)),
                validation=bind('alpm_pkg_get_validation',c.c_int,[c.c_void_p])(local_pkg),
                installed_size=bind('alpm_pkg_get_isize',c.c_int64,[c.c_void_p])(local_pkg),
                files=[text(f.name) for f in files.files[:files.count]],
                backup=dict(name=text(backup.name),hash=text(backup.hash)))
        finally:
            assert release(handle)==0
    print(json.dumps(result,indent=2))

if __name__=='__main__':
    main()
