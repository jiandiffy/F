#!/bin/bash
# 为 F.app 生成一个稳定的本地代码签名身份（只需运行一次）。
#
# 为什么需要它：build.sh 之前用 ad-hoc 签名（codesign -s -），每次重建 cdhash 都会变，
# macOS 会把新包当成"另一个 app"，于是完整磁盘访问、辅助功能等权限全部失效。
# 换成固定证书后，TCC 的 code requirement 只认证书，重建不会再掉权限。
#
# 用法：  ./scripts/f-signing-setup.sh
# 可选：  F_SIGN_IDENTITY="My Signing" ./scripts/f-signing-setup.sh
set -euo pipefail

IDENTITY="${F_SIGN_IDENTITY:-F Local Signing}"
KC="$HOME/Library/Keychains/f-signing.keychain-db"
PW_FILE="$HOME/Library/Application Support/F/signing-keychain-password"

if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1; then
  echo "✓ 签名身份已存在：$IDENTITY"
  echo "  keychain: $KC"
  exit 0
fi

mkdir -p "$(dirname "$PW_FILE")"
if [ ! -f "$PW_FILE" ]; then
  openssl rand -base64 24 | tr -d '\n' > "$PW_FILE"
  chmod 600 "$PW_FILE"
fi
PW="$(cat "$PW_FILE")"

if [ ! -f "$KC" ]; then
  security create-keychain -p "$PW" "$KC"
  echo "✓ 已创建独立 keychain：$KC"
fi
security unlock-keychain -p "$PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'CONF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = F Local Signing
O = F
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1
P12PASS="f-signing"
if ! openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$IDENTITY" -out "$TMP/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1; then
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1
fi

security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null

# 把 keychain 加进用户搜索列表，codesign 才能找到这个身份
EXISTING="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//' | tr '\n' ' ')"
if ! printf '%s' "$EXISTING" | grep -q "f-signing.keychain-db"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $EXISTING "$KC"
fi

echo "✓ 已生成签名身份：$IDENTITY"
security find-certificate -c "$IDENTITY" "$KC" | grep -E '"labl"|"subj"' | sed 's/^/  /' || true
echo
echo "之后 build.sh 会自动用它签名；权限只需要重新授予一次。"
