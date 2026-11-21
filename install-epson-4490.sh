#!/usr/bin/env bash
# Reinstall the Epson Perfection 4490 Photo (GT-X750, USB 04b8:0119)
# stack that already works on this CachyOS / Arch machine:
#   sane, simple-scan, iscan, iscan-data, libesint54 + esfw54.bin
#
# Run as your normal user (it will ask for sudo):
#   ./install-epson-4490.sh
# Optional low-res test scan after install:
#   ./install-epson-4490.sh --test

set -euo pipefail

VENDOR="0x04b8"
PRODUCT="0x0119"
BUNDLE_URL="https://www.hamrick.com/files/iscan-gt-x750-bundle-2.30.4.x64.rpm.tar.gz"
LIB_NAME="libesint54.so.2.0.1"
FW_NAME="esfw54.bin"
LIB_DIR="/usr/lib/iscan"
FW_DIR="/usr/share/iscan"
# iscan-registry stores this path. /usr/lib64 is a symlink to /usr/lib.
REGISTRY_LIB="/usr/lib64/iscan/libesint54"
REGISTRY_FW="${FW_DIR}/${FW_NAME}"
INTERPRETER_FILE="/usr/var/lib/iscan/interpreter"
RUN_TEST=0

if [[ "${1:-}" == "--test" ]]; then
  RUN_TEST=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--test]" >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this as your normal user. It calls sudo for the root steps." >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "The GT-X750 plugin is x86_64 only (this machine is $(uname -m))." >&2
  exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
  echo "This installer targets Arch Linux and CachyOS (pacman + an AUR helper)." >&2
  exit 1
fi

aur_helper=""
if command -v yay >/dev/null 2>&1; then
  aur_helper="yay"
elif command -v paru >/dev/null 2>&1; then
  aur_helper="paru"
else
  echo "Install yay or paru first, then re-run this script." >&2
  exit 1
fi

echo "==> Packages: sane, simple-scan, iscan, iscan-data"
sudo pacman -S --needed --noconfirm base-devel git sane simple-scan
"$aur_helper" -S --needed --noconfirm iscan-data iscan

echo "==> GT-X750 plugin and firmware"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fL --retry 3 -o "${work}/bundle.tar.gz" "$BUNDLE_URL"
tar -xzf "${work}/bundle.tar.gz" -C "$work"

plugin_rpm="$(find "$work" -type f -name 'iscan-plugin-gt-x750-*.x86_64.rpm' | head -n 1)"
if [[ -z "$plugin_rpm" ]]; then
  echo "Plugin RPM was not inside the downloaded bundle." >&2
  exit 1
fi

mkdir -p "${work}/plugin"
bsdtar -xf "$plugin_rpm" -C "${work}/plugin"

src_lib="$(find "${work}/plugin" -type f -name "$LIB_NAME" | head -n 1)"
src_fw="$(find "${work}/plugin" -type f -name "$FW_NAME" | head -n 1)"
if [[ -z "$src_lib" || -z "$src_fw" ]]; then
  echo "Bundle is missing ${LIB_NAME} or ${FW_NAME}." >&2
  exit 1
fi

sudo mkdir -p "$LIB_DIR" "$FW_DIR"
sudo install -m 755 "$src_lib" "${LIB_DIR}/${LIB_NAME}"
sudo ln -sfn "$LIB_NAME" "${LIB_DIR}/libesint54.so.2"
sudo ln -sfn "$LIB_NAME" "${LIB_DIR}/libesint54.so"
sudo install -m 644 "$src_fw" "${FW_DIR}/${FW_NAME}"

expected="interpreter usb ${VENDOR} ${PRODUCT} ${REGISTRY_LIB} ${REGISTRY_FW}"
current=""
if [[ -f "$INTERPRETER_FILE" ]]; then
  current="$(sudo cat "$INTERPRETER_FILE")"
fi

if [[ "$current" == *"$expected"* ]]; then
  echo "==> Interpreter already registered"
else
  echo "==> Registering epkowa interpreter for ${VENDOR}:${PRODUCT}"
  sudo iscan-registry --add interpreter usb "$VENDOR" "$PRODUCT" "$REGISTRY_LIB" "$REGISTRY_FW"
fi

if ! id -nG "$USER" | tr ' ' '\n' | grep -qx scanner; then
  echo "==> Adding ${USER} to the scanner group"
  sudo usermod -aG scanner "$USER"
  need_relogin=1
else
  need_relogin=0
fi

# iscan ships this file with a bare "usb" line, which is the config that works.
# Leave an existing file alone when that line is already active.
if [[ -f /etc/sane.d/epkowa.conf ]] && ! grep -Eq '^[[:space:]]*usb[[:space:]]*$' /etc/sane.d/epkowa.conf; then
  echo "==> Enabling USB detection in /etc/sane.d/epkowa.conf"
  printf '\nusb\n' | sudo tee -a /etc/sane.d/epkowa.conf >/dev/null
fi

if [[ ! -f /etc/sane.d/dll.d/epkowa.conf ]] || ! grep -qx 'epkowa' /etc/sane.d/dll.d/epkowa.conf; then
  echo "==> Enabling the epkowa SANE backend"
  echo epkowa | sudo tee /etc/sane.d/dll.d/epkowa.conf >/dev/null
fi

sudo tee /usr/local/bin/scan-epson >/dev/null <<'EOF'
#!/usr/bin/env bash
# Scan with the registered Epson GT-X750 / Perfection 4490 interpreter.
# USB bus numbers change, so the device is taken from `scanimage -L`.
#   scan-epson                 -> ~/scan.png at 300 dpi Color
#   scan-epson ~/desk.png
#   RES=150 MODE=Gray scan-epson ~/gray.png
set -euo pipefail
mode="${MODE:-Color}"
res="${RES:-300}"
out="${1:-${HOME}/scan.png}"
device="$(scanimage -L 2>/dev/null | sed -n "s/.*\`\(epkowa:interpreter:[^']*\)'.*/\1/p" | head -n 1)"
if [[ -z "$device" ]]; then
  echo "No epkowa interpreter device found." >&2
  echo "Power the scanner on, plug it in, then run: scanimage -L" >&2
  exit 1
fi
echo "Scanning with ${device} -> ${out} (${mode}, ${res} dpi)"
scanimage -d "$device" --mode "$mode" --resolution "$res" --format=png -o "$out"
EOF
sudo chmod 755 /usr/local/bin/scan-epson

echo
echo "Installed."
echo "  GUI: Simple Scan, or Image Scan (iscan)"
echo "  CLI: scan-epson ~/scan.png"
echo "       scanimage -L"
if [[ "$need_relogin" -eq 1 ]]; then
  echo "Log out and back in so the scanner group membership applies."
fi

echo
echo "==> Devices seen by SANE"
scanimage -L || true

if [[ "$RUN_TEST" -eq 1 ]]; then
  echo "==> Test scan (150 dpi) -> /tmp/epson4490-test.png"
  RES=150 scan-epson /tmp/epson4490-test.png
  file /tmp/epson4490-test.png
fi
