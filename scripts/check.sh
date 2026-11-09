#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"
python3 scripts/build-runtime.py
node tests/layout.test.js
node tests/monitor.test.js
python3 -m unittest discover -s tests -v
python3 - <<'PY'
import ast
import json
from pathlib import Path
for path in [Path('displays.py'), Path('scripts/install.py')]:
    ast.parse(path.read_text())
manifest = json.loads(Path('manifest.json').read_text())
assert manifest['omarchy']['clonedFrom'] == 'omarchy.monitor'
for entry in manifest['entryPoints'].values():
    assert Path(entry).is_file()
catalogs = [json.loads(path.read_text()) for path in Path('i18n').glob('*.json')]
assert all(catalog.keys() == catalogs[0].keys() for catalog in catalogs)
print('Python syntax, manifest and translations: OK')
PY
omarchy plugin validate "$project_dir"
for file in Monitor.qml BarWidget.qml NativeMonitor.qml DisplayEditor.qml tests/smoke.qml tests/KeyboardPanel.qml; do
  /usr/lib/qt6/bin/qmlformat -n "$file" >/dev/null
done
printf 'QML syntax: OK\n'
