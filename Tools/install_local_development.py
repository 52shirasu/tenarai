# coding: utf-8
"""Install an already-built personal development bundle.

Never selects a different input source; only puts back a tenarai source that was
selected before the install, because stopping the IME makes macOS fall back to another
one (otherwise an install leaves the session on Apple's Japanese input)."""
from pathlib import Path
from datetime import datetime
import os
import argparse
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
work = repo.parent / 'work'
parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
configuration = parser.parse_args().configuration
source = work / ('DerivedData/Build/Products/' + configuration + '/azooKeyMac.app')
target = Path.home() / 'Library/Input Methods/tenarai-Dev.app'
agent = Path.home() / 'Library/LaunchAgents/local.tenarai.inputmethod.tenarai.ConverterServer.plist'
updater_agent = Path.home() / 'Library/LaunchAgents/local.tenarai.inputmethod.tenarai.TrendWordsUpdater.plist'
domain = 'gui/' + str(os.getuid())
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
env = dict(os.environ, DEVELOPER_DIR=str(work/'toolchain/Xcode.app/Contents/Developer'))
selection_tool = ['/usr/bin/xcrun', 'swift', str(repo/'Tools/input_source_selection.swift')]


def run_swift(arguments, **kwargs):
    try:
        return subprocess.run(arguments, env=env, check=True, **kwargs)
    except subprocess.CalledProcessError:
        # The bundled toolchain cannot compile against a newer system SDK.
        return subprocess.run(arguments, env={k: v for k, v in os.environ.items() if k != 'DEVELOPER_DIR'}, check=True, **kwargs)


try:
    previous_source = run_swift(selection_tool + ['current'], capture_output=True, text=True).stdout.strip()
except Exception:
    previous_source = ''
# Finish copying before touching the running IME. The old installer exposed a
# partial bundle while ditto was still writing it, allowing premature relaunch.
target.parent.mkdir(parents=True, exist_ok=True)
staging_root = Path(tempfile.mkdtemp(prefix='.tenarai-stage-', dir=target.parent))
staged = staging_root / 'tenarai-Dev.app'
try:
    subprocess.run(['ditto', str(source), str(staged)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
except Exception:
    # Nothing was stopped or replaced yet; only remove the partial staging copy,
    # which would otherwise remain inside ~/Library/Input Methods.
    shutil.rmtree(staging_root, ignore_errors=True)
    raise
if agent.exists():
    subprocess.run(['launchctl', 'bootout', domain, str(agent)], check=False)
backup = None
if target.exists():
    executable = str(target / 'Contents/MacOS/azooKeyMac')
    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    for row in rows:
        parts = row.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == executable:
            subprocess.run(['kill', '-TERM', parts[0]], check=True)
    backup = work / ('previous-tenarai-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.app.backup')
    target.rename(backup)
    print('Previous development bundle:', backup)
target.parent.mkdir(parents=True, exist_ok=True)
try:
    staged.rename(target)
    staging_root.rmdir()
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    subprocess.run([str(repo/'Tools/install_converter_server_launch_agent.sh'), str(target)], check=True)
    subprocess.run([str(repo/'Tools/install_trend_words_updater_launch_agent.sh'), str(target)], check=True)
except Exception:
    # A denied/partial copy must not leave the user's IME missing or stopped.
    if backup is not None and backup.exists():
        if target.exists():
            failed = work / ('failed-tenarai-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.app')
            target.rename(failed)
        backup.rename(target)
        if agent.exists():
            subprocess.run(['launchctl', 'bootout', domain, str(agent)], check=False)
            subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
        # The weekly trend word updater follows the restored bundle: an older bundle
        # without the updater must not keep a launch agent pointing at a missing program.
        if updater_agent.exists():
            subprocess.run(['launchctl', 'bootout', domain, str(updater_agent)], check=False)
            if (target / 'Contents/Helpers/TrendWordsUpdater/TrendWordsUpdater').exists():
                subprocess.run(['launchctl', 'bootstrap', domain, str(updater_agent)], check=True)
            else:
                updater_agent.unlink()
        print('Restored previous development bundle:', target)
    raise
# Registration is idempotent.
run_swift(['/usr/bin/xcrun', 'swift', str(repo/'Tools/register_local_input_method.swift')])
# Terminate any host that macOS relaunched during the replacement window;
# it may still have the previous executable mapped in memory.
executable = str(target / 'Contents/MacOS/azooKeyMac')
for row in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    parts = row.strip().split(None, 1)
    if len(parts) == 2 and parts[1] == executable:
        subprocess.run(['kill', '-TERM', parts[0]], check=False)
subprocess.run(['open', str(target)], check=True)
# macOS does not always start an ad-hoc signed input method after login even when
# it is the selected source; start it at login. Not fatal: the IME is already running.
launcher = subprocess.run([str(repo/'Tools/install_input_method_login_launch_agent.sh'), str(target)], check=False)
if launcher.returncode != 0:
    print('WARNING: could not install the login launcher; after a login, open the bundle once by hand')
print('Installed:', target)
if previous_source.startswith('local.tenarai.inputmethod.tenarai'):
    try:
        run_swift(selection_tool + ['select', previous_source])
        now = run_swift(selection_tool + ['current'], capture_output=True, text=True).stdout.strip()
        print('Input source before install restored:', previous_source, '(now: ' + now + ')')
    except Exception as error:
        print('WARNING: could not restore the input source', previous_source, '-', error)
else:
    print('Input source was not tenarai before install; left unchanged:', previous_source or '(unknown)')
