#!/usr/bin/env python3
"""Package immutable QML URLs so a long-lived shell does not reuse old types."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
FILES = ('Monitor.qml', 'NativeMonitor.qml', 'DisplayEditor.qml', 'Model.js', 'Layout.js', 'displays.py')


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    # Glob relative to the project even when invoked from another directory.
    files = [Path(name) for name in FILES] + [path.relative_to(ROOT) for path in sorted((ROOT / 'i18n').glob('*.json'))]
    digest = hashlib.sha256()
    digest.update(manifest['version'].encode())
    for path in files:
        digest.update(str(path).encode() + b'\0' + (ROOT / path).read_bytes())
    version = manifest['version'].replace('.', '_')
    relative = Path('runtime') / f'v_{version}_{digest.hexdigest()[:12]}'
    directory = ROOT / relative
    for path in files:
        target = directory / path
        if target.exists():
            if target.read_bytes() != (ROOT / path).read_bytes():
                raise RuntimeError(f'Immutable runtime changed: {target}')
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, target)
    manifest['entryPoints']['barWidget'] = str(relative / 'Monitor.qml')
    text = json.dumps(manifest, indent=2) + '\n'
    if (ROOT / 'manifest.json').read_text() != text:
        (ROOT / 'manifest.json').write_text(text)
    print('Runtime:', relative)


if __name__ == '__main__':
    main()
