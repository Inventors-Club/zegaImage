#!/usr/bin/env bash
###############################################################################
# retroarch.sh
#
# Installs RetroArch and configures it to auto-launch on tty1 at boot
# via a dedicated systemd unit (no console autologin, no .bash_profile
# hack). SSH sessions are unaffected.
#
# After install + reboot, the Pi will boot directly into RetroArch with
# the panel as the display. Pressing the SHUTDOWN button or `student`-side
# `systemctl stop retroarch` returns to a normal console (or you can
# `sudo systemctl disable retroarch` to disable auto-launch permanently).
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

USER_NAME=${SUDO_USER:-USER}
id "${USER_NAME}" >/dev/null 2>&1 \
    || { echo "ERROR: user '${USER_NAME}' does not exist." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy RetroArch auto-launch setup"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Install RetroArch.
# ---------------------------------------------------------------------------
echo "[1/3] Installing retroarch..."
if ! command -v retroarch >/dev/null; then
    apt-get update -qq
    # `unzip` is needed for RetroArch's Core Downloader to auto-extract
# .so.zip downloads. Debian's retroarch package doesn't depend on it,
# so without this the downloader silently leaves cores as zips in
# ~/.config/retroarch/downloads/ and they never appear in the menu.
apt-get install -y retroarch unzip >/dev/null
fi
command -v retroarch >/dev/null \
    || { echo "ERROR: retroarch not installed" >&2; exit 1; }

# NOTE on wifi: we used to swap NetworkManager -> ConnMan here so that
# RetroArch's built-in Wi-Fi menu (which shells out to connmanctl) would
# work on-device. In practice this was unreliable — the menu would hide
# itself in subtle situations, and ConnMan's wifi setup is harder to
# pre-bake into a fresh image.
#
# The convention every retro handheld distro (and Pi OS itself) actually
# uses is: students edit /boot/firmware/custom.toml (or wpa_supplicant.conf)
# on the SD card from any computer BEFORE first boot. Pi OS's firstboot
# script reads it and configures wifi. No on-device wifi menu required.
#
# So we now keep NetworkManager (default Pi OS stack) and rely on the
# pre-bake-on-SD workflow for student wifi config.

# ---------------------------------------------------------------------------
# Step 2. Make sure the user can talk to display, input and audio devices.
# ---------------------------------------------------------------------------
echo "[2/4] Adding ${USER_NAME} to video / input / audio / render groups..."
usermod -aG video,input,audio,render "${USER_NAME}"

# ---------------------------------------------------------------------------
# Step 3. Patch retroarch.cfg for a working-out-of-the-box experience:
#   - libretro_directory: point at user-writable ~/.config/retroarch/cores
#     so the Online Updater's Core Downloader can actually write to it.
#     (Debian's default points at /usr/lib/aarch64-linux-gnu/libretro/,
#     which only root can write — Core Downloader silently fails.)
#   - core_updater_buildbot_cores_url: Debian ships this blank to avoid
#     auto-downloading binary blobs. We set it to the libretro buildbot's
#     linux/aarch64 directory so the menu actually fetches cores.
#   - Hotkey to exit a running game: F4 (no need for keyboard combos).
#     Maps to the SELECT button on our gpio-keys layout via KEY_RIGHTSHIFT
#     as enable_hotkey, then KEY_F4 to quit. Defaults vary by build.
# ---------------------------------------------------------------------------
echo "[3/4] Patching retroarch.cfg for sane defaults..."

USER_HOME="/home/${USER_NAME}"
RA_CFG="${USER_HOME}/.config/retroarch/retroarch.cfg"

# Ensure config exists by running retroarch once with --menu to create it.
if [[ ! -f "${RA_CFG}" ]]; then
    sudo -u "${USER_NAME}" mkdir -p "${USER_HOME}/.config/retroarch/cores"
    sudo -u "${USER_NAME}" /usr/bin/retroarch --menu --features 2>/dev/null || true
fi

# set_kv: replace existing key=val or append if missing
# set_kv() {
#     local key="$1" val="$2"
#     if grep -q "^${key} =" "${RA_CFG}"; then
#         sed -i "s|^${key} = .*|${key} = \"${val}\"|" "${RA_CFG}"
#     else
#         echo "${key} = \"${val}\"" >> "${RA_CFG}"
#     fi
# }

# User-writable core directory.
sudo -u "${USER_NAME}" mkdir -p "${USER_HOME}/.config/retroarch/cores"
# set_kv libretro_directory             "~/.config/retroarch/cores"
# set_kv core_updater_buildbot_cores_url \
    "http://buildbot.libretro.com/nightly/linux/aarch64/latest/"

# Kiosk-style: don't let RetroArch save its in-memory config back to
# retroarch.cfg on exit. Without this, RetroArch overwrites our cfg
# (and reverts edits like menu_driver=rgui back to xmb) every time it
# shuts down. The cfg is now the authoritative source — changes the
# user makes via RetroArch's menu UI are forgotten on exit, which is
# what we want for an immutable kiosk image.
# set_kv config_save_on_exit            "false"

# Force RGUI menu driver — XMB is the upstream default but it doesn't
# render legibly on a 320x240 panel. RGUI is the bitmap-font, made-for-
# tile-displays menu we've tested.
# set_kv menu_driver                    "rgui"

# Hide the Wi-Fi menu — without ConnMan it doesn't work, and we now
# rely on pre-baked /boot/firmware/custom.toml for student wifi setup.
# set_kv menu_show_wifi                 "false"

# Show the Bluetooth menu item — works out of the box on Trixie since
# BlueZ is the standard stack (no swap needed). Lets students pair
# gamepads, BT headphones, BT keyboards from the device itself.
# Especially useful since our audio chip is hardware-faulty: BT
# headphones become the practical audio output.
# set_kv menu_show_bluetooth            "true"
# Same pattern as wifi_driver — default "null" makes the menu inert.
# set_kv bluetooth_driver               "bluez"

# Default the file browser to ~/roms so users don't navigate from /
#every time they Load Content. ROM subdirs by system: snes, nes,
#genesis, gb, gba, pygame (for our shim).
sudo -u "${USER_NAME}" mkdir -p \
    "${USER_HOME}/roms/snes" \
    "${USER_HOME}/roms/nes" \
    "${USER_HOME}/roms/genesis" \
    "${USER_HOME}/roms/gb" \
    "${USER_HOME}/roms/gba" \
    "${USER_HOME}/roms/pygame"
# set_kv rgui_browser_directory         "~/roms"
# set_kv content_directory              "~/roms"
# set_kv input_remapping_directory      "~/.config/retroarch/remaps"

# Symlink any system-installed cores into the user cores dir so they
# remain visible after we move libretro_directory.
for src in /usr/lib/libretro/*.so; do
    [[ -f "$src" ]] || continue
    sudo -u "${USER_NAME}" ln -sf "$src" "${USER_HOME}/.config/retroarch/cores/$(basename "$src")"
done

# In-game close-content hotkey: SELECT (KEY_RIGHTSHIFT, "rshift") +
# START (KEY_ENTER, "enter") closes the running content and returns to
# RetroArch's main menu, where everything is properly sized for the
# 320x240 panel.
#
# We DON'T use the Quick Menu overlay (input_menu_toggle) because RGUI's
# bitmap font gets non-uniformly scaled when overlaid on cores with
# unusual viewports — text comes out squished. Closing the game and
# going back to the panel-native main menu sidesteps the problem.
#
# DON'T use input_exit_emulator either: that kills the RetroArch process
# and relies on systemd Restart= to bring it back, which is slow.
# set_kv input_enable_hotkey            "rshift"
# set_kv input_close_content            "enter"
# set_kv input_menu_toggle              "nul"
# set_kv input_exit_emulator            "nul"

# # IMPORTANT: don't touch video_fullscreen, video_context_driver,
# # aspect_ratio_index, video_force_aspect, or video_aspect_ratio* on
# # this hardware. RetroArch's auto-detection of all those Just Works
# # for the 320x240 ILI9341 panel; any attempt to pin them produces
# # either a blank panel, a stretched menu, or both. The working
# # defaults are: video_fullscreen=false, aspect_ratio_index=22 (Custom
# # viewport), auto-detected video_context_driver. Trust them.
# #
# # DO set menu_rgui_aspect_ratio_lock = 1 (Fit Screen) — this is
# # RGUI-specific and only affects how the menu is scaled relative to
# # the current video viewport. Without it, opening the main menu after
# # a game with an unusual viewport shows squished text. (We don't use
# # the in-game Quick Menu overlay either way — see the input_close_content
# # block below.)
# # menu_rgui_aspect_ratio is INTEGER-valued (0-6, indexes into a fixed
# # preset list), NOT a string. Don't pass "4:3" / "Auto" / etc — it
# # breaks rendering and the panel goes black.
# # 0 = 4:3 (default), 1 = 16:9, 2 = 16:9C, 3 = 3:2, 4 = 3:2C, 5 = 5:3, 6 = 5:3C
# set_kv menu_rgui_aspect_ratio         "0"
# # 1 = Fit Screen: preserves the menu's bitmap font aspect (so text
# # isn't squished) at the cost of possible letterboxing. Value 3 (Fill
# # Screen) stretches and distorts the font; 2 (Integer Scale) limits to
# # Nx scaling. On our 320x240 4:3 panel with a 4:3 menu, "Fit" results
# # in no letterbox AND no distortion.
# set_kv menu_rgui_aspect_ratio_lock    "1"
# #
# # Custom viewport: 264x240 centered on the 320x240 panel matches the
# # Zega Mame Boy 2.7's case cutout. The 28px on each side fall behind
# # the case bezel and are invisible. Vendor's Buster image used the
# # same dimensions (hdmi_cvt = 264 240 ...).
# set_kv aspect_ratio_index             "22"
# set_kv custom_viewport_width          "264"
# set_kv custom_viewport_height         "240"
# set_kv custom_viewport_x              "28"
# set_kv custom_viewport_y              "0"
#
# ---------------------------------------------------------------------------
# Step 4. systemd unit.
#
# Conflicts=getty@tty1.service: systemd stops getty on tty1 when RetroArch
# starts, so the login prompt doesn't fight us for the TTY. tty2-tty6 still
# get a login prompt — you can Ctrl+Alt+F2 to get a console at any time.
#
# Type=simple + Restart=on-failure means if RetroArch crashes it'll come
# back; if you `systemctl stop retroarch` you get a console back on tty1.
# ---------------------------------------------------------------------------
echo "[4/4] Installing /etc/systemd/system/retroarch.service..."

cat > /etc/systemd/system/retroarch.service <<EOF
[Unit]
Description=RetroArch on tty1
After=systemd-user-sessions.service zega-panel.service
Wants=zega-panel.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
ExecStart=/usr/bin/retroarch -f
Restart=on-failure
RestartSec=3
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment=HOME=/home/${USER_NAME}
Environment=SDL_VIDEODRIVER=kmsdrm

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable retroarch.service >/dev/null

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
command -v retroarch >/dev/null \
    && echo "  OK   retroarch installed: $(retroarch --version 2>&1 | head -1)" \
    || echo "  FAIL retroarch not on PATH"
id -nG "${USER_NAME}" | tr ' ' '\n' | grep -qE '^(video|input)$' \
    && echo "  OK   ${USER_NAME} in video/input groups" \
    || echo "  FAIL ${USER_NAME} missing video/input groups (reboot may be needed)"
[[ -s /etc/systemd/system/retroarch.service ]] \
    && echo "  OK   /etc/systemd/system/retroarch.service" \
    || echo "  FAIL /etc/systemd/system/retroarch.service"
systemctl is-enabled retroarch.service >/dev/null \
    && echo "  OK   retroarch.service enabled" \
    || echo "  FAIL retroarch.service not enabled"

cat <<EOF

Done. Reboot to launch RetroArch on tty1:
  sudo reboot

To disable auto-launch later (without uninstalling):
  sudo systemctl disable retroarch.service

To stop a running RetroArch and recover a console:
  sudo systemctl stop retroarch.service
  # then switch to tty2 with Ctrl+Alt+F2 if needed

Logs:
  journalctl -u retroarch.service --no-pager
EOF
