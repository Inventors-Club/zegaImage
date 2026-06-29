#!/usr/bin/env bash
###############################################################################
# buttons.sh
#
# Zega Mame Boy 2.7 button input setup. Generates and installs a custom
# gpio-keys device-tree overlay that maps each face/action/shoulder/d-pad
# button to a Linux KEY_* code, producing a real /dev/input/eventN device.
# RetroArch picks this up natively via its keyboard input driver, no
# userspace daemon required (no retrogame.cfg, no polling).
#
# All buttons are active-low with internal pull-up enabled; the physical
# wiring shorts the GPIO to GND when the button is pressed.
#
# Also installs the upstream gpio-shutdown / gpio-poweroff overlays for
# the dedicated SHUTDOWN (GPIO 3) and POWER OFF (GPIO 4) pins, so the
# device powers off cleanly when the corresponding button is held.
#
# Button-to-GPIO map (Zega 2.7, physical pin in parens):
#   R1=GPIO 2 (pin 3)         L1=GPIO 5 (pin 29)
#   SELECT=GPIO 6 (pin 31)    X=GPIO 12 (pin 32)
#   START=GPIO 13 (pin 33)    B=GPIO 16 (pin 36)
#   LEFT=GPIO 17 (pin 11)     Y=GPIO 20 (pin 38)
#   DOWN=GPIO 23 (pin 16)     RIGHT=GPIO 24 (pin 18)
#   UP=GPIO 25 (pin 22)       A=GPIO 26 (pin 37)
#
# KEY codes are hardcoded integers (from linux/input-event-codes.h) to
# avoid pulling in the kernel headers just for symbolic names.
#
# Run as root, then reboot.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BOOT_DIR="/boot/firmware"
CONFIG_TXT="${BOOT_DIR}/config.txt"
OVERLAY_DIR="${BOOT_DIR}/overlays"

[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found." >&2; exit 1; }
command -v dtc >/dev/null || { echo "dtc not found. Run display.sh first (it installs device-tree-compiler)." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy buttons setup (gpio-keys + shutdown/poweroff)"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Generate the gpio-keys DTS and compile to dtbo.
# Integer KEY codes per linux/input-event-codes.h:
#   KEY_Q=16  KEY_W=17  KEY_A=30  KEY_S=31  KEY_Z=44  KEY_X=45
#   KEY_ENTER=28  KEY_RIGHTSHIFT=54
#   KEY_UP=103  KEY_LEFT=105  KEY_RIGHT=106  KEY_DOWN=108
# ---------------------------------------------------------------------------
echo "[1/3] Building zega-buttons overlay..."

cat > /tmp/zega-buttons.dts <<'EOF'
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    /* Release GPIO 20 from the global I2S pinctrl group. The base SoC dtsi
     * declares &i2s_pins = <18 19 20 21>, but PCM_DIN (20) is never used
     * (we only output audio); meanwhile the Zega 2.7 wires the Y button to
     * GPIO 20. Without this override, the I2S driver claims pin 20 first,
     * gpio-keys fails to bind, and ALL buttons are reverted by the kernel.
     * After this fragment runs, I2S sees only <18 19 21> and Y is free. */
    fragment@0 {
        target = <&i2s_pins>;
        __overlay__ {
            brcm,pins = <18 19 21>;
        };
    };

    /* Pinctrl group: set all button GPIOs to input with pull-up so the
     * gpio-keys driver sees them idle high when unpressed. Without this,
     * lines float and the kernel reports stuck-pressed buttons (e.g.
     * UP autorepeats into the local console). brcm,pull: 0=none 1=down 2=up. */
    fragment@1 {
        target = <&gpio>;
        __overlay__ {
            zega_btn_pins: zega-btn-pins {
                brcm,pins     = <2 5 6 12 13 16 17 20 23 24 25 26>;
                brcm,function = <0>;
                brcm,pull     = <2>;
            };
        };
    };

    fragment@2 {
        target-path = "/";
        __overlay__ {
            zega_buttons: zega-buttons {
                compatible = "gpio-keys";
                pinctrl-names = "default";
                pinctrl-0     = <&zega_btn_pins>;
                #address-cells = <1>;
                #size-cells = <0>;
                autorepeat;

                /* D-pad — arrow keys */
                up      { label = "UP";     gpios = <&gpio 25 1>; linux,code = <103>; debounce-interval = <20>; };
                down    { label = "DOWN";   gpios = <&gpio 23 1>; linux,code = <108>; debounce-interval = <20>; };
                left    { label = "LEFT";   gpios = <&gpio 17 1>; linux,code = <105>; debounce-interval = <20>; };
                right   { label = "RIGHT";  gpios = <&gpio 24 1>; linux,code = <106>; debounce-interval = <20>; };

                /* Face buttons (physical layout: Y X / B A). RetroArch
                 * keyboard defaults map A=KEY_X, B=KEY_Z, X=KEY_S, Y=KEY_A.
                 * GPIO assignments per physical labels (verified by user 2026-05-27):
                 *   A=26, B=16, X=12, Y=20.
                 * NB: vendor's /boot/retrogame.cfg comments labeled buttons by
                 * emulator-ACTION name, not physical label — their "A button"
                 * = action A = KEY_Z, which is the PHYSICAL B in their setup.
                 * The pinout-image labels are authoritative for physical IDs. */
                btn_a   { label = "A";      gpios = <&gpio 26 1>; linux,code = < 45>; debounce-interval = <20>; };
                btn_b   { label = "B";      gpios = <&gpio 16 1>; linux,code = < 44>; debounce-interval = <20>; };
                btn_x   { label = "X";      gpios = <&gpio 12 1>; linux,code = < 31>; debounce-interval = <20>; };
                btn_y   { label = "Y";      gpios = <&gpio 20 1>; linux,code = < 30>; debounce-interval = <20>; };

                /* Shoulders — may not be externally exposed but wired through. */
                btn_l1  { label = "L1";     gpios = <&gpio  5 1>; linux,code = < 16>; debounce-interval = <20>; };
                btn_r1  { label = "R1";     gpios = <&gpio  2 1>; linux,code = < 17>; debounce-interval = <20>; };

                /* Menu */
                btn_start  { label = "START";  gpios = <&gpio 13 1>; linux,code = < 28>; debounce-interval = <20>; };
                btn_select { label = "SELECT"; gpios = <&gpio  6 1>; linux,code = < 54>; debounce-interval = <20>; };
            };
        };
    };
};
EOF

dtc -@ -q -I dts -O dtb -o "${OVERLAY_DIR}/zega-buttons.dtbo" /tmp/zega-buttons.dts

[[ -s "${OVERLAY_DIR}/zega-buttons.dtbo" ]] \
    || { echo "ERROR: zega-buttons.dtbo is empty after compile" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 2. Strip any prior Zega button / shutdown / poweroff entries, then
#         append fresh ones.
# ---------------------------------------------------------------------------
echo "[2/3] Patching ${CONFIG_TXT}..."

[[ -f "${CONFIG_TXT}.zega-buttons.bak" ]] || cp "${CONFIG_TXT}" "${CONFIG_TXT}.zega-buttons.bak"

sed -i -E '/^[[:space:]]*dtoverlay=(zega-buttons|gpio-shutdown|gpio-poweroff)([,[:space:]]|$)/d' "${CONFIG_TXT}"

cat >> "${CONFIG_TXT}" <<'EOF'

# Zega Mame Boy: gpio-keys overlay for the 12 face/action/shoulder/d-pad
# buttons. Active-low with internal pull-up; pressed = pin to GND.
dtoverlay=zega-buttons

# SHUTDOWN button (GPIO 3, U8 pin 5): hold for systemd-initiated shutdown.
dtoverlay=gpio-shutdown,gpio_pin=3

# POWER OFF (GPIO 4, U8 pin 7): cuts power once shutdown reaches "off".
dtoverlay=gpio-poweroff,gpiopin=4
EOF

# ---------------------------------------------------------------------------
# Step 3. Validation summary.
# ---------------------------------------------------------------------------
echo "[3/3] Validation:"
for f in "${OVERLAY_DIR}/zega-buttons.dtbo" "${OVERLAY_DIR}/gpio-shutdown.dtbo" "${OVERLAY_DIR}/gpio-poweroff.dtbo"; do
    [[ -s "$f" ]] && echo "  OK   $(basename "$f")" || echo "  FAIL $(basename "$f")"
done
grep -qE '^dtoverlay=zega-buttons$'             "${CONFIG_TXT}" && echo "  OK   dtoverlay=zega-buttons"             || echo "  FAIL dtoverlay=zega-buttons"
grep -qE '^dtoverlay=gpio-shutdown,gpio_pin=3$' "${CONFIG_TXT}" && echo "  OK   dtoverlay=gpio-shutdown,gpio_pin=3" || echo "  FAIL dtoverlay=gpio-shutdown,gpio_pin=3"
grep -qE '^dtoverlay=gpio-poweroff,gpiopin=4$'  "${CONFIG_TXT}" && echo "  OK   dtoverlay=gpio-poweroff,gpiopin=4"  || echo "  FAIL dtoverlay=gpio-poweroff,gpiopin=4"

cat <<EOF

Done. Reboot to activate:
  sudo reboot

After reboot, verify:
  cat /proc/bus/input/devices            # expect a "zega-buttons" entry
  ls /dev/input/                         # event<N> for the new keyboard
  sudo evtest                            # interactive: pick the device, press buttons

Config backup: ${CONFIG_TXT}.zega-buttons.bak
EOF
