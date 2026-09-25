#!/usr/bin/env python3
"""Exercise desktop integration using temporary entries and fake helper commands."""
from pathlib import Path
import tempfile,subprocess,os
with tempfile.TemporaryDirectory(prefix='shelly-desktop-test-') as d:
 root=Path(d);home=root/'home';apps=home/'.local/share/flatpak/exports/share/applications';apps.mkdir(parents=True)
 (apps/'example.desktop').write_text('[Desktop Entry]\nType=Application\nName=Example\nExec=example\n')
 tools=root/'bin';tools.mkdir();refresh=tools/'update-desktop-database';refresh.write_text('#!/bin/bash\nexit 0\n');refresh.chmod(0o755)
 # Isolate the system source as well as HOME; never touch installed entries.
 script=root/'integrate';script.write_text((Path(__file__).resolve().parents[1] / 'shelly-flatpak-integrate').read_text().replace('/var/lib/flatpak/exports/share/applications',str(root/'absent-system')))
 env={**os.environ,'HOME':str(home),'PATH':str(tools)+':'+os.environ['PATH']}
 def run():return subprocess.run(['bash',str(script)],env=env,text=True,capture_output=True)
 first=run();assert first.returncode==0,first.stderr
 dest=home/'.local/share/applications/example.desktop';assert dest.read_text().count('[Desktop Action ShellyManage]')==1
 second=run();assert second.returncode==0 and '0 entries updated' in second.stdout
 refresh.write_text('#!/bin/bash\nprintf "fixture refresh failure" >&2\nexit 1\n')
 warning=run();assert warning.returncode==0 and 'cache could not be refreshed' in warning.stderr
 (apps/'other.desktop').write_text('[Desktop Entry]\nName=Other\n');cp=tools/'cp';cp.write_text('#!/bin/bash\nprintf "fixture copy failure" >&2\nexit 1\n');cp.chmod(0o755)
 partial=run();assert partial.returncode==1 and '1 entries could not' in partial.stderr and 'fixture' in partial.stderr
 assert not (dest.parent/'other.desktop').exists();assert not list(dest.parent.glob('.shelly-desktop.*'))
 print('Desktop integration fixtures: success, repeat, refresh warning, partial copy failure, and temporary-file cleanup passed.')
