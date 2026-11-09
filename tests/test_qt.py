"""Load the real QML with local fake commands; never alter physical displays."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = Path('/usr/share/omarchy/shell')


@unittest.skipUnless(shutil.which('quickshell') and SHELL.exists(), 'Omarchy/Quickshell required')
class QtIntegration(unittest.TestCase):
    def test_unified_panel_and_native_ipc(self):
        self.run_panel(1)

    def test_original_controls_with_two_displays(self):
        self.run_panel(2)

    def test_native_scale_with_internal_display_disabled(self):
        self.run_panel(2, internal_disabled=True)

    def run_panel(self, display_count, internal_disabled=False):
        with tempfile.TemporaryDirectory(prefix='monitor-qt-') as directory:
            stage = Path(directory)
            for path in SHELL.iterdir():
                if path.is_dir() and path.name != 'Ui':
                    (stage / path.name).symlink_to(path, target_is_directory=True)
            ui = stage / 'Ui'
            ui.mkdir()
            for path in (SHELL / 'Ui').iterdir():
                if path.name != 'KeyboardPanel.qml':
                    (ui / path.name).symlink_to(path)
            shutil.copy2(ROOT / 'tests/KeyboardPanel.qml', ui / 'KeyboardPanel.qml')
            manifest = json.loads((ROOT / 'manifest.json').read_text())
            entry_dir = (ROOT / manifest['entryPoints']['barWidget']).parent
            (stage / 'Monitor').symlink_to(entry_dir, target_is_directory=True)
            shutil.copy2(ROOT / 'tests/smoke.qml', stage / 'shell.qml')
            runtime = stage / 'runtime'
            runtime.mkdir(mode=0o700)
            config = stage / 'config'
            (config / 'omarchy/displays').mkdir(parents=True)
            (config / 'omarchy/displays/profiles.json').write_text(json.dumps({
                'profiles': {}, 'primary': '', 'gdk_scale': 2,
            }))
            bin_dir = stage / 'bin'
            bin_dir.mkdir()
            monitor = {
                'name': 'eDP-1', 'description': '<img src="https://example.invalid/test">',
                'width': 2880, 'height': 1800, 'refreshRate': 90, 'scale': 2,
                'x': 0, 'y': 0, 'focused': True, 'disabled': False,
                'availableModes': ['2880x1800@90.00Hz', '2880x1800@60.00Hz'],
            }
            displays = [{'name': 'eDP-1', 'enabled': True, 'focused': True, 'width': 2880, 'height': 1800}]
            monitors = [monitor]
            if display_count > 1:
                external = dict(monitor, name='HDMI-A-1', description='<img src="https://example.invalid/external">', focused=False, x=1440)
                monitors.append(external)
                displays.append(dict(displays[0], name='HDMI-A-1', focused=internal_disabled))
                if internal_disabled:
                    monitor.update(disabled=True, focused=False)
                    external['focused'] = True
                    displays[0].update(enabled=False, focused=False)
            focused = 'HDMI-A-1' if internal_disabled else 'eDP-1'
            state = '42\neDP-1\n\n1\n\n' + focused + '\n2\n' + json.dumps(displays) + '\n'
            commands = {
                'omarchy-monitor-state': '#!/usr/bin/env python3\nprint(' + repr(state) + ', end="")\n',
                'hyprctl': (
                    '#!/usr/bin/env python3\nimport json, os, sys\n'
                    'with open(os.environ["MONITOR_TEST_CALLS"], "a") as f:\n'
                    '    f.write(json.dumps(sys.argv) + "\\n")\n'
                    'print("ok" if sys.argv[1] == "eval" else ' + repr(json.dumps(monitors)) + ')\n'
                ),
            }
            for command in ['omarchy-brightness-display', 'omarchy-display-text-size']:
                commands[command] = (
                    '#!/usr/bin/env python3\nimport json, os, sys, time\n'
                    'time.sleep(0.1)\n'
                    'with open(os.environ["MONITOR_TEST_CALLS"], "a") as f:\n'
                    '    f.write(json.dumps(sys.argv) + "\\n")\n'
                )
            for name, content in commands.items():
                path = bin_dir / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ)
            env.update(QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='generic',
                       QT_QUICK_BACKEND='software', XDG_RUNTIME_DIR=str(runtime),
                       XDG_CONFIG_HOME=str(config), XDG_STATE_HOME=str(stage / 'state'),
                       MONITOR_TEST_CALLS=str(stage / 'calls.jsonl'),
                       MONITOR_TEST_DISPLAY_COUNT=str(display_count),
                       MONITOR_TEST_FOCUS=focused,
                       PATH=str(bin_dir) + os.pathsep + env['PATH'])
            env.pop('WAYLAND_DISPLAY', None)
            env.pop('DISPLAY', None)
            result = subprocess.run(['quickshell', '-p', str(stage), '--no-color'],
                                    env=env, text=True, capture_output=True, timeout=12)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('MONITOR_QT_TESTS_OK', output, output)
            for marker in ['TEST_FAILED', 'ReferenceError', 'TypeError', 'Unable to assign',
                           'Failed to load configuration', 'is not a type', 'Error loading QML']:
                self.assertNotIn(marker, output, output)
            calls = [json.loads(line) for line in (stage / 'calls.jsonl').read_text().splitlines()]
            self.assertTrue(any(call[-1] == '64%' for call in calls), calls)
            self.assertTrue(any(Path(call[0]).name == 'hyprctl' and 'eval' in call and 'scale = 1.6' in call[-1] for call in calls), calls)
            text_calls = [call for call in calls if Path(call[0]).name == 'omarchy-display-text-size']
            self.assertEqual(text_calls[-1][-1], '14', text_calls)


if __name__ == '__main__':
    unittest.main()
