#!/bin/bash
# ============================================================================
# JioSTB C200A — Stage 1: ACS-based ADB Enable + Hardening
#
# Credits: ak_0o7 for finding, Otus9051 for consolidation
# ============================================================================
#
# ARCHITECTURE:
#   The JioSTB phones home to https://acs.oss.jio.com:8443 via CWMP (TR-069).
#   By redirecting that DNS to your host, the STB connects to your local ACS:
#
#     STB ──HTTPS──> pass_front.py (:8443, TLS term) ──HTTP──> GenieACS CWMP (:7547)
#     This script ──REST──> GenieACS NBI (:7557) ──queued tasks──> STB (next Inform)
#
#   pass_front.py handles TLS termination with the RILROOTCA cert chain,
#   session-cookie-sticky routing, and the network-check gate spoof.
#
# PREREQUISITES (see genieacs-tr069-deployment-guide.md):
#   1. GenieACS + MongoDB running in Docker:
#        cd worked_exploit/tls && docker compose up -d
#   2. pass_front.py running (TLS front-end):
#        cd worked_exploit/tls && python3 pass_front.py &
#   3. DNS redirect: acs.oss.jio.com → your host LAN IP
#      (router DNS override, dnsmasq, Pi-hole, etc.)
#   4. STB rebooted after DNS redirect is active
#   5. pycryptodome installed: pip install pycryptodome
#
# Usage:
#   ./stage1.sh                                  # auto-discover device
#   ./stage1.sh --nbi URL --device ID            # non-interactive
#   ./stage1.sh --stb-ip 192.168.x.x            # specify STB IP for ADB
#   ./stage1.sh --list-devices                   # show devices in GenieACS
#   ./stage1.sh --tasks-only                     # queue tasks, skip ADB wait
#   ./stage1.sh --skip-prereqs                   # skip prerequisite checks
#   ./stage1.sh http://IP:7557 DEVICE_ID         # legacy positional args
#
# Environment (override any default):
#   NBI_URL     GenieACS NBI endpoint   (default: http://127.0.0.1:7557)
#   STB_IP      STB's LAN IP for ADB   (default: auto-discover)
#   TLS_PORT    pass_front.py port      (default: 8443)

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ── Configurable defaults ──────────────────────────────────────
NBI_URL="${NBI_URL:-http://127.0.0.1:7557}"
TLS_PORT="${TLS_PORT:-8443}"
DEVICE_ID=""
SERIAL=""
STB_IP="${STB_IP:-}"
SKIP_PREREQS=false
LIST_ONLY=false
TASKS_ONLY=false
ADB_PORT=5555
INFORM_INTERVAL=360
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TLS_DIR="$SCRIPT_DIR/tls"
STALE_THRESHOLD=900  # 15 minutes — device not seen since = stale

# ── Argument parsing ───────────────────────────────────────────
usage() {
    echo "Usage: $0 [OPTIONS] [NBI_URL] [DEVICE_ID]"
    echo ""
    echo "Options:"
    echo "  --nbi URL         GenieACS NBI endpoint"
    echo "  --device ID       Full device ID (skip discovery)"
    echo "  --serial SN       STB serial number (matches against device IDs)"
    echo "  --stb-ip IP       STB LAN IP for ADB connection"
    echo "  --tls-port PORT   TLS front-end port (default: 8443)"
    echo "  --list-devices    List devices in GenieACS and exit"
    echo "  --tasks-only      Queue TR-069 tasks only, skip ADB"
    echo "  --skip-prereqs    Skip prerequisite checks"
    echo "  -h, --help        Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nbi)          NBI_URL="$2"; shift 2 ;;
        --device)       DEVICE_ID="$2"; shift 2 ;;
        --serial)       SERIAL="$2"; shift 2 ;;
        --stb-ip)       STB_IP="$2"; shift 2 ;;
        --tls-port)     TLS_PORT="$2"; shift 2 ;;
        --skip-prereqs) SKIP_PREREQS=true; shift ;;
        --list-devices) LIST_ONLY=true; shift ;;
        --tasks-only)   TASKS_ONLY=true; shift ;;
        -h|--help)      usage ;;
        *)
            if [[ "$1" == http* ]]; then NBI_URL="$1"
            elif [[ -z "$DEVICE_ID" && "$1" != -* ]]; then DEVICE_ID="$1"
            fi
            shift ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────
log()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }
die()  { fail "$@"; exit 1; }

json_py() { python3 -c "import sys,json; $1" 2>/dev/null; }

# URL-encode a device ID for NBI paths
url_encode() { python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(),safe=''))" <<< "$1"; }

banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║     JioSTB C200A — Stage 1: TR-069 ADB Enable       ║"
    echo "║         Credits: ak_0o7, Otus9051                    ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

queue_task() {
    local desc="$1"
    local payload="$2"

    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        "$NBI_URL/devices/$DEV_ENC/tasks" \
        -H 'Content-Type: application/json' -d "$payload" 2>/dev/null || echo -e "\n000")
    CODE=$(echo "$RESP" | tail -1)

    case "$CODE" in
        200) log "$desc — applied (device was connected)" ;;
        202) log "$desc — queued for next Inform" ;;
        *)   warn "$desc — HTTP $CODE (task may still apply)" ;;
    esac
}

banner

# ═══════════════════════════════════════════════════════════════
# [1/6] Prerequisite checks + auto-start services
# ═══════════════════════════════════════════════════════════════
PASS_FRONT_LAUNCHED=false
PASS_FRONT_PID=""

cleanup() {
    if [ -n "$PASS_FRONT_PID" ] && kill -0 "$PASS_FRONT_PID" 2>/dev/null; then
        echo ""
        echo -e "  ${CYAN}Stopping pass_front.py (pid $PASS_FRONT_PID)...${NC}"
        kill "$PASS_FRONT_PID" 2>/dev/null
        wait "$PASS_FRONT_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

port_open() {
    python3 -c "
import socket,sys; s=socket.socket(); s.settimeout(2)
try:
    s.connect(('127.0.0.1',int(sys.argv[1])))
    s.close()
    sys.exit(0)
except ConnectionRefusedError:
    sys.exit(1)
except Exception:
    # TLS server accepted the TCP connection then killed it — port is open
    sys.exit(0)
" "$1" 2>/dev/null
}

if [ "$SKIP_PREREQS" = false ]; then
    echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

    command -v curl >/dev/null 2>&1    || die "curl not found"
    command -v python3 >/dev/null 2>&1 || die "python3 not found (needed for JSON + pass_front.py)"
    if [ "$TASKS_ONLY" = false ]; then
        command -v adb >/dev/null 2>&1 || die "adb not found (install android-tools, or use --tasks-only)"
    fi

    # GenieACS NBI reachable?
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "$NBI_URL/devices/" 2>/dev/null || echo "000")
    if [ "$HTTP" = "000" ]; then
        fail "Cannot reach GenieACS NBI at $NBI_URL"
        echo -e "    Start GenieACS: ${CYAN}cd $TLS_DIR && docker compose up -d${NC}"
        exit 1
    fi
    log "GenieACS NBI reachable ($NBI_URL)"

    # TLS front-end — auto-launch pass_front.py if not running
    # Check both default ports (8443 and 9443)
    TLS_RUNNING=false
    if port_open 8443 && port_open 9443; then
        log "TLS front-end already listening on :8443 + :9443"
        TLS_RUNNING=true
    elif port_open 8443; then
        log "TLS front-end listening on :8443 (port 9443 not open)"
        TLS_RUNNING=true
    elif port_open 9443; then
        log "TLS front-end listening on :9443 (port 8443 not open)"
        TLS_RUNNING=true
    fi

    if [ "$TLS_RUNNING" = false ]; then
        if [ -f "$TLS_DIR/pass_front.py" ]; then
            echo -ne "  ${CYAN}Starting pass_front.py...${NC} "
            python3 "$TLS_DIR/pass_front.py" </dev/null >>"$TLS_DIR/pass_front.log" 2>&1 &
            PASS_FRONT_PID=$!
            sleep 2
            if kill -0 "$PASS_FRONT_PID" 2>/dev/null && port_open 8443; then
                if port_open 9443; then
                    log "pass_front.py started (pid $PASS_FRONT_PID, ports 8443+9443)"
                else
                    log "pass_front.py started (pid $PASS_FRONT_PID, port 8443)"
                fi
                PASS_FRONT_LAUNCHED=true
            else
                fail "pass_front.py failed to start — check $TLS_DIR/pass_front.log"
                exit 1
            fi
        else
            die "pass_front.py not found at $TLS_DIR/pass_front.py"
        fi
    fi

    echo ""

    # If we just launched pass_front, the STB needs a reboot to connect to us
    if [ "$PASS_FRONT_LAUNCHED" = true ]; then
        echo -e "${YELLOW}  pass_front.py was just started.${NC}"
        echo -e "  ${CYAN}Make sure DNS redirect is active (acs.oss.jio.com -> your LAN IP),${NC}"
        echo -e "  ${CYAN}then reboot the STB so it connects to your ACS.${NC}"
        echo ""
    fi
else
    echo -e "${YELLOW}[1/6] Prerequisite checks skipped${NC}"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# [2/6] Device discovery
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[2/6] Finding device in GenieACS...${NC}"

DEVICES_JSON=$(curl -s "$NBI_URL/devices/?projection=_id,_lastInform" 2>/dev/null || echo "[]")

# Annotate each device with staleness + online status
DEVICES_ANNOTATED=$(python3 -c "
import sys, json, datetime
threshold = $STALE_THRESHOLD
now = datetime.datetime.now(datetime.timezone.utc)
devices = json.load(sys.stdin)
for d in devices:
    li = d.get('_lastInform')
    if li:
        try:
            ts = datetime.datetime.fromisoformat(li.replace('Z','+00:00'))
            age = (now - ts).total_seconds()
            d['_age_s'] = int(age)
            d['_online'] = age < threshold
        except: d['_age_s'] = -1; d['_online'] = False
    else:
        d['_age_s'] = -1; d['_online'] = False
json.dump(devices, sys.stdout)
" <<< "$DEVICES_JSON" 2>/dev/null || echo "[]")

DEVICE_COUNT=$(json_py "print(len(json.load(sys.stdin)))" <<< "$DEVICES_ANNOTATED" || echo "0")
DEVICE_COUNT="${DEVICE_COUNT:-0}"
ONLINE_COUNT=$(json_py "print(sum(1 for d in json.load(sys.stdin) if d.get('_online')))" <<< "$DEVICES_ANNOTATED" || echo "0")

# Helper: format device list with status
print_device_list() {
    local filter_arg="${1:-all}"  # "all" or "online"
    python3 -c "
import sys, json
filt = '$filter_arg'
for i, d in enumerate(json.load(sys.stdin), 1):
    did = d.get('_id', '?')
    age = d.get('_age_s', -1)
    online = d.get('_online', False)
    if filt == 'online' and not online:
        continue
    if online:
        status = '\033[0;32mONLINE\033[0m'
    elif age > 0:
        if age < 3600: ago = f'{age//60}m ago'
        elif age < 86400: ago = f'{age//3600}h ago'
        else: ago = f'{age//86400}d ago'
        status = f'\033[1;33mSTALE ({ago})\033[0m'
    else:
        status = '\033[0;31mNEVER SEEN\033[0m'
    print(f'    {i}) {did}  [{status}]')
" <<< "$DEVICES_ANNOTATED"
}

if [ "$LIST_ONLY" = true ]; then
    if [ "$DEVICE_COUNT" = "0" ]; then
        echo "  No devices found."
    else
        print_device_list all
    fi
    exit 0
fi

if [ "$DEVICE_COUNT" = "0" ]; then
    fail "No devices found in GenieACS."
    echo ""
    echo -e "  The STB hasn't connected yet. Checklist:"
    echo -e "    1. DNS redirect active: ${CYAN}acs.oss.jio.com${NC} -> your host LAN IP"
    echo -e "    2. pass_front.py running on :$TLS_PORT"
    echo -e "    3. GenieACS Docker stack running (cwmp :7547, nbi :7557)"
    echo -e "    4. Reboot the STB, then wait up to 6 minutes"
    echo ""
    echo -e "  Then: ${CYAN}$0 --list-devices${NC}"
    exit 1
fi

# --- Resolve device ID from --device, --serial, or interactive ---
if [ -n "$DEVICE_ID" ]; then
    # Explicit device ID — verify it exists
    EXISTS=$(json_py "
d=json.load(sys.stdin)
print('yes' if any(x['_id']=='$DEVICE_ID' for x in d) else 'no')
" <<< "$DEVICES_ANNOTATED")
    if [ "$EXISTS" != "yes" ]; then
        fail "Device '$DEVICE_ID' not found in GenieACS."
        echo "  Available devices:"
        print_device_list all
        exit 1
    fi
    log "Device found: $DEVICE_ID"

elif [ -n "$SERIAL" ]; then
    # Match serial against device IDs (format: OUI-Model-Serial)
    DEVICE_ID=$(json_py "
import sys
serial = '$SERIAL'
for d in json.load(sys.stdin):
    if serial in d.get('_id', ''):
        print(d['_id']); break
" <<< "$DEVICES_ANNOTATED")
    if [ -z "$DEVICE_ID" ]; then
        fail "No device matching serial '$SERIAL'."
        echo "  Available devices:"
        print_device_list all
        exit 1
    fi
    log "Matched serial $SERIAL -> $DEVICE_ID"

else
    # Interactive: prefer online devices, always show status
    if [ "$ONLINE_COUNT" = "1" ] && [ "$DEVICE_COUNT" = "1" ]; then
        DEVICE_ID=$(json_py "print(json.load(sys.stdin)[0]['_id'])" <<< "$DEVICES_ANNOTATED")
        log "Auto-selected device: $DEVICE_ID"
    else
        if [ "$ONLINE_COUNT" -ge 1 ] 2>/dev/null; then
            echo -e "  ${GREEN}$ONLINE_COUNT online${NC}, $DEVICE_COUNT total:"
        else
            echo -e "  $DEVICE_COUNT devices (${YELLOW}none currently online${NC}):"
        fi
        print_device_list all
        echo ""
        echo -e "  ${CYAN}Enter device number, serial number, or 'wait' to wait for a new device:${NC}"
        echo -ne "  > "
        read -r CHOICE

        if [ "$CHOICE" = "wait" ]; then
            echo -e "  ${CYAN}Waiting for a device to connect (reboot the STB)...${NC}"
            # Snapshot current _lastInform values to detect changes
            PREV_SNAPSHOT=$(json_py "
d={x['_id']:x.get('_lastInform','') for x in json.load(sys.stdin)}
print(repr(d))
" <<< "$DEVICES_ANNOTATED")
            for attempt in $(seq 1 120); do
                sleep 5
                printf "\r  Waiting... %ds" "$((attempt * 5))"
                FRESH=$(curl -s "$NBI_URL/devices/?projection=_id,_lastInform" 2>/dev/null || echo "[]")
                NEW_DEV=$(python3 -c "
import sys, json
prev = $PREV_SNAPSHOT
devices = json.load(sys.stdin)
for d in devices:
    did = d.get('_id','')
    li = d.get('_lastInform','')
    if did not in prev:
        print(did); break
    if li and li != prev.get(did,''):
        print(did); break
" <<< "$FRESH" 2>/dev/null || true)
                if [ -n "$NEW_DEV" ]; then
                    echo ""
                    DEVICE_ID="$NEW_DEV"
                    log "Device connected: $DEVICE_ID"
                    break
                fi
            done
            [ -z "$DEVICE_ID" ] && die "Timed out waiting for device."
        elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] 2>/dev/null; then
            DEVICE_ID=$(json_py "
d=json.load(sys.stdin)
i=int('$CHOICE')-1
print(d[i]['_id'] if 0<=i<len(d) else '')
" <<< "$DEVICES_ANNOTATED")
            [ -z "$DEVICE_ID" ] && die "Invalid selection."
        else
            # Treat as serial number
            DEVICE_ID=$(json_py "
serial = '$CHOICE'
for d in json.load(sys.stdin):
    if serial in d.get('_id', ''):
        print(d['_id']); break
" <<< "$DEVICES_ANNOTATED")
            [ -z "$DEVICE_ID" ] && die "No device matching '$CHOICE'."
        fi
        log "Selected: $DEVICE_ID"
    fi
fi

# Warn if selected device is stale
DEVICE_ONLINE=$(json_py "
for d in json.load(sys.stdin):
    if d['_id']=='$DEVICE_ID':
        print('yes' if d.get('_online') else 'no'); break
" <<< "$DEVICES_ANNOTATED" || echo "no")
if [ "$DEVICE_ONLINE" != "yes" ]; then
    DEVICE_AGE=$(json_py "
for d in json.load(sys.stdin):
    if d['_id']=='$DEVICE_ID':
        a=d.get('_age_s',-1)
        if a<0: print('never')
        elif a<3600: print(f'{a//60}m ago')
        elif a<86400: print(f'{a//3600}h ago')
        else: print(f'{a//86400}d ago')
        break
" <<< "$DEVICES_ANNOTATED")
    warn "Device last seen $DEVICE_AGE — it may be offline."
    echo -e "  ${CYAN}Reboot the STB to force it to reconnect to your ACS.${NC}"
    echo -e "  ${CYAN}Tasks will queue and apply once it comes back online.${NC}"
    echo ""
fi

DEV_ENC=$(url_encode "$DEVICE_ID")

echo -e "  ${CYAN}NBI:${NC}    $NBI_URL"
echo -e "  ${CYAN}Device:${NC} $DEVICE_ID"
echo ""

# ═══════════════════════════════════════════════════════════════
# [3/6] Refresh device data model
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[3/6] Refreshing device data model...${NC}"
echo -e "  ${CYAN}Populates all TR-069 parameters from the device.${NC}"

queue_task "refreshObject (full tree)" \
    '{"name":"refreshObject","objectName":""}'

echo ""

# ═══════════════════════════════════════════════════════════════
# [4/6] Queue TR-069 parameter changes
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[4/6] Queuing TR-069 tasks...${NC}"
echo -e "  ${CYAN}Tasks apply when the STB sends its next Inform (~${INFORM_INTERVAL}s).${NC}"
echo -e "  ${CYAN}Reboot the STB to trigger an immediate Inform.${NC}"
echo ""

queue_task "Enable USB Debugging" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.USB.USBDebugging",true,"xsd:boolean"]
    ]
}'

queue_task "Set Debug Validity (2037)" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.USB.DebugValidityDate","2037-01-01T00:00:00.000Z","xsd:dateTime"]
    ]
}'

queue_task "Disable FOTA + Enable Downgrade" '{
    "name":"setParameterValues",
    "parameterValues":[
        ["Device.JioSTB.FOTA.Disable","true","xsd:string"],
        ["Device.JioSTB.FOTA.DowngradeEnable","true","xsd:string"],
        ["Device.JioSTB.FOTA.DowngradeValidityDate","2037-12-31T23:59:59.000Z","xsd:dateTime"]
    ]
}'

echo ""

if [ "$TASKS_ONLY" = true ]; then
    echo -e "${GREEN}Tasks queued. The STB will apply them on its next Inform.${NC}"
    echo -e "Reboot the STB to trigger an immediate Inform."
    echo -e "Once ADB is enabled, connect: ${CYAN}adb connect <STB_IP>:$ADB_PORT${NC}"
    echo -e "Then re-run with ${CYAN}--skip-prereqs --stb-ip <IP>${NC} to finish post-setup."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# [5/6] ADB connection
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[5/6] Connecting via ADB...${NC}"

ADB_TARGET=""

# If no STB IP given, check for an already-connected device first, then ask
if [ -z "$STB_IP" ]; then
    EXISTING=$(adb devices 2>/dev/null | grep -E 'device$' | head -1 | awk '{print $1}' || true)
    if [ -n "$EXISTING" ]; then
        ADB_TARGET="$EXISTING"
        STB_IP="${EXISTING%%:*}"
        log "Using already-connected device: $ADB_TARGET"
    else
        echo -e "  ${CYAN}Enter the STB's LAN IP (check your router's DHCP page):${NC}"
        echo -ne "  > "
        read -r STB_IP
        [ -z "$STB_IP" ] && die "STB IP required. Find it and re-run with --stb-ip <IP>"
    fi
fi

if [ -z "$ADB_TARGET" ]; then
    ADB_TARGET="$STB_IP:$ADB_PORT"
    echo -e "  ${CYAN}Trying adb connect $ADB_TARGET ... (Ctrl+C to abort)${NC}"
    FOUND=0
    for i in $(seq 1 60); do
        if adb connect "$ADB_TARGET" 2>/dev/null | grep -q "connected"; then
            FOUND=1; break
        fi
        printf "\r  Attempt %d/60 (%ds)..." "$i" "$((i * 5))"
        sleep 5
    done
    echo ""
    [ "$FOUND" = "0" ] && die "Could not connect to $ADB_TARGET — is ADB enabled on the STB?"
fi

log "ADB connected ($ADB_TARGET)"

adb_cmd() {
    if [ -n "$ADB_TARGET" ]; then
        adb -s "$ADB_TARGET" "$@" 2>/dev/null
    else
        adb "$@" 2>/dev/null
    fi
}

# Wait for ADB authorization — the TV shows an RSA key prompt on first connect
ADB_STATE=$(adb_cmd get-state || echo "unknown")
if [ "$ADB_STATE" != "device" ]; then
    echo -e "  ${YELLOW}Waiting for ADB authorization...${NC}"
    echo -e "  ${CYAN}Check the TV — accept the RSA key prompt when it appears.${NC}"
    for i in $(seq 1 60); do
        ADB_STATE=$(adb_cmd get-state || echo "unknown")
        [ "$ADB_STATE" = "device" ] && break
        printf "\r  Waiting for auth... %ds" "$((i * 2))"
        sleep 2
    done
    echo ""
    [ "$ADB_STATE" != "device" ] && die "ADB not authorized after 120s. Accept the prompt on the TV and retry."
fi

log "ADB authorized"
echo ""

# ═══════════════════════════════════════════════════════════════
# [6/6] ADB post-setup
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[6/6] Configuring device via ADB...${NC}"

adb_sh() { adb_cmd shell "$@"; }

# Enable Developer Options
adb_sh "settings put global device_provisioned 1"
adb_sh "settings put global development_settings_enabled 1"
log "Device provisioned + Developer Options enabled"

# Kill and disable Jio TR069 client (stops phoning home to real ACS)
adb_sh "cmd appops set com.jio.tr069client RUN_IN_BACKGROUND ignore"
adb_sh "cmd appops set com.jio.tr069client RUN_ANY_IN_BACKGROUND ignore"
adb_sh "pm disable-user --user 0 com.jio.tr069client"
log "TR069 client disabled"

# Uninstall bloatware (per-user, not system-wide — reversible with factory reset)
echo -e "  Removing Jio bloatware..."
BLOAT=(
    com.jio.stb.bot
    com.jio.controlcentre
    com.jio.stb.hotellauncher
    com.jio.stb.catv
    com.jio.product.exploremyremote
    com.jio.profileutility
    com.media.jio.sso.stb
    com.android.app.jio.voiceassist
    com.teamviewer.quicksupport.addon.jio_stb
    com.aksys.jiogamepad
    com.rjl.mobileremote.receiver
    com.jio.dialserver
    com.omni.sci
    com.omni.simplesetup
    com.jio.stbadservice
    com.jio.systemstats
    com.rjil.podlogservice
    com.jio.adc.aka
    com.jio.adc.embedded
    com.jio.smartmemorymanager
    com.jio.appoptimizer
    com.jio.backgroundscheduler
    com.jio.stb.remotediagnose
    com.jio.bioscopecontentservice
    com.jio.media.stb.ondemand.patchwall
    com.jio.stbwidget
    com.jiostb.inactivitytimer
    com.jiostb.fti
    com.jio.universalsetup
    com.rjil.jio.stb.commandreceiver
    com.jio.httpupdate
    com.jio.usbupdate
    com.jio.store
    com.jio.media.jiobeats
    com.jio.mymusic.app
    com.jio.myjiotv
    com.jio.media.jionewsstb
    com.jio.jiocloudpc
    com.jio.jiopay
    com.jio.jiocall
    com.jio.yt
    com.jio.web
    com.jiostb.jiogames
    com.jio.screensaver
    com.jio.stb.screensaver
)

REMOVED=0
for pkg in "${BLOAT[@]}"; do
    if adb_sh "pm uninstall --user 0 $pkg" 2>/dev/null | grep -q "Success"; then
        REMOVED=$((REMOVED+1))
    fi
done
log "Removed $REMOVED bloatware packages"

echo ""
echo -e "${GREEN}Stage 1 complete.${NC}"
echo ""
echo "  Done:"
echo "    - USB debugging enabled (expires 2037)"
echo "    - FOTA updates disabled"
echo "    - Firmware downgrade enabled"
echo "    - TR069 client disabled"
echo "    - $REMOVED bloatware packages removed"
echo ""
echo "  Next steps:"
echo "    1. Install a replacement launcher FIRST:"
echo "       adb install <launcher.apk>"
echo ""
echo "    2. THEN remove the Jio launcher (crash-loops without a replacement!):"
echo "       adb shell pm uninstall --user 0 com.iwedia.ui.rjio.launcher.reliance"
echo ""
echo "    3. Run unlock.sh for bootloader unlock"
