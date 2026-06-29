#!/usr/bin/env bash
###############################################################################
# wifi.sh
#
# Zega Mame Boy wifi provisioning. Installs a boot-time service that reads
# /boot/firmware/wifi.txt for SSID + PSK and configures NetworkManager.
#
# Provisioning flow (per boot):
#   1. If /boot/firmware/wifi.txt does NOT exist, create it with a template
#      so the user can find and edit it.
#   2. If both SSID and PSK are set, attempt `nmcli device wifi connect`.
#   3. On success, overwrite the file with the empty template so the
#      credentials don't sit in plaintext on the SD card.
#   4. On failure, leave the file untouched so the user can fix the
#      values and reboot to retry.
#
# The file lives on the FAT32 boot partition, so it's readable / editable
# by mounting the SD card on any computer — no SSH or terminal needed for
# first-time provisioning.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BOOT_DIR="/boot/firmware"
[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found." >&2; exit 1; }
command -v nmcli >/dev/null || { echo "nmcli not found — install NetworkManager first." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy wifi provisioning setup"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Install /usr/local/bin/zega-wifi-init
# ---------------------------------------------------------------------------
echo "[1/3] Installing /usr/local/bin/zega-wifi-init..."

cat > /usr/local/bin/zega-wifi-init <<'EOF'
#!/usr/bin/env bash
# Read /boot/firmware/wifi.txt for SSID + PSK, connect via NetworkManager,
# and on success scrub the credentials from the file. See wifi.sh header
# for the full flow description.

set -uo pipefail

WIFI_FILE="/boot/firmware/wifi.txt"
TEMPLATE='# Zega Mame Boy wifi provisioning.
#
# Edit the two fields below and reboot. On a successful connect, the
# credentials are scrubbed from this file and replaced with this template.
# On failure (wrong PSK, network out of range, etc.), the file is left
# alone so you can fix the values and retry.
#
# The SSID is the wifi network name. The PSK is the password (WPA/WPA2).
# Spaces and special characters are fine; do not quote the values.

SSID=
PSK=
'

# ---- Step 1: ensure the file exists (create with template if missing).
if [[ ! -f "${WIFI_FILE}" ]]; then
    printf '%s' "${TEMPLATE}" > "${WIFI_FILE}"
    chmod 600 "${WIFI_FILE}"
    echo "Created ${WIFI_FILE} with template; nothing to provision yet."
    exit 0
fi

# ---- Step 2: extract SSID and PSK (first non-comment line per key).
SSID="$(grep -m1 -E '^SSID=' "${WIFI_FILE}" | sed -E 's/^SSID=//')"
PSK="$( grep -m1 -E '^PSK='  "${WIFI_FILE}" | sed -E 's/^PSK=//')"

if [[ -z "${SSID}" || -z "${PSK}" ]]; then
    echo "${WIFI_FILE}: SSID or PSK empty; nothing to do."
    exit 0
fi

# ---- Step 3: wait briefly for NetworkManager radio to be ready,
#              then attempt the connection.
for _ in $(seq 1 15); do
    state="$(nmcli -t -f STATE general 2>/dev/null || true)"
    if [[ "${state}" == "connected" || "${state}" == "connecting (getting IP configuration)" \
       || "${state}" == "disconnected" ]]; then
        break
    fi
    sleep 1
done

echo "Connecting to SSID '${SSID}'..."
if nmcli device wifi connect "${SSID}" password "${PSK}"; then
    # ---- Step 4: scrub credentials by overwriting with the template.
    printf '%s' "${TEMPLATE}" > "${WIFI_FILE}"
    chmod 600 "${WIFI_FILE}"
    echo "Connected; credentials scrubbed from ${WIFI_FILE}."
    exit 0
else
    echo "Connect failed; ${WIFI_FILE} left intact so you can fix and retry." >&2
    exit 1
fi
EOF
chmod +x /usr/local/bin/zega-wifi-init

# Sanity check: bash syntax
bash -n /usr/local/bin/zega-wifi-init \
    || { echo "ERROR: zega-wifi-init has bash syntax errors" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 2. Install systemd unit
# ---------------------------------------------------------------------------
echo "[2/3] Installing systemd unit..."

cat > /etc/systemd/system/zega-wifi-init.service <<'EOF'
[Unit]
Description=Zega Mame Boy wifi provisioning from /boot/firmware/wifi.txt
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zega-wifi-init
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
# If the connect fails we exit non-zero but don't want systemd to mark
# the boot degraded; the file-on-disk is the recovery mechanism.
SuccessExitStatus=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zega-wifi-init.service >/dev/null

# ---------------------------------------------------------------------------
# Step 3. Pre-create the template file now so the user sees it immediately
#         (without waiting for the first boot of the service).
# ---------------------------------------------------------------------------
echo "[3/3] Pre-creating ${BOOT_DIR}/wifi.txt..."

if [[ ! -f "${BOOT_DIR}/wifi.txt" ]]; then
    /usr/local/bin/zega-wifi-init >/dev/null || true
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
[[ -x /usr/local/bin/zega-wifi-init ]] \
    && echo "  OK   /usr/local/bin/zega-wifi-init" \
    || echo "  FAIL /usr/local/bin/zega-wifi-init"
[[ -s /etc/systemd/system/zega-wifi-init.service ]] \
    && echo "  OK   /etc/systemd/system/zega-wifi-init.service" \
    || echo "  FAIL /etc/systemd/system/zega-wifi-init.service"
systemctl is-enabled zega-wifi-init.service >/dev/null \
    && echo "  OK   zega-wifi-init.service enabled" \
    || echo "  FAIL zega-wifi-init.service not enabled"
[[ -f "${BOOT_DIR}/wifi.txt" ]] \
    && echo "  OK   ${BOOT_DIR}/wifi.txt (template present)" \
    || echo "  FAIL ${BOOT_DIR}/wifi.txt"

cat <<EOF

Done. To provision wifi:

  1. Edit ${BOOT_DIR}/wifi.txt (from this system, or by mounting the SD
     card on any computer — it's on the FAT32 boot partition).
  2. Set the SSID= and PSK= fields. Do not quote the values.
  3. Reboot.

On a successful connection the file is overwritten with the empty
template so the password doesn't sit in plaintext.

To test once now, without rebooting:
  sudo /usr/local/bin/zega-wifi-init

To re-run later:
  sudo systemctl start zega-wifi-init.service
  journalctl -u zega-wifi-init.service --no-pager
EOF
