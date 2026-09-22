#!/usr/bin/env bash
###############################################################################
# SetMyPiUp — Professional Raspberry Pi 5 setup & application installer
#
# Version:     1.0.0
# Target:      Raspberry Pi 5, Raspberry Pi OS 64-bit (Debian Bookworm+)
# Author:      Miiyamoto255
# License:     MIT
#
# What it does:
#   - Detects hardware (warns on non-Pi-5, gates overclock to Pi 5 only)
#   - Lets the user pick which apps to install (whiptail/dialog/CLI)
#   - Installs each app in isolation so one failure never breaks the run
#   - Applies Waydroid kernel tweaks (psi=1, 4K pages via kernel8.img)
#   - Optionally overclocks Pi 5 CPU 2.7GHz / GPU 1GHz (with cooling warning)
#   - Logs everything, prints a summary, then reboots (unless skipped)
#
# Usage:
#   chmod +x SetMyPiUp.sh
#   sudo ./SetMyPiUp.sh                        # interactive TUI
#   sudo ./SetMyPiUp.sh --help                 # full help
#   sudo ./SetMyPiUp.sh --list                 # list installable IDs
#   sudo ./SetMyPiUp.sh --all --yes            # install everything, no prompts
#   sudo ./SetMyPiUp.sh --only git,docker,vim  # install subset (example)
#   sudo ./SetMyPiUp.sh --no-reboot            # install without rebooting
#   sudo ./SetMyPiUp.sh --dry-run              # show what would happen
#
# Design notes (production-ready):
#   - `set -uo pipefail` but NEVER `set -e`: every installer is wrapped so a
#     failure is recorded and the script continues.
#   - All privileged file edits are backed up with timestamps and idempotent.
#   - Boot files are auto-located (/boot/firmware/* on Bookworm, /boot/* legacy).
#   - Re-runnable: every step checks "already installed?" first.
###############################################################################

set -uo pipefail

# ---------------------------------------------------------------- Globals ----

SCRIPT_NAME="SetMyPiUp"
SCRIPT_VERSION="1.0.0"
LOG_FILE="${LOG_FILE:-/var/log/setmypiup.log}"
DRY_RUN=false
ASSUME_YES=false
DO_REBOOT=true
INSTALL_ALL=false
ONLY_LIST=""
EXCLUDE_LIST=""
WITH_OVERCLOCK="ask"   # ask | yes | no
WITH_WAYDROID_TWEAKS=true
TARGET_USER="${SUDO_USER:-}"
TARGET_HOME=""
CONFIG_TXT=""
CMDLINE_TXT=""
PI_MODEL="Unknown"
IS_PI5=false
IS_ARM64=false
declare -a SELECTED_IDS=()
declare -a SUCCESS_LIST=()
declare -a FAILED_LIST=()
declare -a SKIPPED_LIST=()

# App catalog: ID -> "Human Name|installer_function|description"
declare -A APP_CATALOG=(
  [git]="Git + Git LFS + LSB|install_git|Version control, large-file support and LSB release info"
  [curl]="cURL|install_curl|Command-line URL transfer tool"
  [wget]="wget|install_wget|Command-line file downloader"
  [python]="Python 3 + pip|install_python|Python3, pip, venv and pipx"
  [flatpak]="Flatpak + Flathub|install_flatpak|Sandboxed app framework + Flathub repo"
  [pi-apps]="Pi-Apps|install_pi_apps|Community app store for Raspberry Pi"
  [brave]="Brave Browser|install_brave|Privacy-focused Chromium browser (official ARM64 repo)"
  [vscode]="VS Code|install_vscode|Visual Studio Code (official Microsoft ARM64 repo)"
  [chromium]="Chromium|install_chromium|Open-source Chromium browser"
  [nodejs]="Node.js LTS|install_nodejs|Node.js 22 LTS + npm (NodeSource ARM64)"
  [docker]="Docker Engine|install_docker|Containers via official get.docker.com script"
  [pihole]="Pi-hole|install_pihole|Network-wide ad blocker (official installer)"
  [libreoffice]="LibreOffice|install_libreoffice|Full office suite"
  [kodi]="Kodi|install_kodi|Media center"
  [vlc]="VLC|install_vlc|Media player"
  [gimp]="GIMP|install_gimp|Image editor"
  [obs]="OBS Studio|install_obs|Streaming and recording studio"
  [qemu]="QEMU + virt-manager|install_qemu|Machine emulation and virtualization"
  [snapd]="snapd|install_snapd|Snap package daemon"
  [java]="Java (OpenJDK 17 + 21)|install_java|OpenJDK LTS runtimes and JDKs"
  [dotnet]=".NET SDK 8.0|install_dotnet|.NET SDK + ASP.NET runtime (Microsoft feed, ARM64)"
  [fastfetch]="Fastfetch|install_fastfetch|Fast system info tool"
  [adb]="Android ADB + Fastboot|install_adb|Android platform tools"
  [prismlauncher]="PrismLauncher|install_prismlauncher|Minecraft launcher (via Pi-Apps, else Flatpak)"
  [dolphin]="Dolphin Emulator|install_dolphin|GameCube / Wii emulator"
  [eden]="Eden Switch Emulator|install_eden|Switch emulator (Flatpak, else AppImage)"
  [steam]="Steam (x86 via Box64)|install_steam|Steam via Pi-Apps Box64 automation"
  [retropie]="RetroPie|install_retropie|Retro gaming framework (setup script clone)"
  [waydroid]="Waydroid|install_waydroid|Android containers + kernel tweaks (psi=1, 4K pages)"
  [mcpi-reborn]="MCPI: Reborn|install_mcpi_reborn|Minecraft Pi Reborn by TheBrokenRail"
  [llamacpp]="llama.cpp|install_llamacpp|LLM inference, built from source for ARM NEON"
  [opencode]="OpenCode|install_opencode|AI coding agent (official installer)"
  [claude-code]="Claude Code|install_claude_code|Anthropic CLI via npm"
  [sunshine]="Sunshine + Moonlight|install_sunshine|Game streaming host (Sunshine) + client (Moonlight)"
)

# Stable display order (whiptail checklist + --list)
ORDERED_IDS=(
  git curl wget python flatpak pi-apps brave vscode chromium
  nodejs docker pihole libreoffice kodi vlc gimp obs qemu snapd
  java dotnet fastfetch adb prismlauncher dolphin eden steam
  retropie waydroid mcpi-reborn llamacpp opencode claude-code sunshine
)

# Overclock constants (Pi 5 ONLY)
OC_ARM_FREQ=2700
OC_GPU_FREQ=1000
OC_VOLT_DELTA=50000

# ---------------------------------------------------------------- Colors -----

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0 2>/dev/null || true)"
  C_RED="$(tput setaf 1 2>/dev/null || true)"
  C_GREEN="$(tput setaf 2 2>/dev/null || true)"
  C_YELLOW="$(tput setaf 3 2>/dev/null || true)"
  C_BLUE="$(tput setaf 4 2>/dev/null || true)"
  C_BOLD="$(tput bold 2>/dev/null || true)"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD=""
fi

# ---------------------------------------------------------------- Logging ----

log_init() {
  local logdir
  logdir="$(dirname "$LOG_FILE")"
  if [[ ! -d "$logdir" ]]; then
    mkdir -p "$logdir" 2>/dev/null || LOG_FILE="./setmypiup.log"
  fi
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./setmypiup.log"
    touch "$LOG_FILE" 2>/dev/null || true
  fi
  {
    echo "=================================================================="
    echo "$SCRIPT_NAME v$SCRIPT_VERSION — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "CMD: $0 $*"
    echo "=================================================================="
  } >>"$LOG_FILE" 2>/dev/null || true
}

# Early fallback: parse_args() may log before log_init() runs (e.g. bad flag
# on a system where /var/log is not writable). Point the log at ./ if needed.
if ! { : >>"$LOG_FILE"; } 2>/dev/null; then
  LOG_FILE="./setmypiup.log"
fi

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  { echo "[$ts] [$level] $msg" >>"$LOG_FILE"; } 2>/dev/null || true
  case "$level" in
    INFO)  echo "${C_BLUE}[*]${C_RESET} $msg" ;;
    OK)    echo "${C_GREEN}[OK]${C_RESET} $msg" ;;
    WARN)  echo "${C_YELLOW}[!]${C_RESET} $msg" ;;
    ERROR) echo "${C_RED}[X]${C_RESET} $msg" >&2 ;;
  esac
}
log_info()  { log "INFO" "$@"; }
log_ok()    { log "OK" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------- Helpers ----

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_dry_run() { [[ "$DRY_RUN" == true ]]; }

run_cmd() {
  # run_cmd <description> <command...>
  # Never aborts the script; returns the command's exit code.
  local desc="$1"; shift
  if is_dry_run; then
    log_info "[dry-run] would run ($desc): $*"
    return 0
  fi
  log_info "Running ($desc): $*"
  "$@" >>"$LOG_FILE" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    log_warn "Command failed ($desc) rc=$rc — see $LOG_FILE"
  fi
  return $rc
}

apt_update() {
  if is_dry_run; then log_info "[dry-run] would run: apt-get update"; return 0; fi
  log_info "Updating APT package index..."
  if DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  log_warn "apt-get update failed once, retrying..."
  sleep 3
  DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG_FILE" 2>&1
}

apt_install() {
  # apt_install pkg1 [pkg2 ...] — idempotent, noninteractive, tolerant.
  if [[ $# -eq 0 ]]; then return 0; fi
  if is_dry_run; then log_info "[dry-run] would apt-install: $*"; return 0; fi
  log_info "APT installing: $*"
  # shellcheck disable=SC2086
  if DEBIAN_FRONTEND=noninteractive apt-get install -y $* >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  log_warn "apt install failed for: $* — running apt --fix-broken and retrying once"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -f >>"$LOG_FILE" 2>&1 || true
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y $* >>"$LOG_FILE" 2>&1
}

flatpak_install() {
  # flatpak_install <flathub-id> — system-wide, noninteractive.
  local app_id="$1"
  if [[ -z "$app_id" ]]; then return 1; fi
  if is_dry_run; then log_info "[dry-run] would flatpak install: $app_id"; return 0; fi
  if ! command_exists flatpak; then
    log_warn "flatpak not installed, cannot install $app_id"
    return 1
  fi
  if flatpak info "$app_id" >>"$LOG_FILE" 2>&1; then
    log_info "Flatpak $app_id already installed."
    return 0
  fi
  log_info "Flatpak installing: $app_id"
  flatpak install -y --noninteractive flathub "$app_id" >>"$LOG_FILE" 2>&1
}

backup_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then return 0; fi
  local bak="${f}.setmypiup-bak-$(date '+%Y%m%d-%H%M%S')"
  if is_dry_run; then log_info "[dry-run] would back up $f -> $bak"; return 0; fi
  cp -a "$f" "$bak" 2>>"$LOG_FILE" || { log_warn "Could not back up $f"; return 1; }
  log_info "Backed up $f -> $bak"
}

get_boot_file() {
  # get_boot_file <firmware-name> <legacy-name> — echoes first existing path.
  local fw="/boot/firmware/$1" legacy="/boot/$2"
  if [[ -f "$fw" ]]; then echo "$fw"; elif [[ -f "$legacy" ]]; then echo "$legacy"; else echo "$fw"; fi
}

ensure_config_value() {
  # ensure_config_value <file> <key> <value> — idempotent key=value in config.txt.
  local file="$1" key="$2" value="$3"
  if [[ -z "$file" || -z "$key" ]]; then return 1; fi
  if is_dry_run; then log_info "[dry-run] would set $key=$value in $file"; return 0; fi
  [[ -f "$file" ]] || { log_warn "$file not found"; return 1; }
  backup_file "$file" || true
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=${value}|" "$file" 2>>"$LOG_FILE" || return 1
  else
    printf '%s=%s\n' "$key" "$value" >>"$file" 2>>"$LOG_FILE" || return 1
  fi
  log_info "Set $key=$value in $file"
}

ensure_config_marker_block() {
  # ensure_config_marker_block <file> <marker> <block-content>
  local file="$1" marker="$2" content="$3"
  if is_dry_run; then log_info "[dry-run] would ensure block [$marker] in $file"; return 0; fi
  [[ -f "$file" ]] || { log_warn "$file not found"; return 1; }
  if grep -qF "$marker" "$file" 2>/dev/null; then
    log_info "Marker $marker already present in $file — updating values inside block."
    # Remove old block, re-append fresh (keeps file clean + idempotent).
    awk -v m="$marker" '
      $0 == m"-BEGIN" {skip=1; next}
      $0 == m"-END" {skip=0; next}
      !skip {print}
    ' "$file" >"${file}.tmp" 2>>"$LOG_FILE" || return 1
    mv "${file}.tmp" "$file" 2>>"$LOG_FILE" || return 1
  else
    backup_file "$file" || true
  fi
  {
    echo ""
    echo "${marker}-BEGIN (managed by $SCRIPT_NAME — safe to remove)"
    printf '%s\n' "$content"
    echo "${marker}-END"
  } >>"$file" 2>>"$LOG_FILE" || return 1
  log_info "Wrote $marker block to $file"
}

ensure_cmdline_param() {
  # ensure_cmdline_param <file> <param> — appends "param" to single-line cmdline if missing.
  local file="$1" param="$2"
  if [[ -z "$file" || -z "$param" ]]; then return 1; fi
  if is_dry_run; then log_info "[dry-run] would ensure cmdline param '$param' in $file"; return 0; fi
  [[ -f "$file" ]] || { log_warn "$file not found"; return 1; }
  local content
  content="$(tr -d '\n' <"$file")"
  if [[ "$content" == *"$param"* ]]; then
    log_info "cmdline already contains '$param'"
    return 0
  fi
  backup_file "$file" || true
  # cmdline.txt MUST stay a single line with trailing newline.
  printf '%s %s\n' "$content" "$param" >"$file" 2>>"$LOG_FILE" || return 1
  log_info "Added '$param' to $file"
}

run_as_user() {
  # run_as_user <command...> — runs as TARGET_USER when we are root.
  if [[ "$(id -u)" -eq 0 && -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    sudo -u "$TARGET_USER" -- "$@" >>"$LOG_FILE" 2>&1
    return $?
  fi
  "$@" >>"$LOG_FILE" 2>&1
  return $?
}

github_latest_deb_url() {
  # github_latest_deb_url <owner/repo> <grep-pattern> — echoes .deb browser URL or "".
  local repo="$1" pattern="$2"
  local api="https://api.github.com/repos/${repo}/releases/latest"
  local json
  json="$(curl -fsSL --max-time 30 "$api" 2>>"$LOG_FILE")" || return 1
  echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
    | sed -E 's/.*"([^"]+)".*/\1/' | grep -iE "$pattern" | head -n 1
}

# ------------------------------------------------------- Detection / preflight

detect_environment() {
  local model="Unknown"
  if [[ -f /proc/device-tree/model ]]; then
    model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo Unknown)"
  elif command_exists hostnamectl; then
    model="$(hostnamectl 2>/dev/null | grep -i 'hardware\|model' | head -n1 || echo Unknown)"
  fi
  PI_MODEL="$model"
  log_info "Detected model: $PI_MODEL"

  if echo "$PI_MODEL" | grep -qi "Raspberry Pi 5"; then
    IS_PI5=true
  else
    IS_PI5=false
  fi

  if [[ "$(uname -m)" == "aarch64" ]]; then
    IS_ARM64=true
  else
    IS_ARM64=false
  fi

  CONFIG_TXT="$(get_boot_file config.txt config.txt)"
  CMDLINE_TXT="$(get_boot_file cmdline.txt cmdline.txt)"
  log_info "config.txt -> $CONFIG_TXT ; cmdline.txt -> $CMDLINE_TXT"

  if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
  fi
  if [[ -z "${TARGET_HOME:-}" || ! -d "${TARGET_HOME:-}" ]]; then
    TARGET_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-root}")"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
  fi
  if [[ -z "${TARGET_HOME:-}" ]]; then TARGET_HOME="/home/pi"; fi
  log_info "Target user: $TARGET_USER ($TARGET_HOME)"
}

preflight_checks() {
  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    log_error "Bash 4+ required (associative arrays). Found: $BASH_VERSION"
    exit 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    log_error "Please run as root:  sudo ./SetMyPiUp.sh"
    exit 1
  fi
  if ! $IS_ARM64; then
    log_warn "Not running on aarch64 ($(uname -m)). Many packages are ARM64-only; failures will be recorded, not fatal."
  fi
  if ! $IS_PI5; then
    log_warn "This does not look like a Raspberry Pi 5 ('$PI_MODEL'). Overclocking will be DISABLED; other installs continue."
  fi
  if ! command_exists apt-get; then
    log_error "apt-get not found — this script requires Debian/Raspberry Pi OS."
    exit 1
  fi
}

ensure_base_tools() {
  log_info "Ensuring base tools (curl, wget, gnupg, git, whiptail)..."
  apt_update || log_warn "Initial apt update had issues — continuing anyway."
  apt_install curl wget gnupg ca-certificates lsb-release git whiptail \
    || log_warn "Some base tools failed — continuing; individual installers will retry."
}

# ------------------------------------------------------------------ CLI ------

print_help() {
  cat <<'EOF'
SetMyPiUp — Raspberry Pi 5 professional setup script

Usage:
  sudo ./SetMyPiUp.sh [OPTIONS]

Options:
  --help                Show this help and exit
  --version             Show version and exit
  --list                List installable app IDs and exit
  --all                 Select every app (still prompts unless --yes)
  --only a,b,c          Install only these comma-separated IDs
  --exclude a,b         Exclude these IDs from selection
  --yes, -y             Non-interactive: assume yes to prompts
  --no-reboot           Do not reboot at the end (default: prompt to reboot)
  --reboot              Reboot without prompting at the end
  --dry-run             Show what would happen, change nothing
  --with-overclock      Apply Pi 5 overclock without asking
  --no-overclock        Never apply overclock
  --log-file PATH       Write log to PATH (default /var/log/setmypiup.log)

Examples:
  sudo ./SetMyPiUp.sh
  sudo ./SetMyPiUp.sh --all --yes
  sudo ./SetMyPiUp.sh --only git,docker,vscode,fastfetch --no-reboot
  sudo ./SetMyPiUp.sh --all --exclude pihole,retropie --yes

Notes:
  - Overclock (2.7GHz CPU / 1GHz GPU) applies ONLY on Raspberry Pi 5.
  - Waydroid automatically applies kernel tweaks (psi=1, 4K pages).
  - One failed app never stops the rest. See the summary + log at the end.
EOF
}

list_apps() {
  printf '%-14s  %-28s  %s\n' "ID" "NAME" "DESCRIPTION"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local id entry name rest func desc
  for id in "${ORDERED_IDS[@]}"; do
    entry="${APP_CATALOG[$id]:-}"
    name="${entry%%|*}"; rest="${entry#*|}"; func="${rest%%|*}"; desc="${rest#*|}"
    printf '%-14s  %-28s  %s\n' "$id" "$name" "$desc"
  done
  echo ""
  echo "Special: overclock (Pi 5 CPU 2.7GHz / GPU 1GHz) — offered separately, use --with-overclock / --no-overclock."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) print_help; exit 0 ;;
      --version) echo "$SCRIPT_NAME v$SCRIPT_VERSION"; exit 0 ;;
      --list) list_apps; exit 0 ;;
      --all) INSTALL_ALL=true; shift ;;
      --only)
        [[ -z "${2:-}" ]] && { log_error "--only needs a value"; exit 1; }
        ONLY_LIST="$2"; shift 2 ;;
      --only=*) ONLY_LIST="${1#--only=}"; shift ;;
      --exclude)
        [[ -z "${2:-}" ]] && { log_error "--exclude needs a value"; exit 1; }
        EXCLUDE_LIST="$2"; shift 2 ;;
      --exclude=*) EXCLUDE_LIST="${1#--exclude=}"; shift ;;
      --yes|-y) ASSUME_YES=true; shift ;;
      --no-reboot) DO_REBOOT=false; shift ;;
      --reboot) DO_REBOOT=true; ASSUME_YES=true; shift ;;
      --dry-run) DRY_RUN=true; DO_REBOOT=false; shift ;;
      --with-overclock) WITH_OVERCLOCK="yes"; shift ;;
      --no-overclock) WITH_OVERCLOCK="no"; shift ;;
      --log-file)
        [[ -z "${2:-}" ]] && { log_error "--log-file needs a value"; exit 1; }
        LOG_FILE="$2"; shift 2 ;;
      --log-file=*) LOG_FILE="${1#--log-file=}"; shift ;;
      *) log_error "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
  done
}

# ------------------------------------------------------------ Selection UI ---

csv_contains() {
  # csv_contains <csv> <needle> — true if needle in comma list.
  local csv="$1" needle="$2"
  [[ ",${csv}," == *",${needle},"* ]]
}

select_apps_interactive() {
  local ids=()
  if [[ -n "$ONLY_LIST" ]]; then
    IFS=',' read -ra ids <<<"$ONLY_LIST"
  elif [[ "$INSTALL_ALL" == true ]]; then
    ids=("${ORDERED_IDS[@]}")
  else
    # Interactive TUI preferred; CLI fallback otherwise.
    if command_exists whiptail || command_exists dialog; then
      tui_checklist || return 1
      return 0
    else
      cli_checklist || return 1
      return 0
    fi
  fi
  # Normalize + apply excludes.
  SELECTED_IDS=()
  local id clean
  for id in "${ids[@]}"; do
    clean="$(echo "$id" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$clean" ]] && continue
    if [[ -z "${APP_CATALOG[$clean]:-}" ]]; then
      log_warn "Unknown app ID '$clean' — skipping (see --list)."
      continue
    fi
    if [[ -n "$EXCLUDE_LIST" ]] && csv_contains "$EXCLUDE_LIST" "$clean"; then
      continue
    fi
    SELECTED_IDS+=("$clean")
  done
  if [[ -n "$EXCLUDE_LIST" && "$INSTALL_ALL" == true ]]; then
    local filtered=() x
    for x in "${SELECTED_IDS[@]}"; do csv_contains "$EXCLUDE_LIST" "$x" || filtered+=("$x"); done
    SELECTED_IDS=("${filtered[@]}")
  fi
}

tui_checklist() {
  local tool="whiptail"
  command_exists whiptail || tool="dialog"
  local args=() id entry name desc state
  for id in "${ORDERED_IDS[@]}"; do
    if [[ -n "$EXCLUDE_LIST" ]] && csv_contains "$EXCLUDE_LIST" "$id"; then continue; fi
    entry="${APP_CATALOG[$id]}"
    name="${entry%%|*}"
    args+=("$id" "$name" OFF)
  done
  local out
  if [[ "$tool" == "whiptail" ]]; then
    out="$(whiptail --title "SetMyPiUp v$SCRIPT_VERSION" \
      --checklist "SPACE toggles, ENTER confirms. One failure never stops the rest." \
      24 78 16 "${args[@]}" 3>&1 1>&2 2>&3)" || { log_info "Selection cancelled."; return 1; }
  else
    out="$(dialog --title "SetMyPiUp v$SCRIPT_VERSION" \
      --checklist "SPACE toggles, ENTER confirms." \
      24 78 16 "${args[@]}" 3>&1 1>&2 2>&3)" || { log_info "Selection cancelled."; return 1; }
  fi
  SELECTED_IDS=()
  # shellcheck disable=SC2086
  for id in $out; do
    id="${id//\"/}"
    [[ -n "$id" ]] && SELECTED_IDS+=("$id")
  done
  if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
    log_warn "Nothing selected."
  fi
}

cli_checklist() {
  echo "No whiptail/dialog found — falling back to text selection."
  echo "Available apps:"
  list_apps
  echo "Enter comma-separated IDs (or 'all'):"
  local ans=""
  local tmp=()
  if [[ "$ASSUME_YES" == true || "$INSTALL_ALL" == true ]]; then
    ans="all"
  else
    read -rp "> " ans || return 1
  fi
  SELECTED_IDS=()
  if [[ "$ans" == "all" ]]; then
    SELECTED_IDS=("${ORDERED_IDS[@]}")
  else
    local id clean
    IFS=',' read -ra tmp <<<"$ans"
    for id in "${tmp[@]}"; do
      clean="$(echo "$id" | tr '[:upper:]' '[:lower:]' | xargs)"
      [[ -n "${APP_CATALOG[$clean]:-}" ]] && SELECTED_IDS+=("$clean")
    done
  fi
}

confirm() {
  # confirm <prompt> — true if yes (auto-yes with --yes).
  local prompt="$1"
  if [[ "$ASSUME_YES" == true ]]; then return 0; fi
  local ans
  read -rp "$prompt [y/N] " ans || return 1
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ============================================================ INSTALLERS =====
# Convention: install_* returns 0 on success, non-zero on failure, and NEVER
# calls exit. All output goes to $LOG_FILE. Each starts with an "already
# installed?" fast-path so the script is re-runnable.

install_git() {
  command_exists git && command_exists git-lfs && command_exists lsb_release \
    && { log_info "git already installed."; return 0; }
  apt_update || true
  apt_install git git-lfs lsb-release || return 1
  run_cmd "enable git-lfs" git lfs install --system || log_warn "git-lfs init warning (non-fatal)"
  command_exists git || return 1
  return 0
}

install_curl() {
  command_exists curl && return 0
  apt_update || true
  apt_install curl ca-certificates || return 1
}

install_wget() {
  command_exists wget && return 0
  apt_update || true
  apt_install wget || return 1
}

install_python() {
  command_exists python3 && command_exists pip3 && return 0
  apt_update || true
  apt_install python3 python3-pip python3-venv pipx || return 1
}

install_flatpak() {
  if command_exists flatpak; then
    log_info "flatpak present — ensuring Flathub remote."
  else
    apt_update || true
    apt_install flatpak || return 1
  fi
  if is_dry_run; then return 0; fi
  if ! flatpak remotes 2>>"$LOG_FILE" | grep -q flathub; then
    run_cmd "add Flathub" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
  fi
  return 0
}

install_pi_apps() {
  local dest="$TARGET_HOME/pi-apps"
  if [[ -f "$dest/manage" || -f "$dest/manage.sh" ]]; then
    log_info "Pi-Apps already cloned at $dest — pulling latest."
    if ! is_dry_run; then
      run_as_user git -C "$dest" pull --ff-only || log_warn "pi-apps pull failed (non-fatal)"
    fi
    return 0
  fi
  if is_dry_run; then log_info "[dry-run] would install Pi-Apps to $dest"; return 0; fi
  command_exists git || apt_install git || return 1
  log_info "Cloning Pi-Apps to $dest ..."
  rm -rf "$dest" 2>>"$LOG_FILE" || true
  if ! run_as_user git clone --depth 1 https://github.com/Botspot/pi-apps "$dest"; then
    # Fallback: official web installer as target user.
    log_warn "git clone failed, trying official web installer."
    if ! sudo -u "$TARGET_USER" bash -c 'wget -qO- https://raw.githubusercontent.com/Botspot/pi-apps/master/install | bash' >>"$LOG_FILE" 2>&1; then
      return 1
    fi
  fi
  [[ -f "$dest/manage" || -f "$dest/manage.sh" ]] || { log_warn "Pi-Apps clone missing manage script"; return 1; }
  return 0
}

pi_apps_install() {
  # pi_apps_install <AppName> — uses Pi-Apps CLI if available.
  local app="$1"
  local dest="$TARGET_HOME/pi-apps"
  local manage=""
  [[ -f "$dest/manage" ]] && manage="$dest/manage"
  [[ -z "$manage" && -f "$dest/manage.sh" ]] && manage="$dest/manage.sh"
  if [[ -z "$manage" ]]; then return 1; fi
  if is_dry_run; then log_info "[dry-run] would pi-apps install: $app"; return 0; fi
  log_info "Installing '$app' via Pi-Apps..."
  sudo -u "$TARGET_USER" bash "$manage" install "$app" >>"$LOG_FILE" 2>&1
}

install_brave() {
  command_exists brave-browser && { log_info "Brave already installed."; return 0; }
  apt_install curl gnupg ca-certificates || return 1
  if is_dry_run; then log_info "[dry-run] would add Brave repo + install brave-browser"; return 0; fi
  local keyring="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
  local list="/etc/apt/sources.list.d/brave-browser-release.list"
  if [[ ! -f "$keyring" ]]; then
    curl -fsSL --max-time 60 https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
      -o "$keyring" 2>>"$LOG_FILE" || return 1
  fi
  echo "deb [signed-by=$keyring arch=arm64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    >"$list" 2>>"$LOG_FILE" || return 1
  apt_update || true
  apt_install brave-browser || return 1
}

install_vscode() {
  command_exists code && { log_info "VS Code already installed."; return 0; }
  apt_install curl gnupg ca-certificates || return 1
  if is_dry_run; then log_info "[dry-run] would add Microsoft repo + install code"; return 0; fi
  local keyring="/usr/share/keyrings/packages.microsoft.gpg"
  if [[ ! -f "$keyring" ]]; then
    curl -fsSL --max-time 60 https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o "$keyring" 2>>"$LOG_FILE" || return 1
  fi
  echo "deb [arch=arm64 signed-by=$keyring] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list 2>>"$LOG_FILE" || return 1
  apt_update || true
  apt_install code || return 1
}

install_chromium() {
  (command_exists chromium || command_exists chromium-browser) && { log_info "Chromium present."; return 0; }
  apt_update || true
  # Package name differs across releases; try both, succeed if either works.
  if apt_install chromium; then return 0; fi
  apt_install chromium-browser || return 1
}

install_nodejs() {
  if command_exists node; then log_info "node $(node --version 2>/dev/null) present."; return 0; fi
  apt_install curl ca-certificates gnupg || return 1
  if is_dry_run; then log_info "[dry-run] would add NodeSource 22.x + install nodejs"; return 0; fi
  local setup="/tmp/nodesource_setup_22.x.sh"
  curl -fsSL --max-time 120 https://deb.nodesource.com/setup_22.x -o "$setup" 2>>"$LOG_FILE" || return 1
  run_cmd "nodesource setup" bash "$setup" || return 1
  apt_install nodejs || return 1
  command_exists node || return 1
  return 0
}

install_docker() {
  if command_exists docker; then
    log_info "Docker present — ensuring service enabled."
    if ! is_dry_run; then systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true; fi
    return 0
  fi
  apt_install curl ca-certificates || return 1
  if is_dry_run; then log_info "[dry-run] would run get.docker.com + usermod"; return 0; fi
  local sh="/tmp/get-docker.sh"
  curl -fsSL --max-time 120 https://get.docker.com -o "$sh" 2>>"$LOG_FILE" || return 1
  run_cmd "docker install script" sh "$sh" || return 1
  systemctl enable --now docker >>"$LOG_FILE" 2>&1 || log_warn "Could not start docker (non-fatal)"
  if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    usermod -aG docker "$TARGET_USER" >>"$LOG_FILE" 2>&1 || log_warn "usermod docker group failed (non-fatal)"
  fi
  command_exists docker || return 1
  return 0
}

install_pihole() {
  if command_exists pihole; then log_info "Pi-hole already installed."; return 0; fi
  apt_install curl git iproute2 whiptail || return 1
  if is_dry_run; then log_info "[dry-run] would run Pi-hole unattended installer"; return 0; fi
  log_warn "Pi-hole changes DNS/DHCP — ensure you have console access before continuing."
  if [[ "$ASSUME_YES" != true ]]; then
    confirm "Install Pi-hole now (network/DNS will be reconfigured)?" || { log_info "Pi-hole skipped by user."; return 1; }
  fi
  local dir="/tmp/pihole-install"
  rm -rf "$dir" 2>/dev/null || true
  mkdir -p "$dir" || return 1
  curl -sSL --max-time 120 https://install.pi-hole.net -o "$dir/basic-install.sh" 2>>"$LOG_FILE" || return 1
  chmod +x "$dir/basic-install.sh"
  mkdir -p /etc/pihole
  if [[ ! -f /etc/pihole/setupVars.conf ]]; then
    cat >/etc/pihole/setupVars.conf <<'PIHOLE_VARS'
PIHOLE_INTERFACE=eth0
IPV4_ADDRESS=0.0.0.0
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
PIHOLE_VARS
  fi
  run_cmd "pi-hole installer" bash "$dir/basic-install.sh" --unattended || return 1
  command_exists pihole || return 1
  return 0
}

install_libreoffice() {
  command_exists libreoffice && { log_info "LibreOffice present."; return 0; }
  apt_update || true
  apt_install libreoffice || return 1
}

install_kodi() {
  command_exists kodi && { log_info "Kodi present."; return 0; }
  apt_update || true
  apt_install kodi || return 1
}

install_vlc() {
  command_exists vlc && { log_info "VLC present."; return 0; }
  apt_update || true
  apt_install vlc || return 1
}

install_gimp() {
  command_exists gimp && { log_info "GIMP present."; return 0; }
  apt_update || true
  apt_install gimp || return 1
}

install_obs() {
  if command_exists obs || flatpak info com.obsproject.Studio >>"$LOG_FILE" 2>&1; then
    log_info "OBS Studio present."; return 0
  fi
  apt_update || true
  if apt_install obs-studio v4l2loopback-dkms; then return 0; fi
  log_warn "APT obs-studio failed — trying Flatpak fallback."
  command_exists flatpak || install_flatpak || return 1
  flatpak_install com.obsproject.Studio || return 1
}

install_qemu() {
  command_exists qemu-system-aarch64 && { log_info "QEMU present."; return 0; }
  apt_update || true
  apt_install qemu-system qemu-utils virt-manager || return 1
}

install_snapd() {
  command_exists snap && { log_info "snapd present."; return 0; }
  apt_update || true
  apt_install snapd || return 1
  if ! is_dry_run; then
    systemctl enable --now snapd.socket snapd.service >>"$LOG_FILE" 2>&1 || true
    ln -sf /var/lib/snapd/snap /snap 2>>"$LOG_FILE" || true
  fi
  return 0
}

install_java() {
  if command_exists java && command_exists javac; then
    log_info "Java present: $(java -version 2>&1 | head -n1)"; return 0
  fi
  apt_update || true
  # Install 17 (widely required, e.g. Minecraft tooling) + 21 (current LTS).
  apt_install openjdk-17-jdk openjdk-21-jdk || apt_install default-jdk || return 1
}

install_dotnet() {
  if command_exists dotnet; then log_info "dotnet present."; return 0; fi
  apt_install wget ca-certificates || return 1
  if is_dry_run; then log_info "[dry-run] would add Microsoft feed + install dotnet-sdk-8.0"; return 0; fi
  local deb="/tmp/packages-microsoft-prod.deb"
  if [[ ! -f "$deb" ]]; then
    wget -q --timeout=60 https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O "$deb" 2>>"$LOG_FILE" || return 1
  fi
  dpkg -i "$deb" >>"$LOG_FILE" 2>&1 || apt_install -f || true
  apt_update || true
  if apt_install dotnet-sdk-8.0 aspnetcore-runtime-8.0 dotnet-runtime-8.0; then
    command_exists dotnet && return 0
  fi
  log_warn "Feed install failed — trying dotnet-install script fallback (8.0 LTS)."
  local script="/tmp/dotnet-install.sh"
  curl -fsSL --max-time 120 https://dot.net/v1/dotnet-install.sh -o "$script" 2>>"$LOG_FILE" || return 1
  chmod +x "$script"
  run_cmd "dotnet-install" bash "$script" --channel 8.0 --install-dir /usr/share/dotnet || return 1
  ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet 2>>"$LOG_FILE" || true
  command_exists dotnet || return 1
  return 0
}

install_fastfetch() {
  command_exists fastfetch && { log_info "fastfetch present."; return 0; }
  apt_update || true
  if apt_install fastfetch; then return 0; fi
  log_warn "APT fastfetch unavailable — building latest release .deb fallback."
  if is_dry_run; then return 0; fi
  local url
  url="$(github_latest_deb_url "fastfetch-cli/fastfetch" "linux-arm64|linux-aarch64|arm64")" || return 1
  [[ -z "$url" ]] && return 1
  local deb="/tmp/fastfetch.deb"
  curl -fsSL --max-time 120 "$url" -o "$deb" 2>>"$LOG_FILE" || return 1
  dpkg -i "$deb" >>"$LOG_FILE" 2>&1 || apt_install -f || true
  command_exists fastfetch || return 1
  return 0
}

install_adb() {
  if command_exists adb && command_exists fastboot; then log_info "adb/fastboot present."; return 0; fi
  apt_update || true
  apt_install android-tools-adb android-tools-fastboot || return 1
  if ! is_dry_run && [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    usermod -aG plugdev "$TARGET_USER" >>"$LOG_FILE" 2>&1 || true
  fi
  return 0
}

install_prismlauncher() {
  if command_exists prismlauncher || flatpak info org.PrismLauncher.PrismLauncher >>"$LOG_FILE" 2>&1; then
    log_info "PrismLauncher present."; return 0
  fi
  # Preferred: Pi-Apps (native ARM64 build per request).
  if [[ -d "$TARGET_HOME/pi-apps" ]] || install_pi_apps; then
    if pi_apps_install "PrismLauncher"; then
      command_exists prismlauncher && return 0
      log_info "Pi-Apps PrismLauncher step finished (binary name may vary) — checking Flatpak fallback."
    else
      log_warn "Pi-Apps PrismLauncher failed — trying Flatpak."
    fi
  fi
  command_exists flatpak || install_flatpak || return 1
  flatpak_install org.PrismLauncher.PrismLauncher || return 1
}

install_dolphin() {
  if command_exists dolphin-emu || flatpak info org.DolphinEmu.dolphin-emu >>"$LOG_FILE" 2>&1; then
    log_info "Dolphin present."; return 0
  fi
  apt_update || true
  if apt_install dolphin-emu; then return 0; fi
  log_warn "APT dolphin-emu failed — trying Flatpak."
  command_exists flatpak || install_flatpak || return 1
  flatpak_install org.DolphinEmu.dolphin-emu || return 1
}

install_eden() {
  if flatpak info io.github.eden_emu.eden >>"$LOG_FILE" 2>&1; then
    log_info "Eden present (Flatpak)."; return 0
  fi
  if [[ -x "$TARGET_HOME/Applications/Eden.AppImage" ]]; then
    log_info "Eden present (AppImage)."; return 0
  fi
  command_exists flatpak || install_flatpak || return 1
  if flatpak_install io.github.eden_emu.eden; then return 0; fi
  log_warn "Flatpak Eden failed — trying AppImage fallback (eden-emu.dev)."
  if is_dry_run; then return 0; fi
  local api="https://api.github.com/repos/eden-emulator/Releases/releases/latest"
  local url
  url="$(curl -fsSL --max-time 30 "$api" 2>>"$LOG_FILE" \
    | grep -oE '"browser_download_url": *"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' \
    | grep -iE 'linux.*(aarch64|arm64).*appimage' | head -n 1 || true)"
  if [[ -z "$url" ]]; then
    log_warn "Could not locate Eden ARM64 AppImage (URL scheme may have changed)."
    return 1
  fi
  local dir="$TARGET_HOME/Applications"
  mkdir -p "$dir" || return 1
  curl -fsSL --max-time 300 "$url" -o "$dir/Eden.AppImage" 2>>"$LOG_FILE" || return 1
  chmod +x "$dir/Eden.AppImage"
  chown -R "$TARGET_USER:$TARGET_USER" "$dir" 2>>"$LOG_FILE" || true
  cat >"/usr/share/applications/eden.desktop" <<EOF 2>>"$LOG_FILE" || true
[Desktop Entry]
Name=Eden (Switch Emulator)
Exec=$dir/Eden.AppImage
Icon=applications-games
Type=Application
Categories=Game;Emulator;
EOF
  return 0
}

install_steam() {
  if command_exists steam || [[ -x "$TARGET_HOME/.steam/steam.sh" ]]; then
    log_info "Steam present."; return 0
  fi
  # Steam is x86-only; on Pi it runs via Box86/Box64 automation in Pi-Apps.
  if [[ ! -d "$TARGET_HOME/pi-apps" ]]; then
    install_pi_apps || { log_warn "Steam needs Pi-Apps (Box86/Box64 automation)."; return 1; }
  fi
  if is_dry_run; then log_info "[dry-run] would pi-apps install Steam"; return 0; fi
  pi_apps_install "Steam" || return 1
  command_exists steam && return 0
  # Pi-Apps may install launcher without PATH binary; check desktop file.
  if [[ -f "$TARGET_HOME/.local/share/applications/steam.desktop" || -f "/usr/local/bin/steam" ]]; then
    return 0
  fi
  log_warn "Steam installer finished but no binary found yet (Box86/Box64 setup may need a reboot)."
  return 1
}

install_retropie() {
  local dest="/opt/RetroPie-Setup"
  [[ -d "$TARGET_HOME/RetroPie-Setup" ]] && dest="$TARGET_HOME/RetroPie-Setup"
  if [[ -d "$dest" ]]; then log_info "RetroPie setup already cloned at $dest."; return 0; fi
  apt_install git dialog unzip xmlstarlet || return 1
  if is_dry_run; then log_info "[dry-run] would clone RetroPie-Setup to $dest"; return 0; fi
  log_warn "RetroPie full install takes HOURS — this step only clones the setup script."
  git clone --depth 1 https://github.com/RetroPie/RetroPie-Setup.git "$dest" 2>>"$LOG_FILE" || return 1
  chmod +x "$dest/retropie_setup.sh" 2>>"$LOG_FILE" || true
  if [[ "$dest" == "$TARGET_HOME"* ]]; then chown -R "$TARGET_USER:$TARGET_USER" "$dest" 2>>"$LOG_FILE" || true; fi
  log_info "RetroPie cloned. Run 'sudo $dest/retropie_setup.sh' to install packages."
  return 0
}

apply_waydroid_kernel_tweaks() {
  # psi=1 in cmdline + 4K pages (kernel8.img) for Pi 5 Waydroid support.
  local ok=true
  log_info "Applying Waydroid kernel tweaks (psi=1, 4K pages)..."
  if [[ ! -f "$CMDLINE_TXT" ]]; then
    log_warn "$CMDLINE_TXT not found — cannot set psi=1."
    ok=false
  else
    ensure_cmdline_param "$CMDLINE_TXT" "psi=1" || ok=false
  fi
  if [[ ! -f "$CONFIG_TXT" ]]; then
    log_warn "$CONFIG_TXT not found — cannot set 4K page size."
    ok=false
  else
    # On Pi 5 / Bookworm the default 16K-page kernel breaks Waydroid binder;
    # forcing kernel8.img selects the 4K-page kernel.
    ensure_config_value "$CONFIG_TXT" "kernel" "kernel8.img" || ok=false
  fi
  $ok
}

install_waydroid() {
  local tweaks_ok=true
  apply_waydroid_kernel_tweaks || tweaks_ok=false

  if command_exists waydroid; then
    log_info "Waydroid present — refreshing init (tweaks applied: $tweaks_ok)."
    if ! is_dry_run; then
      systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || true
    fi
    $tweaks_ok && return 0 || return 1
  fi
  apt_install curl ca-certificates python3 lxc sqlite3 || return 1
  if is_dry_run; then
    log_info "[dry-run] would add repo.waydroid.org + install waydroid + init"
    $tweaks_ok
    return 0
  fi
  local script="/tmp/waydroid-repo.sh"
  curl -fsSL --max-time 60 https://repo.waydro.id -o "$script" 2>>"$LOG_FILE" || return 1
  run_cmd "waydroid repo script" bash "$script" || return 1
  apt_update || true
  apt_install waydroid lxc || return 1
  # Image download (~1GB). VANILLA is smaller/more reliable; user can re-init GAPPS later.
  log_info "Downloading Waydroid image (VANILLA, may take a while)..."
  if ! waydroid init >>"$LOG_FILE" 2>&1; then
    log_warn "waydroid init failed — package installed, image can be retried with 'sudo waydroid init'."
    systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || true
    $tweaks_ok
    return
  fi
  systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || log_warn "waydroid-container start issue (non-fatal)"
  $tweaks_ok
}

install_mcpi_reborn() {
  if command_exists minecraft-pi-reborn-client || command_exists mcpi-reborn; then
    log_info "MCPI: Reborn present."; return 0
  fi
  # Preferred: Pi-Apps build (handles ARM specifics).
  if [[ -d "$TARGET_HOME/pi-apps" ]] || install_pi_apps; then
    if pi_apps_install "Minecraft Pi (Reborn)"; then
      command_exists minecraft-pi-reborn-client && return 0
    else
      log_warn "Pi-Apps MCPI Reborn failed — trying .deb fallback."
    fi
  fi
  if is_dry_run; then log_info "[dry-run] would install MCPI:Reborn .deb"; return 0; fi
  apt_install curl jq ca-certificates || return 1
  # TheBrokenRail Gitea releases.
  local api="https://gitea.thebrokenrail.com/api/v1/repos/minecraft-pi-reborn/minecraft-pi-reborn/releases/latest"
  local json
  json="$(curl -fsSL --max-time 30 "$api" 2>>"$LOG_FILE")" || { log_warn "MCPI release API unreachable."; return 1; }
  local url
  url="$(echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
    | sed -E 's/.*"([^"]+)".*/\1/' | grep -iE 'arm64|aarch64' | head -n 1 || true)"
  if [[ -z "$url" ]]; then
    url="$(echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
      | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1 || true)"
  fi
  [[ -z "$url" ]] && { log_warn "No MCPI .deb asset found."; return 1; }
  local deb="/tmp/mcpi-reborn.deb"
  curl -fsSL --max-time 300 "$url" -o "$deb" 2>>"$LOG_FILE" || return 1
  dpkg -i "$deb" >>"$LOG_FILE" 2>&1 || apt_install -f || true
  command_exists minecraft-pi-reborn-client || command_exists minecraft-pi-reborn || return 1
  return 0
}

install_llamacpp() {
  if command_exists llama-cli || command_exists llama-server || [[ -x /opt/llama.cpp/build/bin/llama-cli ]]; then
    log_info "llama.cpp present."; return 0
  fi
  apt_install git build-essential cmake libcurl4-openssl-dev libopenblas-dev || return 1
  if is_dry_run; then log_info "[dry-run] would clone+build llama.cpp"; return 0; fi
  local dest="/opt/llama.cpp"
  if [[ ! -d "$dest/.git" ]]; then
    rm -rf "$dest" 2>>"$LOG_FILE" || true
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$dest" 2>>"$LOG_FILE" || return 1
  else
    git -C "$dest" pull --ff-only >>"$LOG_FILE" 2>&1 || true
  fi
  log_info "Building llama.cpp (Pi 5 ARM NEON, $(nproc) jobs — may take 10-30 min)..."
  if ! cmake -S "$dest" -B "$dest/build" -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release >>"$LOG_FILE" 2>&1; then
    log_warn "cmake configure failed"
    return 1
  fi
  if ! cmake --build "$dest/build" --config Release -j "$(nproc)" >>"$LOG_FILE" 2>&1; then
    log_warn "llama.cpp build failed"
    return 1
  fi
  ln -sf "$dest/build/bin/llama-cli" /usr/local/bin/llama-cli 2>>"$LOG_FILE" || true
  ln -sf "$dest/build/bin/llama-server" /usr/local/bin/llama-server 2>>"$LOG_FILE" || true
  return 0
}

install_opencode() {
  if command_exists opencode; then log_info "opencode present."; return 0; fi
  command_exists curl || apt_install curl || return 1
  if is_dry_run; then log_info "[dry-run] would run opencode.ai/install"; return 0; fi
  # Official installer (installs to ~/.local/bin for invoking user).
  if sudo -u "$TARGET_USER" bash -c 'curl -fsSL https://opencode.ai/install | bash' >>"$LOG_FILE" 2>&1; then
    ln -sf "$TARGET_HOME/.local/bin/opencode" /usr/local/bin/opencode 2>>"$LOG_FILE" || true
    command_exists opencode && return 0
  fi
  log_warn "Official installer failed — trying npm fallback."
  command_exists npm || install_nodejs || return 1
  npm install -g opencode-ai >>"$LOG_FILE" 2>&1 || return 1
  command_exists opencode || return 1
  return 0
}

install_claude_code() {
  if command_exists claude; then log_info "Claude Code present."; return 0; fi
  command_exists npm || install_nodejs || return 1
  if is_dry_run; then log_info "[dry-run] would npm i -g @anthropic-ai/claude-code"; return 0; fi
  npm install -g @anthropic-ai/claude-code >>"$LOG_FILE" 2>&1 || return 1
  command_exists claude || return 1
  return 0
}

install_sunshine() {
  local have_host=false have_client=false
  command_exists sunshine && have_host=true
  flatpak info com.moonlight_stream.Moonlight >>"$LOG_FILE" 2>&1 && have_client=true
  command_exists moonlight && have_client=true
  if $have_host && $have_client; then log_info "Sunshine + Moonlight present."; return 0; fi

  # --- Host: Sunshine (LizardByte) ARM64 .deb ---
  if ! $have_host; then
    if is_dry_run; then
      log_info "[dry-run] would install Sunshine host .deb"
    else
      local url
      url="$(github_latest_deb_url "LizardByte/Sunshine" "debian.*(arm64|aarch64)|arm64.*debian")" || url=""
      if [[ -z "$url" ]]; then
        # Broader match: any arm64 deb.
        local json
        json="$(curl -fsSL --max-time 30 https://api.github.com/repos/LizardByte/Sunshine/releases/latest 2>>"$LOG_FILE" || true)"
        url="$(echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
          | sed -E 's/.*"([^"]+)".*/\1/' | grep -iE 'arm64|aarch64' | grep -iE 'debian|bookworm|ubuntu' | head -n 1 || true)"
        [[ -z "$url" ]] && url="$(echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
          | sed -E 's/.*"([^"]+)".*/\1/' | grep -iE 'arm64|aarch64' | head -n 1 || true)"
      fi
      if [[ -n "$url" ]]; then
        local deb="/tmp/sunshine.deb"
        if curl -fsSL --max-time 300 "$url" -o "$deb" 2>>"$LOG_FILE"; then
          dpkg -i "$deb" >>"$LOG_FILE" 2>&1 || apt_install -f || true
          command_exists sunshine && have_host=true
        else
          log_warn "Sunshine download failed."
        fi
      else
        log_warn "Could not locate Sunshine ARM64 .deb (release assets may have changed)."
      fi
    fi
  fi

  # --- Client: Moonlight (Flatpak) ---
  if ! $have_client; then
    command_exists flatpak || install_flatpak || true
    if flatpak_install com.moonlight_stream.Moonlight; then
      have_client=true
    else
      log_warn "Moonlight Flatpak failed."
    fi
  fi

  if $have_host || $have_client; then
    log_info "Streaming setup: host=$have_host client=$have_client"
    return 0
  fi
  return 1
}

# ------------------------------------------------------- Overclock (Pi5 only)

apply_overclock() {
  if ! $IS_PI5; then
    log_error "Overclock REFUSED: not a Raspberry Pi 5 ('$PI_MODEL'). No changes made."
    return 1
  fi
  if [[ ! -f "$CONFIG_TXT" ]]; then
    log_error "Overclock failed: $CONFIG_TXT not found."
    return 1
  fi
  if is_dry_run; then
    log_info "[dry-run] would set arm_freq=$OC_ARM_FREQ gpu_freq=$OC_GPU_FREQ over_voltage_delta=$OC_VOLT_DELTA in $CONFIG_TXT"
    return 0
  fi
  log_warn "Overclocking to ${OC_ARM_FREQ}MHz CPU / ${OC_GPU_FREQ}MHz GPU."
  log_warn "REQUIRES active cooling (official Active Cooler or Argon THRML). Voids warranty margins — monitor temps!"
  local block
  block="$(printf 'arm_freq=%s\ngpu_freq=%s\nover_voltage_delta=%s' "$OC_ARM_FREQ" "$OC_GPU_FREQ" "$OC_VOLT_DELTA")"
  ensure_config_marker_block "$CONFIG_TXT" "# SetMyPiUp-OC" "$block" || return 1
  log_ok "Overclock block written. Takes effect after reboot. Verify with: vcgencmd measure_clock arm"
  return 0
}

# ------------------------------------------------------- Runner / summary ----

run_installer() {
  # run_installer <id> — dispatches catalog function, isolates failures.
  local id="$1"
  local entry="${APP_CATALOG[$id]:-}"
  if [[ -z "$entry" ]]; then
    log_warn "Unknown ID '$id' — skipping."
    SKIPPED_LIST+=("$id (unknown)")
    return 0
  fi
  local name="${entry%%|*}"
  local rest="${entry#*|}"
  local func="${rest%%|*}"
  log_info "==================== Installing: $name ($id) ===================="
  # Each installer runs with `set +e` semantics (we never use set -e) plus a
  # subshell guard so an unexpected `exit` inside can't kill the whole run.
  local rc=0
  ( set +e; "$func" ) || rc=$?
  if [[ $rc -eq 0 ]]; then
    log_ok "$name installed."
    SUCCESS_LIST+=("$name")
  else
    log_error "$name FAILED (rc=$rc) — continuing with next app. See $LOG_FILE"
    FAILED_LIST+=("$name")
  fi
  return 0
}

print_summary() {
  echo ""
  echo "=================================================================="
  echo " $SCRIPT_NAME v$SCRIPT_VERSION — Summary"
  echo "=================================================================="
  echo " Model:        $PI_MODEL"
  echo " Log:          $LOG_FILE"
  echo " Successful (${#SUCCESS_LIST[@]}):"
  local s
  for s in "${SUCCESS_LIST[@]:-}"; do [[ -n "$s" ]] && echo "   [OK] $s"; done
  echo " Failed (${#FAILED_LIST[@]}):"
  for s in "${FAILED_LIST[@]:-}"; do [[ -n "$s" ]] && echo "   [FAIL] $s"; done
  if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
    echo ""
    echo " Some installs failed — this is expected on occasion (network,"
    echo " upstream renames, Waydroid image size, RetroPie build time)."
    echo " Re-run the script later for just those apps, e.g.:"
    echo "   sudo $0 --only <ids>   # see --list"
  fi
  echo ""
  echo " Kernel/boot notes:"
  echo "   config.txt:  $CONFIG_TXT"
  echo "   cmdline.txt: $CMDLINE_TXT"
  echo "   A reboot is required for kernel, Waydroid, Docker and OC changes."
  echo "=================================================================="
}

do_reboot() {
  if [[ "$DO_REBOOT" != true ]]; then
    log_info "Reboot skipped (--no-reboot / --dry-run). Remember to reboot manually!"
    return 0
  fi
  if is_dry_run; then
    log_info "[dry-run] would reboot now."
    return 0
  fi
  if [[ "$ASSUME_YES" == true ]]; then
    log_warn "Rebooting in 10s (Ctrl+C to cancel)..."
    sleep 10
    log_info "Rebooting now."
    reboot
  else
    if confirm "Reboot now (required for kernel/overclock/Waydroid changes)?"; then
      log_info "Rebooting now."
      reboot
    else
      log_info "Reboot declined — please reboot manually soon."
    fi
  fi
}

# ------------------------------------------------------------------ Main -----

main() {
  parse_args "$@"
  log_init "$@"
  log_info "$SCRIPT_NAME v$SCRIPT_VERSION starting..."

  detect_environment
  preflight_checks
  ensure_base_tools

  select_apps_interactive || { log_info "No apps selected — exiting."; exit 0; }

  if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
    log_warn "Empty selection. Nothing to do. See --list / --all."
    exit 0
  fi

  log_info "Selected (${#SELECTED_IDS[@]}): ${SELECTED_IDS[*]}"
  if is_dry_run; then
    log_info "DRY RUN — no changes will be made."
  elif [[ "$ASSUME_YES" != true ]]; then
    echo "About to install: ${SELECTED_IDS[*]}"
    confirm "Proceed?" || { log_info "Aborted by user."; exit 0; }
  fi

  local id
  for id in "${SELECTED_IDS[@]}"; do
    run_installer "$id"
  done

  # Overclock is separate from the app list (safety-gated to Pi 5).
  local do_oc=false
  case "$WITH_OVERCLOCK" in
    yes) do_oc=true ;;
    no)  do_oc=false ;;
    ask)
      if $IS_PI5; then
        echo ""
        echo "Optional: overclock Pi 5 to ${OC_ARM_FREQ}MHz CPU / ${OC_GPU_FREQ}MHz GPU?"
        echo "(Requires ACTIVE cooling. Pi 5 only — auto-refused elsewhere.)"
        if [[ "$ASSUME_YES" == true ]]; then
          do_oc=false
          log_info "Overclock skipped in non-interactive mode (use --with-overclock to force)."
        elif confirm "Apply overclock"; then
          do_oc=true
        fi
      else
        log_info "Overclock not offered (not a Pi 5)."
      fi
      ;;
  esac
  if $do_oc; then
    log_info "==================== Applying: Pi 5 Overclock ===================="
    if apply_overclock; then
      SUCCESS_LIST+=("Pi 5 Overclock (${OC_ARM_FREQ}/${OC_GPU_FREQ}MHz)")
    else
      FAILED_LIST+=("Pi 5 Overclock")
    fi
  fi

  print_summary
  do_reboot
}

main "$@"
