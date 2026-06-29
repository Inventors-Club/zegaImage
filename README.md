# Zega Mame Boy 2.7 — Pi setup scripts

Setup for the Zega Mame Boy 2.7 handheld running **Raspberry Pi OS Trixie Lite**
on a **Pi Zero 2 W** (BCM2837, kernel 6.12.x). Three idempotent scripts handle
display, audio, and buttons end to end.

## Install order

Run each as root, reboot in between if you want to verify a layer before
moving on (or run all three then reboot once at the end).

```
sudo ./display.sh        # ILI9341 SPI panel via kernel KMS (panel-mipi-dbi-spi)
sudo ./audio.sh          # I2S audio (defaults to hifiberry-dac; pass max98357a to override)
sudo ./buttons.sh        # gpio-keys overlay for 12 buttons + shutdown/poweroff
sudo ./retroarch.sh      # auto-launch RetroArch on tty1 (kiosk mode)
sudo ./pygame-shim.sh    # libretro shim so pygame games appear in RetroArch's menu
sudo ./firstrun.sh       # generic /boot/firmware/firstrun/*.sh runner (optional)
sudo reboot
```

`launcher.sh` (pygame-menu replacement for RetroArch) is kept in the
repo as an option but **superseded by `pygame-shim.sh`** — the shim
approach uses RetroArch as the single frontend with pygame games as
first-class menu entries, so there's nothing custom to maintain on the
UI side.

`wifi.sh` is superseded by Pi OS's native NetworkManager + `rpi-imager`
provisioning; kept in the repo as a fallback for headless setups without
an imager option.

Each script writes a `*.zega-*.bak` copy of `config.txt` before its first
modification so you can roll back.

## Hardware

- SoC: BCM2837 (Pi Zero 2 W). The Zega `[cm5]` config block in `config.txt`
  is unused — this is a Zero 2 W carrier, not a CM5.
- Pinctrl driver: `pinctrl-bcm2835` on `gpiochip0` (54 lines).
- U8 connector: **1:1 with the standard Pi 40-pin header** (verified against
  vendor `config.txt` and PCB silkscreen labels for the audio pins).

### Pin map (BCM GPIO ↔ U8 physical pin ↔ function)

| Function | GPIO | U8 pin |
|---|---|---|
| SHUTDOWN button | 3 | 5 |
| POWER OFF rail | 4 | 7 |
| ACT LED | 15 | 10 |
| I2S BCLK | 18 | 12 |
| I2S LRCLK | 19 | 35 |
| I2S DOUT | 21 | (carrier internal) |
| SPI0 MOSI / panel | 10 | 19 |
| SPI0 MISO (unused) | 9 | 21 |
| SPI0 SCLK / panel | 11 | 23 |
| SPI0 CE0 / panel | 8 | 24 |
| Panel DC | 22 | 15 |
| Panel RESET (real) | 27 | 13 |
| Panel RESET (fake, kernel binding) | 1 | 28 (unwired on U8) |
| R1 | 2 | 3 |
| L1 | 5 | 29 |
| SELECT | 6 | 31 |
| X | 12 | 32 |
| START | 13 | 33 |
| B | 16 | 36 |
| LEFT | 17 | 11 |
| Y | 20 | 38 |
| DOWN | 23 | 16 |
| RIGHT | 24 | 18 |
| UP | 25 | 22 |
| A | 26 | 37 |

## What each script does

### `display.sh` — ILI9341 panel via kernel KMS

- Compiles a one-line **`zega-reset-hog`** overlay so the kernel pinctrl
  holds GPIO 27 (real RESET) high across the userspace-init / driver-bind
  handoff.
- Runs a Python **pre-init** (`/usr/local/bin/zega-preinit`) over
  `/dev/spidev0.0` that ships the panel's specific init sequence and
  paints black. This is what survives the kernel driver later toggling
  what it *thinks* is the reset pin.
- Compiles **`zega-panel-fakereset`** which binds `panel-mipi-dbi-spi` on
  SPI0 with `reset-gpios = <&gpio 1 1>` — GPIO 1 (ID_SCL) is not routed
  on U8, so the driver toggling it is a no-op. `FAKE_RESET_GPIO` was 26
  originally but collided with the A button; moved to 1.
- Writes the panel init blob to `/lib/firmware/panel-mipi-dbi-spi.bin`
  (built with Notro's `mipi-dbi-cmd`).
- Two systemd units: `zega-preinit.service` (oneshot, the Python init)
  and `zega-panel.service` (oneshot, runs `dtoverlay zega-panel-fakereset`
  after preinit).
- Adds `dtparam=spi=on` and `dtoverlay=zega-reset-hog` to `config.txt`.

**Note:** the `fbcon=map:N` directive in cmdline.txt should NOT be set —
modern KMS gives the console to the primary connector automatically.
Adding `fbcon=map:1` actually broke things when HDMI was plugged in
(probe order shifted, console landed on HDMI).

Verify after reboot:

```
ls /dev/dri/                             # card0 (panel) + card1 (HDMI)
gpioinfo | grep -E 'GPIO(22|27|1)\b'     # GPIO 22=dc, 27=zega-panel-reset, 1=reset
systemctl status zega-{preinit,panel}.service
```

### `audio.sh` — I2S MAX98357A or PCM5102A

Accepts a single arg:

- `sudo ./audio.sh hifiberry-dac` (default) — `dtoverlay=hifiberry-dac`,
  the vendor's proven recipe. Works for both PCM5102A DACs and MAX98357A
  amps since I2S framing is identical and neither chip needs driver
  control.
- `sudo ./audio.sh max98357a` — `dtoverlay=max98357a,no-sdmode`. The
  `no-sdmode` flag stops the driver from claiming its default sdmode-pin
  (GPIO 4) — which on the Zega is the POWER OFF button.

Writes `~student/.asoundrc` that addresses the card by *name* (auto-detected
post-install), not number — survives probe-order shifts vs HDMI audio.

Also strips:
- `dtparam=audio=on` if encountered? — no, **leave it commented**.
  Enabling the BCM2835 analog driver alongside I2S can starve the I2S
  clock peripheral (per Adafruit's i2samp.py recipe).
- Any prior `dtoverlay=(simple-audio-card|i2s-mmap|hifiberry-dac|max98357a)`
  lines so re-runs don't accumulate.

`i2s-mmap` is **not** installed — overlay was removed in Trixie because
the bcm2835 I2S driver exposes MMAP natively now.

**Known issue (2026-05-26): audio is broken at the hardware level
(U5 amp chip).**

### Chip identity correction

The driver name `pcm5102a-hifi-0` shown by `aplay -l` is misleading — it's
just what the `hifiberry-dac` overlay names its simple-audio-card config.
The actual silicon is **U5** on the audio PCB, marked `AKK NSO +`. It
takes the three I2S lines (BCLK/LRCLK/DOUT) as input **and** drives
SPKR+/SPKR- directly — i.e. it's an **I2S-input class-D speaker amp**
(MAX98357A or clone equivalent), not a PCM5102A DAC. There's no separate
DAC; U5 does the I2S→analog conversion and amplification in one package.
`hifiberry-dac` and `max98357a` overlays both work because they generate
the same I2S framing.

### Diagnostic progression

- **Pre-cleanup**: pop-on-transition only, no sustained output.
- **After physical cleanup of interconnects**: chip now produces
  continuous output, but on a 1 kHz sine the output is *noise* with
  8-bit-like quantization texture, not the tone.
- **Software ruled out**: with PCM softvol at 0% (signal scaled to
  silence) AND with `/dev/zero` fed directly to `hw:0,0`, the noise
  persists. Software is sending silence; chip outputs noise anyway.
  Vendor's own working Buster image fails the same way on this
  hardware. The signal chain is correct; U5's analog output stage is
  the issue.
- **Wiggle test**: pressing U5 dampens the noise slightly; light touch
  on R5 (31Ω, in U5's output path) injects mains hum. Firm steady
  pressure on R5 does NOT change the noise. That pattern means R5 is
  on a high-impedance node — i.e. U5 isn't driving it solidly. The
  amp's output stage is either damaged or has a marginal joint on a
  power / shutdown / gain pin.

### Next physical action

1. **Reflow U5's pins**. Flux + clean iron, touch each pin for ~1 sec
   to reheat the existing solder. Power pins (VDD/GND, usually opposite
   corners on an 8-pin SOIC) are the prime suspects. Free, takes a
   minute. If a marginal power joint is the cause, this fixes it.
2. **If reflow doesn't help → replace U5**. The silicon output stage
   is damaged. Genuine MAX98357A is cheap (~£3) but the chip on the
   Zega is a clone with non-standard markings. Sourcing a drop-in
   replacement may require trial-and-error.

See `vendor/bash_history.txt` for the vendor's original working recipe
(`i2samp.sh` → `alsamixer` → manual `nano /boot/config.txt`).

### `retroarch.sh` — RetroArch auto-launch (kiosk)

Installs the `retroarch` package and a `retroarch.service` systemd unit
that runs on tty1 as user `student`. The unit `Conflicts=getty@tty1.service`
so systemd stops the login prompt on tty1 when RetroArch starts (you
still get login on tty2-6 via Ctrl+Alt+F2). `Restart=on-failure` brings
RetroArch back if it crashes; `systemctl stop retroarch` returns a
console on tty1. The user is added to `video,input,audio,render` groups
so RetroArch can open `/dev/dri/*`, `/dev/input/event*`, `/dev/snd/*`
without root.

Pygame games are NOT runnable as libretro cores (cores are libretro-API
C shared libraries; pygame is a standalone Python process). The pragmatic
pattern is a launcher menu that `subprocess.Popen()`s either `retroarch`
or `python game.py` as appropriate. EmulationStation does this if you
want it ready-made.

### `launcher.sh` — pygame menu (wraps RetroArch + pygame apps + shell)

A small pygame launcher that boots on tty1 (replacing `retroarch.service`
as the boot target). Reads `~student/launcher.toml` for entries grouped by
category; the D-pad navigates, A launches, B/SELECT reserved for back/
sub-menu later. Each entry's command is `subprocess.run`'d; pygame
releases the panel before exec'ing so RetroArch / a pygame game / a
shell command can take over the KMS connector cleanly, and re-claims
the panel when the child exits.

Why custom instead of attract-mode / Pegasus / ES-DE: at 320×240 on a
Pi Zero 2 W, the prebuilt frontends are all wrong-sized, too heavy on
the GPU, or both. The custom launcher is ~250 lines, fits the panel
exactly, and runs natively against the same SDL/evdev path the rest
of the system uses.

Sample `launcher.toml` is seeded on install with system entries
(RetroArch, Reboot, Shutdown). Add emulator entries with
`["retroarch","-f","-L","/usr/lib/libretro/<core>.so","<rom>"]` and
pygame entries with `["python3","/path/to/app.py"]`.

Installs `python3-pygame`, adds NOPASSWD sudo on `/sbin/reboot` and
`/sbin/poweroff` for user `student` so the menu's system entries work
without prompting.

To edit the menu after install:

```
$EDITOR ~/launcher.toml
sudo systemctl restart zega-launcher.service
```

### `firstrun.sh` — drop-and-go boot-time script runner

Installs `/usr/local/bin/zega-firstrun` + a `zega-firstrun.service`
systemd unit that scans `/boot/firmware/firstrun/` for `*.sh` files on
each boot and runs them once. Successful scripts are archived to
`/boot/firmware/firstrun-done/<name>.<timestamp>.sh`; failed scripts are
left in place to retry next boot. Lexical ordering — prefix `01-`, `02-`
etc. if order matters.

This is the mechanism for "run arbitrary scripts at boot from a file
dropped on the FAT32 partition" — same shape as `wifi.txt` but for full
scripts. End-to-end fresh-SD bootstrap:

```
# After flashing fresh Trixie and mounting the SD card on any computer:
mount /dev/sdX1 /mnt/boot           # adjust device name
mkdir -p /mnt/boot/firstrun
cp display.sh   /mnt/boot/firstrun/01-display.sh
cp audio.sh     /mnt/boot/firstrun/02-audio.sh
cp buttons.sh   /mnt/boot/firstrun/03-buttons.sh
cp retroarch.sh /mnt/boot/firstrun/04-retroarch.sh
umount /mnt/boot
# boot the Pi — scripts run in order, then archive themselves.
```

Catch: `firstrun.sh` itself has to be installed first (the systemd unit
needs to exist before it can run anything). Two ways:
1. One-time SSH bootstrap: SSH in once and `sudo ./firstrun.sh`. Done.
2. Bake `firstrun.sh` into a custom Pi OS image, then it's truly
   zero-touch. Worth it only if you're flashing many devices.

### `wifi.sh` — boot-time wifi provisioning (deprecated)

Installs `/usr/local/bin/zega-wifi-init` + a `zega-wifi-init.service`
oneshot that runs after `NetworkManager.service`. On each boot:

1. If `/boot/firmware/wifi.txt` doesn't exist, it's created with a template
   so the user can find and edit it.
2. If both `SSID=` and `PSK=` are set, `nmcli device wifi connect` is
   attempted.
3. On success, the file is overwritten with the empty template — the
   plaintext credentials don't sit on the SD card after first use.
4. On failure, the file is left untouched so the user can correct the
   values and reboot to retry.

The boot partition is FAT32, so `wifi.txt` can be edited by mounting the
SD card on any computer — no SSH or terminal needed for first-time
provisioning. The service is conservative: it does nothing if the file
is in its empty-template state, so re-runs are harmless.

To verify or re-provision manually:

```
sudo /usr/local/bin/zega-wifi-init
journalctl -u zega-wifi-init.service --no-pager
```

### `buttons.sh` — gpio-keys + shutdown/poweroff

Compiles a custom **`zega-buttons.dtbo`** declaring a `gpio-keys` node
with all 12 face/action/shoulder/d-pad buttons. Active-low, debounce 20 ms.
Hardcoded integer KEY codes (no kernel header dependency):

| Button | GPIO | KEY_* | Code | RetroArch default |
|---|---|---|---|---|
| UP | 25 | KEY_UP | 103 | D-pad ↑ |
| DOWN | 23 | KEY_DOWN | 108 | D-pad ↓ |
| LEFT | 17 | KEY_LEFT | 105 | D-pad ← |
| RIGHT | 24 | KEY_RIGHT | 106 | D-pad → |
| A | 26 | KEY_X | 45 | action A |
| B | 16 | KEY_Z | 44 | action B |
| X | 12 | KEY_S | 31 | action X |
| Y | 20 | KEY_A | 30 | action Y |

> ⚠️ The vendor's `/boot/retrogame.cfg` comments label buttons by emulator
> *action* name, not physical label. Their `# 'A' button` entry corresponds
> to the physical B button in their setup (because the vendor remapped the
> emulator). Always trust the **pinout-image labels** for physical IDs.
| L1 | 5 | KEY_Q | 16 | shoulder L |
| R1 | 2 | KEY_W | 17 | shoulder R |
| START | 13 | KEY_ENTER | 28 | start |
| SELECT | 6 | KEY_RIGHTSHIFT | 54 | select |

Face layout (Switch/SNES style): `Y X / B A`.

Also adds upstream `gpio-shutdown,gpio_pin=3` and
`gpio-poweroff,gpiopin=4` overlays for the SHUTDOWN and POWER OFF
dedicated pins (handled by the kernel, not gpio-keys).

**Known issue (2026-05-25): pinctrl pull-up doesn't apply.** The custom
overlay includes a `brcm,pins/function/pull` pinctrl group targeting
`&gpio`, but the bias doesn't seem to take effect — GPIO 25 floated low
on first boot and the kernel spammed `KEY_UP` autorepeat into the local
console. Workaround: probably need to set bias via the newer generic
pinctrl bindings (`bias-pull-up;` on a `pins = "gpio25"` group) rather
than the brcm,pull integer encoding.

Also: **the physical button switches are degraded** — pressing with a
finger or even a metal tool doesn't reliably close them. A damp tissue
(conductive) DOES close them, and Sonic plays through fine that way. So
the GPIO side and our DT mapping are correct; the tactile switches just
need cleaning or replacement.

Note (2026-05-26): the earlier `gpiomon` probe captured all 738 events
on GPIO 5 (L1) — the only switch making contact via finger pressure.
We initially read this as "mapping wrong" but it was "only one switch
is conductive enough for finger pressure." Vendor's `/boot/retrogame.cfg`
is the authoritative map; our face-button GPIOs were pair-swapped
(A↔B and X↔Y) in the earlier inference from the pinout image — fixed
in this version.

Verify after reboot:

```
cat /proc/bus/input/devices | grep -A4 zega-buttons     # device present
ls /dev/input/                                          # event<N>
```

## Directory layout

```
.
├── README.md                          # this file
├── display.sh                         # idempotent installer
├── audio.sh                           # idempotent installer
├── buttons.sh                         # idempotent installer
├── snapshot/                          # device state at 2026-05-25 19:55 BST
│   ├── config.txt                     # current /boot/firmware/config.txt
│   ├── asound.conf                    # vendor's /etc/asound.conf (note: has buggy `rate` in softvol slave)
│   ├── asoundrc                       # our ~student/.asoundrc
│   ├── pinout-u8.png                  # vendor U8 pinout diagram
│   └── overlays/                      # compiled .dtbo + firmware blob
│       ├── zega-reset-hog.dtbo
│       ├── zega-panel-fakereset.dtbo
│       ├── zega-buttons.dtbo
│       └── panel-mipi-dbi-spi.bin
└── vendor/                            # reference material salvaged from vendor SD
    ├── config.txt                     # vendor's working /boot/config.txt
    ├── bash_history.txt               # commands they ran (i2samp.sh, alsamixer, etc.)
    └── retrogame.sh                   # Adafruit retrogame installer (not used)
```

## Re-bootstrapping from scratch

After flashing a fresh Trixie Lite image to the SD card:

```
# Copy scripts over (from this dir on whatever host)
scp display.sh audio.sh buttons.sh student@<zega-ip>:/home/student/

# Run them
ssh -t student@<zega-ip> '
  sudo ./display.sh &&
  sudo ./audio.sh &&
  sudo ./buttons.sh &&
  sudo reboot'
```

If you re-image and the audio behavior changes (e.g. tone now sustains),
that's evidence the issue is software-state-dependent and worth bisecting.
If audio still pops-only after a clean Trixie + scripts run, the chip /
jack is the suspect.
