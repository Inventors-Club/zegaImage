#!/usr/bin/env bash
###############################################################################
# wifi-template.sh
#
# Drops a /boot/firmware/wifi.txt template that students can edit on their
# laptop (FAT32, mounts anywhere) to configure wifi BEFORE first boot.
#
# Also installs a systemd unit that, on each boot, reads /boot/firmware/wifi.txt
# and converts its contents into a NetworkManager connection. After a successful
# connect the file is replaced with the empty template again (so the SSID and
# password don't sit on disk in plaintext after first use).
#
# Workflow for students:
#   1. Slide SD card out of Zega
#   2. Plug into laptop's SD reader
#   3. Open the "bootfs" volume that appears
#   4. Edit "wifi.txt", set SSID and PSK
#   5. Eject, reinsert in Zega, power on
#   6. Wifi works
#
# Re-run anytime by simply editing /boot/firmware/wifi.txt and rebooting.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BOOT_DIR="/boot/firmware"
[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found." >&2; exit 1; }
command -v nmcli >/dev/null || { echo "nmcli (NetworkManager) not found." >&2; exit 1; }

echo "============================================================"
echo " Zega: pre-bake wifi via /boot/firmware/wifi.txt"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Drop the template (if it doesn't already exist).
# ---------------------------------------------------------------------------
TEMPLATE_BODY='# Zega wifi configuration.
#
# Edit the two fields below and reboot. The Zega reads this file on each
# boot; if SSID and PSK are filled in it connects to that network via
# NetworkManager. After a successful connect the credentials are scrubbed
# (this file is replaced with the empty template again) so they do not
# sit in plaintext on a FAT32 partition that mounts on any computer.
#
# Country code helps with regulatory domain on some Pi models. Defaults to
# AU; set to your two-letter ISO 3166-1 alpha-2 code.

SSID=
PSK=
COUNTRY=AU
'

if [[ ! -f "${BOOT_DIR}/wifi.txt" ]]; then
    printf '%s' "${TEMPLATE_BODY}" > "${BOOT_DIR}/wifi.txt"
    chmod 600 "${BOOT_DIR}/wifi.txt"
    echo "[1/2] Created ${BOOT_DIR}/wifi.txt template"
else
    echo "[1/2] ${BOOT_DIR}/wifi.txt already exists; leaving as-is"
fi

# ---------------------------------------------------------------------------
# Step 2. Install the boot-time reader.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Step 1b. Disable NetworkManager wifi powersave.
#
# The Pi Zero 2 W's brcmfmac driver aggressively powers down the wifi
# chip during low-traffic periods (e.g. long apt installs). The
# connection drops mid-operation, often unrecoverably without a manual
# reconnect. Disabling NM's powersave permanently prevents this.
# Value 2 = disable (per NM docs).
# ---------------------------------------------------------------------------
echo "[1b/2] Disabling wifi powersave (prevents drops during long apt installs)..."
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
systemctl restart NetworkManager 2>/dev/null || true

echo "[2/2] Installing /usr/local/bin/zega-wifi-from-bootfs..."

cat > /usr/local/bin/zega-wifi-from-bootfs <<'EOF'
#!/usr/bin/env bash
# Read /boot/firmware/wifi.txt and apply via nmcli.
# Replace the file with the empty template on a successful connect.

set -uo pipefail

WIFI_FILE="/boot/firmware/wifi.txt"
[[ -f "${WIFI_FILE}" ]] || exit 0

SSID="$(grep -m1 -E '^SSID=' "${WIFI_FILE}" | sed -E 's/^SSID=//')"
PSK="$(grep -m1 -E '^PSK=' "${WIFI_FILE}" | sed -E 's/^PSK=//')"
COUNTRY="$(grep -m1 -E '^COUNTRY=' "${WIFI_FILE}" | sed -E 's/^COUNTRY=//')"

[[ -z "${SSID}" || -z "${PSK}" ]] && exit 0

# Wait briefly for NM to be up.
for _ in $(seq 1 15); do
    nmcli general status >/dev/null 2>&1 && break
    sleep 1
done

# Set country code (helps regulatory domain on some chipsets).
if [[ -n "${COUNTRY}" ]]; then
    iw reg set "${COUNTRY}" >/dev/null 2>&1 || true
fi

echo "Connecting to ${SSID}..."
if nmcli device wifi connect "${SSID}" password "${PSK}"; then
    # Scrub credentials by writing the empty template back.
    printf '%s' '# Zega wifi configuration.
#
# Edit the two fields below and reboot. The Zega reads this file on each
# boot; if SSID and PSK are filled in it connects to that network via
# NetworkManager. After a successful connect the credentials are scrubbed
# (this file is replaced with the empty template again) so they do not
# sit in plaintext on a FAT32 partition that mounts on any computer.

SSID=
PSK=
COUNTRY=AU
' > "${WIFI_FILE}"
    chmod 600 "${WIFI_FILE}"
    echo "Connected. Credentials scrubbed."
else
    echo "Connect failed; wifi.txt left intact for retry." >&2
    exit 1
fi
EOF
chmod +x /usr/local/bin/zega-wifi-from-bootfs

cat > /etc/systemd/system/zega-wifi-from-bootfs.service <<'EOF'
[Unit]
Description=Zega: read /boot/firmware/wifi.txt and apply via NetworkManager
After=NetworkManager.service network.target
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zega-wifi-from-bootfs
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
SuccessExitStatus=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zega-wifi-from-bootfs.service >/dev/null

echo
echo "Done. Workflow:"
echo
echo "  1. Power off the Zega"
echo "  2. Slide out the SD card"
echo "  3. On any laptop, open the bootfs partition that auto-mounts"
echo "  4. Edit wifi.txt, set SSID= and PSK="
echo "  5. Reinsert SD, power on Zega — wifi connects on boot"
echo
echo "After a successful boot, wifi.txt is scrubbed (credentials removed)."
echo "Edit again any time wifi changes."
