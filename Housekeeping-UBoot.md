# JioSTB C200A (ohm) — Bootloader Unlock Exploit

## Device
- **Model:** JioSTB C200A, Amlogic S905X4, Android 11
- **Kernel:** 5.4.125, SELinux enforcing, locked bootloader

## What This Does
Unlocks the bootloader and optionally sets SELinux to permissive by writing
U-Boot environment variables through the Amlogic ISystemControl HIDL service.

## How It Works

### The Problem
The bootloader lock state is stored in `ubootenv.var.lock` — an 8-digit bitmask
in the U-Boot environment partition (`/dev/block/env`). Only the `system_control`
HAL domain can write to this partition, accessed via the ISystemControl HIDL service.
Only `system_app` and a few vendor HALs can call this HIDL service.

### The Chain
1. **CVE-2024-31317** (Zygote command injection) — injects a newline into
   `hidden_api_blacklist_exemptions` settings, causing Zygote to fork a process
   with `--invoke-with` pointing to our command. Runs as `system_app` (uid 1000).

2. **ISystemControl HIDL** — from `system_app` context, calls
   `SystemControlManager.setBootenv()` (from `/vendor/framework/droidlogic.jar`)
   which talks to the Amlogic systemcontrol HAL via HIDL binder.

3. **U-Boot env write** — the HAL writes to `/dev/block/env`, changing:
   - `lock` from `10101000` (locked) to `10100000` (unlocked) — flips bit[4]
   - `EnableSelinux` from `enforcing` to `permissive`

4. **Reboot to fastboot** — U-Boot reads the new env and reports `unlocked:yes`.
   Factory reset required on first boot after unlock state change.

### The Lock Bitmask
```
ubootenv.var.lock = "10101000"
Position: [0][1][2][3][4][5][6][7]
Field:     maj min  unlk pad LOCK crit bldr pad
                    able     STATE

10101000 = locked, unlock allowed
10100000 = UNLOCKED, unlock allowed
```

### JioService Access Control Bypass
The `bootenv.jar` tool needs the ISystemControl HIDL, which requires `system_app`
context. The `jioservice_client.apk` is an alternative tool that calls JioService's
AIDL — it uses package name `com.jio.jiosmartsecurityserver` (an uninstalled
package in JioService's allowedPackages whitelist) to bypass the UID-based access
check. However, JioService can only write `lock_state` (the wrong variable), not
`lock` (the real bitmask). The APK is still useful for querying device info.

## Files
| File | Purpose |
|------|---------|
| `unlock.sh` | Main exploit script — reboots, injects, writes env vars |
| `bootenv.jar` | DEX tool that calls SystemControlManager via reflection |
| `jioservice_client.apk` | APK that calls JioService AIDL (package name spoof) |
| `src/BootEnv.java` | Source for bootenv.jar |
| `src/MainActivity.java` | Source for the APK |
| `src/AndroidManifest.xml` | APK manifest (package: com.jio.jiosmartsecurityserver) |

## Usage

### Prerequisites
- ADB access to the device (USB or network, via `stage1.sh`)
- Device must be booted to Android (not fastboot/recovery)
- ASB date before June 2024 (`adb shell getprop ro.build.version.security_patch`)

### Step-by-step

#### 1. Unlock the bootloader
```bash
./unlock.sh                  # or: ./unlock.sh unlock
```
This reboots the device, injects the CVE-2024-31317 payload, writes `lock=10100000`,
and cleans up the payload. Use `--skip-reboot` if the device was just booted.

#### 2. Verify in fastboot
```bash
adb reboot bootloader
fastboot getvar unlocked     # should say "yes"
fastboot reboot
```

#### 3. Factory reset
The first boot after unlock requires a factory reset. **Plug in a USB keyboard**
before rebooting — you'll need it to navigate the reset prompt.

#### 4. Re-enable ADB
Factory reset wipes everything. Re-run stage1 to get ADB back:
```bash
./stage1.sh
```

#### 5. Set SELinux permissive
The factory reset wiped the SELinux bootenv variable, so this must be done
**after** the reset, as a separate step:
```bash
./unlock.sh selinux
adb reboot                   # takes effect on next boot
```

#### 6. Extract boot.img for Magisk
See `Housekeeping-SDK.md` — uses the sdknativeservice root shell:
```bash
./pull_boot.sh
```

### Other commands
```bash
./unlock.sh read             # read lock, lock_state, EnableSelinux values
./unlock.sh relock           # re-lock (WARNING: bricks if custom images flashed)
./unlock.sh --force-asb ...  # bypass ASB date check
./unlock.sh --skip-reboot .. # skip reboot (device was just booted)
```

### Install the APK Tool (optional, for JioService queries)
```bash
adb install jioservice_client.apk
adb shell am start -n com.jio.jiosmartsecurityserver/com.test.bootenv.MainActivity --es action info
adb logcat -s BootEnv:*
```

## Important Notes

### One Shot Per Boot
CVE-2024-31317 breaks the Zygote connection after firing. You get ONE injection
per boot cycle. The script handles this by rebooting first (unless `--skip-reboot`).

### NEVER Persist the Payload
The payload in `hidden_api_blacklist_exemptions` MUST be deleted within seconds.
If it persists across a reboot, Zygote reads it on boot → crashes → system restarts
Zygote → crash loop → **BOOT LOOP**. The script cleans up automatically, but if
something goes wrong, immediately run:
```bash
adb shell settings delete global hidden_api_blacklist_exemptions
```

### Factory Reset Wipes SELinux Setting
The `EnableSelinux` bootenv variable is reset by factory wipe. That's why
`unlock.sh` now does the lock bitmask only — run `./unlock.sh selinux` separately
after factory reset.

### U-Boot Fastboot Limitations
U-Boot fastboot on this device only supports `reboot`, `getvar`, and basic flash.
For `format` and `erase`, you need fastbootd (`fastboot reboot fastboot`). However,
**fastbootd may not be available** — if it isn't, use the Android Recovery reset
screen with a USB keyboard.

## Key Variables
| Env Variable | Value | Effect |
|-------------|-------|--------|
| `ubootenv.var.lock` | `10100000` | Bootloader unlocked |
| `ubootenv.var.lock` | `10101000` | Bootloader locked (default) |
| `ubootenv.var.lock_state` | `unlock`/`lock` | Jio app-level flag (U-Boot ignores) |
| `ubootenv.var.EnableSelinux` | `permissive`/`enforcing` | SELinux mode on next boot |
