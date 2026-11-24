import pathlib
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class InstallRollbackTest(unittest.TestCase):
    def run_installer(self, fail_on, old_has_updater=False, updater_agent_exists=False):
        """Run the installer against a fake home; `fail_on(args)` decides which call fails."""
        source_script = pathlib.Path(__file__).resolve().parents[1] / 'install_local_development.py'
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        script = root / 'repo/Tools/install_local_development.py'
        script.parent.mkdir(parents=True)
        script.write_text(source_script.read_text())
        home = root / 'home'
        target = home / 'Library/Input Methods/tenarai-Dev.app'
        target.mkdir(parents=True)
        (target / 'old').write_text('original')
        agent = home / 'Library/LaunchAgents/local.tenarai.inputmethod.tenarai.ConverterServer.plist'
        agent.parent.mkdir(parents=True)
        agent.touch()
        if old_has_updater:
            updater = target / 'Contents/Helpers/TrendWordsUpdater/TrendWordsUpdater'
            updater.parent.mkdir(parents=True)
            updater.touch()
        self.updater_agent = home / 'Library/LaunchAgents/local.tenarai.inputmethod.tenarai.TrendWordsUpdater.plist'
        if updater_agent_exists:
            self.updater_agent.touch()
        (root / 'work').mkdir()
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            if args[0] == 'ditto':
                # Model a copy that wrote part of the bundle into its destination.
                destination = pathlib.Path(args[2])
                destination.mkdir(parents=True)
                (destination / 'new').touch()
            if fail_on(args):
                raise subprocess.CalledProcessError(1, args)
            return subprocess.CompletedProcess(args, 0)

        with patch('pathlib.Path.home', return_value=home), patch('subprocess.run', side_effect=run), \
                patch('subprocess.check_output', return_value=''), patch('sys.argv', [str(script)]):
            with self.assertRaises(subprocess.CalledProcessError):
                runpy.run_path(str(script), run_name='__main__')
        return target, calls

    def test_copy_failure_leaves_installed_bundle_and_helper_untouched(self):
        target, calls = self.run_installer(lambda args: args[0] == 'ditto')
        self.assertEqual((target / 'old').read_text(), 'original')
        self.assertFalse((target / 'new').exists())
        # The partial staging copy is removed from ~/Library/Input Methods.
        self.assertEqual([p.name for p in target.parent.iterdir()], ['tenarai-Dev.app'])
        self.assertFalse(any(call[:2] == ['launchctl', 'bootout'] for call in calls))

    def test_failure_after_replacement_restores_old_bundle_and_restarts_helper(self):
        target, calls = self.run_installer(
            lambda args: str(args[0]).endswith('install_converter_server_launch_agent.sh'))
        self.assertEqual((target / 'old').read_text(), 'original')
        self.assertFalse((target / 'new').exists())
        self.assertTrue(any(call[:2] == ['launchctl', 'bootout'] for call in calls))
        self.assertTrue(any(call[:2] == ['launchctl', 'bootstrap'] for call in calls))

    def test_updater_failure_removes_updater_agent_when_old_bundle_has_none(self):
        target, calls = self.run_installer(
            lambda args: str(args[0]).endswith('install_trend_words_updater_launch_agent.sh'),
            updater_agent_exists=True)
        self.assertEqual((target / 'old').read_text(), 'original')
        self.assertFalse(self.updater_agent.exists())
        self.assertTrue(any(call[:2] == ['launchctl', 'bootout'] and call[-1] == str(self.updater_agent)
                            for call in calls))
        self.assertFalse(any(call[:2] == ['launchctl', 'bootstrap'] and call[-1] == str(self.updater_agent)
                             for call in calls))

    def test_updater_failure_restarts_updater_agent_when_old_bundle_has_one(self):
        target, calls = self.run_installer(
            lambda args: str(args[0]).endswith('install_trend_words_updater_launch_agent.sh'),
            old_has_updater=True, updater_agent_exists=True)
        self.assertEqual((target / 'old').read_text(), 'original')
        self.assertTrue(self.updater_agent.exists())
        self.assertTrue(any(call[:2] == ['launchctl', 'bootstrap'] and call[-1] == str(self.updater_agent)
                            for call in calls))


if __name__ == '__main__':
    unittest.main()
