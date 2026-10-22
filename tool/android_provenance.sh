#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK=""
VERIFY_CLEAN=0
OUT="$ROOT/build/provenance/android-provenance.json"

while (($#)); do
  case "$1" in
    --apk) APK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --verify-clean) VERIFY_CLEAN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

AAR="$ROOT/android/app/libs/marten-core.aar"
SING_BOX="${MARTEN_SING_BOX_DIR:-$ROOT/../marten-sing-box}"
TURNCOAT="${TURNCOAT_DIR:-$ROOT/../TURNcoat}"

repo_json() {
  local name="$1" path="$2"
  local revision branch dirty origin_main at_origin origin_live_verified
  revision="$(git -C "$path" rev-parse HEAD)"
  branch="$(git -C "$path" branch --show-current)"
  if [[ -n "$(git -C "$path" status --porcelain --untracked-files=normal)" ]]; then dirty=true; else dirty=false; fi
  origin_main="$(git -C "$path" ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "$origin_main" ]]; then
    origin_live_verified=true
  else
    origin_main="$(git -C "$path" rev-parse --verify refs/remotes/origin/main 2>/dev/null || true)"
    origin_live_verified=false
  fi
  if [[ "$revision" == "$origin_main" ]]; then at_origin=true; else at_origin=false; fi
  if ((VERIFY_CLEAN)) && { [[ "$dirty" != false ]] || [[ "$at_origin" != true ]] || [[ "$origin_live_verified" != true ]]; }; then
    echo "$name is not release-clean (dirty=$dirty at_origin_main=$at_origin origin_live_verified=$origin_live_verified)" >&2
    return 1
  fi
  printf '"%s":{"revision":"%s","branch":"%s","dirty":%s,"origin_main":"%s","at_origin_main":%s,"origin_live_verified":%s}' \
    "$name" "$revision" "$branch" "$dirty" "$origin_main" "$at_origin" "$origin_live_verified"
}

sha_or_empty() {
  local path="$1"
  if [[ -f "$path" ]]; then shasum -a 256 "$path" | awk '{print $1}'; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EMBEDDED_INFO=""
EMBEDDED_SO_SHA=""
EMBEDDED_SOURCE=""
CORE_LINKED=false
SING_BOX_LINKED=false
TURNCOAT_LINKED=false
if [[ -n "$APK" ]]; then
  [[ -f "$APK" ]] || { echo "APK not found: $APK" >&2; exit 2; }
  unzip -p "$APK" lib/arm64-v8a/libmarten-core.so > "$TMP/libmarten-core.so"
  EMBEDDED_SOURCE="apk"
elif [[ -f "$AAR" ]]; then
  unzip -p "$AAR" jni/arm64-v8a/libmarten-core.so > "$TMP/libmarten-core.so"
  EMBEDDED_SOURCE="aar"
fi

if [[ -n "$EMBEDDED_SOURCE" ]]; then
  [[ -s "$TMP/libmarten-core.so" ]] || { echo "embedded arm64 libmarten-core.so is missing" >&2; exit 1; }
  EMBEDDED_INFO="$(go version -m "$TMP/libmarten-core.so" 2>&1)"
  EMBEDDED_SO_SHA="$(sha_or_empty "$TMP/libmarten-core.so")"
  CORE_REVISION="$(git -C "$ROOT/marten-core" rev-parse HEAD)"
  SING_BOX_REVISION="$(git -C "$SING_BOX" rev-parse HEAD)"
  TURNCOAT_REVISION="$(git -C "$TURNCOAT" rev-parse HEAD)"
  grep -aFq "$CORE_REVISION" "$TMP/libmarten-core.so" && CORE_LINKED=true
  grep -aFq "$SING_BOX_REVISION" "$TMP/libmarten-core.so" && SING_BOX_LINKED=true
  grep -aFq "$TURNCOAT_REVISION" "$TMP/libmarten-core.so" && TURNCOAT_LINKED=true
  if ((VERIFY_CLEAN)); then
    if grep -Eq 'vcs\.modified=true|github.com/(Cr0me1ve/marten-sing-box|Cr0me1ve/TURNcoat)[[:space:]]+\(devel\)' <<<"$EMBEDDED_INFO"; then
      echo "embedded core provenance contains modified or devel dependencies" >&2
      exit 1
    fi
    if [[ "$CORE_LINKED" != true || "$SING_BOX_LINKED" != true || "$TURNCOAT_LINKED" != true ]]; then
      echo "embedded core does not contain every expected linked revision" >&2
      exit 1
    fi
  fi
fi

mkdir -p "$(dirname "$OUT")"
REPOS="$(repo_json marten "$ROOT"),$(repo_json marten_core "$ROOT/marten-core"),$(repo_json marten_sing_box "$SING_BOX"),$(repo_json turncoat "$TURNCOAT")"
EMBEDDED_JSON="$(printf '%s' "$EMBEDDED_INFO" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
cat > "$OUT" <<EOF
{
  "schema": "marten-android-provenance-v1",
  "generated_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repositories": {$REPOS},
  "artifacts": {
    "aar": {"path": "android/app/libs/marten-core.aar", "sha256": "$(sha_or_empty "$AAR")"},
    "apk": {"path": "${APK#$ROOT/}", "sha256": "$(sha_or_empty "$APK")"},
    "embedded_arm64_core": {
      "source": "$EMBEDDED_SOURCE",
      "sha256": "$EMBEDDED_SO_SHA",
      "linked_revisions_present": {
        "marten_core": $CORE_LINKED,
        "marten_sing_box": $SING_BOX_LINKED,
        "turncoat": $TURNCOAT_LINKED
      }
    }
  },
  "embedded_go_version_m": $EMBEDDED_JSON
}
EOF

echo "$OUT"
