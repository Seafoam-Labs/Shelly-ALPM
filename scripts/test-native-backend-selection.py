#!/usr/bin/env python3
"""Check native-test backend selection without compiling or installing packages."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).resolve().with_name("test-native-backends.sh")


class BackendSelectionTests(unittest.TestCase):
    def run_selection(self, *args, metadata=False, compile_ok=True, runtime_ok=True):
        with tempfile.TemporaryDirectory(prefix="shelly-backend-selection-") as temporary:
            root = Path(temporary)
            tools = root / "bin"
            tools.mkdir()
            log = root / "commands.jsonl"
            pkg_config = tools / "pkg-config"
            pkg_config.write_text("""#!/usr/bin/env python3
import os, sys
if os.environ['NATIVE_TEST_METADATA'] != '1':
    sys.exit(1)
if sys.argv[1] != '--exists':
    print('-I/private/include -L/private/lib -lalpm')
""")
            zig = tools / "zig"
            zig.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
with open(os.environ['NATIVE_TEST_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1] == 'cc':
    if os.environ['NATIVE_TEST_COMPILE'] != '1':
        sys.exit(1)
    output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
    status = '0' if os.environ['NATIVE_TEST_RUNTIME'] == '1' else '1'
    output.write_text('#!/bin/sh\\nexit ' + status + '\\n')
    output.chmod(0o755)
    sys.exit(0)
# Stop at the first real build, after recording the selected backend.
sys.exit(93)
""")
            pkg_config.chmod(0o755)
            zig.chmod(0o755)
            environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
            environment.update(
                NATIVE_TEST_METADATA=str(int(metadata)),
                NATIVE_TEST_COMPILE=str(int(compile_ok)),
                NATIVE_TEST_RUNTIME=str(int(runtime_ok)),
                NATIVE_TEST_LOG=str(log),
            )
            result = subprocess.run(
                ["bash", str(RUNNER), *args], env=environment,
                capture_output=True, text=True,
            )
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    def assert_variant(self, result, commands, enabled):
        self.assertEqual(result.returncode, 93, result.stderr)
        self.assertEqual(commands[-1][0:2], ["build", "native-backend-test"])
        self.assertIn(f"-Dlibalpm={enabled}", commands[-1])

    def test_default_skips_missing_library_and_runs_rlpm(self):
        result, commands = self.run_selection()
        self.assert_variant(result, commands, "false")
        self.assertIn("SKIP: libalpm-specific tests", result.stderr)

    def test_auto_includes_available_library(self):
        result, commands = self.run_selection("auto", metadata=True)
        self.assert_variant(result, commands, "true")
        self.assertNotIn("SKIP:", result.stderr)
        self.assertIn("-lalpm", commands[0])

    def test_auto_skips_unusable_headers_or_linker(self):
        result, commands = self.run_selection("auto", metadata=True, compile_ok=False)
        self.assert_variant(result, commands, "false")
        self.assertIn("SKIP:", result.stderr)

    def test_auto_skips_missing_runtime_library(self):
        result, commands = self.run_selection("auto", metadata=True, runtime_ok=False)
        self.assert_variant(result, commands, "false")

    def test_explicit_true_requires_library(self):
        result, commands = self.run_selection("true")
        self.assertEqual(result.returncode, 1)
        self.assertIn("libalpm=true was requested", result.stderr)
        self.assertEqual(commands, [])

    def test_explicit_true_runs_when_available(self):
        result, commands = self.run_selection("true", metadata=True)
        self.assert_variant(result, commands, "true")

    def test_explicit_false_bypasses_probe(self):
        result, commands = self.run_selection("false", "ReleaseSafe", metadata=True)
        self.assert_variant(result, commands, "false")
        self.assertEqual(len(commands), 1)
        self.assertIn("-Doptimize=ReleaseSafe", commands[0])

    def test_invalid_mode_fails_before_building(self):
        result, commands = self.run_selection("unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
