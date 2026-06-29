#!/usr/bin/env bash
###############################################################################
# firstrun.sh
#
# Installs a generic "drop-and-go" boot-time script runner. After install,
# any *.sh file you drop into /boot/firmware/firstrun/ is executed once
# on the next boot, in lexical order, then archived so it doesn't re-run.
#
# Mechanism:
#   - /usr/local/bin/zega-firstrun walks /boot/firmware/firstrun/, runs each
#     .sh in sorted order with bash, and on success moves it to
#     /boot/firmware/firstrun-done/<name>.<timestamp>.sh.
#   - Failed scripts are LEFT in firstrun/ so you can fix them and reboot.
#   - The systemd unit zega-firstrun.service runs the walker once per boot.
#
# Use cases:
#   - Drop display.sh, audio.sh, buttons.sh into /boot/firmware/firstrun/ on
#     a fresh SD card; boot once; the device sets itself up unattended.
#   - Stage one-off ops scripts to run on next reboot of a remote device
#     without scheduling them yourself.
#
# Boot partition is FAT32 — you can stage scripts from any computer by
# mounting the SD card, no SSH needed for the first boot.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BOOT_DIR="/boot/firmware"
[[ -d "${BOOT_DIR}" ]] || { echo "${BOOT_DIR} not found." >&2; exit 1; }

echo "============================================================"
echo " Zega Mame Boy first-run / drop-and-go script runner"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. /usr/local/bin/zega-firstrun — walks the directory.
# ---------------------------------------------------------------------------
echo "[1/3] Installing /usr/local/bin/zega-firstrun..."

cat > /usr/local/bin/zega-firstrun <<'EOF'
#!/usr/bin/env bash
# Run every *.sh in /boot/firmware/firstrun/ once, in lexical order.
# Archive successes; leave failures for retry on the next boot.

set -uo pipefail

RUN_DIR="/boot/firmware/firstrun"
DONE_DIR="/boot/firmware/firstrun-done"

# If the directory is missing we silently do nothing — this lets the
# service be left enabled even when there's nothing to run.
[[ -d "${RUN_DIR}" ]] || exit 0

mkdir -p "${DONE_DIR}"

shopt -s nullglob
scripts=("${RUN_DIR}"/*.sh)
[[ ${#scripts[@]} -eq 0 ]] && exit 0

# Sort for deterministic ordering — name your scripts 01-foo.sh, 02-bar.sh
# if order matters.
IFS=$'\n' scripts=($(printf '%s\n' "${scripts[@]}" | sort))

for script in "${scripts[@]}"; do
    name="$(basename "${script}")"
    echo "[zega-firstrun] running ${name}"
    if bash "${script}"; then
        ts="$(date +%Y%m%d-%H%M%S)"
        mv "${script}" "${DONE_DIR}/${name%.sh}.${ts}.sh"
        echo "[zega-firstrun] OK ${name} -> firstrun-done/"
    else
        echo "[zega-firstrun] FAIL ${name} (left in firstrun/ for retry)" >&2
    fi
done
EOF
chmod +x /usr/local/bin/zega-firstrun
bash -n /usr/local/bin/zega-firstrun \
    || { echo "ERROR: zega-firstrun has syntax errors" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 2. systemd unit.
#
# Runs After multi-user.target so apt, networking etc. are available — the
# user's scripts likely need apt and possibly NetworkManager.
# ---------------------------------------------------------------------------
echo "[2/3] Installing /etc/systemd/system/zega-firstrun.service..."

cat > /etc/systemd/system/zega-firstrun.service <<'EOF'
[Unit]
Description=Run scripts staged in /boot/firmware/firstrun/
After=multi-user.target network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zega-firstrun
RemainAfterExit=no
StandardOutput=journal
StandardError=journal
# Don't mark boot degraded if a user script returns non-zero — the
# walker keeps the file around for retry, that's the recovery path.
SuccessExitStatus=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zega-firstrun.service >/dev/null

# ---------------------------------------------------------------------------
# Step 3. Pre-create the drop directory so it's visible immediately.
# ---------------------------------------------------------------------------
echo "[3/3] Creating ${BOOT_DIR}/firstrun/ ..."
mkdir -p "${BOOT_DIR}/firstrun" "${BOOT_DIR}/firstrun-done"

# Drop a README into the firstrun directory.
cat > "${BOOT_DIR}/firstrun/README.txt" <<'EOF'
Drop *.sh files in this directory to have them run once on the next boot.

Order:    lexical. Name them 01-foo.sh, 02-bar.sh if order matters.
Failure:  scripts that exit non-zero are LEFT here for retry on next boot.
Success:  successful scripts are moved to firstrun-done/<name>.<timestamp>.sh.
Logs:     journalctl -u zega-firstrun.service --no-pager

This README is ignored (only *.sh files run). Delete it if you like.
EOF

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
[[ -x /usr/local/bin/zega-firstrun ]] \
    && echo "  OK   /usr/local/bin/zega-firstrun" \
    || echo "  FAIL /usr/local/bin/zega-firstrun"
[[ -s /etc/systemd/system/zega-firstrun.service ]] \
    && echo "  OK   /etc/systemd/system/zega-firstrun.service" \
    || echo "  FAIL /etc/systemd/system/zega-firstrun.service"
systemctl is-enabled zega-firstrun.service >/dev/null \
    && echo "  OK   zega-firstrun.service enabled" \
    || echo "  FAIL zega-firstrun.service not enabled"
[[ -d "${BOOT_DIR}/firstrun" ]] \
    && echo "  OK   ${BOOT_DIR}/firstrun/ created" \
    || echo "  FAIL ${BOOT_DIR}/firstrun/ missing"

cat <<EOF

Done. Drop *.sh files in ${BOOT_DIR}/firstrun/ and reboot; they'll run
once and get archived to ${BOOT_DIR}/firstrun-done/ on success.

To stage a fresh install end-to-end on a new SD card:
  cp display.sh   ${BOOT_DIR}/firstrun/01-display.sh
  cp audio.sh     ${BOOT_DIR}/firstrun/02-audio.sh
  cp buttons.sh   ${BOOT_DIR}/firstrun/03-buttons.sh
  cp retroarch.sh ${BOOT_DIR}/firstrun/04-retroarch.sh
  reboot

Watch progress with:
  journalctl -u zega-firstrun.service -f
EOF
