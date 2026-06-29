#!/usr/bin/env bash
###############################################################################
# pygame-shim.sh
#
# Installs the pygame libretro shim. Pygame .py files become first-class
# entries in RetroArch's game menu alongside emulator ROMs, with no
# separate launcher needed.
#
# Architecture:
#   1. pygame_shim_libretro.so is a tiny "fake core" — when RetroArch
#      asks it to run a .py file, it writes the path to
#      /tmp/zega-pygame-pending and tells RetroArch to shut down.
#   2. zega-retroarch-wrapper is a bash loop around RetroArch:
#      retroarch exits -> check pending file -> if present, run
#      python3 on it -> re-launch retroarch.
#   3. The wrapper is what retroarch.service ExecStart's, so to systemd
#      it looks like RetroArch is just always running.
#
# After install, drop .py files in ~student/roms/pygame/ and use RetroArch's
# Import Content -> Scan Directory to build a playlist. Selecting a .py
# entry runs it via python3, then drops back into RetroArch's menu.
###############################################################################

set -euo pipefail
trap 'echo; echo "ERROR: failed at line $LINENO. Last command: $BASH_COMMAND" >&2; exit 1' ERR

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

USER_NAME="student"
id "${USER_NAME}" >/dev/null 2>&1 \
    || { echo "ERROR: user '${USER_NAME}' does not exist." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${SCRIPT_DIR}/pygame_shim.c" ]] \
    || { echo "ERROR: pygame_shim.c not found next to pygame-shim.sh." >&2; exit 1; }

echo "============================================================"
echo " Zega pygame-libretro shim install"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# Step 1. Compiler + pygame runtime (skip apt failure if packages already OK).
# ---------------------------------------------------------------------------
echo "[1/5] Ensuring gcc and python3-pygame are installed..."

apt_install_if_missing() {
    local pkg="$1"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" || true
    dpkg -s "${pkg}" >/dev/null 2>&1
}

DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
apt_install_if_missing gcc           || { echo "ERROR: gcc install failed";          exit 1; }
apt_install_if_missing libc6-dev     || { echo "ERROR: libc6-dev install failed";    exit 1; }
apt_install_if_missing python3-pygame || { echo "ERROR: python3-pygame install failed"; exit 1; }

# ---------------------------------------------------------------------------
# Step 2. Compile the shim.
# ---------------------------------------------------------------------------
echo "[2/5] Compiling pygame_shim_libretro.so..."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cp "${SCRIPT_DIR}/pygame_shim.c" "${BUILD_DIR}/"
gcc -O2 -fPIC -Wall -Wextra -shared \
    -o "${BUILD_DIR}/pygame_shim_libretro.so" \
    "${BUILD_DIR}/pygame_shim.c"

install -d -m 0755 /usr/lib/libretro
install -m 0644 "${BUILD_DIR}/pygame_shim_libretro.so" /usr/lib/libretro/

# ---------------------------------------------------------------------------
# Step 3. RetroArch .info metadata so the scanner associates *.py with us.
# ---------------------------------------------------------------------------
echo "[3/5] Installing /usr/share/libretro/info/pygame_shim_libretro.info..."

install -d -m 0755 /usr/share/libretro/info
cat > /usr/share/libretro/info/pygame_shim_libretro.info <<'EOF'
display_name = "Pygame Shim (zega)"
authors = "zega"
supported_extensions = "py"
corename = "pygame-shim"
manufacturer = "zega"
categories = "Engine"
systemname = "Pygame"
systemid = "pygame"
license = "MIT"
display_version = "0.1"
notes = "Runs pygame .py games via python3; not a real emulator core."
EOF

# ---------------------------------------------------------------------------
# Step 4. The retroarch <-> python3 loop wrapper, plus the systemd unit
#         pointing at it (replacing the plain retroarch ExecStart).
# ---------------------------------------------------------------------------
echo "[4/5] Installing wrapper and systemd unit..."

cat > /usr/local/bin/zega-retroarch-wrapper <<'WRAP'
#!/usr/bin/env bash
# zega-retroarch-wrapper: loop RetroArch + pygame.
# - Launch RetroArch.
# - If on exit /tmp/zega-pygame-pending exists, the shim core asked us
#   to run a pygame; spawn the SELECT+START quit watcher alongside the
#   python process so the user can always return to RetroArch even if
#   the game forgets to handle the combo. Then loop.
# - If no pending file, the user really wanted to quit; exit.
#
# Games SHOULD also handle SELECT+START themselves (see hello.py for
# the pattern). The watcher is a safety net for forgetful games.

PENDING="/tmp/zega-pygame-pending"

pick_python() {
    local game="$1"
    local real gamedir
    real="$(readlink -f -- "$game")"     # follow symlinks for dev workflows
    gamedir="$(dirname -- "$real")"
    if   [[ -x "${gamedir}/.venv/bin/python"  ]]; then echo "${gamedir}/.venv/bin/python"
    elif [[ -x "${gamedir}/.venv/bin/python3" ]]; then echo "${gamedir}/.venv/bin/python3"
    else echo "python3"
    fi
}

start_watcher() {
    local target_pid="$1"
    nohup /usr/local/bin/zega-pygame-quit-watcher "${target_pid}" \
        >/dev/null 2>&1 &
    echo $!
}

while true; do
    rm -f "${PENDING}"
    /usr/bin/retroarch -f
    rc=$?
    if [[ -e "${PENDING}" ]]; then
        game="$(cat "${PENDING}")"
        rm -f "${PENDING}"
        if [[ -n "${game}" && -f "${game}" ]]; then
            py="$(pick_python "${game}")"
            echo "[zega-wrapper] running ${game} with ${py}"
            "${py}" "${game}" &
            game_pid=$!
            watcher_pid=$(start_watcher "${game_pid}")
            wait "${game_pid}" || echo "[zega-wrapper] pygame exited $?"
            kill "${watcher_pid}" 2>/dev/null
        fi
    else
        exit "${rc}"
    fi
done
WRAP
chmod +x /usr/local/bin/zega-retroarch-wrapper

# ---------------------------------------------------------------------------
# Step 4b. SELECT+START quit watcher — reads /dev/input/event0 (the
# kernel gpio-keys device exposed by buttons.sh), SIGTERMs the target
# pid when SELECT (KEY_RIGHTSHIFT, code 54) + START (KEY_ENTER, code 28)
# are held together. Exits automatically when target is gone.
#
# Has a 2-second startup delay + buffer drain so menu-launch button
# presses (the user pressing A to start the game, possibly still
# holding START as they navigated the menu) don't trigger an immediate
# quit. After the grace period the watcher only responds to fresh
# button events.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/zega-pygame-quit-watcher <<'WATCH'
#!/usr/bin/env python3
"""Watch gpio-keys for SELECT+START combo; SIGTERM the target on detection.

Usage: zega-pygame-quit-watcher <target_pid>

Reads /dev/input/event0 (the kernel gpio-keys device exposed by buttons.sh).
On detecting SELECT + START held simultaneously, sends SIGTERM to the given
PID. Also exits if the target dies on its own.
"""
import os
import signal
import struct
import sys
import time

KEY_RIGHTSHIFT = 54   # our SELECT button
KEY_ENTER      = 28   # our START button
EV_KEY         = 1
EVENT_FORMAT   = "llHHi"
EVENT_SIZE     = struct.calcsize(EVENT_FORMAT)
STARTUP_GRACE  = 2.0  # seconds — give user time to release menu buttons


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def drain(f):
    """Discard any buffered events accumulated during the startup grace."""
    while True:
        try:
            data = f.read(EVENT_SIZE)
        except BlockingIOError:
            return
        if not data:
            return


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: zega-pygame-quit-watcher <target_pid>")
    pid = int(sys.argv[1])

    # Sleep before opening so menu-launch keys are well in the past.
    time.sleep(STARTUP_GRACE)
    if not alive(pid):
        return

    try:
        f = open("/dev/input/event0", "rb")
    except OSError:
        sys.exit("could not open /dev/input/event0")
    os.set_blocking(f.fileno(), False)
    drain(f)

    held = {KEY_RIGHTSHIFT: False, KEY_ENTER: False}
    while alive(pid):
        try:
            data = f.read(EVENT_SIZE)
        except BlockingIOError:
            time.sleep(0.05)
            continue
        if not data or len(data) < EVENT_SIZE:
            time.sleep(0.05)
            continue
        _, _, t, code, value = struct.unpack(EVENT_FORMAT, data)
        if t == EV_KEY and code in held:
            held[code] = (value != 0)
            if all(held.values()):
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
                break


if __name__ == "__main__":
    main()
WATCH
chmod +x /usr/local/bin/zega-pygame-quit-watcher

cat > /etc/systemd/system/retroarch.service <<EOF
[Unit]
Description=RetroArch + pygame shim wrapper on tty1
After=systemd-user-sessions.service zega-panel.service
Wants=zega-panel.service
Conflicts=getty@tty1.service zega-launcher.service

[Service]
Type=simple
User=${USER_NAME}
Group=${USER_NAME}
ExecStart=/usr/local/bin/zega-retroarch-wrapper
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
systemctl disable zega-launcher.service 2>/dev/null || true
systemctl enable retroarch.service >/dev/null

# ---------------------------------------------------------------------------
# Step 5. Pre-create the pygame ROMs directory.
# ---------------------------------------------------------------------------
echo "[5/5] Creating /home/${USER_NAME}/roms/pygame/ ..."
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
    "/home/${USER_NAME}/roms" "/home/${USER_NAME}/roms/pygame"

# Drop a tiny example pygame game so the menu isn't empty on first boot.
if [[ ! -f "/home/${USER_NAME}/roms/pygame/hello.py" ]]; then
    cat > "/home/${USER_NAME}/roms/pygame/hello.py" <<'PY'
"""Hello world for the pygame shim.

Demonstrates the standard zega quit pattern: SELECT + START (held together)
returns the player to RetroArch's main menu. Single-button quits also work:
A button or ESC. Students writing their own games should include the
SELECT+START check so the device always has a reliable "back to menu" combo.
"""
import os, pygame
os.environ.setdefault("SDL_VIDEODRIVER", "kmsdrm")
pygame.init()
screen = pygame.display.set_mode((320, 240))
font = pygame.font.SysFont("monospace", 14, bold=True)
small = pygame.font.SysFont("monospace", 10)
clock = pygame.time.Clock()
running = True
while running:
    for ev in pygame.event.get():
        if ev.type == pygame.QUIT:
            running = False
        elif ev.type == pygame.KEYDOWN and ev.key in (pygame.K_x, pygame.K_ESCAPE):
            running = False
    # Standard zega quit pattern: SELECT + START held together.
    keys = pygame.key.get_pressed()
    if keys[pygame.K_RSHIFT] and keys[pygame.K_RETURN]:
        running = False
    screen.fill((20, 20, 40))
    screen.blit(font.render("hello, zega!", True, (255, 200, 80)), (60, 90))
    screen.blit(small.render("A to quit", True, (180, 180, 180)), (110, 130))
    screen.blit(small.render("or SELECT + START", True, (180, 180, 180)), (75, 150))
    pygame.display.flip()
    clock.tick(30)
pygame.quit()
PY
    chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/roms/pygame/hello.py"
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
echo
echo "Validation:"
[[ -s /usr/lib/libretro/pygame_shim_libretro.so ]] \
    && echo "  OK   /usr/lib/libretro/pygame_shim_libretro.so" \
    || echo "  FAIL /usr/lib/libretro/pygame_shim_libretro.so"
[[ -s /usr/share/libretro/info/pygame_shim_libretro.info ]] \
    && echo "  OK   /usr/share/libretro/info/pygame_shim_libretro.info" \
    || echo "  FAIL info file"
[[ -x /usr/local/bin/zega-retroarch-wrapper ]] \
    && echo "  OK   /usr/local/bin/zega-retroarch-wrapper" \
    || echo "  FAIL wrapper script"
[[ -s /etc/systemd/system/retroarch.service ]] \
    && echo "  OK   /etc/systemd/system/retroarch.service" \
    || echo "  FAIL retroarch.service"
systemctl is-enabled retroarch.service >/dev/null \
    && echo "  OK   retroarch.service enabled" \
    || echo "  FAIL retroarch.service not enabled"

cat <<EOF

Done. Reboot to launch into RetroArch:
  sudo reboot

On first boot, in RetroArch:
  1. Main Menu -> Online Updater -> Update Core Info Files
  2. Main Menu -> Import Content -> Scan Directory
     -> /home/${USER_NAME}/roms/pygame
  3. The "Pygame" playlist appears; hello.py is in it.
  4. Pick it -> RetroArch quits -> python3 runs the game -> press A
     -> python3 exits -> wrapper relaunches RetroArch -> back at the menu.

To add more games: drop .py files in /home/${USER_NAME}/roms/pygame/
and re-scan.

If RetroArch doesn't pick up the core, check:
  ls /usr/lib/libretro/pygame_shim_libretro.so
  ls /usr/share/libretro/info/pygame_shim_libretro.info
EOF
