#!/usr/bin/env bash
###############################################################################
# labwc-esde.sh
#
# Install labwc + configure it to auto-launch ES-DE on the panel at boot.
# Replaces our retroarch.service / zega-launcher.service as the boot target.
#
# Architecture:
#   tty1 → labwc → ES-DE (SDL2 Wayland client)
#     where labwc bridges card0 (vc4 GPU/GBM) → card1 (SPI panel scanout)
#
# Requires:
#   - panel-mipi-dbi-spi via display.sh
#   - ~student/es-de + ~student/resources (compiled via our Docker arm64 build)
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

USER_NAME="student"
USER_HOME="/home/${USER_NAME}"
id "${USER_NAME}" >/dev/null 2>&1 \
    || { echo "ERROR: user '${USER_NAME}' does not exist." >&2; exit 1; }

[[ -x "${USER_HOME}/es-de" ]] \
    || { echo "ERROR: ${USER_HOME}/es-de not found or not executable." >&2; exit 1; }

echo "============================================================"
echo " Zega: labwc kiosk launching ES-DE"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Install labwc + seatd + Wayland test tools (kept for debugging).
# ---------------------------------------------------------------------------
echo "[1/4] Installing labwc + seatd..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
for pkg in labwc seatd weston glmark2-wayland; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || true
    fi
done
dpkg -s labwc seatd >/dev/null 2>&1 \
    || { echo "ERROR: labwc/seatd install failed" >&2; exit 1; }
systemctl enable seatd >/dev/null
systemctl start seatd || true

# ---------------------------------------------------------------------------
# Step 2. labwc config to autostart ES-DE.
#
# labwc autostart is a shell script at ~/.config/labwc/autostart that runs
# once the compositor is ready. Anything launched here becomes a Wayland
# client on the panel.
# ---------------------------------------------------------------------------
echo "[2/4] Configuring ~${USER_NAME}/.config/labwc/ ..."

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
    "${USER_HOME}/.config" "${USER_HOME}/.config/labwc"

cat > "${USER_HOME}/.config/labwc/autostart" <<'EOF'
#!/bin/sh
# Wait briefly for compositor to be fully ready.
sleep 1

# Force SDL apps to use the Wayland backend.
export SDL_VIDEODRIVER=wayland

# Launch ES-DE. --resources-dir points at our compiled resources tree.
exec /home/student/es-de --resources-dir /home/student/resources/
EOF
chmod +x "${USER_HOME}/.config/labwc/autostart"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/labwc/autostart"

# Minimal rc.xml: no decorations (we're in kiosk mode).
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
#
# Conflicts with retroarch.service and zega-launcher.service so swapping in
# this unit cleanly takes the panel from whatever owned tty1 before.
# ---------------------------------------------------------------------------
echo "[3/4] Installing /etc/systemd/system/zega-labwc.service..."

cat > /etc/systemd/system/zega-labwc.service <<EOF
[Unit]
Description=labwc kiosk (ES-DE on the panel)
After=systemd-user-sessions.service zega-panel.service seatd.service
Wants=zega-panel.service seatd.service
Conflicts=getty@tty1.service retroarch.service zega-launcher.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
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
Environment=WLR_DRM_DEVICES=/dev/dri/card1
Environment=WLR_RENDERER=gles2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable retroarch.service 2>/dev/null || true
systemctl disable zega-launcher.service 2>/dev/null || true
systemctl enable zega-labwc.service >/dev/null

# ---------------------------------------------------------------------------
# Step 4. Make sure XDG_RUNTIME_DIR exists for student even without a login.
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
    && echo "  OK   labwc autostart configured" \
    || echo "  FAIL autostart"
systemctl is-enabled zega-labwc.service >/dev/null \
    && echo "  OK   zega-labwc.service enabled" \
    || echo "  FAIL service not enabled"
! systemctl is-enabled retroarch.service >/dev/null 2>&1 \
    && echo "  OK   retroarch.service disabled" \
    || echo "  WARN retroarch.service still enabled (will conflict)"

cat <<EOF

Done. Reboot to launch:
  sudo reboot

Logs:
  journalctl -u zega-labwc.service --no-pager
  cat ~student/.local/state/ES-DE/logs/es_log.txt 2>/dev/null

To revert to retroarch.service or zega-launcher.service:
  sudo systemctl disable zega-labwc.service
  sudo systemctl enable retroarch.service        # or zega-launcher.service
  sudo reboot
EOF
