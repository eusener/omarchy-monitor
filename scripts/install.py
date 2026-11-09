#!/usr/bin/env python3
"""Install this local project with a backup and one monitor widget."""
import copy
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

PLUGIN_ID = 'eusener.displays'
NATIVE_ID = 'omarchy.monitor'
SECTIONS = ('left', 'centerBegin', 'center', 'centerEnd', 'right', 'tray')
PROJECT = Path(__file__).resolve().parents[1]


def widget_id(entry):
    return entry.get('id') if isinstance(entry, dict) else entry


def merged_config(config):
    result = copy.deepcopy(config)
    layout = result.setdefault('bar', {}).setdefault('layout', {})
    occurrences = [(section, i, entry) for section in SECTIONS
                   for i, entry in enumerate(layout.get(section, []))
                   if widget_id(entry) in (NATIVE_ID, PLUGIN_ID)]
    anchor = next((row for row in occurrences if widget_id(row[2]) == NATIVE_ID),
                  occurrences[0] if occurrences else ('right', len(layout.get('right', [])), {}))
    replacement = {}
    for wanted_id in (NATIVE_ID, PLUGIN_ID):
        for _, _, entry in occurrences:
            if widget_id(entry) == wanted_id and isinstance(entry, dict):
                replacement.update(entry)
    replacement['id'] = PLUGIN_ID
    for section in SECTIONS:
        if section not in layout and section != anchor[0]:
            continue
        entries = []
        for i, entry in enumerate(layout.get(section, [])):
            if (section, i) == anchor[:2]:
                entries.append(replacement)
            if widget_id(entry) not in (NATIVE_ID, PLUGIN_ID):
                entries.append(entry)
        if not occurrences and section == anchor[0]:
            entries.append(replacement)
        layout[section] = entries
    return result


def atomic_json(path, data):
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.monitor-install-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
        os.chmod(temporary, path.stat().st_mode & 0o777 if path.exists() else 0o644)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    if shutil.which('omarchy'):
        subprocess.run(['omarchy', 'plugin', 'validate', str(PROJECT)], check=True)
    config_home = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config')
    shell_path = config_home / 'omarchy/shell.json'
    config = json.loads(shell_path.read_text()) if shell_path.exists() else {'version': 1}
    merged = merged_config(config)
    target = config_home / 'omarchy/plugins' / PLUGIN_ID
    linked = target.is_symlink() and target.resolve() == PROJECT
    if linked and merged == config:
        print('Already installed:', target)
        return
    backup = config_home / 'omarchy/backups' / ('monitor-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    backup.mkdir(parents=True)
    if shell_path.exists():
        shutil.copy2(shell_path, backup / 'shell.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    if not linked:
        if target.exists() or target.is_symlink():
            target.rename(backup / PLUGIN_ID)
        target.symlink_to(PROJECT, target_is_directory=True)
    atomic_json(shell_path, merged)
    print('Installed:', target, '->', PROJECT)
    print('Backup:', backup)
    shell_cli = shutil.which('omarchy-shell')
    if shell_cli:
        refreshed = subprocess.run([shell_cli, 'shell', 'rescanPlugins'], text=True,
                                   capture_output=True, timeout=5)
        if refreshed.returncode:
            print('Shell IPC unavailable; configuration saved for automatic reload or the next session.')
        else:
            print('Shell plugins rescanned.')


if __name__ == '__main__':
    main()
