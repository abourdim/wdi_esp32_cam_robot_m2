#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ESP32-CAM robot launcher -- check/install PlatformIO, then build, flash,
# monitor, or push firmware over WiFi to the robot.
#
# Ported from the CamRobot workshop launcher. That repo held four PlatformIO
# projects under firmware/ and picked between them; this one is a single
# Arduino sketch at the repository root, so the app-selection menu is gone.
# Its OTA also worked differently -- see ota_flash() below.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH="wdi_esp32_cam_robot_m2.ino"
PIO_ENV="esp32cam"
PIO_DEBUG_ENV="esp32cam-debug"
FIRMWARE_BIN="$SCRIPT_DIR/.pio/build/$PIO_ENV/firmware.bin"
EXPORT_DIR="$SCRIPT_DIR/export"

# Defaults from the sketch header: fallback AP password, OTA password, and the
# address the robot serves on when it falls back to its own access point.
DEFAULT_OTA_IP="192.168.4.1"
DEFAULT_OTA_PASSWORD="88888888"

# The project online, for the docs menu below.
GITHUB_URL="https://github.com/abourdim/wdi_esp32_cam_robot_m2"

# --- colors -----------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_DIM='\033[2m'
  C_CYAN='\033[36m'; C_AMBER='\033[33m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_BOLD='\033[1m'
else
  C_RESET=''; C_DIM=''; C_CYAN=''; C_AMBER=''; C_RED=''; C_GREEN=''; C_BOLD=''
fi

ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $1"; }
warn()  { echo -e "${C_AMBER}[!!]${C_RESET} $1"; }
err()   { echo -e "${C_RED}[XX]${C_RESET} $1"; }
info()  { echo -e "${C_CYAN}[--]${C_RESET} $1"; }

banner() {
  echo -e "${C_CYAN}${C_BOLD}"
  echo "  ┌──────────────────────────────────────────────┐"
  echo "  │   🤖  ESP32-CAM ROBOT -- PLATFORMIO LAUNCH    │"
  echo "  └──────────────────────────────────────────────┘"
  echo -e "${C_RESET}"
}

pause() { read -rp "$(echo -e "${C_DIM}Press Enter to continue...${C_RESET}")" _; }

# --- pio discovery -----------------------------------------------------------
PIO_BIN=""

find_pio() {
  if command -v pio >/dev/null 2>&1; then
    PIO_BIN="$(command -v pio)"
    return 0
  fi
  # POSIX install, then the Windows layout of the same virtualenv -- this repo
  # is normally driven from Git Bash on Windows.
  if [ -x "$HOME/.platformio/penv/bin/pio" ]; then
    PIO_BIN="$HOME/.platformio/penv/bin/pio"
    return 0
  fi
  if [ -x "$HOME/.platformio/penv/Scripts/pio.exe" ]; then
    PIO_BIN="$HOME/.platformio/penv/Scripts/pio.exe"
    return 0
  fi
  PIO_BIN=""
  return 1
}

pio_run() {
  if ! find_pio; then
    err "PlatformIO not found. Use option 2 (Install PlatformIO) first."
    return 1
  fi
  "$PIO_BIN" "$@"
}

have_build() { [ -f "$FIRMWARE_BIN" ]; }

# --- menu actions -------------------------------------------------------------

check_install() {
  echo
  info "Checking for prerequisites..."

  if command -v python3 >/dev/null 2>&1; then
    ok "python3 found: $(python3 --version 2>&1)"
  else
    err "python3 not found -- required to install/run PlatformIO."
  fi

  if command -v pip3 >/dev/null 2>&1; then
    ok "pip3 found"
  else
    warn "pip3 not found (only needed for the pip install method)."
  fi

  # Only OTA needs curl, so this is a warning rather than an error.
  if command -v curl >/dev/null 2>&1; then
    ok "curl found (needed for option 9, flashing over WiFi)"
  else
    warn "curl not found -- option 9 (OTA) will not work without it."
  fi

  if find_pio; then
    ok "PlatformIO found at: $PIO_BIN"
    "$PIO_BIN" --version
  else
    warn "PlatformIO not found. Use option 2 to install it."
  fi

  echo
  if [ -f "$SCRIPT_DIR/$SKETCH" ]; then
    ok "Sketch found: $SKETCH"
  else
    err "Sketch $SKETCH is missing from $SCRIPT_DIR"
  fi

  if [ -f "$SCRIPT_DIR/platformio.ini" ]; then
    ok "platformio.ini found (env: $PIO_ENV)"
  else
    err "platformio.ini is missing -- nothing can be built without it."
  fi

  if have_build; then
    ok "Built firmware present: $(basename "$FIRMWARE_BIN")"
  else
    info "No firmware built yet (option 3 builds it)."
  fi
  pause
}

install_pio() {
  echo
  info "Installing PlatformIO Core..."
  echo "  1) pip install (fast, needs python3 + pip3)"
  echo "  2) official installer script (self-contained virtualenv)"
  echo "  b) back"
  read -rp "Choose an option: " choice
  case "$choice" in
    1)
      if ! command -v pip3 >/dev/null 2>&1; then
        err "pip3 not found. Install Python 3 + pip first, or use option 2."
      else
        pip3 install -U platformio && ok "Installed. You may need to restart your shell or add pip's bin dir to PATH."
      fi
      ;;
    2)
      if ! command -v python3 >/dev/null 2>&1; then
        err "python3 not found. Install Python 3 first."
      else
        curl -fsSL -o "${TMPDIR:-/tmp}/get-platformio.py" \
          https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py \
          && python3 "${TMPDIR:-/tmp}/get-platformio.py" \
          && ok "Installed to ~/.platformio. Add ~/.platformio/penv/bin to your PATH."
      fi
      ;;
    b|B) return ;;
    *) warn "Unrecognized option." ;;
  esac
  pause
}

build_firmware() {
  echo
  info "Building $SKETCH (pio run)..."
  pio_run run -d "$SCRIPT_DIR" && ok "Build succeeded." || err "Build failed -- see output above."
  pause
}

clean_firmware() {
  echo
  info "Cleaning build artifacts..."
  pio_run run -t clean -d "$SCRIPT_DIR" && ok "Cleaned."
  pause
}

list_ports() {
  echo
  info "Detected serial devices:"
  pio_run device list
  pause
}

pick_port() {
  # Prints nothing on failure/no-selection; sets $SELECTED_PORT
  SELECTED_PORT=""
  echo
  info "Available serial ports:"
  pio_run device list
  echo
  read -rp "Enter the port to use (e.g. COM5 or /dev/ttyUSB0), or leave blank for auto-detect: " SELECTED_PORT
}

flash_firmware() {
  echo
  # This board is wired to a bare UART0 header: GPIO1/GPIO3 plus power and
  # ground, with no DTR/RTS auto-reset and no boot button. So the usual
  # "hold BOOT" step becomes a wire, and it has to come off again afterwards.
  warn "This board has NO auto-reset and NO boot button. To flash:"
  warn "  1) Jumper GPIO0 to GND on the ESP32-CAM module"
  warn "  2) Tap RESET (or power-cycle)"
  warn "  3) Start the upload"
  warn "  4) Remove the jumper and reset again once it finishes"
  warn "Do this once, then use OTA from then on (menu option 9)."
  echo
  warn "Power the board from a stable 5V supply, and leave the motors stopped"
  warn "during the upload. If the upload connects and then dies right after the"
  warn "baud switch, the upload speed is already pinned to 115200 in"
  warn "platformio.ini -- lower it further there if it still fails."
  echo
  pick_port
  echo
  info "Flashing $SKETCH..."
  if [ -n "$SELECTED_PORT" ]; then
    pio_run run -t upload --upload-port "$SELECTED_PORT" -d "$SCRIPT_DIR" && ok "Flash succeeded." || err "Flash failed -- see output above."
  else
    pio_run run -t upload -d "$SCRIPT_DIR" && ok "Flash succeeded." || err "Flash failed -- see output above."
  fi
  pause
}

# The CamRobot launcher pushed OTA with `pio run -e esp32cam-ota`, i.e. espota
# against ArduinoOTA. This firmware has no ArduinoOTA: the Debug sidebar posts
# the raw application image to /update with the password in an X-OTA-Password
# header (see update_handler in the sketch). curl does the same thing, which
# saves the Export Compiled Binary / pick-the-right-.bin dance in readme.md.
ota_flash() {
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required for OTA and was not found."
    pause; return
  fi

  if ! have_build; then
    warn "No built firmware found."
    read -rp "Build it now? [Y/n] " yn
    case "$yn" in
      n|N) return ;;
      *) pio_run run -d "$SCRIPT_DIR" || { err "Build failed -- nothing to send."; pause; return; } ;;
    esac
    have_build || { err "Build produced no $FIRMWARE_BIN"; pause; return; }
  fi

  echo
  info "The robot must be powered and on WiFi -- either its own"
  info "'ESP32-Robot-XXXX' access point ($DEFAULT_OTA_IP) or a router it joined."
  info "Its motors and flash LED are stopped automatically before writing."
  warn "Do not cut power during the upload."
  echo
  read -rp "Robot IP [$DEFAULT_OTA_IP]: " ip
  ip="${ip:-$DEFAULT_OTA_IP}"
  read -rp "OTA password [$DEFAULT_OTA_PASSWORD]: " otapw
  otapw="${otapw:-$DEFAULT_OTA_PASSWORD}"

  echo
  info "Pushing $(basename "$FIRMWARE_BIN") to $ip over OTA..."
  # "Expect:" suppresses curl's 100-continue handshake, which the ESP32's
  # httpd does not answer and which otherwise stalls the upload for a second.
  if curl -f --progress-bar \
       -X POST \
       -H "X-OTA-Password: $otapw" \
       -H "Content-Type: application/octet-stream" \
       -H "Expect:" \
       --max-time 300 \
       --data-binary "@$FIRMWARE_BIN" \
       "http://$ip/update"; then
    echo
    ok "OTA succeeded -- the robot reboots itself."
  else
    echo
    err "OTA failed. Check the IP and the password, that you are on the same"
    err "network, and that the board was flashed once by USB with the"
    err "OTA-capable partition scheme (platformio.ini sets min_spiffs.csv)."
  fi
  pause
}

# readme.md's manual OTA workflow wants the application .bin -- not the
# bootloader, partitions, or merged images -- to hand to the browser uploader.
# This is that file, copied out under the name the readme uses.
export_bin() {
  if ! have_build; then
    warn "No built firmware found -- build it first (option 3)."
    pause; return
  fi
  mkdir -p "$EXPORT_DIR"
  local dest="$EXPORT_DIR/${SKETCH}.bin"
  if cp "$FIRMWARE_BIN" "$dest"; then
    ok "Exported application image:"
    echo "     $dest"
    info "Upload this file in the robot's Debug sidebar (OTA password $DEFAULT_OTA_PASSWORD)."
  else
    err "Could not write $dest"
  fi
  pause
}

monitor_serial() {
  echo
  pick_port
  echo
  info "Opening serial monitor at 115200 baud. Press Ctrl+C to exit."
  info "Console commands: help, status, log, camera, stop."
  if [ -n "$SELECTED_PORT" ]; then
    pio_run device monitor -b 115200 -p "$SELECTED_PORT"
  else
    pio_run device monitor -b 115200
  fi
}

build_flash_monitor() {
  build_firmware
  flash_firmware
  read -rp "Open serial monitor now? [y/N] " yn
  case "$yn" in
    y|Y) monitor_serial ;;
    *) ;;
  esac
}

debug_build_flash_monitor() {
  echo
  warn "DEBUG MODE: this flashes a symbol-rich diagnostic build."
  warn "Use it only while reproducing a crash; option 5 restores the normal build."
  echo
  info "Building debug firmware ($PIO_DEBUG_ENV)..."
  if ! pio_run run -e "$PIO_DEBUG_ENV" -d "$SCRIPT_DIR"; then
    err "Debug build failed -- see output above."
    pause
    return
  fi

  warn "To flash: jumper GPIO0 to GND, reset/power-cycle, then start upload."
  warn "Remove the GPIO0 jumper and reset again after upload completes."
  pick_port

  info "Flashing debug firmware..."
  if [ -n "$SELECTED_PORT" ]; then
    pio_run run -e "$PIO_DEBUG_ENV" -t upload --upload-port "$SELECTED_PORT" -d "$SCRIPT_DIR" || { err "Debug flash failed."; pause; return; }
  else
    pio_run run -e "$PIO_DEBUG_ENV" -t upload -d "$SCRIPT_DIR" || { err "Debug flash failed."; pause; return; }
  fi

  ok "Debug firmware flashed."
  info "Opening exception-decoding serial monitor at 115200 baud."
  if ! find_pio; then
    err "PlatformIO disappeared from PATH."
    pause
    return
  fi

  if [ -n "$SELECTED_PORT" ]; then
    (cd "$SCRIPT_DIR" && "$PIO_BIN" device monitor -e "$PIO_DEBUG_ENV" -b 115200 -p "$SELECTED_PORT")
  else
    (cd "$SCRIPT_DIR" && "$PIO_BIN" device monitor -e "$PIO_DEBUG_ENV" -b 115200)
  fi
}

# --- browser -----------------------------------------------------------------
# Hands a URL to whatever the platform calls a browser. Git Bash on Windows has
# neither xdg-open nor open, so it falls through to cmd's start -- the doubled
# slash keeps Git Bash from rewriting "//c" into a path. The empty "" is start's
# window-title argument, without which it treats a quoted URL as the title.
open_url() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe //c start "" "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Shared tail of every "open something" action: report, or print the address so
# the user can paste it when no opener was found.
launch_or_print() {
  local target="$1"
  echo
  info "Opening $target ..."
  if open_url "$target"; then
    ok "Handed off to your browser."
  else
    err "Could not launch a browser. Open this yourself:"
    echo "     $target"
  fi
}

open_web() {
  echo
  info "The robot must be powered and this machine on the same network --"
  info "either its own 'ESP32-Robot-XXXX' access point ($DEFAULT_OTA_IP) or a"
  info "router it joined. The sketch registers no mDNS name, so this is by IP."
  echo
  read -rp "Robot IP [$DEFAULT_OTA_IP]: " ip
  ip="${ip:-$DEFAULT_OTA_IP}"
  # Tolerate a pasted "http://192.168.4.1/" as readily as a bare address.
  ip="${ip#http://}"
  ip="${ip#https://}"
  ip="${ip%/}"

  launch_or_print "http://$ip/"
  pause
}

# The two pages the repo ships need no robot on the network: the manual, and
# the console that drives the board over USB from a WebSerial-capable browser.
# The third entry is the project online.
open_docs() {
  echo
  echo "  1) README.html -- the full robot manual"
  echo "  2) ESP32_Robot_USB_Serial_Console.html -- USB serial console"
  echo "  3) GitHub repository (online)"
  echo "  b) back"
  read -rp "Choose an option: " choice

  local file=""
  case "$choice" in
    1) file="$SCRIPT_DIR/README.html" ;;
    2) file="$SCRIPT_DIR/ESP32_Robot_USB_Serial_Console.html" ;;
    3) launch_or_print "$GITHUB_URL"; pause; return ;;
    b|B) return ;;
    *) warn "Unrecognized option."; pause; return ;;
  esac

  if [ ! -f "$file" ]; then
    err "Missing: $file"
    pause; return
  fi

  # cygpath only exists under Git Bash/MSYS, where cmd would choke on a
  # /d/work/... path; everywhere else a file:// URL is what the opener wants.
  local target=""
  if command -v cygpath >/dev/null 2>&1; then
    target="$(cygpath -w "$file")"
  else
    target="file://$file"
  fi

  launch_or_print "$target"
  pause
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    banner
    echo -e "  Sketch: ${C_AMBER}$SKETCH${C_RESET}  (env: $PIO_ENV)"
    if find_pio; then
      echo -e "  PlatformIO: ${C_GREEN}found${C_RESET} ($PIO_BIN)"
    else
      echo -e "  PlatformIO: ${C_RED}not found${C_RESET}"
    fi
    if have_build; then
      echo -e "  Build: ${C_GREEN}present${C_RESET}"
    else
      echo -e "  Build: ${C_DIM}none yet${C_RESET}"
    fi
    echo
    echo "  1) Check installation"
    echo "  2) Install PlatformIO"
    echo "  3) Build firmware"
    echo "  4) Flash firmware (USB)"
    echo "  5) Build + Flash + Monitor"
    echo "  6) Serial monitor"
    echo "  7) List serial ports"
    echo "  8) Clean build"
    echo "  9) Flash over WiFi (OTA)"
    echo "  d) Debug build + Flash + Monitor"
    echo "  w) Open the robot web UI in a browser"
    echo "  h) Open docs, USB console page, or GitHub"
    echo "  x) Export .bin for the browser uploader"
    echo "  q) Quit"
    echo
    read -rp "Choose an option: " opt || { echo; info "Bye."; exit 0; }
    case "$opt" in
      1) check_install ;;
      2) install_pio ;;
      3) build_firmware ;;
      4) flash_firmware ;;
      5) build_flash_monitor ;;
      6) monitor_serial ;;
      7) list_ports ;;
      8) clean_firmware ;;
      9) ota_flash ;;
      d|D) debug_build_flash_monitor ;;
      w|W) open_web ;;
      h|H) open_docs ;;
      x|X) export_bin ;;
      q|Q) echo; info "Bye."; exit 0 ;;
      *) warn "Unrecognized option." ; sleep 1 ;;
    esac
  done
}

main_menu
