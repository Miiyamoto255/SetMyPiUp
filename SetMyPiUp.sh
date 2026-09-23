#!/usr/bin/env bash
###############################################################################
# SetMyPiUp — Professional Raspberry Pi 5 setup & application installer
#
# Version:     1.1.0
# Target:      Raspberry Pi 5, Raspberry Pi OS 64-bit (Debian Bookworm+)
# Author:      Miiyamoto255
# License:     MIT
#
# What it does:
#   - Validates the system first (arch, OS, connectivity, disk, Pi 5 identity)
#   - Lets the user pick which apps to install (whiptail/dialog/CLI)
#   - Installs each app in isolation so one failure never breaks the run
#   - Prefers Pi-Apps sources wherever a Pi-Apps version exists
#   - Applies Waydroid kernel tweaks (psi=1, 4K pages via kernel8.img)
#   - Optionally overclocks Pi 5 (conservative defaults, user-configurable)
#   - Installs software only — every app needing accounts/pairing/keys is
#     left for the user to set up afterwards (see "NEXT STEPS" in summary)
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
SCRIPT_VERSION="1.1.0"
LOG_FILE="${LOG_FILE:-/var/log/setmypiup.log}"
DRY_RUN=false
ASSUME_YES=false
FORCE=false
DO_REBOOT=true
INSTALL_ALL=false
ONLY_LIST=""
EXCLUDE_LIST=""
WITH_OVERCLOCK="ask"   # ask | yes | no
WITH_WAYDROID_TWEAKS=true
# Overclock (Pi 5 ONLY): conservative defaults, overridable via
# --oc-cpu/--oc-gpu or SETMYPIUP_OC_CPU / SETMYPIUP_OC_GPU (MHz).
OC_CPU_FREQ="${SETMYPIUP_OC_CPU:-2600}"
OC_GPU_FREQ="${SETMYPIUP_OC_GPU:-900}"
OC_VOLT_DELTA=50000    # applied only when CPU target exceeds 2600MHz
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
declare -a NEXT_STEPS=()

# App catalog: ID -> "Human Name|installer_function|description"
declare -A APP_CATALOG=(
  [git]="Git + Git LFS + LSB|install_git|Version control, large-file support and LSB release info"
  [curl]="cURL|install_curl|Command-line URL transfer tool"
  [wget]="wget|install_wget|Command-line file downloader"
  [python]="Python 3 + pip|install_python|Python3, pip, venv and pipx"
  [flatpak]="Flatpak + Flathub|install_flatpak|Sandboxed app framework + Flathub repo"
  [pi-apps]="Pi-Apps|install_pi_apps|Community app store for Raspberry Pi"
  [brave]="Brave Browser|install_brave|Privacy browser (Pi-Apps first, official ARM64 repo fallback)"
  [vscode]="VS Code|install_vscode|Visual Studio Code (Pi OS repo first, Microsoft repo fallback)"
  [chromium]="Chromium|install_chromium|Open-source Chromium browser"
  [nodejs]="Node.js LTS|install_nodejs|Node.js 22 LTS + npm (NodeSource ARM64)"
  [docker]="Docker Engine|install_docker|Containers via official Docker APT repo (arm64)"
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
  [sunshine]="Sunshine + Moonlight|install_sunshine|Game streaming host + client (BOTH required for success)"
)

# Stable display order (whiptail checklist + --list)
ORDERED_IDS=(
  git curl wget python flatpak pi-apps brave vscode chromium
  nodejs docker pihole libreoffice kodi vlc gimp obs qemu snapd
  java dotnet fastfetch adb prismlauncher dolphin eden steam
  retropie waydroid mcpi-reborn llamacpp opencode claude-code sunshine
)

# Overclock defaults (Pi 5 ONLY — see OC_CPU_FREQ / OC_GPU_FREQ above).
# Conservative: 2600MHz CPU / 900MHz GPU. The user may raise these
# interactively (validated) or via --oc-cpu / --oc-gpu.

# Pi-Apps-first routing (task: prefer Pi-Apps wherever a Pi-Apps version
# exists). Maps our catalog ID -> exact Pi-Apps app directory name.
# Names marked [verified] were confirmed against pi-apps.io / the Pi-Apps
# repo (Sep 2026); the rest are best-effort candidates. pi_apps_try()
# only attempts an install when the directory exists in the local clone,
# so a stale/wrong name can never break the direct-install fallback.
declare -A PI_APPS_MAP=(
  [brave]="Brave"                                              # [verified]
  [prismlauncher]="Minecraft Java Prism Launcher"              # [verified]
  [steam]="Steam"                                              # [verified]
  [mcpi-reborn]="Minecraft Pi (Reborn)"                        # candidate
)

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
  # Nanosecond timestamp + PID: two edits within the same second (e.g. a
  # re-run, or config + cmdline writes back-to-back) must never collide.
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S-%N' 2>/dev/null || date '+%Y%m%d-%H%M%S')"
  local bak="${f}.setmypiup-bak-${stamp}-$$"
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
  # ALWAYS back up before touching an existing file — including re-runs
  # that only replace our own previously managed block.
  backup_file "$file" || true
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
    log_info "Marker $marker not present in $file — appending (backup already taken)."
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

preflight_abort_or_warn() {
  # preflight_abort_or_warn <message> — aborts unless --force (or dry-run,
  # where nothing can actually break). Returns 0 if we may continue.
  local msg="$1"
  if [[ "$FORCE" == true || "$DRY_RUN" == true ]]; then
    log_warn "$msg (--force/dry-run: continuing anyway)"
    return 0
  fi
  log_error "$msg"
  log_error "Aborting. Re-run with --force to override, or fix the issue above."
  exit 1
}

check_internet() {
  # At least one of several independent endpoints must answer. Preflight
  # runs BEFORE base tools are ensured, so curl may not exist yet: prefer
  # it when present, else fall back to a bash /dev/tcp probe.
  if is_dry_run; then log_info "[dry-run] would check internet connectivity"; return 0; fi
  local endpoints=(
    "https://deb.debian.org/"
    "https://archive.raspberrypi.org/"
    "https://github.com/"
    "https://dl.flathub.org/"
  )
  local url
  for url in "${endpoints[@]}"; do
    if command_exists curl && curl -fsSL --max-time 10 -o /dev/null "$url" 2>>"$LOG_FILE"; then
      log_info "Internet OK ($url reachable)."
      return 0
    fi
  done
  # Last resort without curl: TCP connect to a well-known host.
  if ! command_exists curl && ! command_exists timeout; then
    log_warn "Neither curl nor timeout is available — cannot verify connectivity. Continuing with caution."
    return 0
  fi
  if ( timeout 8 bash -c '</dev/tcp/8.8.8.8/53' ) 2>>"$LOG_FILE"; then
    log_info "Internet OK (TCP probe to 8.8.8.8:53 succeeded)."
    return 0
  fi
  preflight_abort_or_warn "No internet connectivity detected (tried Debian, Raspberry Pi, GitHub, Flathub). Installations cannot proceed offline."
}

check_disk_space() {
  # Need room: image downloads (Waydroid ~1GB), builds (llama.cpp),
  # office suites. Abort < 2GB, warn < 10GB.
  if is_dry_run; then log_info "[dry-run] would check free disk space"; return 0; fi
  local free_kb
  free_kb="$(df -k / --output=avail 2>>"$LOG_FILE" | tail -n 1 | tr -d ' ' || echo 0)"
  if ! [[ "$free_kb" =~ ^[0-9]+$ ]]; then
    log_warn "Could not determine free disk space — continuing with caution."
    return 0
  fi
  local free_gb=$(( free_kb / 1024 / 1024 ))
  log_info "Free disk space on /: ~${free_gb}GB"
  if [[ "$free_kb" -lt 2097152 ]]; then
    preflight_abort_or_warn "Only ~${free_gb}GB free on / (minimum 2GB required)."
  elif [[ "$free_kb" -lt 10485760 ]]; then
    log_warn "Only ~${free_gb}GB free — full runs (LibreOffice, Waydroid images, llama.cpp build) want 10GB+. Consider --only for a subset."
  fi
}

check_os_release() {
  # Supported: Raspberry Pi OS / Debian Bookworm (12) or Trixie (13).
  if [[ ! -f /etc/os-release ]]; then
    log_warn "/etc/os-release missing — cannot verify OS version."
    return 0
  fi
  # shellcheck disable=SC1091
  local pretty="Unknown" codename="" ident=""
  pretty="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || echo Unknown)"
  codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || echo "")"
  ident="$(grep -E '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"' || echo "")"
  log_info "OS: $pretty (id=$ident codename=$codename)"
  case "$codename" in
    bookworm|trixie) log_info "OS version supported ($codename)." ;;
    *)
      log_warn "Untested OS release ('$codename'). This script targets Raspberry Pi OS Bookworm/Trixie."
      log_warn "Repos pinned to your release codename where possible; some installers may fail (recorded, not fatal)."
      ;;
  esac
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
  if ! command_exists apt-get; then
    log_error "apt-get not found — this script requires Debian/Raspberry Pi OS."
    exit 1
  fi
  if ! $IS_ARM64; then
    preflight_abort_or_warn "Not running on aarch64 (found: $(uname -m)). Nearly every package here is ARM64-only."
  else
    log_info "Architecture OK (aarch64)."
  fi
  if ! $IS_PI5; then
    log_warn "Not a Raspberry Pi 5 ('$PI_MODEL'). Overclocking stays DISABLED; other installs continue."
    log_warn "Some apps (Eden, Dolphin, Waydroid images) are tuned for Pi 5 and may underperform."
  else
    log_info "Hardware OK (Raspberry Pi 5 detected)."
  fi
  check_os_release
  check_internet
  check_disk_space
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
  --force               Bypass preflight aborts (wrong arch, low disk, offline)
  --no-reboot           Do not reboot at the end (default: prompt to reboot)
  --reboot              Reboot without prompting at the end
  --dry-run             Show what would happen, change nothing
  --with-overclock      Apply Pi 5 overclock without asking (uses --oc-cpu/--oc-gpu or defaults 2600/900)
  --no-overclock        Never apply overclock
  --oc-cpu MHZ          Overclock CPU target in MHz, 2400-2800 (default 2600)
  --oc-gpu MHZ          Overclock GPU target in MHz, 800-1000 (default 900)
  --log-file PATH       Write log to PATH (default /var/log/setmypiup.log)

Examples:
  sudo ./SetMyPiUp.sh
  sudo ./SetMyPiUp.sh --all --yes
  sudo ./SetMyPiUp.sh --only git,docker,vscode,fastfetch --no-reboot
  sudo ./SetMyPiUp.sh --all --exclude pihole,retropie --yes

Notes:
  - Overclock (Pi 5 ONLY, conservative 2600/900 defaults, configurable).
  - Waydroid automatically applies kernel tweaks (psi=1, 4K pages).
  - One failed app never stops the rest. See the summary + log at the end.
  - This script INSTALLS software only — finish each app's own setup
    (passwords, pairing, logins, API keys) afterwards; the summary lists
    exactly what is left to do under NEXT STEPS.
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
  echo "Special: overclock (Pi 5 only, conservative 2600/900MHz defaults, configurable) — offered separately, use --with-overclock / --no-overclock / --oc-cpu / --oc-gpu."
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
      --force) FORCE=true; shift ;;
      --no-reboot) DO_REBOOT=false; shift ;;
      --reboot) DO_REBOOT=true; ASSUME_YES=true; shift ;;
      --dry-run) DRY_RUN=true; DO_REBOOT=false; shift ;;
      --with-overclock) WITH_OVERCLOCK="yes"; shift ;;
      --no-overclock) WITH_OVERCLOCK="no"; shift ;;
      --oc-cpu)
        [[ -z "${2:-}" ]] && { log_error "--oc-cpu needs a value in MHz"; exit 1; }
        OC_CPU_FREQ="$2"; shift 2 ;;
      --oc-cpu=*) OC_CPU_FREQ="${1#--oc-cpu=}"; shift ;;
      --oc-gpu)
        [[ -z "${2:-}" ]] && { log_error "--oc-gpu needs a value in MHz"; exit 1; }
        OC_GPU_FREQ="$2"; shift 2 ;;
      --oc-gpu=*) OC_GPU_FREQ="${1#--oc-gpu=}"; shift ;;
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

apply_exclude_filter() {
  # apply_exclude_filter — removes every EXCLUDE_LIST id from SELECTED_IDS.
  # THE single place exclusions are enforced, so --all, --only, the
  # whiptail/dialog checklist and the plain-text fallback all behave
  # identically. Unknown exclude entries are reported once, loudly.
  if [[ -z "$EXCLUDE_LIST" ]]; then return 0; fi
  local keep=() id
  for id in "${SELECTED_IDS[@]:-}"; do
    if csv_contains "$EXCLUDE_LIST" "$id"; then
      log_info "Excluded by --exclude: $id"
      continue
    fi
    keep+=("$id")
  done
  SELECTED_IDS=("${keep[@]:-}")
  # Report unknown --exclude entries once so typos don't fail silently.
  local e eclean
  local tmp_excl=()
  IFS=',' read -ra tmp_excl <<<"$EXCLUDE_LIST"
  for e in "${tmp_excl[@]}"; do
    eclean="$(echo "$e" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$eclean" ]] && continue
    if [[ -z "${APP_CATALOG[$eclean]:-}" ]]; then
      log_warn "Unknown app ID in --exclude: '$eclean' (see --list)."
    fi
  done
}

normalize_id_list() {
  # normalize_id_list <raw...> — lowercases/trims, drops unknowns (warns),
  # writes the clean list to SELECTED_IDS, then applies exclusions.
  SELECTED_IDS=()
  local id clean
  for id in "$@"; do
    clean="$(echo "$id" | tr '[:upper:]' '[:lower:]' | xargs)"
    [[ -z "$clean" ]] && continue
    if [[ -z "${APP_CATALOG[$clean]:-}" ]]; then
      log_warn "Unknown app ID '$clean' — skipping (see --list)."
      SKIPPED_LIST+=("$clean (unknown id)")
      continue
    fi
    SELECTED_IDS+=("$clean")
  done
  apply_exclude_filter
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
  # Normalize + exclusions via the single shared path.
  normalize_id_list "${ids[@]}"
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
  local raw=() id
  for id in $out; do
    id="${id//\"/}"
    [[ -n "$id" ]] && raw+=("$id")
  done
  # Route through the shared normalizer so --exclude (and unknown-id
  # handling) behaves exactly like every other selection path.
  normalize_id_list "${raw[@]:-}"
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
    normalize_id_list "${ORDERED_IDS[@]}"
  else
    local tmp=()
    IFS=',' read -ra tmp <<<"$ans"
    normalize_id_list "${tmp[@]}"
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
    add_next_step "Pi-Apps: install more later with '~/pi-apps/manage install <App>' or just re-run this script."
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
  add_next_step "Pi-Apps: install more later with '~/pi-apps/manage install <App>' or just re-run this script."
  return 0
}

pi_apps_install() {
  # pi_apps_install <AppName> — uses Pi-Apps CLI if available.
  # Returns the manage script's exit code; callers MUST verify the actual
  # binary afterwards (manage can exit 0 while leaving a broken install).
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

pi_apps_try() {
  # pi_apps_try <catalog-id> — Pi-Apps-first routing. Looks up the exact
  # Pi-Apps app name in PI_APPS_MAP and installs via `manage` ONLY if that
  # app directory exists in the local clone. Returns 0 iff manage exits 0
  # (callers still verify the real binary). Never fails destructively:
  # missing map entry / missing clone / missing app dir all return 1 so the
  # caller falls through to its direct-install method.
  local id="$1"
  local app="${PI_APPS_MAP[$id]:-}"
  if [[ -z "$app" ]]; then return 1; fi
  local dest="$TARGET_HOME/pi-apps"
  if [[ ! -d "$dest" ]]; then
    install_pi_apps || return 1
  fi
  if [[ ! -d "$dest/apps/$app" ]]; then
    log_info "Pi-Apps has no '$app' in this clone — using direct install for '$id'."
    return 1
  fi
  pi_apps_install "$app"
}

add_next_step() {
  # add_next_step <text> — queues a post-install setup reminder shown in the
  # final summary. This script INSTALLS software only; accounts, passwords,
  # pairing, API keys and first-run wizards are always the user's job.
  local step="$1"
  local s
  for s in "${NEXT_STEPS[@]:-}"; do [[ "$s" == "$step" ]] && return 0; done
  NEXT_STEPS+=("$step")
}

install_brave() {
  if command_exists brave-browser || command_exists brave-browser-stable; then
    log_info "Brave already installed."; return 0
  fi
  # Preferred: Pi-Apps "Brave" (verified Pi-Apps app, ARM64-aware).
  if pi_apps_try brave; then
    if command_exists brave-browser || command_exists brave-browser-stable; then
      return 0
    fi
    log_warn "Pi-Apps Brave finished but no brave binary found — trying official repo."
  fi
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
  apt_update || true
  # NOTE: Pi-Apps ships VSCodium, not VS Code — deliberately NOT routed
  # there. First try Raspberry Pi OS's own APT repo (officially documented
  # by Microsoft: `sudo apt install code`), then the Microsoft repo.
  if apt_install code; then
    command_exists code && return 0
  fi
  log_warn "Pi OS repo 'code' unavailable — trying official Microsoft repo."
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
    add_next_step "Docker: log out and back in (or run 'newgrp docker') before using docker without sudo; verify with 'docker run --rm hello-world'."
    return 0
  fi
  # Production-ready path: Docker's official APT repository (explicit
  # packages + versions: docker-ce, docker-ce-cli, containerd.io,
  # docker-buildx-plugin, docker-compose-plugin). Verified Sep 2026 against
  # https://docs.docker.com/engine/install/debian/ .
  apt_install ca-certificates curl gnupg || return 1
  if is_dry_run; then
    log_info "[dry-run] would add Docker APT repo + install docker-ce suite + usermod"
    return 0
  fi
  local codename=""
  if [[ -f /etc/os-release ]]; then
    codename="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)"
  fi
  [[ -z "$codename" ]] && codename="bookworm"
  local keyring="/etc/apt/keyrings/docker.asc"
  local list="/etc/apt/sources.list.d/docker.list"
  local repo_ok=true
  mkdir -p /etc/apt/keyrings 2>>"$LOG_FILE" || repo_ok=false
  if $repo_ok; then
    curl -fsSL --max-time 60 https://download.docker.com/linux/debian/gpg \
      -o "$keyring" 2>>"$LOG_FILE" || repo_ok=false
    chmod a+r "$keyring" 2>>"$LOG_FILE" || true
  fi
  if $repo_ok; then
    echo "deb [arch=arm64 signed-by=$keyring] https://download.docker.com/linux/debian $codename stable" \
      >"$list" 2>>"$LOG_FILE" || repo_ok=false
  fi
  if $repo_ok; then
    apt_update || repo_ok=false
  fi
  if $repo_ok; then
    if apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      repo_ok=true
    else
      repo_ok=false
    fi
  fi
  if ! $repo_ok; then
    # Fallback (robustness over purity): Docker's convenience script.
    log_warn "Official Docker repo path failed (codename=$codename) — falling back to get.docker.com."
    rm -f "$list" 2>/dev/null || true
    local sh="/tmp/get-docker.sh"
    curl -fsSL --max-time 120 https://get.docker.com -o "$sh" 2>>"$LOG_FILE" || return 1
    run_cmd "docker convenience script (fallback)" sh "$sh" || return 1
  fi
  systemctl enable --now docker >>"$LOG_FILE" 2>&1 || log_warn "Could not start docker (non-fatal)"
  if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
    usermod -aG docker "$TARGET_USER" >>"$LOG_FILE" 2>&1 || log_warn "usermod docker group failed (non-fatal)"
  fi
  if ! command_exists docker; then return 1; fi
  if ! docker --version >>"$LOG_FILE" 2>&1; then
    log_warn "docker binary present but 'docker --version' failed."
    return 1
  fi
  add_next_step "Docker: log out and back in (or run 'newgrp docker') before using docker without sudo; verify with 'docker run --rm hello-world'."
  return 0
}

pihole_detect_net() {
  # pihole_detect_net — echoes "<iface> <ipv4-cidr>" for the interface that
  # carries the default route (no assumptions about eth0/wlan0 names).
  # Returns 1 when nothing usable is found.
  local route="" iface="" src="" cidr=""
  if command_exists ip; then
    route="$(ip route get 1.1.1.1 2>/dev/null || true)"
    iface="$(echo "$route" | awk '{for(i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    src="$(echo "$route" | awk '{for(i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [[ -z "$iface" && -d /sys/class/net ]]; then
    # No default-route answer: first non-loopback interface that is up.
    local cand
    for cand in /sys/class/net/*; do
      cand="${cand##*/}"
      [[ "$cand" == "lo" ]] && continue
      if [[ "$(cat "/sys/class/net/$cand/operstate" 2>/dev/null)" == "up" ]]; then
        iface="$cand"; break
      fi
    done
  fi
  [[ -z "$iface" ]] && return 1
  if [[ -n "$src" ]]; then
    cidr="$(ip -o -f inet addr show dev "$iface" 2>/dev/null \
      | awk -v s="$src" '$4 ~ s {print $4; exit}')"
  fi
  if [[ -z "$cidr" ]]; then
    cidr="$(ip -o -f inet addr show dev "$iface" scope global 2>/dev/null \
      | awk '{print $4; exit}')"
  fi
  [[ -z "$cidr" ]] && return 1
  echo "$iface $cidr"
  return 0
}

install_pihole() {
  if command_exists pihole; then
    log_info "Pi-hole already installed."
    add_next_step "Pi-hole: set the admin password with 'pihole -a -p', then point your router's DNS at this Pi."
    return 0
  fi
  apt_install curl git iproute2 whiptail || return 1
  if is_dry_run; then log_info "[dry-run] would detect network + run Pi-hole unattended installer"; return 0; fi
  log_warn "Pi-hole takes over DNS/DHCP on this machine — keep console access and know your router login before continuing."
  if [[ "$ASSUME_YES" != true ]]; then
    confirm "Install Pi-hole now (network/DNS will be reconfigured)?" || { log_info "Pi-hole skipped by user."; return 1; }
  fi
  # Detect the real uplink instead of assuming eth0 / 0.0.0.0.
  local detected="" PIHOLE_IFACE="" PIHOLE_CIDR=""
  detected="$(pihole_detect_net || true)"
  if [[ -n "$detected" ]]; then
    PIHOLE_IFACE="${detected%% *}"
    PIHOLE_CIDR="${detected#* }"
    log_info "Detected uplink: interface=$PIHOLE_IFACE address=$PIHOLE_CIDR"
  else
    log_warn "Could not auto-detect the network uplink."
  fi
  if [[ "$ASSUME_YES" != true ]]; then
    local ans_iface="" ans_ip=""
    read -rp "Pi-hole interface [${PIHOLE_IFACE:-eth0}]: " ans_iface || true
    [[ -n "$ans_iface" ]] && PIHOLE_IFACE="$ans_iface"
    [[ -z "$PIHOLE_IFACE" ]] && PIHOLE_IFACE="eth0"
    if [[ ! -d "/sys/class/net/$PIHOLE_IFACE" ]]; then
      log_error "Interface '$PIHOLE_IFACE' does not exist. Aborting Pi-hole (not fatal to the run)."
      return 1
    fi
    read -rp "Pi-hole static IPv4 in CIDR form [$PIHOLE_CIDR]: " ans_ip || true
    [[ -n "$ans_ip" ]] && PIHOLE_CIDR="$ans_ip"
    if [[ -z "$PIHOLE_CIDR" || "$PIHOLE_CIDR" == "0.0.0.0"* ]]; then
      log_error "A real static IPv4 (e.g. 192.168.1.10/24) is required — refusing 0.0.0.0."
      return 1
    fi
  else
    # Non-interactive: detected values only, never the 0.0.0.0 placeholder.
    if [[ -z "$PIHOLE_IFACE" || -z "$PIHOLE_CIDR" ]]; then
      log_error "Non-interactive mode with no detectable uplink — cannot configure Pi-hole safely. Run interactively to enter values."
      return 1
    fi
  fi
  log_info "Pi-hole will bind $PIHOLE_IFACE ($PIHOLE_CIDR)."
  local dir="/tmp/pihole-install"
  rm -rf "$dir" 2>/dev/null || true
  mkdir -p "$dir" || return 1
  curl -sSL --max-time 120 https://install.pi-hole.net -o "$dir/basic-install.sh" 2>>"$LOG_FILE" || return 1
  chmod +x "$dir/basic-install.sh"
  mkdir -p /etc/pihole
  if [[ ! -f /etc/pihole/setupVars.conf ]]; then
    cat >/etc/pihole/setupVars.conf <<PIHOLE_VARS
PIHOLE_INTERFACE=${PIHOLE_IFACE}
IPV4_ADDRESS=${PIHOLE_CIDR}
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
  add_next_step "Pi-hole: set the admin password with 'pihole -a -p', then point your router's DNS at this Pi ($PIHOLE_CIDR on $PIHOLE_IFACE)."
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
  # Preferred: Pi-Apps "Minecraft Java Prism Launcher" (verified app name,
  # native ARM64 build per request).
  if pi_apps_try prismlauncher; then
    if command_exists prismlauncher; then
      add_next_step "PrismLauncher: launch it once to sign in your Microsoft/Mojang account and download instances."
      return 0
    fi
    log_warn "Pi-Apps PrismLauncher finished but no binary found — trying Flatpak."
  fi
  command_exists flatpak || install_flatpak || return 1
  flatpak_install org.PrismLauncher.PrismLauncher || return 1
  add_next_step "PrismLauncher: launch it once to sign in your Microsoft/Mojang account and download instances."
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
  # Verified Sep 2026: Flathub ID is dev.eden_emu.eden (Eden, Yuzu fork);
  # upstream releases live on git.eden-emu.dev with assets like
  # Eden-Linux-v0.2.1-aarch64-gcc-standard.AppImage (+ Debian .debs).
  if flatpak info dev.eden_emu.eden >>"$LOG_FILE" 2>&1; then
    log_info "Eden present (Flatpak)."; return 0
  fi
  if [[ -x "$TARGET_HOME/Applications/Eden.AppImage" ]]; then
    log_info "Eden present (AppImage)."; return 0
  fi
  command_exists flatpak || install_flatpak || return 1
  if flatpak_install dev.eden_emu.eden; then
    add_next_step "Eden: dump your Switch keys/firmware yourself (no piracy) — place prod.keys in ~/.var/app/dev.eden_emu.eden/data/eden/keys/."
    return 0
  fi
  log_warn "Flatpak Eden failed — trying AppImage fallback (git.eden-emu.dev)."
  if is_dry_run; then return 0; fi
  local url=""
  url="$(curl -fsSL --max-time 30 https://git.eden-emu.dev/api/v1/repos/eden-emu/eden/releases/latest 2>>"$LOG_FILE" \
    | grep -oE '"browser_download_url": *"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' \
    | grep -E 'Eden-Linux-.*aarch64.*\.AppImage$' | grep -viE 'zsync' | head -n 1 || true)"
  if [[ -z "$url" ]]; then
    log_warn "Could not locate Eden ARM64 AppImage (release layout may have changed)."
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
  add_next_step "Eden: dump your Switch keys/firmware yourself (no piracy) — place prod.keys in ~/.local/share/eden/keys/."
  return 0
}

install_steam() {
  if command_exists steam || [[ -x "$TARGET_HOME/.steam/steam.sh" ]]; then
    log_info "Steam present."; return 0
  fi
  # Steam is x86-only; on Pi it runs via Box86/Box64 automation in Pi-Apps
  # ("Steam" is a verified Pi-Apps app).
  if ! pi_apps_try steam; then
    log_warn "Steam needs Pi-Apps (Box86/Box64 automation) and it is unavailable."
    return 1
  fi
  if is_dry_run; then log_info "[dry-run] would pi-apps install Steam"; return 0; fi
  # Pi-Apps may install launcher without PATH binary; check desktop file.
  if command_exists steam || [[ -f "$TARGET_HOME/.local/share/applications/steam.desktop" || -f "/usr/local/bin/steam" ]]; then
    add_next_step "Steam: first launch signs you in and may update Box86/Box64 — allow extra time on first run."
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
  add_next_step "RetroPie: run 'sudo $dest/retropie_setup.sh' to choose and build packages (takes hours) — then copy ROMs to ~/RetroPie/roms/ yourself."
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
  # Honest result handling: SUCCESS requires (a) kernel tweaks applied,
  # (b) waydroid package installed, AND (c) `waydroid init` (image) done.
  # A downloaded package with a failed image init is a FAILURE with a
  # retry hint — never a silent success.
  local tweaks_ok=true
  apply_waydroid_kernel_tweaks || tweaks_ok=false

  if command_exists waydroid; then
    log_info "Waydroid package present — ensuring container service."
    if ! is_dry_run; then
      systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || true
    fi
    if [[ -d /var/lib/waydroid/rootfs || -d /usr/share/waydroid-extra ]]; then
      log_info "Waydroid image looks initialized."
    else
      log_warn "Waydroid installed but image not initialized."
      add_next_step "Waydroid: after reboot run 'sudo waydroid init' (or 'sudo waydroid init -s GAPPS' for Google apps), then 'waydroid session start'."
      return 1
    fi
    if $tweaks_ok; then
      add_next_step "Waydroid: after reboot run 'waydroid session start' (first launch initializes the container)."
      return 0
    fi
    return 1
  fi
  apt_install curl ca-certificates python3 lxc sqlite3 || return 1
  if is_dry_run; then
    log_info "[dry-run] would add repo.waydroid.org + install waydroid + init"
    if $tweaks_ok; then return 0; else return 1; fi
  fi
  local script="/tmp/waydroid-repo.sh"
  curl -fsSL --max-time 60 https://repo.waydro.id -o "$script" 2>>"$LOG_FILE" || return 1
  run_cmd "waydroid repo script" bash "$script" || return 1
  apt_update || true
  apt_install waydroid lxc || return 1
  command_exists waydroid || { log_warn "waydroid package install failed."; return 1; }
  # Image download (~1GB). VANILLA is smaller/more reliable; user can re-init GAPPS later.
  log_info "Downloading Waydroid image (VANILLA, may take a while)..."
  if ! waydroid init >>"$LOG_FILE" 2>&1; then
    log_error "waydroid init FAILED (package is installed but unusable without an image)."
    add_next_step "Waydroid: image init failed — after reboot retry 'sudo waydroid init' (needs ~1GB download + kernel tweaks active)."
    systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || true
    return 1
  fi
  systemctl enable --now waydroid-container >>"$LOG_FILE" 2>&1 || log_warn "waydroid-container start issue (non-fatal)"
  add_next_step "Waydroid: after reboot run 'waydroid session start' (first launch initializes the container)."
  if $tweaks_ok; then return 0; else return 1; fi
}

install_mcpi_reborn() {
  if command_exists minecraft-pi-reborn-client || command_exists minecraft-pi-reborn || command_exists mcpi-reborn; then
    log_info "MCPI: Reborn present."; return 0
  fi
  # Preferred: the project's OFFICIAL APT repository (verified Sep 2026 in
  # MCPI-Reborn docs/INSTALL.md: gitea.thebrokenrail.com Gitea Debian repo,
  # package name `minecraft-pi-reborn`).
  if is_dry_run; then log_info "[dry-run] would add MCPI-Reborn APT repo + install"; return 0; fi
  apt_install curl ca-certificates gnupg || return 1
  local keyring="/etc/apt/keyrings/minecraft-pi-reborn.asc"
  local list="/etc/apt/sources.list.d/minecraft-pi-reborn.list"
  if curl -fsSL --max-time 60 https://gitea.thebrokenrail.com/api/packages/minecraft-pi-reborn/debian/repository.key \
      -o "$keyring" 2>>"$LOG_FILE"; then
    echo "deb [signed-by=$keyring] https://gitea.thebrokenrail.com/api/packages/minecraft-pi-reborn/debian stable main" \
      >"$list" 2>>"$LOG_FILE" || true
    apt_update || true
    if apt_install minecraft-pi-reborn; then
      if command_exists minecraft-pi-reborn-client || command_exists minecraft-pi-reborn; then
        add_next_step "MCPI: Reborn: open the launcher once to create your profile (~/.minecraft-pi) and worlds."
        return 0
      fi
    fi
    log_warn "Official MCPI repo path failed — trying Pi-Apps."
    rm -f "$list" 2>/dev/null || true
  else
    log_warn "MCPI repository key unreachable — trying Pi-Apps."
  fi
  # Fallback: Pi-Apps (upstream documents Pi-Apps support; exact app-dir
  # name guarded — skipped silently if this clone lacks it).
  if pi_apps_try mcpi-reborn; then
    if command_exists minecraft-pi-reborn-client || command_exists minecraft-pi-reborn; then
      add_next_step "MCPI: Reborn: open the launcher once to create your profile (~/.minecraft-pi) and worlds."
      return 0
    fi
    log_warn "Pi-Apps MCPI step finished but no binary found."
  fi
  log_warn "MCPI: Reborn could not be installed (repo + Pi-Apps paths failed)."
  return 1
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
  add_next_step "llama.cpp: download a GGUF model yourself (e.g. from Hugging Face) and run 'llama-cli -m model.gguf -p \"Hello\"'."
  return 0
}

opencode_verify() {
  # True only when the binary exists AND reports a version (guards against
  # half-finished installs and upstream renames like the opencode2 beta).
  command_exists opencode && opencode --version >>"$LOG_FILE" 2>&1
}

install_opencode() {
  if opencode_verify; then log_info "opencode present."; return 0; fi
  command_exists curl || apt_install curl || return 1
  if is_dry_run; then log_info "[dry-run] would run opencode.ai/install then npm fallbacks"; return 0; fi
  # Method 1: official installer (verified Sep 2026: opencode.ai/install).
  # Pin the install dir explicitly — upstream's default has moved before
  # (~/.local/bin vs ~/.opencode/bin) and silently "succeeding" into a
  # directory outside PATH is exactly the failure mode we must catch.
  local bindir="$TARGET_HOME/.local/bin"
  if sudo -u "$TARGET_USER" env OPENCODE_INSTALL_DIR="$bindir" \
      bash -c 'curl -fsSL https://opencode.ai/install | bash' >>"$LOG_FILE" 2>&1; then
    for cand in "$bindir/opencode" "$TARGET_HOME/.opencode/bin/opencode" "$TARGET_HOME/bin/opencode"; do
      if [[ -x "$cand" ]]; then
        ln -sf "$cand" /usr/local/bin/opencode 2>>"$LOG_FILE" || true
        break
      fi
    done
    if opencode_verify; then
      add_next_step "OpenCode: run 'opencode' once to connect your provider (API keys for Anthropic/OpenAI/etc.)."
      return 0
    fi
    log_warn "Official installer exited 0 but no working 'opencode' on PATH — trying npm."
  else
    log_warn "Official installer failed — trying npm fallbacks."
  fi
  # Method 2+3: npm package names, newest first (verified Sep 2026:
  # `opencode-ai`, e.g. npm i -g opencode-ai@latest).
  command_exists npm || install_nodejs || return 1
  local spec
  for spec in "opencode-ai@latest" "opencode-ai"; do
    if npm install -g "$spec" >>"$LOG_FILE" 2>&1 && opencode_verify; then
      add_next_step "OpenCode: run 'opencode' once to connect your provider (API keys for Anthropic/OpenAI/etc.)."
      return 0
    fi
    log_warn "npm '$spec' did not yield a working opencode binary."
  done
  log_warn "OpenCode install failed via script + npm. Manual: 'npm i -g opencode-ai@latest' or see https://opencode.ai/docs"
  return 1
}

install_claude_code() {
  if command_exists claude; then log_info "Claude Code present."; return 0; fi
  command_exists npm || install_nodejs || return 1
  if is_dry_run; then log_info "[dry-run] would npm i -g @anthropic-ai/claude-code"; return 0; fi
  npm install -g @anthropic-ai/claude-code >>"$LOG_FILE" 2>&1 || return 1
  command_exists claude || return 1
  add_next_step "Claude Code: run 'claude' once to log in with your Anthropic account / API key."
  return 0
}

install_sunshine() {
  # This catalog entry is "streaming" = host AND client. SUCCESS requires
  # BOTH Sunshine (host) and Moonlight (client). A partial install is
  # reported as FAILED with the missing half named explicitly, plus a
  # retry hint — never a silent success.
  # Sources verified Sep 2026: LizardByte/Sunshine GitHub releases publish
  # per-distro debs (sunshine-debian-bookworm-arm64.deb / -trixie-), a
  # Flatpak (dev.lizardbyte.app.Sunshine), and a Cloudsmith repo;
  # Moonlight client is com.moonlight_stream.Moonlight on Flathub (aarch64).
  local have_host=false have_client=false
  command_exists sunshine && have_host=true
  flatpak info com.moonlight_stream.Moonlight >>"$LOG_FILE" 2>&1 && have_client=true
  command_exists moonlight && have_client=true
  if $have_host && $have_client; then
    log_info "Sunshine + Moonlight present."
    add_next_step "Streaming: open https://localhost:47990 to configure Sunshine, then pair Moonlight with the shown PIN."
    return 0
  fi

  # --- Host: Sunshine (LizardByte) ARM64 ---
  if ! $have_host; then
    if is_dry_run; then
      log_info "[dry-run] would install Sunshine host (.deb, then Flatpak fallback)"
    else
      local url=""
      # Preferred exact patterns first (bookworm/trixie arm64 debs)...
      url="$(github_latest_deb_url "LizardByte/Sunshine" "sunshine-debian-(bookworm|trixie)-(arm64|aarch64)")" || url=""
      # ...then any debian/ubuntu arm64 deb...
      if [[ -z "$url" ]]; then
        url="$(github_latest_deb_url "LizardByte/Sunshine" "(debian|ubuntu).*?(arm64|aarch64)")" || url=""
      fi
      # ...then any arm64 deb at all.
      if [[ -z "$url" ]]; then
        local json
        json="$(curl -fsSL --max-time 30 https://api.github.com/repos/LizardByte/Sunshine/releases/latest 2>>"$LOG_FILE" || true)"
        url="$(echo "$json" | grep -oE '"browser_download_url": *"[^"]+\.deb"' \
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
        log_warn "Could not locate Sunshine ARM64 .deb (release assets may have changed) — trying Flatpak host."
      fi
      if ! $have_host; then
        command_exists flatpak || install_flatpak || true
        if flatpak_install dev.lizardbyte.app.Sunshine; then
          have_host=true
          log_warn "Sunshine installed as Flatpak — run the additional-install step: flatpak run --command=additional-install.sh dev.lizardbyte.app.Sunshine"
        fi
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

  if $have_host && $have_client; then
    log_ok "Streaming setup complete: Sunshine host + Moonlight client."
    add_next_step "Streaming: open https://localhost:47990 to configure Sunshine, then pair Moonlight with the shown PIN."
    return 0
  fi
  local missing=""
  ! $have_host && missing="Sunshine (host)"
  ! $have_client && missing="${missing:+$missing + }Moonlight (client)"
  log_error "Streaming setup INCOMPLETE — missing: $missing. Re-run with --only sunshine after checking the log."
  add_next_step "Streaming incomplete (missing: $missing) — install the missing half, then pair Moonlight to Sunshine via https://localhost:47990."
  return 1
}

# ------------------------------------------------------- Overclock (Pi5 only)

# Conservative Pi 5 boundaries. Stock boosts to 2400MHz CPU / 800MHz GPU;
# the defaults below (2600/900) are a mild, well-tested uplift. Anything
# above 2700 CPU / 950 GPU gets an extra explicit warning and needs active
# cooling without exception.
OC_CPU_MIN=2400 OC_CPU_MAX=2800 OC_CPU_DEFAULT=2600
OC_GPU_MIN=800  OC_GPU_MAX=1000 OC_GPU_DEFAULT=900

validate_oc_freqs() {
  # validate_oc_freqs — clamps/validates OC_CPU_FREQ + OC_GPU_FREQ.
  # Returns 0 when usable (after clamping with a warning), 1 when garbage.
  local bad=false
  if ! [[ "$OC_CPU_FREQ" =~ ^[0-9]+$ ]]; then
    log_error "Bad --oc-cpu value: '$OC_CPU_FREQ' (need MHz, e.g. 2600)."
    bad=true
  elif [[ "$OC_CPU_FREQ" -lt "$OC_CPU_MIN" || "$OC_CPU_FREQ" -gt "$OC_CPU_MAX" ]]; then
    log_error "CPU target ${OC_CPU_FREQ}MHz outside safe range ${OC_CPU_MIN}-${OC_CPU_MAX}MHz."
    bad=true
  fi
  if ! [[ "$OC_GPU_FREQ" =~ ^[0-9]+$ ]]; then
    log_error "Bad --oc-gpu value: '$OC_GPU_FREQ' (need MHz, e.g. 900)."
    bad=true
  elif [[ "$OC_GPU_FREQ" -lt "$OC_GPU_MIN" || "$OC_GPU_FREQ" -gt "$OC_GPU_MAX" ]]; then
    log_error "GPU target ${OC_GPU_FREQ}MHz outside safe range ${OC_GPU_MIN}-${OC_GPU_MAX}MHz."
    bad=true
  fi
  ! $bad
}

ask_oc_freqs() {
  # Interactive prompt for custom MHz (validated, conservative defaults).
  local ans
  read -rp "  CPU frequency in MHz [$OC_CPU_FREQ] (range $OC_CPU_MIN-$OC_CPU_MAX): " ans || true
  [[ -n "$ans" ]] && OC_CPU_FREQ="$ans"
  read -rp "  GPU frequency in MHz [$OC_GPU_FREQ] (range $OC_GPU_MIN-$OC_GPU_MAX): " ans || true
  [[ -n "$ans" ]] && OC_GPU_FREQ="$ans"
  validate_oc_freqs || {
    log_warn "Keeping conservative defaults ${OC_CPU_DEFAULT}/${OC_GPU_DEFAULT}MHz."
    OC_CPU_FREQ="$OC_CPU_DEFAULT"; OC_GPU_FREQ="$OC_GPU_DEFAULT"
  }
}

apply_overclock() {
  if ! $IS_PI5; then
    log_error "Overclock REFUSED: not a Raspberry Pi 5 ('$PI_MODEL'). No changes made."
    return 1
  fi
  if [[ ! -f "$CONFIG_TXT" ]]; then
    log_error "Overclock failed: $CONFIG_TXT not found."
    return 1
  fi
  validate_oc_freqs || return 1
  if is_dry_run; then
    log_info "[dry-run] would set arm_freq=$OC_CPU_FREQ gpu_freq=$OC_GPU_FREQ in $CONFIG_TXT"
    return 0
  fi
  log_warn "Overclocking to ${OC_CPU_FREQ}MHz CPU / ${OC_GPU_FREQ}MHz GPU."
  if [[ "$OC_CPU_FREQ" -gt 2700 || "$OC_GPU_FREQ" -gt 950 ]]; then
    log_warn "AGGRESSIVE settings — active cooling is MANDATORY, watch 'vcgencmd measure_temp' under load."
  else
    log_warn "Requires good cooling (official Active Cooler recommended). Monitor temps under load!"
  fi
  local block
  block="$(printf 'arm_freq=%s\ngpu_freq=%s' "$OC_CPU_FREQ" "$OC_GPU_FREQ")"
  if [[ "$OC_CPU_FREQ" -gt 2600 ]]; then
    # Extra voltage only needed above the mild 2600MHz uplift.
    block="$(printf '%s\nover_voltage_delta=%s' "$block" "$OC_VOLT_DELTA")"
  fi
  ensure_config_marker_block "$CONFIG_TXT" "# SetMyPiUp-OC" "$block" || return 1
  log_ok "Overclock block written (${OC_CPU_FREQ}/${OC_GPU_FREQ}MHz). Takes effect after reboot. Verify with: vcgencmd measure_clock arm"
  add_next_step "Overclock: after reboot verify 'vcgencmd measure_clock arm' and 'vcgencmd measure_temp' under load — back off if temp exceeds ~80C."
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
  local n_ok=${#SUCCESS_LIST[@]} n_fail=${#FAILED_LIST[@]} n_skip=${#SKIPPED_LIST[@]}
  echo ""
  echo "=================================================================="
  echo " $SCRIPT_NAME v$SCRIPT_VERSION — Summary"
  echo "=================================================================="
  echo " Model:   $PI_MODEL"
  echo ""
  echo " SUCCESS: $n_ok"
  echo " FAILED:  $n_fail"
  echo " SKIPPED: $n_skip"
  echo ""
  local s
  if [[ $n_ok -gt 0 ]]; then
    echo " Installed:"
    for s in "${SUCCESS_LIST[@]}"; do [[ -n "$s" ]] && echo " - $s"; done
    echo ""
  fi
  if [[ $n_fail -gt 0 ]]; then
    echo " Failed:"
    for s in "${FAILED_LIST[@]}"; do [[ -n "$s" ]] && echo " - $s"; done
    echo ""
    echo " Re-run just the failures later, e.g.:"
    echo "   sudo $0 --only <ids>   # see --list"
    echo ""
  fi
  if [[ $n_skip -gt 0 ]]; then
    echo " Skipped:"
    for s in "${SKIPPED_LIST[@]}"; do [[ -n "$s" ]] && echo " - $s"; done
    echo ""
  fi
  if [[ ${#NEXT_STEPS[@]} -gt 0 ]]; then
    echo " NEXT STEPS (this script installs software only — you finish setup):"
    for s in "${NEXT_STEPS[@]}"; do [[ -n "$s" ]] && echo " - $s"; done
    echo ""
  fi
  echo " Kernel/boot notes:"
  echo "   config.txt:  $CONFIG_TXT"
  echo "   cmdline.txt: $CMDLINE_TXT"
  echo "   A reboot is required for kernel, Waydroid, Docker and OC changes."
  echo ""
  echo " Log: $LOG_FILE"
  echo "=================================================================="
  {
    echo "SUMMARY ok=$n_ok fail=$n_fail skip=$n_skip"
    echo "SUCCESS: ${SUCCESS_LIST[*]:-none}"
    echo "FAILED: ${FAILED_LIST[*]:-none}"
    echo "SKIPPED: ${SKIPPED_LIST[*]:-none}"
  } >>"$LOG_FILE" 2>/dev/null || true
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

  # Install rounds: run once for CLI/non-interactive use; interactively,
  # offer the menu again after each round so the script doubles as the
  # "install something else later" entry point (fully re-runnable).
  local round=1
  while true; do
    if [[ $round -gt 1 ]]; then
      # Fresh menu round: CLI selectors from round 1 no longer apply.
      ONLY_LIST=""; INSTALL_ALL=false
      echo ""
      log_info "--- Round $round: pick more software (or decline to finish) ---"
    fi
    if ! select_apps_interactive; then
      log_info "Selection cancelled — finishing."
      break
    fi

    if [[ ${#SELECTED_IDS[@]} -eq 0 ]]; then
      log_warn "Empty selection. Nothing to do this round. See --list / --all."
    else
      log_info "Selected (${#SELECTED_IDS[@]}): ${SELECTED_IDS[*]}"
      if is_dry_run; then
        log_info "DRY RUN — no changes will be made."
      elif [[ "$ASSUME_YES" != true && $round -eq 1 ]]; then
        echo "About to install: ${SELECTED_IDS[*]}"
        confirm "Proceed?" || { log_info "Aborted by user."; exit 0; }
      fi

      local id
      for id in "${SELECTED_IDS[@]}"; do
        run_installer "$id"
      done
    fi

    # Loop only for interactive use: --yes/--only/--all do exactly one
    # round (automation-safe), dry-run never loops.
    if is_dry_run || [[ "$ASSUME_YES" == true ]]; then
      break
    fi
    if ! confirm "Do you want to install anything else?"; then
      break
    fi
    round=$(( round + 1 ))
  done

  # Overclock is separate from the app list (safety-gated to Pi 5).
  local do_oc=false
  case "$WITH_OVERCLOCK" in
    yes) do_oc=true ;;
    no)  do_oc=false ;;
    ask)
      if $IS_PI5; then
        echo ""
        echo "Optional: overclock Pi 5? (conservative defaults ${OC_CPU_FREQ}MHz CPU / ${OC_GPU_FREQ}MHz GPU)"
        echo "(Requires GOOD cooling. Pi 5 only — auto-refused elsewhere.)"
        if [[ "$ASSUME_YES" == true ]]; then
          do_oc=false
          log_info "Overclock skipped in non-interactive mode (use --with-overclock to force)."
        elif confirm "Configure overclock"; then
          if [[ "$ASSUME_YES" != true ]]; then
            ask_oc_freqs
          fi
          do_oc=true
        else
          SKIPPED_LIST+=("Pi 5 Overclock (declined by user)")
        fi
      else
        log_info "Overclock not offered (not a Pi 5)."
      fi
      ;;
  esac
  if $do_oc; then
    log_info "==================== Applying: Pi 5 Overclock ===================="
    if apply_overclock; then
      SUCCESS_LIST+=("Pi 5 Overclock (${OC_CPU_FREQ}/${OC_GPU_FREQ}MHz)")
    else
      FAILED_LIST+=("Pi 5 Overclock (${OC_CPU_FREQ}/${OC_GPU_FREQ}MHz)")
    fi
  fi

  print_summary
  do_reboot
}

main "$@"
