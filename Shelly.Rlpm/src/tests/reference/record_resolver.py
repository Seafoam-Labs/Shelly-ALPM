#!/usr/bin/env python3
"""Optional resolver oracle: hash-pinned libalpm, private roots, NOLOCK, prepare only.

Never commits, downloads, refreshes databases, or reads the host package DB.
Normal Zig tests replay its JSON and do not load this library.
"""
import argparse
import ctypes as c
import hashlib
import io
import json
import locale
from pathlib import Path
import random
import re
import shlex
import sys
import tarfile
import tempfile
import traceback
sys.dont_write_bytecode = True
from record_metadata import List, ListPtr, isolated_capture

HERE = Path(__file__).parent
FIELDS = ('depends', 'provides', 'conflicts', 'replaces', 'optional_depends', 'groups', 'make_depends', 'check_depends')
def p(name, version='1-1', **kwargs):
    return dict(name=name, version=version, **kwargs)
def repo(packages, name='test', usage=15):
    return dict(name=name, usage=usage, packages=packages)
def case(name, local=(), packages=(), targets=(), **kwargs):
    return dict(dict(name=name, local=list(local), repositories=[repo(list(packages))], targets=list(targets)), **kwargs)

def manual_cases():
    cases = [
        case('literal-before-provider', packages=[p('a', provides=['virtual']), p('virtual')], targets=['virtual']),
        case('later-repo-literal', targets=['virtual'], repositories=[repo([p('a', provides=['virtual'])]), repo([p('virtual')], 'second')]),
        case('priority-before-version', targets=['app'], repositories=[repo([p('app')]), repo([p('app', '9-1')], 'second')]),
        case('qualified', targets=['second/app'], repositories=[repo([p('app')]), repo([p('app', '9-1')], 'second')]),
        case('provider-order', packages=[p('z', provides=['virtual']), p('a', provides=['virtual'])], targets=['virtual'], answers={'select_provider': 1}),
        case('installed-provider', local=[p('z', '1-1')], packages=[p('a', provides=['virtual']), p('z', '2-1', provides=['virtual'])], targets=['virtual']),
        case('installed-satisfier', local=[p('old', provides=['virtual=3'])], packages=[p('app', depends=['virtual>=2']), p('virtual', '9-1')], targets=['app']),
        case('explicit-provider', packages=[p('app', depends=['virtual']), p('a', provides=['virtual']), p('z', provides=['virtual'])], targets=['app', 'z']),
        case('two-constraints-two-providers', local=[p('a', provides=['virtual=1']), p('b', provides=['virtual=4'])], packages=[p('app', depends=['virtual>=3', 'virtual<=2'])], targets=['app']),
        case('all-missing', packages=[p('app', depends=['a', 'b'])], targets=['app']),
        case('skip-broken', packages=[p('app', depends=['missing']), p('okay')], targets=['app', 'okay'], answers={'remove_packages':1}),
        case('skip-all', packages=[p('app', depends=['missing'])], targets=['app'], answers={'remove_packages':1}),
        case('skip-with-provider-question',packages=[p('app',depends=['v']),p('broken',depends=['missing']),p('a',provides=['v']),p('b',provides=['v'])],targets=['app','broken'],answers={'remove_packages':1,'select_provider':1}),
        case('skip-before-provider-question',packages=[p('app',depends=['v']),p('broken',depends=['missing']),p('a',provides=['v']),p('b',provides=['v'])],targets=['broken','app'],answers={'remove_packages':1,'select_provider':1}),
        case('nested-missing', packages=[p('app', depends=['library']), p('library', depends=['missing'])], targets=['app']),
        case('cycle', packages=[p('a', depends=['b']), p('b', depends=['c']), p('c', depends=['a'])], targets=['a']),
        case('indirect-cycle', local=[p('b', depends=['c'])], packages=[p('a', depends=['b']), p('c', depends=['a'])], targets=['a','c']),
        case('self-dependency', packages=[p('a', depends=['a'])], targets=['a']),
        case('build-deps-metadata-only', packages=[p('a', make_depends=['missing'], check_depends=['missing'])], targets=['a']),
        case('ignore-decline', packages=[p('app')], targets=['app'], ignore_packages=['a*']),
        case('ignore-accept', packages=[p('app')], targets=['app'], ignore_packages=['a*'], answers={'install_ignored':1}),
        case('ignored-dependency', packages=[p('app',depends=['library']),p('library')], targets=['app'], ignore_packages=['library']),
        case('ignored-group', packages=[p('app',groups=['hidden'])], targets=['app'], ignore_groups=['h?dden']),
        case('ignore-no-inversion', packages=[p('app')], targets=['app'], ignore_packages=['!app']),
        case('assumed-version', packages=[p('app',depends=['virtual>=2'])], targets=['app'], assume_installed=['virtual=2']),
        case('assumed-unversioned', packages=[p('app',depends=['virtual>=2'])], targets=['app'], assume_installed=['virtual']),
        case('empty-relation-name-assume', packages=[p('app',depends=['<2'])], targets=['app'], assume_installed=['unrelated']),
        case('empty-assumed-provision', packages=[p('app',depends=['<2'])], targets=['app'], assume_installed=['']),
        case('duplicate-same', packages=[p('app')], targets=['app','app']),
        case('duplicate-other-repo', targets=['test/app','second/app'], repositories=[repo([p('app')]),repo([p('app','2-1')],'second')]),
        case('duplicate-filename', packages=[p('a',filename='same.pkg.tar'),p('b',filename='same.pkg.tar')], targets=['a','b']),
        case('arch-cachyos', packages=[p('app',arch='x86_64_v3')], targets=['app'], architectures=['x86_64_v3','x86_64']),
        case('arch-invalid', packages=[p('app',arch='aarch64')], targets=['app'], architectures=['x86_64_v3']),
        case('arch-pulled-not-prechecked', packages=[p('app',arch='any',depends=['library']),p('library',arch='aarch64')], targets=['app'], architectures=['x86_64_v3']),
        case('inner-conflict', packages=[p('a',conflicts=['b']),p('b')], targets=['a','b']),
        case('inner-providing-target', packages=[p('a',conflicts=['b'],provides=['b']),p('b'),p('c',depends=['b'])], targets=['b','c','a']),
        case('reverse-conflict', local=[p('old',conflicts=['virtual>=2'])], packages=[p('new',provides=['virtual=2'])], targets=['new'], answers={'conflict':1}),
        case('conflict-decline', local=[p('old')], packages=[p('new',conflicts=['old'])], targets=['new']),
        case('conflict-breaks-survivor', local=[p('old'),p('stay',depends=['old'])], packages=[p('new',conflicts=['old'])], targets=['new'], answers={'conflict':1}),
        case('unrelated-broken-local', local=[p('old',depends=['missing'])], packages=[p('new')], targets=['new']),
        case('lost-provision', local=[p('a',provides=['virtual']),p('b',depends=['virtual'])], packages=[p('a','2-1')], targets=['a']),
        case('remove-shared-provider', local=[p('a',provides=['virtual']),p('b',provides=['virtual']),p('c',depends=['virtual'])], remove=['a']),
        case('remove-both-providers', local=[p('a',provides=['virtual']),p('b',provides=['virtual']),p('c',depends=['virtual'])], remove=['a','b']),
        case('remove-optional-recursion',local=[p('a',depends=['b']),p('b',reason=1),p('c',optional_depends=['b: support'])],remove=['a'],flags=1<<5),
        case('upgrade-priority',local=[p('a','5-1')],repositories=[repo([p('a','4-1')]),repo([p('a','9-1')],'second')],system_upgrade=True),
        case('downgrade-opt-in',local=[p('a','5-1')],packages=[p('a','4-1')],system_upgrade=True,allow_downgrade=True),
        case('upgrade-absent',local=[p('orphan')],system_upgrade=True),
        case('upgrade-ignore',local=[p('a')],packages=[p('a','2-1')],system_upgrade=True,ignore_packages=['a']),
        case('replace-accept',local=[p('old',reason=1)],packages=[p('new',replaces=['old'])],system_upgrade=True,answers={'replace':1}),
        case('replace-decline-literal',local=[p('old')],packages=[p('new',replaces=['old']),p('old','2-1')],system_upgrade=True),
        case('replace-reuse-explicit-reason',local=[p('a',reason=1),p('b',reason=0)],packages=[p('new',replaces=['a','b'])],system_upgrade=True,answers={'replace':1}),
        case('replace-dependency-reused',local=[p('old'),p('stay',depends=['old'])],packages=[p('new',provides=['old'],replaces=['old']),p('stay','2-1',depends=['old'])],system_upgrade=True,answers={'replace':1}),
        case('replace-literal-only',local=[p('old',provides=['virtual'])],packages=[p('new',replaces=['virtual'])],system_upgrade=True,answers={'replace':1}),
        case('mixed-file-sync',packages=[p('dep')],archives=[p('app',depends=['dep'])],targets=['@0']),
        case('mixed-file-conflict',local=[p('old')],archives=[p('app',conflicts=['old'])],targets=['@0'],answers={'conflict':1}),
        case('archive-with-sync-target',packages=[p('app',depends=['virtual'])],archives=[p('file',provides=['virtual'])],targets=['app','@0']),
        case('archives-duplicate-filename',archives=[p('a',path='shared.pkg.tar'),p('b',path='shared.pkg.tar')],targets=['@0','@1']),
        case('archives-duplicate-filename-nodeps',archives=[p('a',path='shared.pkg.tar'),p('b',path='shared.pkg.tar')],targets=['@0','@1'],flags=1),
        case('providers-same-name-two-repos',repositories=[repo([p('provider',provides=['v'])]),repo([p('provider','2-1',provides=['v'])],'second')],targets=['v'],answers={'select_provider':1}),
        case('installed-provider-before-choice',local=[p('z')],repositories=[repo([p('a',provides=['v'])]),repo([p('z',provides=['v'])],'second')],targets=['v']),
        case('ignored-literal-provider-fallback',packages=[p('v'),p('provider',provides=['v'])],targets=['v'],ignore_packages=['v']),
        case('local-upgrade-fallback',local=[p('provider',provides=['v'])],packages=[p('app',depends=['v']),p('provider','2-1',provides=['v'],depends=['missing'])],targets=['app','provider']),
        case('local-upgrade-fallback-skip',local=[p('provider',provides=['v'])],packages=[p('app',depends=['v']),p('provider','2-1',provides=['v'],depends=['missing'])],targets=['app','provider'],answers={'remove_packages':1}),
        case('target-version-not-ignored',packages=[p('app')],targets=['app>=2'],flags=8),
        case('three-inner-conflicts',packages=[p('a',conflicts=['b','c']),p('b'),p('c')],targets=['a','b','c']),
        case('self-conflict-virtual',packages=[p('a',provides=['v'],conflicts=['v'])],targets=['a']),
        case('conflicting-constraints-selected-name',packages=[p('a',depends=['dep>=2']),p('b',depends=['dep<2']),p('dep','2-1')],targets=['a','b']),
        case('removal-all-provider-recursion',local=[p('app',depends=['v']),p('a',provides=['v'],reason=1),p('b',provides=['v'],reason=1)],remove=['app'],flags=1<<5),
        case('recurse-all-alone',local=[p('app',depends=['dep']),p('dep')],remove=['app'],flags=1<<16),
        case('remove-versioned-recursion',local=[p('app',depends=['dep>=2']),p('dep',reason=1)],remove=['app'],flags=8|1<<5),
        case('all-executor-flags-retained',packages=[p('app',depends=['dep']),p('dep')],targets=['app'],flags=(1<<2)|(1<<6)|(1<<7)|(1<<9)|(1<<10)|(1<<17)),
    ]
    for usage in range(16):
        cases.append(case(f'usage-{usage}',repositories=[repo([p('app')],usage=usage)],targets=['app']))
    for flags in (0,1,8,1<<11,1|1<<11,8|1<<11):
        cases.append(case(f'conflict-flags-{flags}',local=[p('old')],packages=[p('app',depends=['missing'],conflicts=['old'])],targets=['app'],flags=flags))
    for flags in (0,1<<13,1<<8,1<<14,(1<<8)|(1<<14)):
        for version in ('1-1','2-1','0-1'):
            cases.append(case(f'reason-needed-{flags}-{version}',local=[p('app',reason=1)],packages=[p('app',version)],targets=['app'],flags=flags))
    for flags in (0,1,1<<4,1<<5,(1<<4)|(1<<5),1<<15,(1<<5)|(1<<15),(1<<5)|(1<<16),(1<<4)|(1<<15),1|(1<<4)|(1<<5)):
        cases.append(case(f'remove-flags-{flags}',local=[p('app',depends=['dep']),p('dep',depends=['leaf'],reason=1),p('leaf',reason=1),p('stay',depends=['dep'])],remove=['app','dep'],flags=flags))
    return cases

def frozen_cases():
    names = ['depconflict100','depconflict110','depconflict111','depconflict120','dependency-cycle-fixed-by-upgrade','deprange001','remove-recursive-cycle','remove-optdepend-of-installed-package','remove-assumeinstalled','sync-install-assumeinstalled','sync-update-assumeinstalled','sync-update-package-removing-required-provides']
    names += [f'sync-nodepversion{i:02d}' for i in range(1,7)]
    names += [f'remove{i:03d}' for i in (10,11,12,20,21,30,31,40,41,42,43,44,45,47,49,50,51,52)]
    class Pkg:
        def __init__(self,name,version='1.0-1'):
            self.name=name; self.version=version; self.reason=0; self.arch='any'; self.files=[]
            for attr in ('depends','provides','conflicts','replaces','optdepends','groups','makedepends','checkdepends'): setattr(self,attr,[])
        def filename(self): return f'{self.name}-{self.version}.pkg.tar.gz'
        def export(self):
            return p(self.name,self.version,reason=self.reason,arch=self.arch,**{key:getattr(self,{'optional_depends':'optdepends','make_depends':'makedepends','check_depends':'checkdepends'}.get(key,key)) for key in FIELDS})
    class Test:
        def __init__(self): self.dbs={}; self.archives=[]; self.option={}; self.args=''; self.rules=[]
        def addpkg2db(self,db,pkg): self.dbs.setdefault(db,[]).append(pkg)
        def addpkg(self,pkg): self.archives.append(pkg)
        def addrule(self,rule): self.rules.append(rule)
    result=[]
    with tarfile.open(HERE/'downstream-source-tests.tar.gz') as archive:
        for name in names:
            path=f'test/pacman/tests/{name}.py'; source=archive.extractfile(path).read()
            test=Test(); exec(compile(source,path,'exec'),{'self':test,'pmpkg':Pkg})
            tokens=shlex.split(test.args); flags=0; targets=[]; assume=[]; ask=0; operation=tokens.pop(0)
            if 'd' in operation: flags |= 1 if operation.count('d')>1 else 8
            if 'c' in operation: flags |= 1<<4
            if 's' in operation: flags |= 1<<5
            if operation.count('s')>1: flags |= 1<<16
            if 'u' in operation and 'R' in operation: flags |= 1<<15
            i=0
            while i<len(tokens):
                token=tokens[i];i+=1
                if token=='--debug': continue
                if token.startswith('--ask='): ask=int(token.split('=')[1]);continue
                if token=='--assume-installed': assume.append(tokens[i]);i+=1;continue
                if token.startswith('-'): raise ValueError((name,token))
                targets.append(token)
            if 'U' in operation: targets=['@'+str(next(i for i,pkg in enumerate(test.archives) if pkg.filename()==target)) for target in targets]
            result.append(dict(name='frozen/'+name,source=path,source_sha256=hashlib.sha256(source).hexdigest(),local=[pkg.export() for pkg in test.dbs.pop('local',[])],repositories=[repo([pkg.export() for pkg in pkgs],db) for db,pkgs in test.dbs.items()],archives=[pkg.export() for pkg in test.archives],targets=[] if 'R' in operation else targets,remove=targets if 'R' in operation else [],flags=flags,system_upgrade='u' in operation and 'S' in operation,assume_installed=assume,answers={'conflict':int(bool(ask&4))},upstream_expected_failure=getattr(test,'expectfailure',False)))
    return result

def generated_cases():
    rng=random.Random(540941)
    result=[]
    for i in range(160):
        local=[]; packages=[]
        for name in ('a','b','c','d'):
            depends=rng.sample(['a','b','c','v>=2','absent'],rng.randrange(3))
            provides=['v='+str(rng.randrange(1,4))] if rng.randrange(2) else []
            if rng.randrange(3): local.append(p(name,depends=depends,provides=provides,reason=rng.randrange(2)))
            if rng.randrange(4): packages.append(p(name,str(rng.randrange(1,4))+'-1',depends=depends if rng.randrange(2) else [],provides=provides,conflicts=[rng.choice(['a','b','v'])] if rng.randrange(4)==0 else []))
        kwargs=dict(answers={'conflict':rng.randrange(2),'remove_packages':rng.randrange(2)},flags=rng.choice([0,1,8,1<<11,1<<4,1<<5,1<<15]))
        if i%3==0: kwargs.update(system_upgrade=True)
        elif i%3==1: kwargs.update(targets=[pkg['name'] for pkg in rng.sample(packages,min(len(packages),2))])
        else: kwargs.update(remove=[pkg['name'] for pkg in rng.sample(local,min(len(local),2))])
        result.append(case(f'generated-{i:03d}',local,packages,**kwargs))
    return result

class Missing(c.Structure): _fields_=[('target',c.c_char_p),('dep',c.c_void_p),('causing',c.c_char_p)]
class Dependency(c.Structure): _fields_=[('name',c.c_char_p),('version',c.c_char_p),('description',c.c_char_p),('name_hash',c.c_ulong),('mode',c.c_int)]
class Conflict(c.Structure): _fields_=[('first',c.c_void_p),('second',c.c_void_p),('reason',c.c_void_p)]
class Question(c.Structure): _fields_=[('kind',c.c_int),('answer',c.c_int),('first',c.c_void_p),('second',c.c_void_p),('third',c.c_void_p)]

def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--library',required=True,type=Path)
    args=parser.parse_args(); digest=hashlib.sha256(args.library.read_bytes()).hexdigest()
    manifest=json.loads((HERE/'manifest.json').read_text())
    if digest!=manifest['library']['sha256']: parser.error('library does not match frozen reference')
    locale.setlocale(locale.LC_ALL,'C');lib=c.CDLL(str(args.library.resolve())); libc=c.CDLL(None)
    libc.free.argtypes=[c.c_void_p]
    libc.vsnprintf.argtypes=[c.c_void_p,c.c_size_t,c.c_char_p,c.c_void_p]
    def bind(name,restype,*args):
        fn=getattr(lib,name);fn.restype=restype;fn.argtypes=list(args);return fn
    initialize=bind('alpm_initialize',c.c_void_p,c.c_char_p,c.c_char_p,c.POINTER(c.c_int))
    release=bind('alpm_release',c.c_int,c.c_void_p)
    errno=bind('alpm_errno',c.c_int,c.c_void_p)
    register=bind('alpm_register_syncdb',c.c_void_p,c.c_void_p,c.c_char_p,c.c_int)
    localdb=bind('alpm_get_localdb',c.c_void_p,c.c_void_p)
    getpkg=bind('alpm_db_get_pkg',c.c_void_p,c.c_void_p,c.c_char_p)
    getdb=bind('alpm_pkg_get_db',c.c_void_p,c.c_void_p)
    dbname=bind('alpm_db_get_name',c.c_char_p,c.c_void_p)
    pkgname=bind('alpm_pkg_get_name',c.c_char_p,c.c_void_p)
    pkgversion=bind('alpm_pkg_get_version',c.c_char_p,c.c_void_p)
    origin=bind('alpm_pkg_get_origin',c.c_int,c.c_void_p)
    reason=bind('alpm_pkg_get_reason',c.c_int,c.c_void_p)
    compute_dep=bind('alpm_dep_compute_string',c.c_void_p,c.c_void_p)
    getadd=bind('alpm_trans_get_add',ListPtr,c.c_void_p)
    getremove=bind('alpm_trans_get_remove',ListPtr,c.c_void_p)
    add=bind('alpm_add_pkg',c.c_int,c.c_void_p,c.c_void_p)
    remove=bind('alpm_remove_pkg',c.c_int,c.c_void_p,c.c_void_p)
    find=bind('alpm_find_dbs_satisfier',c.c_void_p,c.c_void_p,ListPtr,c.c_char_p)
    getdbs=bind('alpm_get_syncdbs',ListPtr,c.c_void_p)
    getcache=bind('alpm_db_get_pkgcache',ListPtr,c.c_void_p)
    new_version=bind('alpm_sync_get_new_version',c.c_void_p,c.c_void_p,ListPtr)
    should_ignore=bind('alpm_pkg_should_ignore',c.c_int,c.c_void_p,c.c_void_p)
    satisfier=bind('alpm_find_satisfier',c.c_void_p,ListPtr,c.c_char_p)
    version_compare=bind('alpm_pkg_vercmp',c.c_int,c.c_char_p,c.c_char_p)
    getdepends=bind('alpm_pkg_get_depends',ListPtr,c.c_void_p)
    getprovides=bind('alpm_pkg_get_provides',ListPtr,c.c_void_p)
    prepare=bind('alpm_trans_prepare',c.c_int,c.c_void_p,c.POINTER(ListPtr))
    free_list=bind('alpm_list_free',None,ListPtr)
    header=(HERE/'downstream-alpm.h').read_text()
    errors=re.findall(r'\b(ALPM_ERR_\w+)\s*(?:=\s*0)?\s*[,\n]',header.split('typedef enum _alpm_errno_t {',1)[1].split('}',1)[0])
    categories={'PKG_NOT_FOUND':'target_not_found','PKG_IGNORED':'ignored','TRANS_DUP_TARGET':'duplicate_target','TRANS_DUP_FILENAME':'duplicate_filename','PKG_INVALID_ARCH':'invalid_architecture','UNSATISFIED_DEPS':'unsatisfied_dependencies','CONFLICTING_DEPS':'conflicting_dependencies'}
    def walk(head):
        while head: yield head.contents.data;head=head.contents.next
    def identity(pkg):
        db='file' if origin(pkg)==1 else dbname(getdb(pkg)).decode()
        return db+'/'+pkgname(pkg).decode()+'@'+pkgversion(pkg).decode()
    def dep(ptr):
        value=compute_dep(ptr)
        try: return c.string_at(value).decode()
        finally: libc.free(value)
    def description(pkg):
        values={'NAME':[pkg['name']],'VERSION':[pkg['version']],'FILENAME':[pkg.get('filename',pkg['name']+'-'+pkg['version']+'.pkg.tar')],'ARCH':[pkg.get('arch','any')],'CSIZE':['100'],'ISIZE':['300'],'REASON':[str(pkg.get('reason',0))]}
        for field in FIELDS: values[{'optional_depends':'OPTDEPENDS','make_depends':'MAKEDEPENDS','check_depends':'CHECKDEPENDS'}.get(field,field.upper())]=pkg.get(field,[])
        return ''.join('%'+field+'%\n'+'\n'.join(items)+'\n\n' for field,items in values.items() if items).encode()
    def matches(dependency,version):
        if dependency.mode==1: return True
        cmp=version_compare(version,dependency.version)
        return {2:cmp==0,3:cmp>=0,4:cmp<=0,5:cmp<0,6:cmp>0}[dependency.mode]
    def selected_provision(dependency,provided):
        value=c.cast(provided,c.POINTER(Dependency)).contents
        return dependency.name==value.name and (dependency.mode==1 or (value.mode==2 and matches(dependency,value.version)))
    def graph(handle,flags):
        if flags&1: return []
        adds=list(walk(getadd(handle))); removed={pkgname(pkg) for pkg in walk(getremove(handle))}|{pkgname(pkg) for pkg in adds}
        future=adds+[pkg for pkg in walk(getcache(localdb(handle))) if pkgname(pkg) not in removed]
        nodes=[List(pkg,None,None) for pkg in future]
        for i in range(len(nodes)-1): nodes[i].next=c.pointer(nodes[i+1])
        head=c.pointer(nodes[0]) if nodes else ListPtr()
        assumed=bind('alpm_option_get_assumeinstalled',ListPtr,c.c_void_p)(handle)
        result=[]
        for pkg in future:
            for dep_ptr in walk(getdepends(pkg)):
                original=dep(dep_ptr); dependency=c.cast(dep_ptr,c.POINTER(Dependency)).contents
                effective=Dependency(dependency.name,dependency.version,dependency.description,dependency.name_hash,1 if flags&8 else dependency.mode)
                chosen=satisfier(head,effective.name if flags&8 else original.encode())
                value=dict(requiring=identity(pkg),dependency=original,satisfier=None,provision=None,assumed=None)
                if chosen:
                    value['satisfier']=identity(chosen)
                    if effective.name!=pkgname(chosen) or not matches(effective,pkgversion(chosen)):
                        value['provision']=next(dep(provided) for provided in walk(getprovides(chosen)) if selected_provision(effective,provided))
                else:
                    value['assumed']=next((dep(provided) for provided in walk(assumed) if selected_provision(effective,provided)),None)
                    if value['assumed'] is None: continue
                result.append(value)
        return result
    def archive(path,entries):
        with tarfile.open(path,'w',format=tarfile.USTAR_FORMAT) as output:
            for name,contents in entries:
                info=tarfile.TarInfo(name);info.size=len(contents);output.addfile(info,io.BytesIO(contents))
    results=[]
    with tempfile.TemporaryDirectory(prefix='rlpm-resolver-reference-') as temp:
        option_root=Path(temp)/'options-root';option_root.mkdir()
        option_db=Path(temp)/'options-db';option_db.mkdir()
        error=c.c_int();handle=initialize(str(option_root).encode(),str(option_db).encode(),c.byref(error));assert handle
        assumed_options=[]
        try:
            for text in ('virtual','virtual=2','virtual=alpha:1.0: description','empty=','', 'virtual>=2','virtual<2','virtual>2','virtual<=2'):
                relation=bind('alpm_dep_from_string',c.c_void_p,c.c_char_p)(text.encode());assert relation
                success=bind('alpm_option_add_assumeinstalled',c.c_int,c.c_void_p,c.c_void_p)(handle,relation)==0
                assumed_options.append(dict(relation=text,success=success))
                bind('alpm_dep_free',None,c.c_void_p)(relation)
        finally: assert release(handle)==0
        for number,case_value in enumerate(frozen_cases()+manual_cases()+generated_cases()):
            base=Path(temp)/str(number);base.mkdir();root=base/'root';root.mkdir();db=base/'db';(db/'local').mkdir(parents=True);(db/'sync').mkdir();(db/'local/ALPM_DB_VERSION').write_text('9\n')
            for pkg in case_value['local']:
                directory=db/'local'/(pkg['name']+'-'+pkg['version']);directory.mkdir();(directory/'desc').write_bytes(description(pkg));(directory/'files').write_text('')
            for repository in case_value['repositories']:
                archive(db/'sync'/(repository['name']+'.db'),[(pkg['name']+'-'+pkg['version']+'/desc',description(pkg)) for pkg in repository['packages']])
            for index,pkg in enumerate(case_value.get('archives',[])):
                info=f"pkgname = {pkg['name']}\npkgver = {pkg['version']}\narch = {pkg.get('arch','any')}\nsize = 300\n"
                for field in FIELDS:
                    key={'depends':'depend','optional_depends':'optdepend','make_depends':'makedepend','check_depends':'checkdepend','groups':'group','conflicts':'conflict'}.get(field,field)
                    info+=''.join(f'{key} = {item}\n' for item in pkg.get(field,[]))
                archive(base/f'{index}.pkg.tar',[('.PKGINFO',info.encode()),('payload',b'')])
            def capture():
                error=c.c_int();handle=initialize(str(root).encode(),str(db).encode(),c.byref(error));assert handle
                questions=[];cycles=[];callback_errors=[]
                @c.CFUNCTYPE(None,c.c_void_p,c.POINTER(Question))
                def question_callback(_,pointer):
                    try:
                        q=pointer.contents;kind={1:'install_ignored',2:'replace',4:'conflict',16:'remove_packages',32:'select_provider'}[q.kind]
                        answer=case_value.get('answers',{}).get(kind,0);q.answer=answer
                        value=dict(kind=kind,answer=answer)
                        if kind=='install_ignored': value['packages']=[identity(q.first)]
                        elif kind=='replace': value['packages']=[identity(q.first),identity(q.second)]
                        elif kind=='conflict':
                            conflict=c.cast(q.first,c.POINTER(Conflict)).contents;value.update(packages=[identity(conflict.first),identity(conflict.second)],dependency=dep(conflict.reason))
                        else:
                            value['packages']=[identity(pkg) for pkg in walk(c.cast(q.first,ListPtr))]
                            if kind=='select_provider': value['dependency']=dep(q.second)
                        questions.append(value)
                    except BaseException as exc: callback_errors.append(repr(exc))
                @c.CFUNCTYPE(None,c.c_void_p,c.c_int,c.c_char_p,c.c_void_p)
                def log_callback(_,level,fmt,va):
                    buffer=c.create_string_buffer(4096);libc.vsnprintf(buffer,len(buffer),fmt,va)
                    text=buffer.value.decode(errors='replace')
                    if ' will be installed before its ' in text or ' will be removed after its ' in text: cycles.append(text.strip())
                try:
                    bind('alpm_option_set_questioncb',c.c_int,c.c_void_p,c.c_void_p,c.c_void_p)(handle,question_callback,None)
                    bind('alpm_option_set_logcb',c.c_int,c.c_void_p,c.c_void_p,c.c_void_p)(handle,log_callback,None)
                    for field,option in [('ignore_packages','ignorepkg'),('ignore_groups','ignoregroup'),('architectures','architecture')]:
                        for value in case_value.get(field,[]): assert bind('alpm_option_add_'+option,c.c_int,c.c_void_p,c.c_char_p)(handle,value.encode())==0
                    for value in case_value.get('assume_installed',[]):
                        relation=bind('alpm_dep_from_string',c.c_void_p,c.c_char_p)(value.encode())
                        assert bind('alpm_option_add_assumeinstalled',c.c_int,c.c_void_p,c.c_void_p)(handle,relation)==0
                        bind('alpm_dep_free',None,c.c_void_p)(relation)
                    databases={}
                    for repository in case_value['repositories']:
                        database=register(handle,repository['name'].encode(),0);assert database;databases[repository['name']]=database
                        assert bind('alpm_db_set_usage',c.c_int,c.c_void_p,c.c_int)(database,repository['usage'])==0
                    queries=[]
                    for pkg in walk(getcache(localdb(handle))):
                        newer=new_version(pkg,getdbs(handle))
                        queries.append(dict(package=identity(pkg),new_version=identity(newer) if newer else None,ignored=bool(should_ignore(handle,pkg))))
                    flags=case_value.get('flags',0)|(1<<17)
                    assert bind('alpm_trans_init',c.c_int,c.c_void_p,c.c_int)(handle,flags)==0
                    status=0;stage='target';data=ListPtr()
                    for name in case_value.get('remove',[]):
                        pkg=getpkg(localdb(handle),name.encode());assert pkg
                        status=remove(handle,pkg)
                        if status: break
                    for target in case_value['targets']:
                        if status: break
                        if target.startswith('@'):
                            archive_path=base/(target[1:]+'.pkg.tar')
                            if 'path' in case_value['archives'][int(target[1:])]:
                                selected_path=base/case_value['archives'][int(target[1:])]['path']
                                selected_path.write_bytes(archive_path.read_bytes());archive_path=selected_path
                            pkg=c.c_void_p();status=bind('alpm_pkg_load',c.c_int,c.c_void_p,c.c_char_p,c.c_int,c.c_int,c.POINTER(c.c_void_p))(handle,str(archive_path).encode(),1,0,c.byref(pkg))
                            assert status==0
                        else:
                            if '/' in target:
                                repository,relation=target.split('/',1);node=List(databases[repository],None,None);dbs=c.pointer(node)
                            else: relation=target;dbs=getdbs(handle)
                            pkg=find(handle,dbs,relation.encode())
                            if not pkg: status=-1;break
                        status=add(handle,pkg)
                    if status==0 and case_value.get('system_upgrade'):
                        stage='upgrade';status=bind('alpm_sync_sysupgrade',c.c_int,c.c_void_p,c.c_int)(handle,int(case_value.get('allow_downgrade',False)))
                    if status==0: stage='prepare';status=prepare(handle,c.byref(data))
                    error_name=errors[errno(handle)] if status else 'ALPM_ERR_OK'
                    result=dict(success=status==0,stage=stage,error=error_name,category=categories.get(error_name.removeprefix('ALPM_ERR_')),questions=questions,cycles=cycles,issues=[])
                    result['add']=[dict(identity=identity(pkg),reason=reason(pkg)) for pkg in walk(getadd(handle))]
                    result['remove']=[identity(pkg) for pkg in walk(getremove(handle))]
                    result['queries']=queries
                    result['edges']=graph(handle,flags) if status==0 else []
                    for ptr in walk(data):
                        if error_name=='ALPM_ERR_UNSATISFIED_DEPS':
                            issue=c.cast(ptr,c.POINTER(Missing)).contents
                            result['issues'].append(dict(requiring=issue.target.decode(),dependency=dep(issue.dep),causing=issue.causing.decode() if issue.causing else None))
                            bind('alpm_depmissing_free',None,c.c_void_p)(ptr)
                        elif error_name=='ALPM_ERR_CONFLICTING_DEPS':
                            issue=c.cast(ptr,c.POINTER(Conflict)).contents
                            result['issues'].append(dict(first=identity(issue.first),second=identity(issue.second),dependency=dep(issue.reason)))
                            bind('alpm_conflict_free',None,c.c_void_p)(ptr)
                        else: libc.free(ptr)
                    free_list(data)
                    assert not callback_errors,callback_errors
                    assert bind('alpm_trans_release',c.c_int,c.c_void_p)(handle)==0
                    return result
                finally: assert release(handle)==0
            def checked_capture():
                try: return capture()
                except BaseException:
                    print(case_value['name'],file=sys.stderr);traceback.print_exc();raise
            captured=isolated_capture(checked_capture,False)
            if 'reference_signal' in captured: raise RuntimeError((case_value['name'],captured))
            results.append(dict(case_value,result=captured))
    print(json.dumps(dict(schema=1,library_sha256=digest,locale='C',generated_seed=540941,assumed_options=assumed_options,cases=results),indent=2))

if __name__=='__main__': main()
