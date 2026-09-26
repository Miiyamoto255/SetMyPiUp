# SetMyPiUp 🍓

Professional, production-ready Raspberry Pi 5 setup script (v1.3.0).
Pick the apps you want from a menu — one failed install never breaks the rest —
then the Pi reboots so kernel / Docker / Waydroid / overclock changes take effect.
Re-run anytime: after each round you're asked "Do you want to install anything else?".

- **Script:** `SetMyPiUp.sh` (Bash, no dependencies beyond a stock Pi OS)
- **Target:** Raspberry Pi 5, Raspberry Pi OS 64-bit (Debian Bookworm or newer)
- **License:** MIT

## Quick start

```bash
git clone https://github.com/Miiyamoto255/SetMyPiUp.git
cd ~/SetMyPiUp
chmod +x SetMyPiUp.sh
sudo ./SetMyPiUp.sh                  # interactive menu (recommended)
```

Non-interactive examples:

```bash
sudo ./SetMyPiUp.sh --all --yes                    # everything, no prompts
sudo ./SetMyPiUp.sh --only git,docker,vscode,fastfetch --no-reboot
sudo ./SetMyPiUp.sh --all --exclude pihole,retropie --yes
./SetMyPiUp.sh --list                              # show installable IDs
./SetMyPiUp.sh --dry-run --all                     # show what would happen. Good for testing
sudo ./SetMyPiUp.sh --with-overclock --oc-cpu 2700 --oc-gpu 950
sudo ./SetMyPiUp.sh --force                        # force running on x86_64 or on non-Pi devices 
sudo ./SetMyPiUp.sh --only pihole --allow-network-changes   # Pi-hole needs this opt-in when non-interactive
sudo ./SetMyPiUp.sh --only dotnet --dotnet-version 9.0 --no-reboot
```

> The script must run as root (`sudo`). Per-user tools are installed for
> `${SUDO_USER}` automatically. Preflight checks (arch, OS, internet, disk,
> Pi 5 identity) run first — bypass aborts only with `--force`.

## What gets installed

| ID | App | Method |
|---|---|---|
| `git` | Git + Git LFS + lsb-release | APT |
| `curl` / `wget` | cURL / wget | APT |
| `python` | Python3 + pip + venv + pipx | APT |
| `flatpak` | Flatpak + Flathub | APT + `flatpak remote-add` |
| `pi-apps` | Pi-Apps store | `Botspot/pi-apps` clone (per-user) |
| `brave` | Brave Browser | Pi-Apps first, official ARM64 repo fallback |
| `vscode` | VS Code | Pi OS APT (`code`) first, Microsoft repo fallback (Pi-Apps only has VSCodium — deliberately not used) |
| `chromium` | Chromium | APT |
| `nodejs` | Node.js LTS (default 22) + npm | NodeSource ARM64 (`--node-major` to change) |
| `docker` | Docker Engine | Official Docker APT repo (`docker-ce` suite); convenience script only as fallback |
| `pihole` | Pi-hole | Official installer, auto-detected interface/IP (strict CIDR check, never `0.0.0.0`), confirm before running. Non-interactive runs SKIP it unless `--allow-network-changes` is passed |
| `libreoffice` / `kodi` / `vlc` / `gimp` | Desktop apps | APT |
| `obs` | OBS Studio | APT, Flatpak fallback |
| `qemu` | QEMU + virt-manager | APT |
| `snapd` | snapd | APT, service enabled |
| `java` | OpenJDK LTS (default 17 + 21) | APT (`--java-versions` to change) |
| `dotnet` | .NET SDK (default 8.0) | Codename-aware Microsoft feed (12/13), script fallback (`--dotnet-version 9.0`) |
| `fastfetch` | Fastfetch | APT, GitHub `.deb` fallback |
| `adb` | ADB + Fastboot | APT, `plugdev` group |
| `prismlauncher` | PrismLauncher | Pi-Apps "Minecraft Java Prism Launcher" first, Flatpak fallback |
| `dolphin` | Dolphin Emulator | APT, Flatpak fallback |
| `eden` | Eden Switch Emulator | Flatpak `dev.eden_emu.eden`, AppImage fallback (git.eden-emu.dev) |
| `steam` | Steam (x86 via Box64) | Pi-Apps automation (handles Box86/Box64) |
| `retropie` | RetroPie | Clones `RetroPie-Setup` (full build is manual — takes hours) |
| `waydroid` | Waydroid | `repo.waydro.id` + `waydroid init` (VANILLA) + kernel tweaks ↓ (init failure = FAILED, with retry hint) |
| `mcpi-reborn` | MCPI: Reborn (TheBrokenRail) | Official Gitea APT repo first, Pi-Apps fallback |
| `llamacpp` | llama.cpp | Built from source (`ggerganov/llama.cpp`, ARM NEON) |
| `opencode` | OpenCode | Official `opencode.ai/install` (pinned dir + version check), `opencode-ai@latest` npm fallbacks |
| `claude-code` | Claude Code | `npm i -g @anthropic-ai/claude-code` |
| `sunshine` | Sunshine host + Moonlight client | LizardByte ARM64 `.deb` (+ Flatpak host fallback) + Flatpak Moonlight — BOTH required for success |
| `fnf` | Friday Night Funkin' | Pi-Apps Shadow Engine (preferred) / Rewritten |
| `steamlink` | Steam Link | Pi-Apps first, official APT fallback |
| `scrcpy` | scrcpy | Pi-Apps first, APT fallback (pulls in ADB tools) |
| `godot` | Godot Engine | Pi-Apps first, official Linux arm64 editor fallback |
| `blender` | Blender | Pi-Apps candidate, official Debian package |
| `ruffle` | Ruffle (Flash emulator) | Flathub first, official ARM64 tarball fallback |
| `celeste64` | Celeste 64 | Pi-Apps native ARM build (not Celeste Classic — different game) |
| `ppsspp` | PPSSPP (PSP) | Pi-Apps first, APT fallback |
| `freetube` | FreeTube | Pi-Apps first, official arm64 `.deb` fallback |
| `audacity` | Audacity | Pi-Apps first, APT fallback |
| `sonicpi` | Sonic Pi | APT, upstream arm64 `.deb` fallback (a live-coding *music synth* — not a code editor) |
| `doom3` | Doom 3 | Pi-Apps first, dhewm3 engine via APT (you supply the pak files) |
| `btop` / `thunderbird` / `filezilla` / `gparted` | System tools | APT (GParted ships with a backup warning) |
| `supertuxkart` / `minetest` / `retroarch` / `zeroad` | Games | APT |
| `wine` | Wine (x64 on 64-bit OS) | Pi-Apps only (Box86/Box64 build is intertwined) |

## Waydroid kernel tweaks (automatic with `waydroid`)

On Pi / Bookworm the default 16K-page kernel breaks Waydroid's binder.
Selecting `waydroid` applies, idempotently, atomically (stage + rename)
and with a mandatory timestamped backup before every edit:

1. **`psi=1`** appended to `cmdline.txt`
   (`/boot/firmware/cmdline.txt`, legacy fallback `/boot/cmdline.txt` —
   file stays a single line).
2. **4K pages** via `kernel=kernel8.img` in `config.txt`
   (`/boot/firmware/config.txt`, legacy fallback `/boot/config.txt`).

Skipped automatically on non-Pi hardware and with `--no-waydroid-tweaks`.
A failed image init (`waydroid init`) counts as FAILED with a retry hint.

Reboot afterwards, then:

```bash
sudo waydroid init -s GAPPS   # optional: Google apps image instead of VANILLA
systemctl status waydroid-container
waydroid session start
```

## Overclock — Pi 5 ONLY, optional, conservative

Offered separately after app installation (or forced/skipped via flags).
Defaults are a mild **2600MHz CPU / 900MHz GPU** — you can accept them or
type your own values (validated: CPU 2400–2800, GPU 800–1000):

```bash
sudo ./SetMyPiUp.sh --with-overclock    # apply without asking (defaults)
sudo ./SetMyPiUp.sh --no-overclock      # never apply
sudo ./SetMyPiUp.sh --with-overclock --oc-cpu 2700 --oc-gpu 950
```

- Extra voltage (`over_voltage_delta=50000`) is added only above 2600MHz CPU.
- Settings above 2700 CPU / 950 GPU trigger an additional aggressive warning.
- Written as a managed, idempotent `# SetMyPiUp-OC` block in `config.txt`
  (timestamped backup kept every time, even on re-runs).
- **Refused on anything that isn't a Raspberry Pi 5** (checked via
  `/proc/device-tree/model`) — the script logs an error and continues.
- ⚠️ **Requires good cooling** (official Active Cooler recommended).
  Verify after reboot: `vcgencmd measure_clock arm` + `vcgencmd measure_temp`.

## Safety / production-ready design

- **Preflight first:** architecture (aarch64), OS release, internet
  (4 endpoints + TCP fallback), free disk (2GB abort / 10GB warn), Pi 5
  identity. Aborts are overridable with `--force`, skipped in `--dry-run`.
- **Failure isolation:** `set -uo pipefail`, deliberately **no `set -e`**.
  Every installer is wrapped by `run_installer()` — failures are logged,
  recorded for the summary, and the run continues.
- **Honest reporting:** Waydroid fails if `waydroid init` fails; Sunshine
  fails unless BOTH host and client install (missing half named).
  Result codes are centralized: `0` = installed, `2` = skipped, else failed.
- **Re-runnable + self-updating:** each installer fast-paths when already
  installed; repo additions, config edits and Flatpak remotes are idempotent.
  Already-installed apps get an **update check** (`apt --only-upgrade`,
  `flatpak update`, `npm update -g`, `manage update`, `git pull`, even a
  llama.cpp rebuild-if-changed) — selecting an installed app updates it,
  then the run continues with the rest.
  Config backups are MANDATORY before every edit (abort otherwise),
  atomic (stage + rename), with nanosecond+PID-unique names.
- **Verified installs:** Git/Python/Node/Java/.NET/OpenCode are verified by
  actually executing them (`--version` probes), not just PATH presence.
- **Install-only philosophy:** the script never finishes app setup for you.
  Passwords, pairing, logins and API keys are listed under NEXT STEPS.
- **Logging:** everything to `/var/log/setmypiup.log`
  (override with `--log-file PATH`); console shows concise colored status.
- **Summary:** `SUCCESS / FAILED / SKIPPED` counts with dash lists,
  copy-paste `--only` retry line with the failed IDs, NEXT STEPS reminders,
  reboot reasons and the log path.
- **Reboot:** prompted at the end, naming WHY (kernel/overclock/etc.).
  `--no-reboot` skips, `--reboot` forces (even with failures),
  bare `--yes` does NOT auto-reboot when anything failed,
  `--dry-run` never reboots and never changes anything.
- **Menu:** `whiptail` → `dialog` → plain-text fallback, plus full CLI
  (`--all`, `--only`, `--exclude`, `--yes`) with one shared,
  case/space-insensitive exclusion filter so every interface behaves
  identically. `--only` is always one-shot.
- **Re-run loop:** after each interactive menu round you're asked "Do you
  want to install anything else?" — the script is the permanent installer
  entry point.

## Compatibility

-You can run it in x86_x64/ARM64 Linux or WSL, BUT only for testing. On Linux, install using the commands up in Quick Start with the --force flag. For Windows 10/11, you need WSL activated. When activated, run these commands :

```bash
wsl.exe --install Ubuntu
git clone https://github.com/Miiyamoto255/SetMyPiUp.git
cd ~/SetMyPiUp
chmod +x SetMyPiUp.sh
sudo ./SetMyPiUp.sh --force
```

## Troubleshooting

- **See what failed:** end-of-run summary + `sudo tail -n 100 /var/log/setmypiup.log`
- **Retry failures:** `sudo ./SetMyPiUp.sh --only <id>[,<id>...]` (see `--list`)
- **No menu appears:** install `whiptail` (`sudo apt install whiptail`) —
  the script falls back to text prompts automatically.
- **`apt update` errors:** check network/time (`date`), then re-run; the
  installer retries once and continues regardless.
- **Pi-hole caution:** it reconfigures DNS/DHCP — keep console access.
- **RetroPie caution:** only the setup script is cloned; the actual package
  build is manual via `sudo /opt/RetroPie-Setup/retropie_setup.sh`.
- **Sunshine/Eden/MCPI URLs:** release-asset names change upstream; the
  script tries API discovery first and records a clean failure (never fatal)
  if an asset can't be located.

## Files

- `SetMyPiUp.sh` — the installer (the deliverable)
- `README.md` — this documentation
