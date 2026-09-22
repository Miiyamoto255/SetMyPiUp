# SetMyPiUp 🍓

Professional, production-ready Raspberry Pi 5 setup script.
Pick the apps you want from a menu — one failed install never breaks the rest —
then the Pi reboots so kernel / Docker / Waydroid / overclock changes take effect.

- **Script:** `SetMyPiUp.sh` (Bash, no dependencies beyond a stock Pi OS)
- **Target:** Raspberry Pi 5, Raspberry Pi OS 64-bit (Debian Bookworm or newer)
- **License:** MIT

## Quick start

```bash
chmod +x SetMyPiUp.sh
sudo ./SetMyPiUp.sh                  # interactive menu (recommended)
```

Non-interactive examples:

```bash
sudo ./SetMyPiUp.sh --all --yes                    # everything, no prompts
sudo ./SetMyPiUp.sh --only git,docker,vscode,fastfetch --no-reboot
sudo ./SetMyPiUp.sh --all --exclude pihole,retropie --yes
./SetMyPiUp.sh --list                              # show installable IDs
./SetMyPiUp.sh --dry-run --all                     # show what would happen
```

> The script must run as root (`sudo`). Per-user tools (Pi-Apps, OpenCode,
> npm globals excluded) are installed for `${SUDO_USER}` automatically.

## What gets installed

| ID | App | Method |
|---|---|---|
| `git` | Git + Git LFS + lsb-release | APT |
| `curl` / `wget` | cURL / wget | APT |
| `python` | Python3 + pip + venv + pipx | APT |
| `flatpak` | Flatpak + Flathub | APT + `flatpak remote-add` |
| `pi-apps` | Pi-Apps store | `Botspot/pi-apps` clone (per-user) |
| `brave` | Brave Browser | Official `brave-browser-apt-release` ARM64 repo |
| `vscode` | VS Code | Official Microsoft `code` ARM64 repo |
| `chromium` | Chromium | APT |
| `nodejs` | Node.js 22 LTS + npm | NodeSource ARM64 |
| `docker` | Docker Engine | Official `get.docker.com`, user added to `docker` group |
| `pihole` | Pi-hole | Official installer, `--unattended` (+ confirmation) |
| `libreoffice` / `kodi` / `vlc` / `gimp` | Desktop apps | APT |
| `obs` | OBS Studio | APT, Flatpak fallback |
| `qemu` | QEMU + virt-manager | APT |
| `snapd` | snapd | APT, service enabled |
| `java` | OpenJDK 17 + 21 | APT |
| `dotnet` | .NET SDK 8.0 | Microsoft Debian 12 feed, script fallback |
| `fastfetch` | Fastfetch | APT, GitHub `.deb` fallback |
| `adb` | ADB + Fastboot | APT, `plugdev` group |
| `prismlauncher` | PrismLauncher | Pi-Apps first (as requested), Flatpak fallback |
| `dolphin` | Dolphin Emulator | APT, Flatpak fallback |
| `eden` | Eden Switch Emulator | Flatpak `io.github.eden_emu.eden`, AppImage fallback |
| `steam` | Steam (x86 via Box64) | Pi-Apps automation (handles Box86/Box64) |
| `retropie` | RetroPie | Clones `RetroPie-Setup` (full build is manual — takes hours) |
| `waydroid` | Waydroid | `repo.waydro.id` + `waydroid init` (VANILLA) + kernel tweaks ↓ |
| `mcpi-reborn` | MCPI: Reborn (TheBrokenRail) | Pi-Apps first, Gitea `.deb` fallback |
| `llamacpp` | llama.cpp | Built from source (`ggerganov/llama.cpp`, ARM NEON) |
| `opencode` | OpenCode | Official `opencode.ai/install`, npm fallback |
| `claude-code` | Claude Code | `npm i -g @anthropic-ai/claude-code` |
| `sunshine` | Sunshine host + Moonlight client | LizardByte ARM64 `.deb` + Flatpak Moonlight |

## Waydroid kernel tweaks (automatic with `waydroid`)

On Pi 5 / Bookworm the default 16K-page kernel breaks Waydroid's binder.
Selecting `waydroid` applies, idempotently and with timestamped backups:

1. **`psi=1`** appended to `cmdline.txt`
   (`/boot/firmware/cmdline.txt`, legacy fallback `/boot/cmdline.txt` —
   file stays a single line).
2. **4K pages** via `kernel=kernel8.img` in `config.txt`
   (`/boot/firmware/config.txt`, legacy fallback `/boot/config.txt`).

Reboot afterwards, then:

```bash
sudo waydroid init -s GAPPS   # optional: Google apps image instead of VANILLA
systemctl status waydroid-container
waydroid session start
```

## Overclock — Pi 5 ONLY, optional

Offered separately after app installation (or forced/skipped via flags):

```bash
sudo ./SetMyPiUp.sh --with-overclock    # apply without asking
sudo ./SetMyPiUp.sh --no-overclock      # never apply
```

- CPU `arm_freq=2700`, GPU `gpu_freq=1000`, `over_voltage_delta=50000`
- Written as a managed, idempotent `# SetMyPiUp-OC` block in `config.txt`
  (timestamped backup kept; re-runs replace the block, never duplicate it).
- **Refused on anything that isn't a Raspberry Pi 5** (checked via
  `/proc/device-tree/model`) — the script logs an error and continues.
- ⚠️ **Requires active cooling** (official Active Cooler recommended).
  Verify after reboot: `vcgencmd measure_clock arm` and watch
  `vcgencmd measure_temp` under load.

## Safety / production-ready design

- **Failure isolation:** `set -uo pipefail`, deliberately **no `set -e`**.
  Every installer is wrapped by `run_installer()` — failures are logged,
  recorded for the summary, and the run continues.
- **Re-runnable:** each installer fast-paths when already installed;
  repo additions, config edits and Flatpak remotes are idempotent.
- **Backups:** every privileged file edit keeps a
  `*.setmypiup-bak-<timestamp>` copy.
- **Logging:** everything to `/var/log/setmypiup.log`
  (override with `--log-file PATH`); console shows concise colored status.
- **Reboot:** prompted at the end (required for kernel/Docker/Waydroid/OC).
  `--no-reboot` skips, `--reboot` reboots without prompting,
  `--dry-run` never reboots and never changes anything.
- **Menu:** `whiptail` → `dialog` → plain-text fallback, plus full CLI
  (`--all`, `--only`, `--exclude`, `--yes`) for automation.

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
