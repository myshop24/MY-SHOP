#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
WORK_DIR="$ROOT_DIR/.myshop-release-work"
SOURCE_DIR="$WORK_DIR/source"
RELEASE_DIR="$ROOT_DIR/release"
WORKER_URL="${MYSHOP_BACKEND_URL:-https://rapid-bush-62ea.myshopsatkania.workers.dev}"

log(){ printf '\n==> %s\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

log "Select newest V-numbered source ZIP"
shopt -s nullglob
files=(V-*.zip)
((${#files[@]})) || fail "No V-*.zip source package found in repository root."

best=-1
candidates=()
for file in "${files[@]}"; do
  name="$(basename "$file")"
  [[ "$name" =~ ^V-([0-9]+)-.+\.zip$ ]] || continue
  v=$((10#${BASH_REMATCH[1]}))
  if (( v > best )); then
    best=$v
    candidates=("$name")
  elif (( v == best )); then
    candidates+=("$name")
  fi
done

(( best >= 1 )) || fail "No valid V-numbered source ZIP found."
((${#candidates[@]} == 1)) || {
  printf 'Highest V-%s has multiple ZIPs:\n' "$best"
  printf '  %s\n' "${candidates[@]}"
  fail "Keep exactly one ZIP for the highest version."
}

SOURCE_ZIP="${candidates[0]}"
SOURCE_VERSION="$best"
VERSION_NAME="2.9.$SOURCE_VERSION"
BUILD_ID="MY SHOP V-$SOURCE_VERSION"

echo "SOURCE: $SOURCE_ZIP"
echo "RELEASE ID: $BUILD_ID / $VERSION_NAME"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "SOURCE_VERSION=$SOURCE_VERSION" >> "$GITHUB_ENV"
fi

log "Extract source"
rm -rf "$WORK_DIR" "$RELEASE_DIR"
mkdir -p "$SOURCE_DIR" "$RELEASE_DIR"
unzip -q "$SOURCE_ZIP" -d "$SOURCE_DIR"

BUILD_ID_FILE="$(find "$SOURCE_DIR" -type f -name SOURCE_BUILD_ID.txt -print -quit)"
[[ -n "$BUILD_ID_FILE" ]] || fail "SOURCE_BUILD_ID.txt not found."
PROJECT_DIR="$(dirname "$BUILD_ID_FILE")"
[[ -f "$PROJECT_DIR/app/build.gradle" || -f "$PROJECT_DIR/app/build.gradle.kts" ]] || fail "Android app Gradle file not found."
[[ -f "$PROJECT_DIR/backend/worker/src/index.js" ]] || fail "Worker source not found."
[[ -f "$PROJECT_DIR/backend/worker/wrangler.toml" ]] || fail "wrangler.toml not found."

log "Normalize release identity automatically from ZIP filename"
printf '%s\n' "$BUILD_ID" > "$PROJECT_DIR/SOURCE_BUILD_ID.txt"
printf '%s\n' "$VERSION_NAME" > "$PROJECT_DIR/SOURCE_VERSION_NAME.txt"

APP_GRADLE="$PROJECT_DIR/app/build.gradle"
[[ -f "$APP_GRADLE" ]] || APP_GRADLE="$PROJECT_DIR/app/build.gradle.kts"

python3 - "$APP_GRADLE" "$PROJECT_DIR/backend/worker/src/index.js" "$SOURCE_VERSION" <<'PY'
import re,sys
app,worker,ver=sys.argv[1],sys.argv[2],int(sys.argv[3])
vname=f"2.9.{ver}"

s=open(app,encoding='utf-8').read()
s,n1=re.subn(r'(?m)^(\s*versionCode\s*(?:=\s*)?)\d+\s*$',
             lambda m:f"{m.group(1)}{ver}",s,count=1)
s,n2=re.subn(r'(?m)^(\s*versionName\s*(?:=\s*)?)["\'][^"\']+["\']\s*$',
             lambda m:f'{m.group(1)}"{vname}"',s,count=1)
if n1!=1 or n2!=1:
    raise SystemExit(f"Could not normalize Android versionCode/versionName: {n1}/{n2}")
s=re.sub(r"MY SHOP V-\d+",f"MY SHOP V-{ver}",s)
s=re.sub(r"2\.9\.\d+",vname,s)
open(app,'w',encoding='utf-8').write(s)

w=open(worker,encoding='utf-8').read()
w2,c1=re.subn(r"version:'2\.9\.\d+'",f"version:'{vname}'",w)
w3,c2=re.subn(r"build:'V-\d+'",f"build:'V-{ver}'",w2)
if c1<1 or c2<1:
    raise SystemExit(f"Worker health markers not found: version={c1} build={c2}")
open(worker,'w',encoding='utf-8').write(w3)
print(f"Identity normalized -> V-{ver} / {vname}; worker markers {c1}/{c2}")
PY

grep -Fqx "$BUILD_ID" "$PROJECT_DIR/SOURCE_BUILD_ID.txt"
grep -Fqx "$VERSION_NAME" "$PROJECT_DIR/SOURCE_VERSION_NAME.txt"
grep -Fq "versionCode $SOURCE_VERSION" "$APP_GRADLE" || grep -Fq "versionCode = $SOURCE_VERSION" "$APP_GRADLE"
grep -Fq "versionName \"$VERSION_NAME\"" "$APP_GRADLE" || grep -Fq "versionName = \"$VERSION_NAME\"" "$APP_GRADLE"
grep -Fq "version:'$VERSION_NAME'" "$PROJECT_DIR/backend/worker/src/index.js"
grep -Fq "build:'V-$SOURCE_VERSION'" "$PROJECT_DIR/backend/worker/src/index.js"
node --check "$PROJECT_DIR/backend/worker/src/index.js"

log "Verify permanent Cloudflare target"
grep -Fq 'name = "rapid-bush-62ea"' "$PROJECT_DIR/backend/worker/wrangler.toml" || fail "Unexpected Worker name."
grep -Fq 'database_name = "my-shop-db"' "$PROJECT_DIR/backend/worker/wrangler.toml" || fail "Unexpected D1 database."
grep -Fq 'binding = "MEDIA"' "$PROJECT_DIR/backend/worker/wrangler.toml" || fail "MEDIA binding missing."

log "Deploy SAME verified Worker source before APK build"
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "GitHub secret CLOUDFLARE_API_TOKEN is missing."
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || fail "GitHub secret CLOUDFLARE_ACCOUNT_ID is missing."
[[ -f "$PROJECT_DIR/backend/worker/package.json" ]] || fail "Worker package.json not found."

(
  cd "$PROJECT_DIR/backend/worker"

  # Worker imports agora-token at runtime/bundle time. A fresh GitHub runner has
  # no node_modules directory, so install the source package dependencies before
  # Wrangler bundles the Worker. Keep the source-declared exact version and verify
  # the exact module path used by src/index.js before touching production.
  npm install --omit=dev --no-audit --no-fund
  node - <<'NODE'
const pkg = require('./node_modules/agora-token/package.json');
if (pkg.version !== '2.0.3') {
  throw new Error(`Unexpected agora-token version: ${pkg.version}`);
}
const resolved = require.resolve('agora-token/src/RtcTokenBuilder2.js');
console.log(`WORKER DEPENDENCY VERIFIED: agora-token ${pkg.version} -> ${resolved}`);
NODE

  npx --yes wrangler@4.128.0 deploy \
    --config wrangler.toml \
    --message "MY SHOP V-$SOURCE_VERSION automatic release run ${GITHUB_RUN_ID:-local}"
)

log "Verify public production Worker identity"
HEALTH_FILE="$WORK_DIR/health.json"
ok=false
for attempt in $(seq 1 30); do
  status="$(curl -sS -o "$HEALTH_FILE" -w '%{http_code}' \
    -H 'Cache-Control: no-cache, no-store, max-age=0' \
    "$WORKER_URL/health?release_check=${GITHUB_RUN_ID:-local}-$attempt-$(date +%s%N)" || true)"

  if [[ "$status" == "200" ]] && python3 - "$HEALTH_FILE" "$SOURCE_VERSION" <<'PY'
import json,sys
p=sys.argv[1]; v=int(sys.argv[2])
try:
    h=json.load(open(p,encoding='utf-8'))
except Exception:
    raise SystemExit(1)
ok=(h.get('ok') is True and h.get('version')==f'2.9.{v}' and h.get('build')==f'V-{v}')
raise SystemExit(0 if ok else 1)
PY
  then
    ok=true
    break
  fi
  sleep 3
done

[[ "$ok" == true ]] || {
  cat "$HEALTH_FILE" 2>/dev/null || true
  fail "Production Worker did not become V-$SOURCE_VERSION / $VERSION_NAME. APK build stopped."
}
echo "PRODUCTION BACKEND VERIFIED: V-$SOURCE_VERSION / $VERSION_NAME"

log "Verify permanent signing key"
[[ -f "$ROOT_DIR/.signing/myshop-release.jks" ]] || fail "Permanent signing key unavailable in .signing/myshop-release.jks"
[[ -n "${MYSHOP_KEYSTORE_PASSWORD:-}" ]] || fail "MYSHOP_KEYSTORE_PASSWORD missing."
[[ -n "${MYSHOP_KEY_ALIAS:-}" ]] || fail "MYSHOP_KEY_ALIAS missing."
[[ -n "${MYSHOP_KEY_PASSWORD:-}" ]] || fail "MYSHOP_KEY_PASSWORD missing."

keytool -list \
  -keystore "$ROOT_DIR/.signing/myshop-release.jks" \
  -storepass "$MYSHOP_KEYSTORE_PASSWORD" \
  -alias "$MYSHOP_KEY_ALIAS" >/dev/null

log "Build exactly one release APK from same verified source"
cd "$PROJECT_DIR"
rm -rf app/build
gradle clean :app:assembleRelease --no-daemon --no-build-cache --rerun-tasks

mapfile -t APKS < <(find app/build/outputs/apk/release -type f -name '*.apk' -print)
((${#APKS[@]} == 1)) || {
  printf 'APK candidates:\n'
  printf '  %s\n' "${APKS[@]:-}"
  fail "Exactly one release APK required; found ${#APKS[@]}."
}
UNSIGNED_APK="${APKS[0]}"

log "Verify APK package/version and sign"
AAPT="$ANDROID_HOME/build-tools/36.0.0/aapt2"
BT="$ANDROID_HOME/build-tools/36.0.0"
OUT="$("$AAPT" dump badging "$UNSIGNED_APK")"

echo "$OUT" | grep -Fq "package: name='com.myshop.app'" || fail "APK package mismatch."
echo "$OUT" | grep -Fq "versionName='$VERSION_NAME'" || fail "APK versionName mismatch."
echo "$OUT" | grep -Fq "versionCode='$SOURCE_VERSION'" || fail "APK versionCode mismatch."

"$BT/zipalign" -f -p 4 "$UNSIGNED_APK" "$RELEASE_DIR/aligned.apk"

"$BT/apksigner" sign \
  --ks "$ROOT_DIR/.signing/myshop-release.jks" \
  --ks-pass "env:MYSHOP_KEYSTORE_PASSWORD" \
  --key-pass "env:MYSHOP_KEY_PASSWORD" \
  --ks-key-alias "$MYSHOP_KEY_ALIAS" \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled true \
  --out "$RELEASE_DIR/MY_SHOP_FINAL_RELEASE.apk" \
  "$RELEASE_DIR/aligned.apk"

rm -f "$RELEASE_DIR/aligned.apk"

"$BT/apksigner" verify --verbose "$RELEASE_DIR/MY_SHOP_FINAL_RELEASE.apk"
"$BT/zipalign" -c -v 4 "$RELEASE_DIR/MY_SHOP_FINAL_RELEASE.apk" >/dev/null

sha256sum "$RELEASE_DIR/MY_SHOP_FINAL_RELEASE.apk" \
  > "$RELEASE_DIR/MY_SHOP_FINAL_RELEASE.apk.sha256"

SOURCE_SHA="$(sha256sum "$ROOT_DIR/$SOURCE_ZIP" | awk '{print $1}')"
{
  echo "SOURCE_VERSION=V-$SOURCE_VERSION"
  echo "VERSION_NAME=$VERSION_NAME"
  echo "SOURCE_ZIP=$SOURCE_ZIP"
  echo "SOURCE_ZIP_SHA256=$SOURCE_SHA"
  echo "BACKEND=$WORKER_URL"
  echo "BACKEND_VERIFIED=V-$SOURCE_VERSION"
  echo "GITHUB_SHA=${GITHUB_SHA:-local}"
} > "$RELEASE_DIR/BUILD_SOURCE_ID.txt"

log "FINAL PASS: backend V-$SOURCE_VERSION verified before APK; signed APK ready"
