import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('monitor_install', Path(__file__).resolve().parents[1] / 'scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallLayout(unittest.TestCase):
    def test_replaces_native_and_custom_once_at_native_position(self):
        original = {'version': 1, 'idle': {'lock': 300}, 'bar': {'layout': {
            'right': [{'id': 'omarchy.audio'}, {'id': 'omarchy.monitor', 'option': 'native'},
                      {'id': 'eusener.displays', 'custom': True}, {'id': 'eusener.power'}],
            'left': [{'id': 'omarchy.menu'}],
        }}}
        actual = installer.merged_config(original)
        self.assertEqual(actual['bar']['layout']['right'], [
            {'id': 'omarchy.audio'}, {'id': 'eusener.displays', 'option': 'native', 'custom': True},
            {'id': 'eusener.power'},
        ])
        self.assertEqual(actual['idle'], original['idle'])
        self.assertEqual(actual['bar']['layout']['left'], original['bar']['layout']['left'])
        self.assertEqual(len(original['bar']['layout']['right']), 4)

    def test_removes_duplicates_across_sections(self):
        actual = installer.merged_config({'bar': {'layout': {
            'left': [{'id': 'eusener.displays'}],
            'right': [{'id': 'omarchy.monitor'}],
        }}})
        self.assertEqual(actual['bar']['layout']['left'], [])
        self.assertEqual(actual['bar']['layout']['right'], [{'id': 'eusener.displays'}])

    def test_idempotent_when_custom_already_present(self):
        config = {'bar': {'layout': {'left': [{'id': 'eusener.displays', 'example': 3}]}}}
        self.assertEqual(installer.merged_config(config), config)

    def test_empty_configuration_puts_widget_on_right(self):
        actual = installer.merged_config({})
        self.assertEqual(actual['bar']['layout']['right'], [{'id': 'eusener.displays'}])


if __name__ == '__main__':
    unittest.main()
