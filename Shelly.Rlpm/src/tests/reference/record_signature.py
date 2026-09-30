#!/usr/bin/env python3
"""Optional verification oracle: hash-pinned libalpm, disposable GPG homes, no network."""
import argparse
import base64
import ctypes as c
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import sys
sys.dont_write_bytecode = True
from record_metadata import isolated_capture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    args = parser.parse_args()
    digest = hashlib.sha256(args.library.read_bytes()).hexdigest()
    manifest = json.loads(Path(__file__).with_name('manifest.json').read_text())
    if digest != manifest['library']['sha256']:
        parser.error('library does not match frozen reference')
    lib = c.CDLL(str(args.library.resolve()))
    libc = c.CDLL(None)
    libc.free.argtypes = [c.c_void_p]

    def bind(name, result, *arguments):
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = list(arguments)
        return function

    initialize = bind('alpm_initialize', c.c_void_p, c.c_char_p, c.c_char_p, c.POINTER(c.c_int))
    release = bind('alpm_release', c.c_int, c.c_void_p)
    load = bind('alpm_pkg_load', c.c_int, c.c_void_p, c.c_char_p, c.c_int, c.c_int, c.POINTER(c.c_void_p))
    free_pkg = bind('alpm_pkg_free', c.c_int, c.c_void_p)
    set_home = bind('alpm_option_set_gpgdir', c.c_int, c.c_void_p, c.c_char_p)
    errno = bind('alpm_errno', c.c_int, c.c_void_p)
    validation = bind('alpm_pkg_get_validation', c.c_int, c.c_void_p)
    result = dict(schema=1, library_sha256=digest, cases=[], checksums={})
    with tempfile.TemporaryDirectory(prefix='rlpm-sig-ref-') as temp:
        base = Path(temp)
        homes = [base / name for name in ('signer', 'verifier', 'unknown')]
        for home in homes:
            home.mkdir(mode=0o700)
            (home / 'gpg.conf').write_text('no-auto-key-retrieve\nno-auto-key-import\nauto-key-locate clear\n')
        signer, verifier, unknown = homes

        def gpg(home, *options, check=True):
            return subprocess.run(['gpg', '--no-options', '--homedir', str(home), '--batch', '--yes', *map(str, options)], cwd=base, capture_output=True, check=check, timeout=30)

        def fingerprint(identity):
            listing = gpg(signer, '--with-colons', '--list-keys', identity).stdout.decode()
            return next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))

        def sign(identity, *options):
            gpg(signer, '--pinentry-mode', 'loopback', '--passphrase', '', '--local-user', identity, *options, '--output', 'demo.tar.sig', '--detach-sign', 'demo.tar')
            gpg(signer, '--check-trustdb')

        def capture(name, home):
            # Each case has its own handle and database. No callbacks accept imports.
            root = base / (name + '-root'); root.mkdir()
            db = base / (name + '-db'); db.mkdir()
            present = (base / 'demo.tar.sig').exists()
            status = gpg(home, '--no-auto-key-retrieve', '--no-auto-key-import', '--auto-key-locate', 'clear', '--no-auto-check-trustdb', '--no-autostart', '--proc-all-sigs', '--status-fd', '1', '--verify', 'demo.tar.sig', 'demo.tar', check=False)
            row = dict(name=name, present=present, status=status.stdout.decode(), exit=status.returncode, keys=gpg(home, '--with-colons', '--list-keys').stdout.decode())
            def policies():
                # libalpm caches the first GPGME homedir process-wide. A fresh
                # child per case is necessary even when handles are released.
                error = c.c_int()
                handle = initialize(str(root).encode(), str(db).encode(), c.byref(error))
                assert handle, error.value
                assert set_home(handle, str(home).encode()) == 0
                outcomes = []
                for requirement, bits in [('disabled', 0), ('optional', 3), ('required', 1)]:
                    for marginal, unknown_trust in [(False, False), (True, False), (False, True), (True, True)]:
                        package = c.c_void_p()
                        level = bits | (4 if marginal and bits else 0) | (8 if unknown_trust and bits else 0)
                        code = load(handle, str(base / 'demo.tar').encode(), 0, level, c.byref(package))
                        outcome = dict(requirement=requirement, allow_marginal=marginal, allow_unknown=unknown_trust, success=code == 0, errno=errno(handle))
                        if code == 0:
                            outcome['validation'] = validation(package)
                            assert free_pkg(package) == 0
                        outcomes.append(outcome)
                assert release(handle) == 0
                return outcomes
            row['policies'] = isolated_capture(policies, None)
            result['cases'].append(row)

        try:
            identity = 'Signature Reference <signature-reference@example.invalid>'
            second = 'Signature Second <signature-second@example.invalid>'
            gpg(signer, '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key', identity, 'ed25519', 'sign', '0')
            gpg(signer, '--output', 'public.gpg', '--export', identity)
            gpg(verifier, '--import', 'public.gpg')
            with tarfile.open(base / 'demo.tar', 'w', format=tarfile.USTAR_FORMAT) as archive:
                data = b'pkgname = demo\npkgver = 1-1\narch = any\n'
                info = tarfile.TarInfo('.PKGINFO'); info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            original = (base / 'demo.tar').read_bytes()
            for algorithm in ('md5', 'sha256'):
                value = bind('alpm_compute_' + algorithm + 'sum', c.c_void_p, c.c_char_p)(str(base / 'demo.tar').encode())
                assert value
                try: result['checksums'][algorithm] = c.string_at(value).decode()
                finally: libc.free(value)
            result['checksums']['data_base64'] = base64.b64encode(original).decode()
            sign(identity)
            result['issuer'] = dict(fingerprint=fingerprint(identity), signature_base64=base64.b64encode((base / 'demo.tar.sig').read_bytes()).decode())
            capture('full', signer)
            capture('untrusted', verifier)
            capture('unknown_key', unknown)
            (base / 'demo.tar').write_bytes(original + b'tampered')
            capture('tampered', signer)
            (base / 'demo.tar').write_bytes(original)
            (base / 'demo.tar.sig').unlink()
            capture('missing', signer)
            (base / 'demo.tar.sig').write_bytes(b'invalid signature')
            capture('malformed', signer)
            gpg(signer, '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key', second, 'ed25519', 'sign', '0')
            sign(identity, '--local-user', second)
            capture('multiple_full', signer)
            capture('multiple_unknown', verifier)
            expired = 'Signature Expired <signature-expired@example.invalid>'
            past = '20250101T000000'
            gpg(signer, '--faked-system-time', past, '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key', expired, 'ed25519', 'sign', '1d')
            sign(expired, '--faked-system-time', past)
            capture('expired_key', signer)
            eternal = 'Signature Old <signature-old@example.invalid>'
            gpg(signer, '--faked-system-time', past, '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key', eternal, 'ed25519', 'sign', '0')
            sign(eternal, '--faked-system-time', past, '--default-sig-expire', '1d')
            capture('expired_signature', signer)
            sign(identity)
            fpr = fingerprint(identity)
            gpg(signer, '--edit-key', fpr, 'disable', 'quit')
            capture('disabled_key', signer)
            gpg(signer, '--edit-key', fpr, 'enable', 'quit')
            revocation = (signer / 'openpgp-revocs.d' / (fpr + '.rev')).read_text().replace(':-----BEGIN PGP PUBLIC KEY BLOCK-----', '-----BEGIN PGP PUBLIC KEY BLOCK-----')
            (base / 'revoke.asc').write_text(revocation)
            gpg(signer, '--import', 'revoke.asc')
            capture('revoked_key', signer)
        finally:
            # Always stop only the agents belonging to this fixture, then remove it.
            for home in homes:
                subprocess.run(['gpgconf', '--homedir', str(home), '--kill', 'all'], check=True, capture_output=True, timeout=30)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
