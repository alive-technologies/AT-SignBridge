#!/usr/bin/env bash
# AT-SignBridge installer: runs the bank's Windows "Aseba Crypto Signer" (Asseco SEE)
# on Linux under Wine, so e-banking token signing works in Chrome/Chromium/Brave/Edge/Firefox.
#
# Usage: ./install.sh <aseba-crypto-signer-*.msi> [--pkcs11 <vendor-pkcs11.dll>]
set -euo pipefail

OPENSC_VERSION="0.27.1"
OPENSC_URL="https://github.com/OpenSC/OpenSC/releases/download/${OPENSC_VERSION}/OpenSC-${OPENSC_VERSION}_x64.msi"
APP="${AT_SIGNBRIDGE_HOME:-$HOME/.local/share/at-signbridge}"
BIN="$HOME/.local/bin"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="mk.asseco_see.aseba_crypto_signer"

# PKCS#11 driver names the signer tries to load (taken from its own log/strings)
DRIVER_NAMES=(eTPKCS11.dll gclib.dll eps2003csp11.dll aetpkss1.dll multpkcs11.dll eBankSCPKCS11.dll slbCk.dll sadaptor.dll)

# Chromium-family config dirs that get a native-messaging manifest (if the browser is present)
CHROMIUM_DIRS=(google-chrome google-chrome-beta google-chrome-unstable chromium BraveSoftware/Brave-Browser microsoft-edge vivaldi)

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

MSI="" VENDOR_DLL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pkcs11) VENDOR_DLL="$(realpath "$2")"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) MSI="$(realpath "$1")"; shift ;;
  esac
done
[ -n "$MSI" ] && [ -f "$MSI" ] || die "Give the path to the signer installer from your bank, e.g. ./install.sh ~/Downloads/aseba-crypto-signer-1.0.1.15-r3.msi"
[ -z "$VENDOR_DLL" ] || [ -f "$VENDOR_DLL" ] || die "PKCS#11 DLL not found: $VENDOR_DLL"

# --- dependencies -----------------------------------------------------------------------------
missing=()
for c in wine wineboot wineserver msiextract curl python3; do command -v "$c" >/dev/null || missing+=("$c"); done
[ -e /usr/sbin/pcscd ] || missing+=(pcscd)
if [ ${#missing[@]} -gt 0 ]; then
  warn "Missing: ${missing[*]}"
  die "Install the dependencies first (Ubuntu/Debian), then re-run:
    sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install -y wine64 wine msitools curl python3 pcscd libccid opensc && sudo systemctl enable --now pcscd.socket"
fi
systemctl is-active --quiet pcscd.socket || systemctl is-active --quiet pcscd || \
  warn "pcscd is not running: sudo systemctl enable --now pcscd.socket"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- signer -----------------------------------------------------------------------------------
say "Extracting signer from $(basename "$MSI")"
mkdir -p "$WORK/signer"
(cd "$WORK/signer" && msiextract "$MSI" >/dev/null)
EXE="$(find "$WORK/signer" -iname 'aseba*crypto*signer*.exe' | head -1)"
[ -n "$EXE" ] || die "No aseba crypto signer .exe inside $MSI — is this the right installer?"
EXE_DIR="$(dirname "$EXE")"
CHROME_JSON="$(find "$WORK/signer" -name "${HOST_NAME}.json" | head -1)"
FF_JSON="$(find "$WORK/signer" -name "${HOST_NAME}_v2.ff.json" | head -1)"
[ -n "$CHROME_JSON" ] || die "No ${HOST_NAME}.json inside $MSI"

mkdir -p "$APP"
rm -rf "$APP/signer"
mkdir -p "$APP/signer"
cp "$EXE" "$APP/signer/aseba_crypto_signer.exe"
find "$EXE_DIR" -maxdepth 1 \( -iname '*.dll' -o -iname 'appsettings*.json' \) -exec cp {} "$APP/signer/" \;

# --- PKCS#11 driver ---------------------------------------------------------------------------
if [ -n "$VENDOR_DLL" ]; then
  say "Using vendor PKCS#11 driver $(basename "$VENDOR_DLL")"
  DLL="$VENDOR_DLL"
else
  say "Downloading OpenSC ${OPENSC_VERSION} (Windows PKCS#11 driver, talks to Linux pcscd via Wine)"
  curl -fsSL -o "$WORK/opensc.msi" "$OPENSC_URL"
  mkdir -p "$WORK/opensc"
  (cd "$WORK/opensc" && msiextract "$WORK/opensc.msi" >/dev/null)
  DLL="$(find "$WORK/opensc" -name 'opensc-pkcs11.dll' -not -ipath '*onepin*' | head -1)"
  [ -n "$DLL" ] || die "opensc-pkcs11.dll not found in the OpenSC installer"
fi

# --- Wine prefix ------------------------------------------------------------------------------
export WINEPREFIX="$APP/wineprefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml="
if [ ! -d "$WINEPREFIX/drive_c" ]; then
  say "Creating Wine prefix (first time takes ~1 minute)"
  wineboot -i >/dev/null 2>&1
fi
SYS32="$WINEPREFIX/drive_c/windows/system32"
for n in "${DRIVER_NAMES[@]}"; do cp "$DLL" "$SYS32/$n"; done
for d in "Program Files/Gemalto/Classic Client/BIN" "Program Files/Gemplus/GemSafe Libraries/BIN"; do
  mkdir -p "$WINEPREFIX/drive_c/$d" && cp "$DLL" "$WINEPREFIX/drive_c/$d/gclib.dll"
done

# --- launcher + manifests ---------------------------------------------------------------------
install -m 755 "$SRC/relay.py" "$APP/relay.py"
cat > "$APP/run.sh" <<EOF
#!/bin/sh
exec /usr/bin/python3 -I "$APP/relay.py" "\$@"
EOF
chmod 755 "$APP/run.sh"

registered=()
for b in "${CHROMIUM_DIRS[@]}"; do
  [ -d "$HOME/.config/$b" ] || continue
  dir="$HOME/.config/$b/NativeMessagingHosts"
  mkdir -p "$dir"
  rm -f "$dir/$HOST_NAME.json.disabled"
  python3 -I - "$CHROME_JSON" "$APP/run.sh" "$dir/$HOST_NAME.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
m["path"] = sys.argv[2]
m["description"] = "Aseba Crypto Signer (AT-SignBridge / Wine)"
json.dump(m, open(sys.argv[3], "w"), indent=2)
PY
  registered+=("$b")
done
if [ -n "$FF_JSON" ] && [ -d "$HOME/.mozilla" ]; then
  dir="$HOME/.mozilla/native-messaging-hosts"
  mkdir -p "$dir"
  name="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig"))["name"])' "$FF_JSON")"
  python3 -I - "$FF_JSON" "$APP/run.sh" "$dir/$name.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
m["path"] = sys.argv[2]
json.dump(m, open(sys.argv[3], "w"), indent=2)
PY
  registered+=("firefox (deb only; snap Firefox cannot run native hosts)")
fi
[ ${#registered[@]} -gt 0 ] || warn "No supported browser profile found in ~/.config — start your browser once and re-run"

mkdir -p "$BIN"
sed "s#@APP@#$APP#g" "$SRC/at-signbridge" > "$BIN/at-signbridge"
chmod 755 "$BIN/at-signbridge"

# --- self-test --------------------------------------------------------------------------------
say "Self-test (no PIN needed)"
resp="$(python3 -I -c 'import json,struct,sys; d=json.dumps({"type":"VERSION","nonce":"selftest"}).encode(); sys.stdout.buffer.write(struct.pack("<I",len(d))+d)' \
  | timeout 60 "$APP/run.sh" chrome-extension://selftest/ | tail -c +5 || true)"
case "$resp" in
  *'"result": "ok"'*|*'"result":"ok"'*) say "Signer answers: $resp" ;;
  *) warn "Signer did not answer the version check (got: ${resp:-nothing}). See $APP/relay.log" ;;
esac

say "Done. Registered for: ${registered[*]:-none}"
echo "    Plug in your token, open your bank in the browser and sign as on Windows."
echo "    Manage with: at-signbridge status | on | off | test | log | uninstall"
