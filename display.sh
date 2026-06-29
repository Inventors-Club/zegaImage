#!/usr/bin/env bash
###############################################################################
# zega-mame-boy-display.sh
#
# Fresh-install setup for the Zega Mame Boy ILI9341 SPI panel on Raspberry Pi
# OS Trixie Lite. Produces a working KMS pipeline (/dev/dri/card1 at 320x240)
# on a clean SD card in one pass.
#
# Architecture:
#   1. dtoverlay=zega-reset-hog loads at boot, kernel pinctrl holds GPIO 27
#      output-high so panel RESET stays de-asserted forever.
#   2. zega-preinit.service runs userspace ILI9341 init via /dev/spidev0.0,
#      paints black, exits.
#   3. zega-panel.service applies zega-panel-fakereset overlay; kernel binds
#      panel-mipi-dbi-spi driver on a fake reset pin (GPIO 26, unwired).
#   4. /dev/dri/card1 appears, ready for RetroArch / PyGame via KMSDRM.
#
# Designed for a fresh Trixie Lite install. Run as root, then reboot.
###############################################################################

set -euo pipefail

# Make failures loud rather than silent
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# let's remove the backlight altogether, the only pins we use for this are 27, 22, 10, 11, 8
DC_GPIO=22
RESET_GPIO=27
FAKE_RESET_GPIO=1
# ILI9341 datasheet says 10 MHz max, but in practice tight handheld
# builds run them at 40-80 MHz reliably. 48 MHz gives ~38 fps full-screen
# updates and is the safe sweet spot for Adafruit/Waveshare clones.
# If you see colored streaks, partial frames, or random blocks: drop to
# 32 MHz. If 48 looks clean, you can try 60-64 MHz for ~50 fps.
SPI_HZ=48000000
PANEL_WIDTH=264
PANEL_HEIGHT=240

BOOT_DIR="/boot/firmware"
CONFIG_TXT="${BOOT_DIR}/config.txt"

[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found -- is this Raspberry Pi OS Trixie?" >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy display setup"
echo "   DC=${DC_GPIO}  RESET=${RESET_GPIO} (hog)  FAKE_RESET=${FAKE_RESET_GPIO}"
echo "   SPI=${SPI_HZ}Hz  ${PANEL_WIDTH}x${PANEL_HEIGHT}"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Prerequisites
# ---------------------------------------------------------------------------
echo "[1/7] Installing packages..."
apt-get update -qq
apt-get install -y \
    device-tree-compiler \
    python3 \
    python3-spidev \
    python3-gpiozero \
    wget \
    ca-certificates \
    >/dev/null

# ---------------------------------------------------------------------------
# Step 2. Firmware blob (panel-mipi-dbi-spi.bin) -- required for driver probe
# ---------------------------------------------------------------------------
echo "[2/7] Building firmware blob..."

if [[ ! -x /usr/local/bin/mipi-dbi-cmd ]]; then
    wget -q -O /usr/local/bin/mipi-dbi-cmd \
        https://raw.githubusercontent.com/notro/panel-mipi-dbi/main/mipi-dbi-cmd
    chmod +x /usr/local/bin/mipi-dbi-cmd
fi
[[ -s /usr/local/bin/mipi-dbi-cmd ]] \
    || { echo "ERROR: mipi-dbi-cmd download produced empty file" >&2; exit 1; }

cat > /tmp/zega-init.txt <<'EOF'
command 0x01
delay 128
command 0xEF 0x03 0x80 0x02
command 0xCF 0x00 0xC1 0x30
command 0xED 0x64 0x03 0x12 0x81
command 0xE8 0x85 0x00 0x78
command 0xCB 0x39 0x2C 0x00 0x34 0x02
command 0xF7 0x20
command 0xEA 0x00 0x00
command 0xC0 0x23
command 0xC1 0x10
command 0xC5 0x3E 0x28
command 0xC7 0x86
command 0x36 0xE8
command 0x37 0x00
command 0x3A 0x55
command 0xB1 0x00 0x18
command 0xB6 0x08 0x82 0x27
command 0xF2 0x00
command 0x26 0x01
command 0xE0 0x0F 0x31 0x2B 0x0C 0x0E 0x08 0x4E 0xF1 0x37 0x07 0x10 0x03 0x0E 0x09 0x00
command 0xE1 0x00 0x0E 0x14 0x03 0x11 0x07 0x31 0xC1 0x48 0x08 0x0F 0x0C 0x31 0x36 0x0F
command 0x11
delay 120
command 0x29
delay 20
EOF

/usr/local/bin/mipi-dbi-cmd /lib/firmware/panel-mipi-dbi-spi.bin /tmp/zega-init.txt
[[ -s /lib/firmware/panel-mipi-dbi-spi.bin ]] \
    || { echo "ERROR: firmware blob is empty after compile" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 3. Reset-hog overlay (loaded by config.txt at boot)
# ---------------------------------------------------------------------------
echo "[3/7] Building reset-hog overlay..."

cat > /tmp/zega-reset-hog.dts <<EOF
/dts-v1/;
/plugin/;
/ {
    compatible = "brcm,bcm2835";
    fragment@0 {
        target = <&gpio>;
        __overlay__ {
            zega_reset_hog {
                gpio-hog;
                gpios = <${RESET_GPIO} 0>;
                output-high;
                line-name = "zega-panel-reset";
            };
        };
    };
};
EOF

dtc -@ -q -I dts -O dtb -o "${BOOT_DIR}/overlays/zega-reset-hog.dtbo" \
    /tmp/zega-reset-hog.dts

# ---------------------------------------------------------------------------
# Step 4. Panel overlay (loaded at runtime by zega-panel.service)
# ---------------------------------------------------------------------------
echo "[4/7] Building panel overlay..."

cat > /tmp/zega-panel-fakereset.dts <<EOF
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    fragment@0 {
        target = <&spidev0>;
        __overlay__ { status = "disabled"; };
    };

    fragment@1 {
        target = <&spi0>;
        __overlay__ {
            status = "okay";
            #address-cells = <1>;
            #size-cells = <0>;

            panel@0 {
                compatible = "panel-mipi-dbi-spi";
                reg = <0>;
                spi-max-frequency = <${SPI_HZ}>;
                label = "zega-ili9341";

                dc-gpios    = <&gpio ${DC_GPIO} 0>;
                reset-gpios = <&gpio ${FAKE_RESET_GPIO} 1>;

                width-mm  = <58>;
                height-mm = <43>;

                panel-timing {
                    hactive         = <${PANEL_WIDTH}>;
                    vactive         = <${PANEL_HEIGHT}>;
                    hback-porch     = <0>;
                    hfront-porch    = <0>;
                    hsync-len       = <0>;
                    vback-porch     = <0>;
                    vfront-porch    = <0>;
                    vsync-len       = <0>;
                    clock-frequency = <0>;
                };
            };
        };
    };
};
EOF

dtc -@ -q -I dts -O dtb -o "${BOOT_DIR}/overlays/zega-panel-fakereset.dtbo" \
    /tmp/zega-panel-fakereset.dts

# ---------------------------------------------------------------------------
# Step 5. Preinit script
# ---------------------------------------------------------------------------
echo "[5/7] Installing /usr/local/bin/zega-preinit..."

cat > /usr/local/bin/zega-preinit <<'EOF'
#!/usr/bin/env python3
"""Userspace ILI9341 init for the Zega Mame Boy panel.

Runs over /dev/spidev0.0 with DC on GPIO 22 and BL on GPIO 18. RESET (GPIO
27) is held high by a kernel pinctrl hog declared in zega-reset-hog.dtbo;
this script never touches it. Waits up to 5 seconds for the SPI device to
appear, then runs the panel's specific init sequence and paints black.
"""
import os, sys, time, spidev
from gpiozero import DigitalOutputDevice

DC_PIN = 22
SPI_HZ = 4_000_000
W, H = 320, 240

# Wait for /dev/spidev0.0 -- boot ordering between SPI controller probe
# and this service can race on slower SD cards.
for _ in range(50):
    if os.path.exists('/dev/spidev0.0'):
        break
    time.sleep(0.1)
else:
    sys.exit('ERROR: /dev/spidev0.0 did not appear within 5s')

dc = DigitalOutputDevice(DC_PIN, initial_value=False)

spi = spidev.SpiDev()
spi.open(0, 0)
spi.max_speed_hz = SPI_HZ
spi.mode = 0

def cmd(c, *p):
    dc.off(); spi.writebytes([c])
    if p: dc.on(); spi.writebytes(list(p))

cmd(0x01); time.sleep(0.128)
cmd(0xEF, 0x03, 0x80, 0x02)
cmd(0xCF, 0x00, 0xC1, 0x30)
cmd(0xED, 0x64, 0x03, 0x12, 0x81)
cmd(0xE8, 0x85, 0x00, 0x78)
cmd(0xCB, 0x39, 0x2C, 0x00, 0x34, 0x02)
cmd(0xF7, 0x20)
cmd(0xEA, 0x00, 0x00)
cmd(0xC0, 0x23)
cmd(0xC1, 0x10)
cmd(0xC5, 0x3E, 0x28)
cmd(0xC7, 0x86)
cmd(0x36, 0xE8)
cmd(0x37, 0x00)
cmd(0x3A, 0x55)
cmd(0xB1, 0x00, 0x18)
cmd(0xB6, 0x08, 0x82, 0x27)
cmd(0xF2, 0x00)
cmd(0x26, 0x01)
cmd(0xE0, 0x0F, 0x31, 0x2B, 0x0C, 0x0E, 0x08, 0x4E, 0xF1,
     0x37, 0x07, 0x10, 0x03, 0x0E, 0x09, 0x00)
cmd(0xE1, 0x00, 0x0E, 0x14, 0x03, 0x11, 0x07, 0x31, 0xC1,
     0x48, 0x08, 0x0F, 0x0C, 0x31, 0x36, 0x0F)
cmd(0x11); time.sleep(0.120)
cmd(0x29); time.sleep(0.020)

cmd(0x2A, 0x00, 0x00, (W - 1) >> 8, (W - 1) & 0xFF)
cmd(0x2B, 0x00, 0x00, (H - 1) >> 8, (H - 1) & 0xFF)
cmd(0x2C)
dc.on()
black = b'\x00\x00' * (W * H)
for i in range(0, len(black), 4096):
    spi.writebytes2(black[i:i + 4096])

spi.close()
EOF
chmod +x /usr/local/bin/zega-preinit

# Sanity check: script must parse as valid Python
python3 -c "import ast; ast.parse(open('/usr/local/bin/zega-preinit').read())" \
    || { echo "ERROR: zega-preinit has Python syntax errors" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 6. systemd units
# ---------------------------------------------------------------------------
echo "[6/7] Installing systemd units..."

# Resolve dtoverlay path (varies between Pi OS releases)
DTOVERLAY_BIN=$(command -v dtoverlay || true)
[[ -n "${DTOVERLAY_BIN}" ]] \
    || { echo "ERROR: dtoverlay command not found" >&2; exit 1; }

cat > /etc/systemd/system/zega-preinit.service <<EOF
[Unit]
Description=Zega Mame Boy ILI9341 userspace initialiser
After=systemd-modules-load.service
Before=zega-panel.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zega-preinit
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/zega-panel.service <<EOF
[Unit]
Description=Zega Mame Boy ILI9341 KMS overlay loader
After=zega-preinit.service
Requires=zega-preinit.service
Before=graphical.target

[Service]
Type=oneshot
ExecStart=${DTOVERLAY_BIN} zega-panel-fakereset
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zega-preinit.service >/dev/null 2>&1
systemctl enable zega-panel.service   >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Step 7. config.txt
# ---------------------------------------------------------------------------
echo "[7/7] Updating ${CONFIG_TXT}..."

[[ -f "${CONFIG_TXT}.zega.bak" ]] || cp "${CONFIG_TXT}" "${CONFIG_TXT}.zega.bak"

if ! grep -qE '^[[:space:]]*dtparam=spi=on' "${CONFIG_TXT}"; then
    echo 'dtparam=spi=on' >> "${CONFIG_TXT}"
fi

if ! grep -qE '^[[:space:]]*dtoverlay=zega-reset-hog' "${CONFIG_TXT}"; then
    cat >> "${CONFIG_TXT}" <<'EOF'

# Zega Mame Boy: kernel pinctrl hog keeps GPIO 27 high so panel RESET
# stays de-asserted across the userspace pre-init / driver-bind handoff.
dtoverlay=zega-reset-hog
EOF
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
echo
echo "Validation:"
for f in \
    /lib/firmware/panel-mipi-dbi-spi.bin \
    "${BOOT_DIR}/overlays/zega-reset-hog.dtbo" \
    "${BOOT_DIR}/overlays/zega-panel-fakereset.dtbo" \
    /usr/local/bin/zega-preinit \
    /etc/systemd/system/zega-preinit.service \
    /etc/systemd/system/zega-panel.service ; do
    if [[ -s "$f" ]]; then
        echo "  OK   $f"
    else
        echo "  FAIL $f"
    fi
done

grep -qE '^dtoverlay=zega-reset-hog' "${CONFIG_TXT}" \
    && echo "  OK   dtoverlay=zega-reset-hog in config.txt" \
    || echo "  FAIL dtoverlay=zega-reset-hog missing from config.txt"

systemctl is-enabled zega-preinit.service >/dev/null \
    && echo "  OK   zega-preinit.service enabled" \
    || echo "  FAIL zega-preinit.service not enabled"

systemctl is-enabled zega-panel.service >/dev/null \
    && echo "  OK   zega-panel.service enabled" \
    || echo "  FAIL zega-panel.service not enabled"

cat <<EOF

Done. Reboot to bring everything up:
  sudo reboot

After reboot, verify:
  sudo gpioinfo gpiochip0 | grep '\b${RESET_GPIO}\b'   # output, consumer "zega-panel-reset"
  systemctl status zega-preinit.service                # active (exited)
  systemctl status zega-panel.service                  # active (exited)
  ls /dev/dri/                                         # card0 and card1
  sudo modetest -D /dev/dri/card1                      # lists modes

Config backup: ${CONFIG_TXT}.zega.bak
EOF

