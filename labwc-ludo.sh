#!/usr/bin/env bash
###############################################################################
# labwc-ludo.sh
#
# Install labwc + configure it to auto-launch ludo on the panel at boot.
# Replaces our retroarch.service / zega-launcher.service as the boot target.
#
# Architecture:
#   tty1 -> systemd starts labwc -> labwc autostart spawns ludo
#     where labwc bridges card0 (vc4 GPU/GBM) -> card1 (SPI panel scanout)
#
# Why systemd: ludo + labwc need a real seat/VT to claim DRM, which ssh
# pseudo-ttys can't provide. systemd-on-tty1 gives labwc the seat it needs.
#
# Requires:
#   - panel-mipi-dbi-spi via display.sh
#   - ~student/ludo/ludosrc/ludo (built via the ludo-build Dockerfile)
#   - assets/database submodules populated under ~student/ludo/ludosrc/
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

USER_NAME="student"
USER_HOME="/home/${USER_NAME}"
LUDO_DIR="${USER_HOME}/ludo/ludosrc"
LUDO_BIN="${LUDO_DIR}/ludo"

id "${USER_NAME}" >/dev/null 2>&1 \
    || { echo "ERROR: user '${USER_NAME}' does not exist." >&2; exit 1; }
[[ -x "${LUDO_BIN}" ]] \
    || { echo "ERROR: ${LUDO_BIN} not found or not executable." >&2; exit 1; }
[[ -f "${LUDO_DIR}/assets/font.ttf" ]] \
    || { echo "ERROR: ${LUDO_DIR}/assets/font.ttf missing — run 'git submodule update --init --recursive' in ${LUDO_DIR}." >&2; exit 1; }

echo "============================================================"
echo " Zega: labwc kiosk launching ludo"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Install labwc + seatd.
# ---------------------------------------------------------------------------
echo "[1/4] Ensuring labwc + seatd installed..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
for pkg in labwc seatd; do
    dpkg -s "$pkg" >/dev/null 2>&1 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || true
done
dpkg -s labwc seatd >/dev/null 2>&1 \
    || { echo "ERROR: labwc/seatd install failed" >&2; exit 1; }
systemctl enable seatd >/dev/null
systemctl start seatd || true

# ---------------------------------------------------------------------------
# Step 2. labwc autostart -> ludo
# ---------------------------------------------------------------------------
echo "[2/4] Configuring ${USER_HOME}/.config/labwc/ ..."

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
    "${USER_HOME}/.config" "${USER_HOME}/.config/labwc"

cat > "${USER_HOME}/.config/labwc/autostart" <<EOF
#!/bin/sh
# labwc autostart: spawn ludo as a Wayland client.
# ludo expects assets/, database/ etc. to be in cwd, so we cd to its dir
# before launching.
sleep 1
cd "${LUDO_DIR}"
exec ./ludo
EOF
chmod +x "${USER_HOME}/.config/labwc/autostart"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/labwc/autostart"

# Minimal rc.xml: no decorations.
cat > "${USER_HOME}/.config/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <cornerRadius>0</cornerRadius>
    <name></name>
  </theme>
  <core>
    <gap>0</gap>
    <decoration>none</decoration>
  </core>
</labwc_config>
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/labwc/rc.xml"

# ---------------------------------------------------------------------------
# Step 3. systemd unit on tty1.
# ---------------------------------------------------------------------------
echo "[3/4] Installing /etc/systemd/system/zega-labwc.service..."

cat > /etc/systemd/system/zega-labwc.service <<EOF
[Unit]
Description=labwc kiosk (ludo on the panel)
After=systemd-user-sessions.service seatd.service
Wants=seatd.service
Conflicts=getty@tty1.service retroarch.service zega-launcher.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
SupplementaryGroups=video input render
ExecStart=/usr/bin/labwc
Restart=on-failure
RestartSec=3
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
Environment=HOME=${USER_HOME}
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u "${USER_NAME}")
Environment=WLR_BACKENDS=drm
Environment=WLR_DRM_DEVICES=/dev/dri/card1
Environment=WLR_RENDERER=gles2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable retroarch.service zega-launcher.service zega-labwc.service 2>/dev/null || true
systemctl enable zega-labwc.service >/dev/null

# ---------------------------------------------------------------------------
# Step 4. linger so XDG_RUNTIME_DIR exists at boot before user login.
# ---------------------------------------------------------------------------
echo "[4/4] Enabling user linger for ${USER_NAME}..."
loginctl enable-linger "${USER_NAME}" || true

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
[[ -x /usr/bin/labwc ]] && echo "  OK   labwc installed" || echo "  FAIL labwc"
[[ -x "${USER_HOME}/.config/labwc/autostart" ]] \
    && echo "  OK   autostart configured" || echo "  FAIL autostart"
[[ -s /etc/systemd/system/zega-labwc.service ]] \
    && echo "  OK   zega-labwc.service installed" || echo "  FAIL service"
systemctl is-enabled zega-labwc.service >/dev/null \
    && echo "  OK   zega-labwc.service enabled" || echo "  FAIL not enabled"

cat <<EOF

Done. Reboot to launch:
  sudo reboot

Logs:
  journalctl -u zega-labwc.service --no-pager

To revert:
  sudo systemctl disable zega-labwc.service
  sudo systemctl enable retroarch.service        # or zega-launcher.service
  sudo reboot
EOF
