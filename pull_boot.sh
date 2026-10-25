#!/bin/bash
# ============================================================================
# JioSTB C200A — Pull boot.img via sdknativeservice root
#
# Extracts the boot partition for Magisk patching. Requires:
#   - ADB connected (run stage1.sh)
#   - SELinux permissive (set by unlock.sh)
#
# Uses rootshell2.jar which talks to sdknativeservice via Binder to
# execute commands as uid 0. Just push + app_process, no Zygote injection.
#
# Usage:
#   ./pull_boot.sh                       # pull active slot's boot.img
#   ./pull_boot.sh --slot _b             # pull specific slot
#   ./pull_boot.sh --cmd "id"            # run arbitrary root command
#   ./pull_boot.sh --cmd "cat /proc/mounts"
# ============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SLOT=""
ROOT_CMD=""
OUTPUT="boot.img"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slot)  SLOT="$2"; shift 2 ;;
        --cmd)   ROOT_CMD="$2"; shift 2 ;;
        --out)   OUTPUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--slot _a|_b] [--cmd \"command\"] [--out file]"
            exit 0 ;;
        *) shift ;;
    esac
done

if [ ! -f "$SCRIPT_DIR/rootshell2.jar" ]; then
    echo "[!] rootshell2.jar not found in $SCRIPT_DIR"
    exit 1
fi

# --- Check ADB ---
if ! adb get-state >/dev/null 2>&1; then
    echo "[!] No ADB device connected."
    echo "    Run stage1.sh first (re-run after factory reset)."
    exit 1
fi

# --- Push jar to device ---
REMOTE_JAR="/data/local/tmp/rootshell2.jar"
echo "[*] Pushing rootshell2.jar..."
adb push "$SCRIPT_DIR/rootshell2.jar" "$REMOTE_JAR"

# --- Check that sdknativeservice is running ---
if ! adb shell "service check com.jio.sdk.sdknativeservice" 2>/dev/null | grep -q "found"; then
    echo "[!] sdknativeservice is not running."
    echo "    This service provides root command execution."
    echo "    It may have been killed when bloatware was disabled."
    echo ""
    echo "    Try re-enabling it:"
    echo "      adb shell pm enable com.jio.sdk"
    echo "    Or reboot the device (it starts at boot via init.rc):"
    echo "      adb reboot && adb wait-for-device"
    exit 1
fi
echo "[*] sdknativeservice is running"

# --- Helper: run a command as root via sdknativeservice ---
root_exec() {
    adb shell "CLASSPATH=$REMOTE_JAR /system/bin/app_process / RootShell2 -c $1" 2>&1
}

# --- Arbitrary command mode ---
if [ -n "$ROOT_CMD" ]; then
    echo "[*] Running as root: $ROOT_CMD"
    root_exec "$ROOT_CMD"
    exit 0
fi

# --- Determine active slot ---
if [ -z "$SLOT" ]; then
    SLOT=$(adb shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '[:space:]')
    if [ -z "$SLOT" ]; then
        echo "[!] Could not detect slot suffix, defaulting to _a"
        SLOT="_a"
    fi
fi

PARTITION="boot${SLOT}"
BLOCK_DEV="/dev/block/by-name/${PARTITION}"
echo "[*] Active slot: $SLOT — extracting $BLOCK_DEV"

# --- Extract boot.img as root ---
REMOTE_OUT="/data/local/tmp/boot.img"
echo "[*] dd $BLOCK_DEV -> $REMOTE_OUT ..."
root_exec "dd if=$BLOCK_DEV of=$REMOTE_OUT bs=4096 2>&1"
root_exec "chmod 666 $REMOTE_OUT"

# --- Pull ---
echo "[*] Pulling boot.img..."
if adb shell "test -f $REMOTE_OUT && echo exists" 2>/dev/null | grep -q "exists"; then
    adb pull "$REMOTE_OUT" "$OUTPUT"
    SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || stat -f%z "$OUTPUT" 2>/dev/null || echo "?")
    echo "[*] Saved: $OUTPUT ($SIZE bytes)"
    echo ""
    echo "Next: patch with Magisk, then flash:"
    echo "  1. Transfer $OUTPUT to phone, patch in Magisk app [it is recommended to patch in TV]"
    echo "  2. adb reboot bootloader"
    echo "  3. fastboot reboot fastboot [uboot fastboot -> fastbootd]"
    echo "  4. fastboot flash ${PARTITION} magisk_patched-xxxxx.img"
    echo "  5. fastboot reboot"
else
    echo "[!] boot.img not found at $REMOTE_OUT — dd may have failed"
    echo "    Debug: ./pull_boot.sh --cmd 'ls -la $BLOCK_DEV'"
    echo "    Debug: ./pull_boot.sh --cmd 'ls -la $REMOTE_OUT'"
fi
