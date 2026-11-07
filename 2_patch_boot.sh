#!/bin/bash
# ============================================================================
# JioSTB JMSD200A — Step 2: Native On-Device Magisk Boot Patcher
# ============================================================================
# This script extracts Magisk v27.0 binaries and scripts, transfers them along
# with stock boot_b.img to the STB, and executes native on-device patching.
# On-device patching ensures Magisk correctly detects the hardware pre-init
# partition ('cache'), preventing bootloops.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/stock_backups"
STOCK_BOOT="$BACKUP_DIR/boot_b.img"
OUTPUT_BOOT="$SCRIPT_DIR/magisk_patched_boot_b.img"
MAGISK_APK="$SCRIPT_DIR/Magisk-v27.0.apk"
STB_IP=""

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
echo -e "${CYAN}     JMSD200A Stage 2: On-Device Magisk Patcher       ${NC}"
echo -e "${CYAN}======================================================${NC}"

# 1. Prerequisite Checks
[ -f "$STOCK_BOOT" ] || err "Stock boot image not found at $STOCK_BOOT. Run 1_dump_stock.sh first."
[ -f "$MAGISK_APK" ] || err "Magisk APK not found at $MAGISK_APK."

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

# 2. Extract Magisk components locally
WORK_DIR=$(mktemp -d /tmp/magisk_extract.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

info "Extracting Magisk v27.0 binary components..."
unzip -q -j "$MAGISK_APK" "lib/arm64-v8a/libmagiskboot.so" -d "$WORK_DIR"
mv "$WORK_DIR/libmagiskboot.so" "$WORK_DIR/magiskboot"

unzip -q -j "$MAGISK_APK" "lib/arm64-v8a/libmagiskinit.so" -d "$WORK_DIR"
mv "$WORK_DIR/libmagiskinit.so" "$WORK_DIR/magiskinit"

unzip -q -j "$MAGISK_APK" "lib/armeabi-v7a/libmagisk32.so" -d "$WORK_DIR"
mv "$WORK_DIR/libmagisk32.so" "$WORK_DIR/magisk32"

unzip -q -j "$MAGISK_APK" "lib/arm64-v8a/libmagisk64.so" -d "$WORK_DIR"
mv "$WORK_DIR/libmagisk64.so" "$WORK_DIR/magisk64"

unzip -q -j "$MAGISK_APK" "assets/boot_patch.sh" -d "$WORK_DIR"
unzip -q -j "$MAGISK_APK" "assets/util_functions.sh" -d "$WORK_DIR"
unzip -q -j "$MAGISK_APK" "assets/stub.apk" -d "$WORK_DIR"

log "Extracted binaries: magiskboot, magiskinit, magisk32, magisk64, boot_patch.sh, util_functions.sh, stub.apk"

# 3. Setup STB working directory
REMOTE_PREP="/data/local/tmp/magisk_prep"
info "Setting up remote staging directory $REMOTE_PREP on STB..."
$ADB shell "rm -rf $REMOTE_PREP && mkdir -p $REMOTE_PREP"

info "Pushing Magisk components and stock boot_b.img to STB..."
$ADB push "$WORK_DIR/"* "$REMOTE_PREP/" >/dev/null
$ADB push "$STOCK_BOOT" "$REMOTE_PREP/boot_b.img" >/dev/null

$ADB shell "chmod 755 $REMOTE_PREP/magiskboot $REMOTE_PREP/magisk32 $REMOTE_PREP/magisk64 $REMOTE_PREP/magiskinit $REMOTE_PREP/boot_patch.sh"

# 4. Execute on-device patch
echo ""
info "Executing native on-device Magisk patch (KEEPVERITY=true)..."
$ADB shell "cd $REMOTE_PREP && KEEPVERITY=true sh boot_patch.sh boot_b.img"

# 5. Verify and pull patched image
NEW_BOOT_EXISTS=$($ADB shell "[ -f $REMOTE_PREP/new-boot.img ] && echo yes || echo no" | tr -d '\r')
[ "$NEW_BOOT_EXISTS" = "yes" ] || err "Patching failed: new-boot.img was not generated."

NEW_BOOT_SIZE=$($ADB shell "stat -c %s $REMOTE_PREP/new-boot.img" | tr -d '\r')
if [ "$NEW_BOOT_SIZE" -ne 67108864 ]; then
    err "Unexpected new-boot.img size: $NEW_BOOT_SIZE bytes (expected 67108864 bytes / 64MB)"
fi

info "Pulling patched boot image to $OUTPUT_BOOT..."
$ADB pull "$REMOTE_PREP/new-boot.img" "$OUTPUT_BOOT"

# Clean up remote staging
$ADB shell "rm -rf $REMOTE_PREP"

# Check header
MAGIC=$(head -c 8 "$OUTPUT_BOOT" | strings || true)
if [ "$MAGIC" != "ANDROID!" ]; then
    err "Invalid boot magic header: expected 'ANDROID!', got '$MAGIC'"
fi

SHA=$(sha256sum "$OUTPUT_BOOT" | awk '{print $1}')
log "Patched boot image successfully verified!"
log "SHA256: $SHA"
log "Size:   $NEW_BOOT_SIZE bytes"

echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  ✓ Boot Image Patched Successfully!                 ${NC}"
echo -e "${GREEN}  Output: $OUTPUT_BOOT                               ${NC}"
echo -e "${GREEN}======================================================${NC}"
