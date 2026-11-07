# JioSTB JMSD200A — Stock Restoration & Safety Manual

---

## 1. Was the Boot Image Patch Safe? (In-Device Explanation)

Yes, **it was 100% patched in-device**. 

### How It Was Patched
Rather than relying on a PC script or an external tool, the patch was performed **directly on the STB's hardware and runtime environment**:
1. Magisk v27.0 native binaries (`magiskboot`, `magiskinit`, `magisk32`, `stub.apk`, `boot_patch.sh`, and `util_functions.sh`) were extracted and pushed directly into the STB's memory filesystem at `/data/local/tmp/magisk_prep/`.
2. The patch script was executed inside the STB (`adb shell`) running on the STB’s CPU (`armv8l`).
3. While running on the STB, Magisk queried the live partition table and active storage (`magisk32 --preinit-device`), identifying `cache` as the pre-init partition.
4. If this had been patched on a PC, it would have defaulted to a generic configuration (or failed to resolve the pre-init partition entirely), which is what causes bootloops.

### Why We Did Not Use the Magisk App UI on TV
Android TV OS 11 on the JMSD200A lacks the standard Storage Access Framework (`DocumentsUI`) file picker app. When clicking **"Select and Patch a File"** inside the TV app interface, Magisk crashes or does nothing because no file picker is registered. 
Under the hood, the Magisk APK's Java code simply unpacks those exact same assets into `/data/user/0/com.topjohnwu.magisk/` and runs `boot_patch.sh`. Running `boot_patch.sh` directly via shell on the device executes the **exact same binary code** without the UI failure point.

---

## 2. Multi-Layer Safety Net (Why Your Box Will Not Brick)

| Safety Layer | Mechanism | Protection Level |
| :--- | :--- | :--- |
| **Layer 1: Stock Backups Verified** | Bit-for-bit raw partition dumps of `boot_b`, `boot_a`, `vendor_boot_b`, `dtbo_b`, `vbmeta_b` saved on PC and FAT32 USB. | Complete stock image recovery available. |
| **Layer 2: Fastboot Slot Redundancy (A/B)** | Only slot `_b` is being touched. Slot `_a` contains 100% virgin stock factory boot images. | If slot `_b` ever fails to boot, switching active slot to `a` immediately restores stock boot. |
| **Layer 3: U-Boot Fastboot Access** | Fastboot runs at the U-Boot bootloader level (`is-userspace: no`), meaning it initializes before Android or kernel ever load. | Even if Android boot crashes, U-Boot fastboot remains fully accessible over USB. |
| **Layer 4: U-Boot USB Shell (`store write`)** | U-Boot environment can directly write flash memory from FAT32 USB (`store write`). | Partition images can be restored from the USB stick without fastboot. |

---

## 3. Driver Installation Guide (Ubuntu & Windows)

### A. Ubuntu / Linux Setup

#### 1. Install Tools
```bash
sudo apt update
sudo apt install -y android-tools-adb android-tools-fastboot
```

#### 2. Configure Udev Rules (Permissions)
Create `/etc/udev/rules.d/51-android.rules`:
```bash
sudo tee /etc/udev/rules.d/51-android.rules << 'EOF'
# Google / Android Fastboot / Amlogic Gadget
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", ATTR{idProduct}=="0d02", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0666", GROUP="plugdev"
# Amlogic WorldCup / Download Gadget
SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", ATTR{idProduct}=="0cee", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="1b8e", MODE="0666", GROUP="plugdev"
EOF
```

#### 3. Reload Udev
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo usermod -aG plugdev $USER
```

---

### B. Windows Setup

#### 1. Install Platform Tools (ADB & Fastboot)
1. Download official [Android SDK Platform-Tools for Windows](https://dl.google.com/android/repository/platform-tools-latest-windows.zip).
2. Extract to `C:\platform-tools`.
3. Add `C:\platform-tools` to your system `PATH`.

#### 2. Install Fastboot Driver (Google USB Driver)
When the device is in bootloader (`18d1:0d02`):
1. Download the [Google USB Driver ZIP](https://developer.android.com/studio/run/win-usb).
2. Extract the ZIP.
3. Open **Device Manager** on Windows (`devmgmt.msc`).
4. Look under **Other Devices** for `Android` or `USB download gadget` with a yellow exclamation mark.
5. Right-click → **Update driver** → **Browse my computer for drivers**.
6. Select **Let me pick from a list of available drivers on my computer**.
7. Click **Have Disk...** and browse to the extracted `android_winusb.inf`.
8. Select **Android Bootloader Interface** and click Next/Install.

#### 3. Alternative: Zadig (Universal Driver Installer)
If Windows fails to bind the driver:
1. Download [Zadig](https://zadig.akeo.ie/).
2. In Zadig, go to **Options** → check **List All Devices**.
3. Select `USB download gadget` or `Android` (Vendor ID `18D1`, Product ID `0D02`).
4. Choose **WinUSB** as the driver target and click **Replace Driver**.

#### 4. Amlogic Burning Tool Drivers (Optional Disaster Recovery)
If you ever need low-level Amlogic recovery:
1. Download **Amlogic USB Burning Tool v3.x** or the standalone **Amlogic Driver Assistant** (`InstallDriver.exe`).
2. Run installer to install the `WorldCup Device` driver.

---

## 4. Step-by-Step Stock Restoration Procedures

### Scenario A: Fastboot Restore (Primary & Quickest)

If the device hangs, bootloops, or you want to return to stock:

1. Connect PC to STB via the male-to-male USB cable (USB 2.0 port).
2. Put STB into bootloader mode:
   - If ADB is reachable: `adb reboot bootloader`
   - If device is powered off: Hold the physical reset pinhole/button with a paperclip and plug in power until PC fastboot detects it.
3. Verify connection:
   ```bash
   sudo fastboot devices
   ```
   *(Must show `RFLSBGLA3409774   Android Fastboot`)*
4. Flash the stock `boot_b` image:
   ```bash
   sudo fastboot flash boot_b /home/ubuntu/Housekeeping-PoC/stock_backups/boot_b.img
   ```
5. Reboot to system:
   ```bash
   sudo fastboot reboot
   ```
*The device will boot back into 100% factory stock Android.*

---

### Scenario B: Instant Fallback to Stock Slot A

Because this device utilizes Android A/B seamless slots and all our changes were targeted strictly to Slot B, **Slot A remains untouched stock**.

1. In fastboot:
   ```bash
   sudo fastboot set_active a
   sudo fastboot reboot
   ```
2. The device will boot using the original, unmodified `boot_a`, `vendor_boot_a`, and `dtbo_a`.

---

### Scenario C: Complete All-Partition Stock Restore via Fastboot

If you ever need to restore every dumped partition back to factory state:

```bash
cd /home/ubuntu/Housekeeping-PoC/stock_backups

# Restore Slot B (Active)
sudo fastboot flash boot_b boot_b.img
sudo fastboot flash vendor_boot_b vendor_boot_b.img
sudo fastboot flash dtbo_b dtbo_b.img
sudo fastboot flash vbmeta_b vbmeta_b.img

# Restore Slot A
sudo fastboot flash boot_a boot_a.img

# Reboot
sudo fastboot reboot
```

---

### Scenario D: U-Boot USB Stick Recovery (No PC Needed)

Because your SanDisk Cruzer Blade FAT32 USB drive has `boot_b.img` stored on it, U-Boot can flash it directly from the drive:

1. Plug FAT32 USB into the STB.
2. In Android shell (or via U-Boot trigger):
   ```bash
   # Read boot_b.img from USB 0:1 into RAM (0x10000000) and write to eMMC boot_b:
   fatload usb 0:1 0x10000000 boot_b.img
   store write 0x10000000 boot_b 0 0x4000000
   ```

---

### Scenario E: Android Recovery / Factory Wipe

If user data causes a crash:
1. Connect a standard USB keyboard to the STB.
2. If Android enters bootloop, the system will automatically show the **Android Recovery** rescue screen.
3. Use the arrow keys on the keyboard to select **Wipe data / factory reset**.
4. Confirm with **Enter**.
