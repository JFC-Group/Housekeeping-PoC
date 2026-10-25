# Housekeeping
## A two stage bootloader unlock exploit for JSTBs

### Tested On:
- JMSC200Av2 on 22.1.09, 24.1.39, and 25.1.9. Should work on older firmwares as well.

#### May not work on JHS series
#### We are not responsible for bricked STBs, getting scammed, thermonuclear warfare caused by using this script, or anything else.
---
### Mechanism:
#### Stage 1 (USB Debugging):
- A fake TR-069 server is created with GenieACS and a self-signed certificate is assigned and a connection port is opened by pass_front.py at :8443 (sometimes :9443 may be required, change python script if that happens)
- DNS of the STB is rerouted. "acs.oss.j.com" points to the device running GenieACS, then STB is rebooted while running the stage1.sh script
- STB connects to 8443 (hopefully with no ssl pinning), connection is routed to GenieACS
- Internal TR-069 variables are flipped by spamming them:
	- Device.JSTB.USB.USBDebugging -> true
	Device.JSTB.USB.DebugValidityDate -> 2037-01-01T00:00:00.000Z
	Device.JSTB.FOTA.Disable -> true
	Device.JSTB.FOTA.DowngradeEnable -> true [downgrade has not been tested]
	Device.JSTB.FOTA.DowngradeValidityDate -> 2037-12-31T23:59:59.000Z
- After adb connect is accomplished, device_provisioned tag is set to 1
- Bloat and TR069 client is disabled.

#### If you only want ADB, just use the stage1.sh
---
### DO NOT SKIP
#### Risks with Stage 2:
- **MIGHT NOT WORK FOR ALL**: The CVE was **patched in June 2024 Android Security Bulletin**. Check your ASB date by either going to Device Info, or `adb shell getprop ro.build.version.security_patch`. If it shows anything **after May 2024, the exploit WILL NOT WORK.** No guarantees are given if the script is ran without checking.
- **ONLY ONE SHOT PER BOOT**: The implemented CVE **breaks zygote connection after running**, so the exploit can only be ran once per boot.
- **UBOOT FASTBOOT IS HEAVILY RESTRICTED**: You cannot run anything like `flash`, `format`, `slot_active`. They can only be done via fastbootd. **BE VERY CAREFUL IF YOU ARE FLASHING ANY CUSTOM IMAGES, AS IT MAY LEAD TO A BRICK**. AML Download/Burn mode is also disabled, unknown if it can be enabled (I bricked my own device this way, please don't make the same mistake)
---
#### Stage 2 (Bootloader Unlock):
- Implemented CVE-2024-31317, **depends entirely on ASB date, might not work for all**
- **CVE-2024-31317** (Zygote command injection): injects a newline into
   `hidden_api_blacklist_exemptions` settings, causing Zygote to fork a process
   with `--invoke-with` pointing to our command. Runs as `system_app` (uid 1000).
- ISystemControl HIDL: from `system_app` context, calls
   `SystemControlManager.setBootenv()` (from `/vendor/framework/droidlogic.jar`)
   which talks to the Amlogic systemcontrol HAL via HIDL binder.
- U-Boot env write:
	 the HAL writes to `/dev/block/env`, changing:
   - `lock` from `10101000` (locked) to `10100000` (unlocked) — flips bit[4]
   - `EnableSelinux` from `enforcing` to `permissive`
- Reboot to fastboot: U-Boot reads the new env and reports `unlocked:yes`.
   Factory reset required on first boot after unlock state change. **Try fastbootd, if not working, try Android Rescue recovery page with a keyboard.**
- If device bootloops, try resetting it. This will only work if the Jio boot animation (not just the logo) shows up and the green LED is blinking, If the green LED stays on and only the Jio logo is shown, try booting into uboot fastboot.
---

### Prerequisites:
- GenieACS Docker, docker-compose.yml is shipped under tls/ dir.
- DNS redirect of acs.oss.jio.com to the device running GenieACS (please disable firewalls)
	An easy way of doing redirects would be an OpenWRT router. Another way could be directly connecting the STB to the docker-running device and creating a subnet, although it is more difficult.
#### Ensure that there is NO INTERNET ACCESS to the STB during this entire procedure until stage1.sh finishes.
---

### Running:
1. Start the Docker container by:
	`cd tls && docker-compose up -d`
2. ./stage1.sh                          # enable ADB
3. ./unlock.sh                          # unlock bootloader
4. adb reboot bootloader → fastboot reboot → factory reset (keyboard needed)
5 ./stage1.sh                          # re-enable ADB after reset
6. ./unlock.sh selinux                  # NOW set SELinux permissive
7. adb reboot                           # SELinux permissive takes effect
8. ./pull_boot.sh                       # extract boot.img for Magisk

---

### Credits:
1. ak_0o7 and Sandip Bhadoriya for the ACS script
2. Otus9051 for consolidating ACS script and unlock.sh
3. Keratin and Anthropic for Claude

I have tried to credit everyone that I am aware of. If you have supported this work in any way and your name is not on here, don't be sad, we are glad that you made this possible!
---

### THIS PROJECT IS UNDER THE APACHE 2.0 LICENSE
Please for the **love of humanity** stop making these into a black market. I am tired. Let this become a way for people to reuse whatever e-waste they have.

We are irresponsible people, please do not hold us accountable, we are broke and have no lawyers.

This README, and almost all of the RE, analysis etc on the unlock/root side, was done by me (Otus9051). Claude merely helped in orchestrating everything. These things take time, coordination, blood and sweat. We do not ask for money. Please credit us, and try not to sell. We make these projects to reduce e-waste that people already have, not create markets. 
