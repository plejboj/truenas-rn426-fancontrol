# TrueNAS RN426 Fan Control

Quiet, temperature-aware fan control for the **NETGEAR ReadyNAS RN426** running **TrueNAS SCALE**.

This project controls the RN426 chassis fan through the motherboard's **ITE IT8622 Super-I/O** using the Linux `it87` driver. It is designed for systems where the front-panel integration works, but fan RPM is missing because `it87` is not loaded automatically.

The controller uses the hottest `drivetemp` sensor as the primary input and the hottest CPU `coretemp` sensor as a safety backstop. It deliberately avoids the IT8622 built-in automatic mode because disconnected temperature inputs on this hardware can report invalid values such as `-128 C`.

## What it does

- Loads `it87 force_id=0x8622` automatically when needed.
- Finds the `it8622` hwmon device dynamically; it does not depend on a fixed `hwmon6` path.
- Controls the chassis fan through `pwm2` in manual mode.
- Uses the hottest HDD temperature as the main control input.
- Uses CPU temperature as an additional safety backstop.
- Checks temperatures and updates/logs fan state every **15 seconds**.
- Detects missing HDD/CPU temperature sensors.
- Detects a stalled fan below **500 RPM**.
- Uses **PWM 255** for actual sensor/fan failures.
- Restores **PWM 128** during normal stop, reboot, or shutdown to avoid an unnecessarily loud restart.
- Can launch itself as a transient `systemd` service, which makes it convenient to use from TrueNAS Init/Shutdown Scripts.

## Tested hardware

Tested on:

- NETGEAR ReadyNAS RN426
- TrueNAS SCALE
- IT8622 Super-I/O
- chassis fan exposed as `fan2_input`
- fan control exposed as `pwm2`

Measured on the test system:

| PWM | Approx. RPM |
|---:|---:|
| 50 | 1130 |
| 70 | 1310 |
| 90 | 1483 |
| 110 | 1658 |
| 128 | 1819 |

Actual RPM will vary between units and replacement fans.

## Current HDD curve

The default curve is tuned for low noise on the tested RN426:

| Hottest HDD | PWM |
|---:|---:|
| <= 40 C | 50 |
| 41 C | 55 |
| 42 C | 60 |
| 43 C | 65 |
| 44 C | 70 |
| 45 C | 75 |
| 46 C | 80 |
| 47 C | 90 |
| 48 C | 105 |
| 49 C | 120 |
| 50 C | 140 |
| 51 C | 165 |
| 52 C | 195 |
| 53 C | 225 |
| >= 54 C | 255 |

On the test RN426, the drives tended to stabilize around **46-47 C**. Increasing PWM beyond roughly 90 did not materially reduce their long-term temperature, while it made the NAS noticeably louder. Your drives, room temperature, workload, dust level, and airflow may differ, so review the curve for your own setup.

## CPU backstop

The CPU normally does not control the fan on this NAS, but it can override the HDD target when required:

| Hottest CPU sensor | Minimum PWM |
|---:|---:|
| <= 54 C | 50 |
| 55-59 C | 70 |
| 60-64 C | 100 |
| 65-69 C | 140 |
| 70-74 C | 200 |
| >= 75 C | 255 |

## Fan RPM only

If you only want fan RPM to appear in the RN426 front-panel project and do not want automatic fan control, loading the module is enough on the tested machine:

```bash
modprobe it87 force_id=0x8622
cat /sys/class/hwmon/*/fan2_input
```

A plain `modprobe it87` may work on some units, but on the tested RN426 it returned `No such device`; `force_id=0x8622` worked immediately.

For RPM-only setups, add this as a TrueNAS **PREINIT** Command:

```bash
modprobe it87 force_id=0x8622
```

Once `fan2_input` exists, the RN426 panel project can pick it up on refresh.

## Installation

Store the script somewhere persistent on your TrueNAS pool. Do not rely on an arbitrary root-filesystem location that may be replaced during a SCALE update.

Example:

```bash
mkdir -p /mnt/POOL/rn426-fancontrol
cp rn426-fancontrol.sh /mnt/POOL/rn426-fancontrol/
chmod 755 /mnt/POOL/rn426-fancontrol/rn426-fancontrol.sh
```

Replace `POOL` with your actual pool name.

### 1. Check detected sensors

```bash
/mnt/POOL/rn426-fancontrol/rn426-fancontrol.sh check
```

Typical output:

```text
Wersja:    2026-08-28.7; interwal 15s
Kontroler: /sys/class/hwmon/hwmon6
Dyski:     max 47 C, czujniki 4, zadany PWM 90
CPU:       max 42 C, czujniki 5, zadany PWM 50
Wynik:     target PWM 90; obecnie PWM 90; fan2 1480 RPM
```

The script currently expects at least four `drivetemp` sensors:

```bash
MIN_DRIVE_SENSORS=4
```

If your RN426 exposes a different number of drive-temperature sensors, edit that value before enabling automatic startup.

### 2. Display the configured curves

```bash
/mnt/POOL/rn426-fancontrol/rn426-fancontrol.sh curve
```

### 3. Test in the foreground

```bash
/mnt/POOL/rn426-fancontrol/rn426-fancontrol.sh daemon
```

The script will print a status line approximately every 15 seconds:

```text
HDDmax=47C(4) HDDtarget=90 CPUmax=42C(5) CPUtarget=50 target=90 PWM=90 fan=1480RPM
```

Press `Ctrl+C` to stop it. A normal stop restores PWM 128.

### 4. Automatic startup on TrueNAS SCALE

Open:

**System Settings -> Advanced -> Init/Shutdown Scripts**

Add:

```text
Type: Script
Script: /mnt/POOL/rn426-fancontrol/rn426-fancontrol.sh
When: Post Init
Enabled: Yes
```

No separate `systemd-run` entry is necessary. When started with no arguments, the script launches its own transient service:

```text
rn426-fancontrol.service
```

A separate PREINIT `modprobe` command is also not required when using the full fan-control script because the script loads `it87` itself.

## Commands

```bash
# Start the systemd service
./rn426-fancontrol.sh start

# Run in foreground
./rn426-fancontrol.sh daemon

# Stop and restore PWM 128
./rn426-fancontrol.sh stop

# Restart service
./rn426-fancontrol.sh restart

# Show systemd status
./rn426-fancontrol.sh status

# Read sensors and calculate target without changing PWM
./rn426-fancontrol.sh check

# Print HDD and CPU curves
./rn426-fancontrol.sh curve
```

Live logs:

```bash
journalctl -u rn426-fancontrol.service -f
```

Service status:

```bash
systemctl status rn426-fancontrol.service
```

## Safety notes

This script directly controls hardware cooling. Use it at your own risk and monitor temperatures carefully after installation.

Important RN426-specific observations:

- `pwm2` controls the chassis fan on the tested machine.
- Very low `pwm2` values can stall the fan; the tested unit was reported to stall below roughly PWM 12. This script never intentionally goes that low.
- The script uses PWM 255 when it detects missing required sensors or a stalled fan.
- A normal reboot/shutdown uses PWM 128 instead of 255 so the NAS does not become unnecessarily loud during every restart.
- Do not assume these temperatures or PWM values are appropriate for every HDD model or environment.

## Related project and credit

The front-panel work and the key IT8622 findings came from the excellent ReadyNAS RN426 TrueNAS panel project by **riplatt**:

https://github.com/riplatt/truenas-rn426-panel

In particular, the discovery that the fan is attached to the IT8622 Super-I/O and can be exposed with:

```bash
modprobe it87 force_id=0x8622
```

made this controller possible.

## License

MIT. See [LICENSE](LICENSE).
