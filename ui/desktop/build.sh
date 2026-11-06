#!/bin/bash
# 编译并就地更新 F.app（不重新创建 bundle，保留系统权限）。
#
# 关键点：
#   1. 默认直接覆盖现有 F.app，不 rm -rf，bundle 路径/身份保持不变；
#   2. 用固定的本地签名身份（scripts/f-signing-setup.sh 生成），
#      避免每次重建 cdhash 变化导致 完整磁盘访问 / 辅助功能 权限失效；
#   3. 编译产物先写 .build/，再原子替换二进制，构建失败不会破坏正在用的 F.app。
#
# 用法：
#   ./build.sh                  # 就地更新 ./F.app
#   ./build.sh --relaunch       # 更新后退出并重新打开 F（会结束当前会话）
#   ./build.sh --app=/Applications/F.app
#   ./build.sh --fresh          # 删掉 bundle 重新打包（会让权限失效，慎用）
#   ./build.sh --no-whiteboard  # 跳过 vite 构建，只编译 Swift
set -euo pipefail
cd "$(dirname "$0")"

BIN="F"
ROOT="$(cd ../.. && pwd)"
APP="${F_APP_PATH:-$PWD/F.app}"
FRESH=0
RELAUNCH=0
BUILD_WEB=1

for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=1 ;;
    --relaunch) RELAUNCH=1 ;;
    --no-whiteboard) BUILD_WEB=0 ;;
    --app=*) APP="${arg#--app=}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

APP="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$APP")"

# The in-app Agent must not kill itself or replace resources while its task is running.
if [ -n "${F_APP_PID:-}" ] && { [ "$FRESH" = "1" ] || [ "$RELAUNCH" = "1" ]; }; then
  echo "F 内置 Agent 请使用 scripts/prepare-update.py，任务结束后由宿主重启。" >&2; exit 2
fi
if [ -n "${F_APP_PID:-}" ] && [ "$APP" = "${F_APP_BUNDLE:-$PWD/F.app}" ]; then
  echo "禁止内置 Agent 直接覆盖运行中的 F。请使用 scripts/prepare-update.py。" >&2; exit 2
fi
LOCK="$PWD/.build-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -f "$LOCK/pid" ] && kill -0 "$(cat "$LOCK/pid")" 2>/dev/null; then
    echo "另一个 F 构建正在运行，请稍后重试。" >&2; exit 2
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
printf '%s' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Finder/干净终端可能没有全局 Node；复用项目自带的 pi 运行时。
if ! command -v npm >/dev/null 2>&1 && [ -x "$ROOT/runtime/node/bin/npm" ]; then
  export PATH="$ROOT/runtime/node/bin:$PATH"
fi

sudo_if_needed() {
  if [ -w "$(dirname "$APP")" ]; then "$@"; else sudo "$@"; fi
}

# ---------- 1. 白板前端 ----------
if [ "$BUILD_WEB" = "1" ] && [ -x "$ROOT/packages/excalidraw/web/node_modules/.bin/vite" ]; then
  echo "构建白板前端…"
  (cd "$ROOT/packages/excalidraw/web" && npm run build >/dev/null)
fi

bash scripts/build-terminal.sh
"$ROOT/runtime/node/bin/node" "$ROOT/runtime/harness/scripts/build.mjs"

# ---------- 2. 编译二进制到暂存目录 ----------
STAGE="$PWD/.build"
rm -rf "$STAGE"
mkdir -p "$STAGE"
echo "编译 Swift…"
SOURCES=(main.swift)
while IFS= read -r source; do SOURCES+=("$source"); done < <(find -L Core Plugins -name '*.swift' -type f | sort)
swiftc -O -target "$(uname -m)-apple-macos11.0" -o "$STAGE/$BIN" "${SOURCES[@]}"

# ---------- 3. 就地安装 ----------
if [ "$FRESH" = "1" ]; then
  echo "⚠️  --fresh：重建 bundle，系统权限需要重新授予"
  sudo_if_needed rm -rf "$APP"
fi

sudo_if_needed mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Info.plist：已存在就沿用（保留用户改过的键），只补 PiAgentDir / PiCLIPath
if [ ! -f "$APP/Contents/Info.plist" ]; then
  cp Info.plist "$APP/Contents/Info.plist"
fi

AGENT_DIR="${PI_CODING_AGENT_DIR:-}"
if [ -z "$AGENT_DIR" ] || [ ! -d "$AGENT_DIR/sessions" ]; then
  AGENT_DIR=""
  for candidate in "$HOME/Library/Application Support/F/agent" "$ROOT/runtime/agent/state" "$HOME/.pi/agent" "$HOME/runtime/agent/state"; do
    if [ -d "$candidate/sessions" ]; then
      AGENT_DIR="$candidate"
      break
    fi
  done
fi

CLI_PATH="${PI_CLI:-}"
if [ -z "$CLI_PATH" ] || [ ! -x "$CLI_PATH" ]; then
  CLI_PATH=""
  for candidate in "$ROOT/runtime/agent/bin/f" "$HOME/runtime/agent/bin/f"; do
    if [ -x "$candidate" ]; then
      CLI_PATH="$candidate"
      break
    fi
  done
fi

if [ -n "$AGENT_DIR" ]; then
  AGENT_DIR="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$AGENT_DIR")"
  sudo_if_needed /usr/libexec/PlistBuddy -c "Set :PiAgentDir $AGENT_DIR" "$APP/Contents/Info.plist" \
    || sudo_if_needed /usr/libexec/PlistBuddy -c "Add :PiAgentDir string $AGENT_DIR" "$APP/Contents/Info.plist"
  echo "pi 会话目录：$AGENT_DIR/sessions"
else
  echo "警告：未找到 pi 会话目录，可在 Info.plist 的 PiAgentDir 中手动填写"
fi

if [ -n "$CLI_PATH" ]; then
  sudo_if_needed /usr/libexec/PlistBuddy -c "Set :PiCLIPath $CLI_PATH" "$APP/Contents/Info.plist" \
    || sudo_if_needed /usr/libexec/PlistBuddy -c "Add :PiCLIPath string $CLI_PATH" "$APP/Contents/Info.plist"
  echo "pi 命令行：$CLI_PATH"
else
  echo "警告：未找到 pi 命令行，可在 Info.plist 的 PiCLIPath 中手动填写"
fi

# 资源：白板整体同步（删掉旧 hash 文件），其余资源逐个覆盖
for resource in whiteboard terminal; do
  sudo_if_needed mkdir -p "$APP/Contents/Resources/$resource"
  if command -v rsync >/dev/null 2>&1; then
    sudo_if_needed rsync -a --delete "$PWD/Resources/$resource/" "$APP/Contents/Resources/$resource/"
  else
    sudo_if_needed rm -rf "$APP/Contents/Resources/$resource"
    sudo_if_needed cp -R "$PWD/Resources/$resource" "$APP/Contents/Resources/$resource"
  fi
done
for f in "$PWD"/Resources/*; do
  [ -d "$f" ] && continue
  sudo_if_needed cp "$f" "$APP/Contents/Resources/"
done

# Freeze the verified Agent kernel and its bundled dependencies into this artifact.
sudo_if_needed mkdir -p "$APP/Contents/Resources/runtime/harness"
for part in src dist; do
  sudo_if_needed rsync -a --delete "$ROOT/runtime/harness/$part/" "$APP/Contents/Resources/runtime/harness/$part/"
done
sudo_if_needed cp "$ROOT/runtime/harness/package.json" "$APP/Contents/Resources/runtime/harness/package.json"
for package in "$ROOT"/packages/*; do
  [ -d "$package/agent" ] || continue
  destination="$APP/Contents/Resources/packages/$(basename "$package")/agent"
  sudo_if_needed mkdir -p "$destination"
  sudo_if_needed rsync -a --delete "$package/agent/" "$destination/"
done
sudo_if_needed mkdir -p "$APP/Contents/Resources/workflows/engine"
sudo_if_needed rsync -a --delete "$ROOT/workflows/engine/" "$APP/Contents/Resources/workflows/engine/"
sudo_if_needed mkdir -p "$APP/Contents/Resources/ui/extensions" "$APP/Contents/Resources/runtime/checkpoints"
sudo_if_needed rsync -a --delete "$ROOT/ui/extensions/" "$APP/Contents/Resources/ui/extensions/"
sudo_if_needed cp "$ROOT/runtime/checkpoints/index.mjs" "$APP/Contents/Resources/runtime/checkpoints/"
sudo_if_needed /usr/bin/python3 "$PWD/scripts/freeze-agent.py" "$APP/Contents/Resources"

# 二进制原子替换（正在运行的进程继续用旧 inode，下次启动即新版本）
sudo_if_needed cp "$STAGE/$BIN" "$APP/Contents/MacOS/$BIN.new"
sudo_if_needed chmod 755 "$APP/Contents/MacOS/$BIN.new"
sudo_if_needed mv -f "$APP/Contents/MacOS/$BIN.new" "$APP/Contents/MacOS/$BIN"

# ---------- 4. 用稳定身份签名 ----------
IDENTITY="${F_SIGN_IDENTITY:-F Local Signing}"
KC="$HOME/Library/Keychains/f-signing.keychain-db"
PW_FILE="$HOME/Library/Application Support/F/signing-keychain-password"

if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1; then
  if [ -f "$PW_FILE" ]; then
    security unlock-keychain -p "$(cat "$PW_FILE")" "$KC" >/dev/null 2>&1 || true
  fi
  EXISTING="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//' | tr '\n' ' ')"
  if ! printf '%s' "$EXISTING" | grep -q "f-signing.keychain-db"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KC" || true
  fi
  sudo_if_needed codesign --force --sign "$IDENTITY" "$APP" >/dev/null
  echo "签名：${IDENTITY}（权限会保留）"
else
  sudo_if_needed codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "签名：ad-hoc"
  echo "⚠️  ad-hoc 签名每次重建都会变更 cdhash，系统权限会失效。"
  echo "    运行 ./scripts/f-signing-setup.sh 生成稳定身份（只需一次）。"
fi

sudo_if_needed codesign --verify --strict "$APP" >/dev/null 2>&1 \
  && echo "✓ 签名校验通过" \
  || echo "⚠️  签名校验失败，可尝试：codesign --force --deep --sign - \"$APP\""

echo "已就地更新 $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

if [ "$RELAUNCH" = "1" ]; then
  echo "重启 F…"
  osascript -e 'quit app "F"' >/dev/null 2>&1 || true
  sleep 1.2
  open "$APP"
fi
