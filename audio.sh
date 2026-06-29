#!/usr/bin/env bash
###############################################################################
# audio.sh
#
# Zega Mame Boy 2.7 audio setup over I2S0 (BCLK=GPIO 18, LRCLK=GPIO 19,
# DIN=GPIO 21). The audio chip lives on a separate carrier PCB, internally
# wired to GPIO 21 (PCM_DOUT) — it is not exposed on the U8 header.
#
# Usage:
#   sudo ./audio.sh                # default driver: hifiberry-dac
#   sudo ./audio.sh hifiberry-dac  # explicit
#   sudo ./audio.sh max98357a      # uses no-sdmode (avoids GPIO 4 / POWER OFF)
#
# Choice rationale:
#   hifiberry-dac  - PCM5102A DAC. Works fine for MAX98357A too because the
#                    I2S signaling is identical and these chips don't need
#                    driver-side control. This is what the vendor used.
#   max98357a      - Correct overlay if the chip is genuinely MAX98357A.
#                    With no-sdmode the driver does not claim SD_MODE.
#
# i2s-mmap is NOT installed — the overlay was removed in Trixie; the
# bcm2835 I2S driver exposes MMAP natively.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

CHIP="${1:-hifiberry-dac}"
case "$CHIP" in
    hifiberry-dac) OVERLAY_LINE="dtoverlay=hifiberry-dac"; CARD_HINT="sndrpihifiberry" ;;
    max98357a)     OVERLAY_LINE="dtoverlay=max98357a,no-sdmode"; CARD_HINT="MAX98357A" ;;
    *) echo "ERROR: chip must be 'hifiberry-dac' or 'max98357a'." >&2; exit 1 ;;
esac

BOOT_DIR="/boot/firmware"
CONFIG_TXT="${BOOT_DIR}/config.txt"
ASOUND_USER_FILE="/home/student/.asoundrc"

[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy audio setup (${CHIP})"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Backup config.txt (once)
# ---------------------------------------------------------------------------
echo "[1/5] Backing up ${CONFIG_TXT}..."
[[ -f "${CONFIG_TXT}.zega-audio.bak" ]] || cp "${CONFIG_TXT}" "${CONFIG_TXT}.zega-audio.bak"

# ---------------------------------------------------------------------------
# Step 2. Strip prior audio overlay attempts
# ---------------------------------------------------------------------------
echo "[2/5] Removing prior audio overlay attempts..."

sed -i -E '/^[[:space:]]*dtoverlay=(simple-audio-card|i2s-mmap|hifiberry-dac|max98357a)([,[:space:]]|$)/d' \
    "${CONFIG_TXT}"

# Drop our own previous Zega audio comment block too, so repeat runs don't
# accumulate stale comments.
sed -i '/^# Zega Mame Boy: /,/^$/{/^# Zega Mame Boy: \(MAX98357A\|hifiberry\|I2S\)/,/^$/d}' \
    "${CONFIG_TXT}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 3. Install the chosen overlay
# ---------------------------------------------------------------------------
echo "[3/5] Installing ${OVERLAY_LINE}..."

cat >> "${CONFIG_TXT}" <<EOF

# Zega Mame Boy: I2S audio (${CHIP}). The amp/DAC sits on the carrier PCB,
# wired internally to GPIO 21 (PCM_DOUT). i2s-mmap is not needed; the kernel
# I2S driver exposes MMAP natively on Trixie / kernel 6.x.
${OVERLAY_LINE}
EOF

# ---------------------------------------------------------------------------
# Step 4. .asoundrc — discover the actual card name if the overlay has
#         already been loaded, otherwise fall back to the predicted name.
# ---------------------------------------------------------------------------
echo "[4/5] Writing ${ASOUND_USER_FILE}..."

CARD_NAME="${CARD_HINT}"
if [[ -r /proc/asound/cards ]]; then
    # Find the simple-card we just installed (one line per card, format
    #   " N [shortname  ]: driver - longname").
    DETECTED=$(awk '/simple-card/ {gsub(/[][]/,"",$2); print $2; exit}' /proc/asound/cards || true)
    if [[ -n "${DETECTED}" ]]; then
        CARD_NAME="${DETECTED}"
        echo "       detected live card name: ${CARD_NAME}"
    else
        echo "       no I2S card live yet; using predicted name ${CARD_NAME}"
        echo "       (re-run this step after reboot if the prediction is wrong)"
    fi
fi

cat > "${ASOUND_USER_FILE}" <<EOF
# Default to the I2S audio card. Card name is stable across probe-order
# changes; card number is not, so do not use \`card 0\` here.
pcm.!default {
    type plug
    slave.pcm "hw:${CARD_NAME},0"
}

ctl.!default {
    type hw
    card ${CARD_NAME}
}
EOF
chown student:student "${ASOUND_USER_FILE}"

# ---------------------------------------------------------------------------
# Step 5. For hifiberry-dac (PCM5102A) the "Digital" PCM control defaults
#         to muted on some images. Unmute and set to 100% if the control
#         exists and the card is already live. For max98357a there are no
#         mixer controls so this is a no-op.
# ---------------------------------------------------------------------------
echo "[5/5] Unmuting PCM (if applicable)..."
if amixer -c "${CARD_NAME}" scontrols 2>/dev/null | grep -q .; then
    amixer -c "${CARD_NAME}" sset 'Digital' 100% unmute 2>/dev/null || true
    amixer -c "${CARD_NAME}" sset 'PCM'     100% unmute 2>/dev/null || true
    alsactl store 2>/dev/null || true
    echo "       mixer state stored"
else
    echo "       no live mixer controls (expected for max98357a, or card not loaded yet)"
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
if grep -qE "^${OVERLAY_LINE//,/\\,}\$" "${CONFIG_TXT}"; then
    echo "  OK   ${OVERLAY_LINE} present in config.txt"
else
    echo "  FAIL ${OVERLAY_LINE} missing"
fi
[[ -s "${ASOUND_USER_FILE}" ]] \
    && echo "  OK   ${ASOUND_USER_FILE} (slave card: ${CARD_NAME})" \
    || echo "  FAIL ${ASOUND_USER_FILE}"

cat <<EOF

Done. Reboot to activate:
  sudo reboot

After reboot, verify:
  cat /proc/asound/cards                                        # confirm card name
  speaker-test -c 2 -r 44100 -F S16_LE -t sine -f 440 -l 1      # 2-sec test tone
  aplay ~/hello.wav                                             # plays via default

If the card name in /proc/asound/cards differs from "${CARD_NAME}", re-run
this script to refresh ${ASOUND_USER_FILE} with the detected name.

Config backup: ${CONFIG_TXT}.zega-audio.bak
EOF
