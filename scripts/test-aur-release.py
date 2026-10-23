#!/usr/bin/env python3
"""Exercise AUR release preparation with local Git remotes and a Shelly stub."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("aur-release.sh").resolve()
PAYLOAD = b"current release payload\n"
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()
PKGBUILD = "pkgver=1.0.0\npkgrel=1\nsource=('payload')\nsha256sums=('stale')\n"


class AurReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aur-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "checkout"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.repo / "scripts/aur-release.sh")
        for name in ["PKGBUILD", "PKGBUILD-bin"]:
            (self.repo / name).write_text(PKGBUILD)
        (self.repo / "payload").write_bytes(PAYLOAD)
        (self.repo / ".SRCINFO").write_text("original root metadata\n")
        self.remote = self.root / "remotes"
        self.remote.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid")
        for name in ["shelly", "shelly-bin"]:
            remote = self.remote / (name + ".git")
            self.git("init", "--quiet", str(remote))
            (remote / "PKGBUILD").write_text(PKGBUILD)
            # Deliberately omit .SRCINFO: cleanup must retain its first generation.
            self.git("-C", str(remote), "add", "PKGBUILD")
            self.git("-C", str(remote), "commit", "--quiet", "-m", "initial")
        self.shelly = self.root / "shelly"
        self.shelly.write_text('''#!/usr/bin/env python3
import hashlib, os, pathlib, sys, tomllib
args = sys.argv[1:]
pkgbuild = pathlib.Path('PKGBUILD')
if '--updpkgsums' in args:
    config = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'shelly/shellybuild.conf'
    destinations = tomllib.loads(config.read_text())['destinations']
    cache = pathlib.Path(destinations['sources'])
    assert cache.is_dir() and not list(cache.iterdir()), 'must start with a fresh cache'
    assert pathlib.Path(destinations['build']).is_dir()
    assert os.environ['SHELLY_LIBALPM'] == 'true'
    with open(os.environ['TEST_CACHE_LOG'], 'a') as log:
        log.write(str(cache) + '\\n')
    (cache / 'download').write_bytes(b'fresh')
    digest = hashlib.sha256(pathlib.Path('payload').read_bytes()).hexdigest()
    pkgbuild.write_text(pkgbuild.read_text().replace('stale', digest))
    pathlib.Path('.SRCINFO').write_text('pkgbase = shelly\\n\\tsha256sums = ' + digest + '\\n')
    pathlib.Path('download-junk').write_text('remove me')
    if os.environ.get('TEST_FAIL') == 'update':
        sys.exit(7)
elif '--makesrcinfo' in args:
    if os.environ.get('TEST_FAIL') == 'metadata':
        print('partial metadata')
        sys.exit(8)
    print(pathlib.Path('.SRCINFO').read_text(), end='')
else:
    if os.environ.get('TEST_FAIL') == 'build':
        sys.exit(9)
''')
        self.shelly.chmod(0o755)
        self.env.update(SHELLY=str(self.shelly), AUR_GIT_BASE=str(self.remote),
                        SHELLY_LIBALPM="true", TEST_CACHE_LOG=str(self.root / "caches"))

    def git(self, *args):
        return subprocess.run(["git", *args], env=self.env, check=True,
                              capture_output=True, text=True).stdout

    def release(self, *args):
        return subprocess.run(["bash", str(self.repo / "scripts/aur-release.sh"), *args],
                              env=self.env, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True)

    def test_updates_checkout_and_preserves_new_metadata_without_pushing(self):
        before = self.git("-C", str(self.remote / "shelly.git"), "rev-parse", "HEAD")
        result = self.release("shelly")
        self.assertEqual(result.returncode, 0, result.stderr)
        clone = self.repo / ".aur-release/shelly"
        self.assertIn(DIGEST, (self.repo / "PKGBUILD").read_text())
        self.assertEqual((clone / ".SRCINFO").read_bytes(), (self.repo / ".SRCINFO").read_bytes())
        self.assertIn(".SRCINFO", self.git("-C", str(clone), "diff", "--cached", "--name-only"))
        self.assertFalse((clone / "download-junk").exists())
        self.assertEqual(before, self.git("-C", str(self.remote / "shelly.git"), "rev-parse", "HEAD"))
        for cache in (self.root / "caches").read_text().splitlines():
            self.assertFalse(Path(cache).exists())

    def test_dry_run_changes_only_clone(self):
        result = self.release("--dry-run", "shelly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / "PKGBUILD").read_text(), PKGBUILD)
        self.assertEqual((self.repo / ".SRCINFO").read_text(), "original root metadata\n")
        self.assertIn(DIGEST, (self.repo / ".aur-release/shelly/PKGBUILD").read_text())

    def test_other_package_does_not_overwrite_root_metadata(self):
        result = self.release("shelly-bin")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(DIGEST, (self.repo / "PKGBUILD-bin").read_text())
        self.assertEqual((self.repo / "PKGBUILD").read_text(), PKGBUILD)
        self.assertEqual((self.repo / ".SRCINFO").read_text(), "original root metadata\n")

    def test_failure_never_copies_partial_results_to_checkout(self):
        for failure in ["update", "build", "metadata"]:
            with self.subTest(failure=failure):
                self.env["TEST_FAIL"] = failure
                result = self.release("--build", "shelly")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.repo / "PKGBUILD").read_text(), PKGBUILD)
                self.assertEqual((self.repo / ".SRCINFO").read_text(), "original root metadata\n")


if __name__ == "__main__":
    unittest.main()
