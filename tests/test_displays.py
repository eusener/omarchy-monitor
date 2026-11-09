import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('displays', Path(__file__).resolve().parents[1] / 'displays.py')
displays = importlib.util.module_from_spec(spec)
spec.loader.exec_module(displays)


class InternalDisplayGuard(unittest.TestCase):
    def test_apply_cannot_turn_off_an_enabled_laptop_panel(self):
        monitors = [{'name': 'eDP-1', 'disabled': False}, {'name': 'HDMI-A-1', 'disabled': False}]
        request = {'monitors': [{'name': 'eDP-1', 'disabled': True},
                                {'name': 'HDMI-A-1', 'disabled': False}]}
        with patch.object(displays, 'live_monitors', return_value=monitors):
            with self.assertRaisesRegex(ValueError, 'laptop switch'):
                displays.cmd_apply(json.dumps(request))


if __name__ == '__main__':
    unittest.main()
