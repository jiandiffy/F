#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEPS="../whiteboard/node_modules/@xterm"
OUT="Resources/terminal"
test -f "$DEPS/xterm/lib/xterm.js" || { echo '缺少终端依赖，请在 whiteboard 运行 npm ci' >&2; exit 1; }
mkdir -p "$OUT"
cp Plugins/Terminal/Web/index.html Plugins/Terminal/Web/terminal.js "$OUT/"
cp "$DEPS/xterm/lib/xterm.js" "$DEPS/xterm/css/xterm.css" "$DEPS/addon-fit/lib/addon-fit.js" "$OUT/"
cp "$DEPS/xterm/LICENSE" "$OUT/xterm-LICENSE"
cp "$DEPS/addon-fit/LICENSE" "$OUT/addon-fit-LICENSE"
