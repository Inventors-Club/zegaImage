#!/usr/bin/env bash
###############################################################################
# launcher.sh
#
# Installs the zega launcher (a small pygame menu) and switches the boot
# autolaunch from retroarch.service to zega-launcher.service. The launcher
# dispatches to RetroArch, pygame apps, or shell commands per entries in
# ~student/launcher.toml.
#
# Run after display.sh + audio.sh + buttons.sh + retroarch.sh.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

USER_NAME="student"
id "${USER_NAME}" >/dev/null 2>&1 \
    || { echo "ERROR: user '${USER_NAME}' does not exist." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${SCRIPT_DIR}/launcher.py" ]] \
    || { echo "ERROR: launcher.py not found next to launcher.sh." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy launcher install"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Python + pygame. Skip apt if pygame is already there — Trixie
# images sometimes have unrelated wedged packages (e.g. plymouth's
# update-initramfs failures) that make every `apt-get install` return
# non-zero. Don't let that block us when our package is already good.
# ---------------------------------------------------------------------------
echo "[1/4] Installing python3-pygame..."
if dpkg -s python3-pygame >/dev/null 2>&1; then
    echo "       python3-pygame already installed; skipping apt."
else
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        python3 python3-pygame || {
        # If pygame DID land but apt returned non-zero from an unrelated
        # broken package, accept that and continue.
        if dpkg -s python3-pygame >/dev/null 2>&1; then
            echo "       python3-pygame installed (apt returned non-zero from unrelated package)."
        else
            echo "ERROR: python3-pygame failed to install." >&2
            exit 1
        fi
    }
fi

# ---------------------------------------------------------------------------
# Step 2. Drop launcher.py into /usr/local/bin.
# ---------------------------------------------------------------------------
echo "[2/4] Installing /usr/local/bin/zega-launcher..."
install -m 0755 "${SCRIPT_DIR}/launcher.py" /usr/local/bin/zega-launcher
python3 -c "import ast; ast.parse(open('/usr/local/bin/zega-launcher').read())" \
    || { echo "ERROR: zega-launcher has python syntax errors" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 3. systemd unit. Conflicts with both getty@tty1 AND retroarch.service
#         so swapping in this unit cleanly demotes RetroArch to "launched by
#         the menu" rather than the boot-time service.
# ---------------------------------------------------------------------------
echo "[3/4] Installing /etc/systemd/system/zega-launcher.service..."

cat > /etc/systemd/system/zega-launcher.service <<EOF
[Unit]
Description=Zega launcher (pygame menu) on tty1
After=systemd-user-sessions.service zega-panel.service
Wants=zega-panel.service
Conflicts=getty@tty1.service retroarch.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
ExecStart=/usr/local/bin/zega-launcher
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
systemctl disable retroarch.service 2>/dev/null || true
systemctl enable zega-launcher.service >/dev/null

# ---------------------------------------------------------------------------
# Step 4. Drop a sample ~student/launcher.toml if none exists.
# ---------------------------------------------------------------------------
echo "[4/4] Seeding /home/${USER_NAME}/launcher.toml ..."

USER_TOML="/home/${USER_NAME}/launcher.toml"
if [[ ! -f "${USER_TOML}" ]]; then
    cat > "${USER_TOML}" <<'EOF'
# zega launcher menu.
# Edit this file to add or remove entries. Reload by rebooting or running
# `sudo systemctl restart zega-launcher.service`.
#
# Each entry needs: label, category, command (array).
# Entries with the same `category` are grouped together; the category
# string is also shown as [tag] on the right side of each row. The
# `command` is exec'd via subprocess.run(); the launcher releases the
# panel before running and re-claims it when the child exits.

[[entries]]
label = "RetroArch"
category = "system"
command = ["retroarch", "-f"]

[[entries]]
label = "Reboot"
category = "system"
command = ["sudo", "reboot"]

[[entries]]
label = "Shutdown"
category = "system"
command = ["sudo", "poweroff"]

# Example pygame entry — uncomment when you have a script ready.
# [[entries]]
# label = "Pong"
# category = "pygame"
# command = ["python3", "/home/student/pygame-apps/pong.py"]

# Example emulator entry — `-L` selects the core, the path is the ROM.
# [[entries]]
# label = "Super Mario World"
# category = "snes"
# command = [
#   "retroarch", "-f",
#   "-L", "/usr/lib/libretro/snes9x_libretro.so",
#   "/home/student/roms/smw.sfc",
# ]
EOF
    chown "${USER_NAME}:${USER_NAME}" "${USER_TOML}"
fi

# Allow student to reboot/poweroff without a password so the menu can do it.
cat > /etc/sudoers.d/zega-launcher-power <<EOF
${USER_NAME} ALL=(root) NOPASSWD: /sbin/reboot, /sbin/poweroff, /usr/sbin/reboot, /usr/sbin/poweroff
EOF
chmod 0440 /etc/sudoers.d/zega-launcher-power

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
[[ -x /usr/local/bin/zega-launcher ]] \
    && echo "  OK   /usr/local/bin/zega-launcher" \
    || echo "  FAIL /usr/local/bin/zega-launcher"
[[ -s /etc/systemd/system/zega-launcher.service ]] \
    && echo "  OK   /etc/systemd/system/zega-launcher.service" \
    || echo "  FAIL /etc/systemd/system/zega-launcher.service"
systemctl is-enabled zega-launcher.service >/dev/null \
    && echo "  OK   zega-launcher.service enabled" \
    || echo "  FAIL zega-launcher.service not enabled"
! systemctl is-enabled retroarch.service >/dev/null 2>&1 \
    && echo "  OK   retroarch.service disabled (replaced)" \
    || echo "  FAIL retroarch.service still enabled"
[[ -f "${USER_TOML}" ]] \
    && echo "  OK   ${USER_TOML}" \
    || echo "  FAIL ${USER_TOML}"

cat <<EOF

Done. Reboot to launch into the menu:
  sudo reboot

Logs:
  journalctl -u zega-launcher.service --no-pager

To edit the menu after install:
  $EDITOR /home/${USER_NAME}/launcher.toml
  sudo systemctl restart zega-launcher.service
EOF
