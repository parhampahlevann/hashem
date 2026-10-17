#!/bin/bash

# ==============================================================================
#   Hashem — GRE + FRP / Backhaul Reverse Tunnel Standalone Script (hashem.sh)
#   Edition: Standalone CLI & Interactive Terminal Menu (No Web Panel/Dashboard)
#   Architecture: GRE Layer 3 Tunnel + FRP / Backhaul / Bagher Reverse Tunnel
#   Features: Auto Arch Detect, Systemd Auto-start, MTU Clamping, Multi-Peer,
#             Native Cluster/Load-Balancer, Watchdog, Encrypted Backup, Doctor
# ==============================================================================

HASHEM_VERSION="2.5.0-cli"
HASHEM_BIN="/usr/local/bin/hashem"
HASHEM_SCRIPT="/usr/local/bin/hashem.sh"
HASHEM_URL_BASE="https://raw.githubusercontent.com/pdnczone/hashem-panel/main"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/frp"
DEFAULT_FRP_VERSION="0.71.0"

# Default GRE internal IPs (/30 subnet)
IRAN_GRE_IP="10.10.10.2"
FOREIGN_GRE_IP="10.10.10.1"
TUNNEL_NAME="gre-tunnel"
PANEL_CONFIG_DIR="${GRE_PANEL_DIR:-/etc/gre-panel}"
WATCHDOG_FILE="${PANEL_CONFIG_DIR}/watchdog.json"
PERF_FILE="${PANEL_CONFIG_DIR}/perf.json"
CARRIER_FILE="${PANEL_CONFIG_DIR}/carrier.json"
AUTO_POOL_STATE="${PANEL_CONFIG_DIR}/auto_pool.json"
PEERS_FILE="${PANEL_CONFIG_DIR}/peers.json"
MAX_PEERS=5

# Always skip web panel installation in standalone mode
export GRE_SKIP_PANEL=1

# Auto Pool tuning (env-overridable)
AUTOPOOL_MIN="${AUTOPOOL_MIN:-20}"
AUTOPOOL_MAX="${AUTOPOOL_MAX:-200}"
AUTOPOOL_MAXPOOL_MIN="${AUTOPOOL_MAXPOOL_MIN:-60}"
AUTOPOOL_MAXPOOL_MAX="${AUTOPOOL_MAXPOOL_MAX:-500}"
AUTOPOOL_LOW_CONNS="${AUTOPOOL_LOW_CONNS:-30}"
AUTOPOOL_COOLDOWN="${AUTOPOOL_COOLDOWN:-60}"
AUTOPOOL_SEVERE_ERRS="${AUTOPOOL_SEVERE_ERRS:-20}"
AUTOPOOL_DOWN_QUIET="${AUTOPOOL_DOWN_QUIET:-3}"
AUTOPOOL_MIN_FREE_MB="${AUTOPOOL_MIN_FREE_MB:-150}"
BACKUP_DIR="/var/backups/hashem"
LOG_DIR="/var/log/hashem"

ensure_hashem_bin() {
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p /usr/local/bin "$PANEL_CONFIG_DIR"
    if [[ -f "$0" && "$0" != "$HASHEM_BIN" ]]; then
        cp "$0" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN" 2>/dev/null || true
        cp "$0" "$HASHEM_SCRIPT" 2>/dev/null && chmod +x "$HASHEM_SCRIPT" 2>/dev/null || true
        ln -sf "$HASHEM_SCRIPT" /usr/local/bin/gre.sh 2>/dev/null || true
    elif [[ ! -x "$HASHEM_BIN" ]]; then
        local cand
        for cand in "$0" ./hashem.sh /tmp/hashem.sh "$HASHEM_SCRIPT"; do
            if [[ -f "$cand" ]]; then
                cp "$cand" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN" 2>/dev/null || true
                break
            fi
        done
    fi
}
ensure_hashem_bin

get_public_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    [[ -z "$ip" ]] && ip=$(curl -sSL --max-time 4 https://api.ipify.org 2>/dev/null || true)
    echo "${ip:-127.0.0.1}"
}

mask_sensitive() {
    local text="$1"
    echo "$text" | sed -E \
        -e 's/(hsh1_[^_]+_[0-9]+_[^_]+_[^_]+_)[A-Za-z0-9_-]{8,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(auth\.token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(token[[:space:]]*=[[:space:]]*")[^"]+/\1[MASKED_TOKEN]/g' \
        -e 's/(--token[[:space:]]+)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g' \
        -e 's/(Token:[[:space:]]*)[A-Za-z0-9_-]{16,128}/\1[MASKED_TOKEN]/g'
}

log_msg() {
    local category="${1:-installer}"
    local level="${2:-INFO}"
    local msg="$3"
    [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -eq 0 ]] || return 0
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    local logfile="${LOG_DIR}/${category}.log"
    local masked
    masked=$(mask_sensitive "$msg")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${masked}" >> "$logfile" 2>/dev/null || true
}

backup_configs() {
    local label="${1:-manual}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local bdir="${BACKUP_DIR}/${ts}_${label}"
    mkdir -p "$bdir" 2>/dev/null || return 1

    [[ -d /etc/hashem ]] && cp -rp /etc/hashem "$bdir/" 2>/dev/null || true
    [[ -d "$PANEL_CONFIG_DIR" ]] && cp -rp "$PANEL_CONFIG_DIR" "$bdir/" 2>/dev/null || true
    [[ -d /etc/frp ]] && cp -rp /etc/frp "$bdir/" 2>/dev/null || true
    [[ -d /etc/backhaul ]] && cp -rp /etc/backhaul "$bdir/" 2>/dev/null || true

    mkdir -p "$bdir/systemd" 2>/dev/null || true
    for u in /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service /etc/systemd/system/backhaul*.service; do
        [[ -f "$u" ]] && cp -p "$u" "$bdir/systemd/" 2>/dev/null || true
    done

    echo "$bdir" > "${BACKUP_DIR}/latest" 2>/dev/null || true
    log_msg "installer" "INFO" "Created config backup at $bdir"
    echo "$bdir"
}

get_component_status() {
    local comp="$1"
    case "$comp" in
        frps)
            local bin="/usr/local/bin/frps"
            local svc="frps"
            if [[ ! -f "$bin" && ! -f "/etc/systemd/system/${svc}.service" && ! -f "/etc/frp/frps.toml" ]]; then
                echo "NOT_INSTALLED"; return 0
            fi
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "RUNNING"; return 0
            elif systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "$bin" ]]; then
                echo "STOPPED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        frpc)
            local bin="/usr/local/bin/frpc"
            local svc="frpc"
            if [[ ! -f "$bin" && ! -f "/etc/systemd/system/${svc}.service" && ! -f "/etc/frp/frpc.toml" ]]; then
                echo "NOT_INSTALLED"; return 0
            fi
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "RUNNING"; return 0
            elif systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "$bin" ]]; then
                echo "STOPPED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        gre)
            local ifname="${2:-$TUNNEL_NAME}"
            local svc="${ifname}.service"
            local link_exists=0
            local addr_exists=0
            ip link show "$ifname" >/dev/null 2>&1 && link_exists=1
            ip -4 addr show dev "$ifname" 2>/dev/null | grep -q "inet " && addr_exists=1
            if [[ "$link_exists" -eq 1 && "$addr_exists" -eq 1 ]]; then
                echo "RUNNING"; return 0
            fi
            if systemctl is-failed --quiet "$svc" 2>/dev/null; then
                echo "BROKEN"; return 0
            elif [[ -f "/etc/systemd/system/${svc}" || "$link_exists" -eq 1 ]]; then
                echo "BROKEN"; return 0
            else
                echo "NOT_INSTALLED"; return 0
            fi
            ;;
        deps)
            local missing=()
            for cmd in ip curl tar iptables systemctl python3 ping openssl; do
                command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
            done
            if [[ ${#missing[@]} -eq 0 ]]; then
                echo "INSTALLED"; return 0
            else
                echo "BROKEN"; return 0
            fi
            ;;
        *)
            echo "UNKNOWN"; return 0
            ;;
    esac
}

wait_for_package_manager_lock() {
    local max_wait=15
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
           fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
           fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
            sleep 1
            waited=$((waited + 1))
        else
            break
        fi
    done
    if [[ $waited -ge $max_wait ]]; then
        fuser -k /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || true
        fuser -k /var/lib/apt/lists/lock >/dev/null 2>&1 || true
        fuser -k /var/lib/dpkg/lock >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true
    fi
}

ensure_dependencies_smart() {
    local DEPS_MARKER="${PANEL_CONFIG_DIR}/.deps_installed"
    if [[ -f "$DEPS_MARKER" ]] && command -v ip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && \
       command -v tar >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1 && \
       command -v systemctl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && \
       command -v openssl >/dev/null 2>&1; then
        return 0
    fi

    local missing_pkgs=()
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v tar >/dev/null 2>&1 || missing_pkgs+=("tar")
    command -v iptables >/dev/null 2>&1 || missing_pkgs+=("iptables")
    command -v systemctl >/dev/null 2>&1 || missing_pkgs+=("systemd")
    command -v python3 >/dev/null 2>&1 || missing_pkgs+=("python3")
    command -v ping >/dev/null 2>&1 || missing_pkgs+=("iputils-ping")
    command -v ss >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v openssl >/dev/null 2>&1 || missing_pkgs+=("openssl")

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        mkdir -p "$PANEL_CONFIG_DIR"
        touch "$DEPS_MARKER" 2>/dev/null || true
        echo -e "${GREEN}[✔️] All system dependencies are satisfied.${NC}"
        return 0
    fi

    local uniq_pkgs
    uniq_pkgs=$(printf "%s\n" "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    echo -e "${CYAN}[*] Installing missing dependencies: ${uniq_pkgs}...${NC}"
    log_msg "installer" "INFO" "Installing missing dependencies: ${uniq_pkgs}"

    if command -v apt-get >/dev/null 2>&1; then
        wait_for_package_manager_lock
        export DEBIAN_FRONTEND=noninteractive
        (timeout 25 apt-get update -qq || true)
        apt-get install -y -qq --no-install-recommends $uniq_pkgs 2>/dev/null || {
            dpkg --configure -a 2>/dev/null || true
            apt-get install -y -qq --no-install-recommends $uniq_pkgs 2>/dev/null || true
        }
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q $uniq_pkgs 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q $uniq_pkgs 2>/dev/null || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm $uniq_pkgs 2>/dev/null || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install -y $uniq_pkgs 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache $uniq_pkgs 2>/dev/null || true
    fi
    mkdir -p "$PANEL_CONFIG_DIR"
    touch "$DEPS_MARKER" 2>/dev/null || true
    echo -e "${GREEN}[✔️] System dependencies installed and cached.${NC}"
}

is_port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn "sport = :$port" 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1 && return 0
    fi
    return 1
}

diagnose_port_process() {
    local port=$1
    echo -e "${CYAN}=== Diagnosing Process Holding Port :$port ===${NC}"
    command -v ss >/dev/null 2>&1 && ss -tulpn "sport = :$port" 2>/dev/null
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" 2>/dev/null
    elif command -v fuser >/dev/null 2>&1; then
        fuser "$port/tcp" 2>/dev/null
    fi
    echo -e "${CYAN}=============================================${NC}"
}

ensure_port_available() {
    local port=$1
    local purpose=${2:-"Required port"}
    local is_bundle=${3:-0}

    while is_port_in_use "$port"; do
        echo -e "${YELLOW}[!] WARNING: ${purpose} ${port} is already in use by another process.${NC}"
        log_msg "tunnel" "WARN" "${purpose} ${port} is in use"
        if [[ ! -t 0 ]]; then
            echo -e "${CYAN}[*] Non-interactive mode: continuing despite port conflict.${NC}"
            echo "$port"
            return 0
        fi
        echo "Options:"
        echo "  1) Retry (after stopping conflicting process)"
        echo "  2) Diagnose process"
        echo "  3) Cancel"
        if [[ "$is_bundle" -ne 1 ]]; then
            echo "  4) Choose another port"
        else
            echo "  4) Explicitly choose another port (override bundle)"
        fi
        read -p "Select option [1-4]: " P_OPT
        case "$P_OPT" in
            1) continue ;;
            2) diagnose_port_process "$port"; echo "" ;;
            3) return 1 ;;
            4)
                prompt_port NEW_PORT "Enter new ${purpose}" "$(gen_random_port)"
                port=$NEW_PORT
                ;;
            *) echo -e "${RED}[!] Invalid option.${NC}" ;;
        esac
    done
    echo "$port"
    return 0
}

cli_bundle_inspect() {
    local BUNDLE="" SHOW_TOKEN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --show-token|-s) SHOW_TOKEN=1; shift ;;
            *) BUNDLE="$1"; shift ;;
        esac
    done
    if [[ -z "$BUNDLE" ]]; then
        read -p "Enter setup bundle (hsh1_... / bh1_... / gh1_...): " BUNDLE
    fi
    if ! bundle_parse "$BUNDLE"; then
        echo -e "${RED}[!] Invalid bundle format.${NC}"
        return 1
    fi

    local DISP_TOKEN="******************************** (Masked, pass --show-token to reveal)"
    [[ "$SHOW_TOKEN" -eq 1 ]] && DISP_TOKEN="$B_TOKEN"

    echo -e "\n${CYAN}=============================================================="
    echo "                  HASHEM TUNNEL BUNDLE INSPECT"
    echo -e "==============================================================${NC}"
    echo -e "Bundle Engine:         ${GREEN}${B_ENGINE}${NC}"
    echo -e "Iran Public IP:        ${CYAN}${B_IRAN_PUB}${NC}"
    echo -e "Control Port:          ${CYAN}${B_FRP_PORT}${NC}"
    echo -e "Iran GRE Internal IP:  ${CYAN}${B_IRAN_GRE:-N/A}${NC}"
    echo -e "Foreign GRE IP:        ${CYAN}${B_FOREIGN_GRE:-N/A}${NC}"
    echo -e "Transport:             ${CYAN}${B_TRANSPORT:-tcp}${NC}"
    echo -e "Reverse Proxy Ports:   ${CYAN}${B_PORTS:-None (Manual configuration)}${NC}"
    echo -e "FOU UDP Ports:         ${CYAN}${B_FOU_P1:-443}, ${B_FOU_P2:-55555}${NC}"
    echo -e "Auth Token:            ${YELLOW}${DISP_TOKEN}${NC}"
    echo -e "${CYAN}==============================================================${NC}\n"
    return 0
}

# ---- Performance Configuration (/etc/gre-panel/perf.json) ----
init_perf_json() {
    mkdir -p "$PANEL_CONFIG_DIR"
    if [[ ! -f "$PERF_FILE" ]]; then
        cat << 'EOF' > "$PERF_FILE"
{
  "proxy_encryption": false,
  "proxy_compression": false,
  "tcp_mux": false,
  "auto_pool": true
}
EOF
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

perf_get_tcpmux() {
    if [[ -n "${PERF_TCPMUX:-}" ]]; then
        [[ "$PERF_TCPMUX" == "1" || "$PERF_TCPMUX" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        d = json.load(f)
    print(("1" if d["tcp_mux"] else "0") if "tcp_mux" in d else "")
except Exception:
    print("")
' 2>/dev/null && return 0
    fi
    echo ""
}

perf_tcpmux_new() {
    [[ "$(perf_get_tcpmux)" == "1" ]] && echo true || echo false
}

perf_tcpmux_lines() {
    if [[ "$(perf_tcpmux_new)" == "true" ]]; then
        printf 'transport.tcpMux = true\ntransport.tcpMuxKeepaliveInterval = 30'
    else
        printf 'transport.tcpMux = false'
    fi
}

tcpmux_eof_hint() {
    [[ -f "${CONFIG_DIR}/frpc.toml" ]] || return 1
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl -u frpc -n 200 --no-pager 2>/dev/null \
        | grep -E 'connect to server error: EOF|login to server success' | tail -n 1 \
        | grep -q 'connect to server error: EOF' || return 1
    echo "tcpMux mismatch: hub is likely tcpMux=true, run \`hashem perf tcpmux on|off\` (must match on hub and spoke)"
}

perf_get_enc() {
    if [[ -n "${PERF_ENC:-}" ]]; then
        [[ "$PERF_ENC" == "1" || "$PERF_ENC" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("proxy_encryption", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    fi
    echo 0
}

perf_get_comp() {
    if [[ -n "${PERF_COMP:-}" ]]; then
        [[ "$PERF_COMP" == "1" || "$PERF_COMP" == "true" ]] && echo 1 || echo 0
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("proxy_compression", False) else 0)
except Exception:
    print(0)
' 2>/dev/null && return 0
    fi
    echo 0
}

perf_set_val() {
    local key="$1" val="$2" is_raw="${3:-0}"
    init_perf_json
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
path = "'"$PERF_FILE"'"
key = "'"$key"'"
raw = '"$is_raw"'
val_str = """'"$val"'"""
try:
    with open(path, "r") as f:
        d = json.load(f)
except Exception:
    d = {}
if raw:
    if val_str in ("true", "True", "1"):
        d[key] = True
    elif val_str in ("false", "False", "0"):
        d[key] = False
    else:
        try:
            d[key] = int(val_str)
        except Exception:
            d[key] = val_str
else:
    d[key] = val_str
with open(path, "w") as f:
    json.dump(d, f, indent=2)
'
        chmod 600 "$PERF_FILE" 2>/dev/null || true
    fi
}

perf_prune_legacy_keys() {
    [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1 || return 0
    python3 -c '
import json
path = "'"$PERF_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    for k in ("force_tls", "chaff_profile", "dpi_enabled", "dpi_rate", "dpi_burst", "auto_tune", "tuning_profile"):
        d.pop(k, None)
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
except Exception:
    pass
' 2>/dev/null || true
}

# ---- Auto Pool ----
perf_get_auto_pool() {
    if [[ -n "${PERF_AUTO_POOL:-}" ]]; then
        [[ "$PERF_AUTO_POOL" == "0" || "$PERF_AUTO_POOL" == "false" ]] && echo 0 || echo 1
        return 0
    fi
    if [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(1 if json.load(f).get("auto_pool", True) else 0)
except Exception:
    print(1)
' 2>/dev/null && return 0
    fi
    echo 1
}

perf_get_int() {
    local key="$1" def="$2"
    [[ -f "$PERF_FILE" ]] && command -v python3 >/dev/null 2>&1 || { echo "$def"; return 0; }
    python3 -c '
import json
try:
    with open("'"$PERF_FILE"'") as f:
        print(int(json.load(f).get("'"$key"'", '"$def"')))
except Exception:
    print('"$def"')
' 2>/dev/null || echo "$def"
}

pool_clamp() {
    local v="$1" lo="$2" hi="$3"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$lo"
    (( v < lo )) && v="$lo"
    (( v > hi )) && v="$hi"
    echo "$v"
}

pool_ram_cap() {
    local ram="${AUTOPOOL_RAM_MB:-}"
    [[ "$ram" =~ ^[0-9]+$ ]] || ram=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null)
    [[ "$ram" =~ ^[0-9]+$ && "$ram" -gt 0 ]] || ram=1024
    pool_clamp $(( ram * 8 / 5 )) "$AUTOPOOL_MAXPOOL_MIN" "$AUTOPOOL_MAXPOOL_MAX"
}

autopool_state_get() {
    local def="${2:-}"
    [[ -f "$AUTO_POOL_STATE" ]] && command -v python3 >/dev/null 2>&1 || { echo "$def"; return 0; }
    python3 - "$AUTO_POOL_STATE" "$1" "$def" <<'PY' 2>/dev/null || echo "$def"
import json, sys
path, key, default = sys.argv[1:4]
try:
    with open(path) as f:
        v = json.load(f).get(key, default)
    print(str(v).lower() if isinstance(v, bool) else v)
except Exception:
    print(default)
PY
}

autopool_state_set() {
    command -v python3 >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$AUTO_POOL_STATE")" 2>/dev/null || true
    python3 - "$AUTO_POOL_STATE" "$@" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    d = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    if v in ("true", "false"):
        d[k] = (v == "true")
    else:
        try:
            d[k] = int(v)
        except ValueError:
            d[k] = v
with open(path + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
os.chmod(path + ".tmp", 0o600)
os.replace(path + ".tmp", path)
PY
}

pool_effective_values() {
    local cap pool maxp
    cap=$(pool_ram_cap)
    if [[ "$(perf_get_auto_pool)" == "1" ]]; then
        local hi=$(( cap * 2 / 3 ))
        (( hi > AUTOPOOL_MAX )) && hi="$AUTOPOOL_MAX"
        (( hi < AUTOPOOL_MIN )) && hi="$AUTOPOOL_MIN"
        pool=$(pool_clamp "$(autopool_state_get pool "$AUTOPOOL_MIN")" "$AUTOPOOL_MIN" "$hi")
        maxp="$cap"
    else
        pool=$(pool_clamp "$(perf_get_int frp_pool_count "$AUTOPOOL_MIN")" 2 1000)
        maxp=$(perf_get_int frp_max_pool 0)
        (( maxp >= 10 )) || maxp="$cap"
    fi
    local need=$(( (pool * 3 + 1) / 2 ))
    (( maxp < need )) && maxp="$need"
    echo "$pool $maxp"
}

autopool_set_toml_key() {
    local f="$1" key="$2" val="$3"
    [[ -f "$f" ]] || return 1
    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$f"; then
        sed -i -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*).*|\1${val}|" "$f"
    else
        local hdr_end
        hdr_end=$(grep -n -m1 -E '^\[\[' "$f" | cut -d: -f1)
        if [[ -n "$hdr_end" ]]; then
            sed -i "$((hdr_end - 1))a ${key} = ${val}" "$f"
        else
            printf '%s = %s\n' "$key" "$val" >> "$f"
        fi
    fi
}

autopool_live_toml_int() {
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/'
}

autopool_count_errors() {
    local since="$1" n=0
    if command -v journalctl >/dev/null 2>&1; then
        n=$(journalctl -u frpc --since "$(date -d "@${since}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" --no-pager -q 2>/dev/null \
            | grep -c 'work connection pool is full')
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    echo "$n"
}

autopool_conn_counts() {
    local total tunnel=0
    total=$(ss -Htn state established 2>/dev/null | wc -l)
    [[ -n "$1" ]] && tunnel=$(ss -Htn state established "( dport = :$1 )" 2>/dev/null | wc -l)
    echo "$tunnel $total"
}

autopool_free_mb() {
    awk '/^MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 1024
}

autopool_cpu_hot() {
    local l ncpu
    l=$(awk '{printf "%d", $1 * 100}' /proc/loadavg 2>/dev/null)
    ncpu=$(nproc 2>/dev/null || echo 1)
    [[ "$l" =~ ^[0-9]+$ ]] || l=0
    (( l > ncpu * 200 )) && echo 1 || echo 0
}

autopool_tick() {
    [[ "$(perf_get_auto_pool)" == "1" ]] || return 0
    local now cap
    now=$(date +%s)
    cap=$(pool_ram_cap)

    if [[ ! -f "${CONFIG_DIR}/frpc.toml" ]]; then
        local f live want need=0 f_ok=0
        read -r _ want <<< "$(pool_effective_values)"
        for f in "${CONFIG_DIR}"/frps*.toml; do
            [[ -f "$f" ]] || continue
            f_ok=1
            live=$(autopool_live_toml_int "$f" transport.maxPoolCount)
            if [[ -z "$live" ]] || (( live < want )); then
                autopool_set_toml_key "$f" transport.maxPoolCount "$want"
                need=1
            fi
        done
        [[ "$f_ok" -eq 1 ]] || return 0
        if [[ "$need" -eq 1 ]]; then
            autopool_state_set max_pool="$want" frps_restart_needed=true last_tick="$now" \
                last_decision=hub_raise_max "last_reason=maxPoolCount raised to ${want} in frps toml"
        else
            autopool_state_set max_pool="$want" last_tick="$now"
        fi
        return 0
    fi

    local pool applied last_tick last_restart quiet hi
    hi=$(( cap * 2 / 3 ))
    (( hi > AUTOPOOL_MAX )) && hi="$AUTOPOOL_MAX"
    (( hi < AUTOPOOL_MIN )) && hi="$AUTOPOOL_MIN"
    applied=$(autopool_live_toml_int "${CONFIG_DIR}/frpc.toml" transport.poolCount)
    [[ "$applied" =~ ^[0-9]+$ ]] || applied="$AUTOPOOL_MIN"
    pool=$(pool_clamp "$(autopool_state_get pool "$applied")" "$AUTOPOOL_MIN" "$hi")
    last_tick=$(autopool_state_get last_tick $(( now - 60 )))
    last_restart=$(autopool_state_get last_restart 0)
    quiet=$(autopool_state_get quiet_ticks 0)
    [[ "$last_tick" =~ ^[0-9]+$ ]] || last_tick=$(( now - 60 ))
    [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
    [[ "$quiet" =~ ^[0-9]+$ ]] || quiet=0

    local hub_port errs counts tunnel total active free_mb hot
    hub_port=$(autopool_live_toml_int "${CONFIG_DIR}/frpc.toml" serverPort)
    errs=$(autopool_count_errors "$last_tick")
    counts=$(autopool_conn_counts "$hub_port")
    read -r tunnel total <<< "$counts"
    active=$(( tunnel - 1 - applied ))
    (( active < 0 )) && active=0
    free_mb=$(autopool_free_mb)
    hot=$(autopool_cpu_hot)

    local decision="hold" reason="steady" new="$pool"
    if (( free_mb < AUTOPOOL_MIN_FREE_MB )) && (( errs > 0 || active > pool )); then
        reason="free RAM ${free_mb}MB below ${AUTOPOOL_MIN_FREE_MB}MB"
        quiet=0
    elif (( errs > 0 )) || { (( active > pool )) && [[ "$hot" -eq 0 ]]; }; then
        quiet=0
        new=$(( (pool * 3 + 1) / 2 ))
        (( new <= pool )) && new=$(( pool + 1 ))
        new=$(pool_clamp "$new" "$AUTOPOOL_MIN" "$hi")
        if (( new > pool )); then
            decision="scale_up"
            (( errs > 0 )) && reason="${errs} pool-full errors" || reason="${active} active conns exceed pool ${pool}"
        else
            reason="at ceiling ${hi}"
        fi
    elif (( errs == 0 )) && [[ "$hot" -eq 0 ]] && (( active < pool )); then
        quiet=$(( quiet + 1 ))
        if (( quiet >= AUTOPOOL_DOWN_QUIET )) && (( pool > AUTOPOOL_MIN )); then
            new=$(( pool * 4 / 5 ))
            (( new < active )) && new="$active"
            new=$(pool_clamp "$new" "$AUTOPOOL_MIN" "$hi")
            if (( new < pool )); then
                decision="scale_down"
                reason="${quiet} quiet ticks"
                quiet=0
            else
                new="$pool"
            fi
        else
            reason="quiet ${quiet}/${AUTOPOOL_DOWN_QUIET}"
        fi
    else
        quiet=0
        reason="busy (active=${active} load_hot=${hot})"
    fi
    pool="$new"

    local last_change; last_change=$(autopool_state_get last_change 0)
    [[ "$decision" == "scale_up" || "$decision" == "scale_down" ]] && last_change="$now"
    local max_pool="$cap" need_max=$(( (pool * 3 + 1) / 2 ))
    (( max_pool < need_max )) && max_pool="$need_max"

    if (( pool != applied )); then
        local since=$(( now - last_restart ))
        if (( since < AUTOPOOL_COOLDOWN )); then
            decision="deferred"; reason="${reason}; cooldown $(( AUTOPOOL_COOLDOWN - since ))s left"
        elif (( active < AUTOPOOL_LOW_CONNS )) || (( errs >= AUTOPOOL_SEVERE_ERRS )); then
            autopool_set_toml_key "${CONFIG_DIR}/frpc.toml" transport.poolCount "$pool"
            systemctl restart frpc >/dev/null 2>&1 || true
            applied="$pool"; last_restart="$now"
            [[ "$decision" == "deferred" || "$decision" == "hold" ]] && decision="applied"
            reason="${reason}; frpc restarted"
        else
            decision="deferred"; reason="${reason}; ${active} active conns"
        fi
    fi

    autopool_state_set pool="$pool" max_pool="$max_pool" applied_pool="$applied" quiet_ticks="$quiet" \
        last_tick="$now" last_restart="$last_restart" last_change="$last_change" last_decision="$decision" \
        "last_reason=${reason}" errors_last_tick="$errs" active_conns="$active" tunnel_conns="$tunnel" \
        total_conns="$total" free_mb="$free_mb" cpu_hot="$hot" role=foreign
}

# ---- Input Validation ----
is_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. a b c d o
    read -r a b c d <<<"$1"
    for o in "$a" "$b" "$c" "$d"; do
        ((10#$o <= 255)) || return 1
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

gen_token32() {
    tr -dc A-Za-z0-9 </dev/urandom | head -c 32 2>/dev/null || openssl rand -hex 16
}

gen_random_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-60000 -n 1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import random; print(random.randint(20000, 60000))'
    else
        awk 'BEGIN{srand(); print int(20000 + rand() * 40001)}'
    fi
}

# ---- Carrier & Multi-Protocol Failover (Direct GRE <-> FOU UDP <-> WSS) ----
init_carrier_json() {
    mkdir -p "$PANEL_CONFIG_DIR"
    if [[ ! -f "$CARRIER_FILE" ]]; then
        cat << 'EOF' > "$CARRIER_FILE"
{
  "mode": "direct",
  "active_carrier": "direct",
  "fou_port1": 443,
  "fou_port2": 55555,
  "wss_port": 8443,
  "candidates": [
    "direct",
    "fou:443",
    "fou:55555",
    "wss:8443"
  ],
  "last_switch": "",
  "switch_count": 0
}
EOF
        chmod 600 "$CARRIER_FILE" 2>/dev/null || true
    fi
}

carrier_get_mode() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        print(json.load(f).get("mode", "direct"))
except Exception:
    print("direct")
' 2>/dev/null || echo "direct"
}

carrier_get_active() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        print(json.load(f).get("active_carrier", "direct"))
except Exception:
    print("direct")
' 2>/dev/null || echo "direct"
}

carrier_get_fou_ports() {
    init_carrier_json
    python3 -c '
import json
try:
    with open("'"$CARRIER_FILE"'") as f:
        d = json.load(f)
        print(f"{d.get(\"fou_port1\", 443)} {d.get(\"fou_port2\", 55555)}")
except Exception:
    print("443 55555")
' 2>/dev/null || echo "443 55555"
}

carrier_set_mode() {
    local M="$1"
    [[ "$M" == "auto" ]] && M="direct"
    [[ "$M" == "direct" || "$M" == fou:* || "$M" == wss* ]] || return 1
    init_carrier_json
    python3 -c '
import json, os, sys
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["mode"] = sys.argv[1]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$M" 2>/dev/null || true
}

carrier_set_fou_ports() {
    local P1=$1 P2=$2
    is_valid_port "$P1" && is_valid_port "$P2" || return 1
    init_carrier_json
    python3 -c '
import json, os, sys
p = "'"$CARRIER_FILE"'"
p1, p2 = int(sys.argv[1]), int(sys.argv[2])
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
wp = d.get("wss_port", 8443)
d["fou_port1"] = p1
d["fou_port2"] = p2
d["candidates"] = ["direct", f"fou:{p1}", f"fou:{p2}", f"wss:{wp}"]
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$P1" "$P2" 2>/dev/null || true
}

carrier_init_kernel() {
    modprobe fou >/dev/null 2>&1 || true
    modprobe ip_gre >/dev/null 2>&1 || true
    local P1 P2
    read -r P1 P2 <<< "$(carrier_get_fou_ports)"
    for port in "$P1" "$P2"; do
        if is_valid_port "$port"; then
            ip fou add port "$port" ipproto 47 >/dev/null 2>&1 || true
            iptables -C INPUT -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
                iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw allow "$port"/udp >/dev/null 2>&1 || true
            fi
        fi
    done
    ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
}

carrier_apply() {
    local TARGET="${1:-direct}"
    local SPECIFIC_IF="${2:-}"
    carrier_init_kernel

    local IFS_TO_APPLY=()
    if [[ -n "$SPECIFIC_IF" ]]; then
        IFS_TO_APPLY+=("$SPECIFIC_IF")
    else
        local dev
        for dev in $(ip -o link show type gre 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            [[ "$dev" == "gre0" || "$dev" == "gretap0" ]] && continue
            IFS_TO_APPLY+=("$dev")
        done
        [[ ${#IFS_TO_APPLY[@]} -eq 0 ]] && IFS_TO_APPLY+=("$TUNNEL_NAME")
    fi

    for dev in "${IFS_TO_APPLY[@]}"; do
        if ip link show "$dev" >/dev/null 2>&1; then
            local DEV_IP=""
            DEV_IP=$(ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
            local TARGET_MTU=1380
            [[ "$TARGET" == wss* ]] && TARGET_MTU=1360

            local CHANGED=0
            if [[ "$TARGET" == "direct" ]]; then
                iptables -t nat -D OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || true
                ip link set dev "$dev" type gre encap none >/dev/null 2>&1 && CHANGED=1
            elif [[ "$TARGET" == fou:* ]]; then
                local DPORT="${TARGET#fou:}"
                if is_valid_port "$DPORT"; then
                    ip fou add port "$DPORT" ipproto 47 >/dev/null 2>&1 || true
                    ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport "$DPORT" >/dev/null 2>&1 && CHANGED=1
                fi
            elif [[ "$TARGET" == wss* ]]; then
                ip fou add port 19998 ipproto 47 >/dev/null 2>&1 || true
                iptables -t nat -C OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || \
                    iptables -t nat -A OUTPUT -p udp --dport 19999 -j DNAT --to-destination 127.0.0.1:19999 >/dev/null 2>&1 || true
                ip link set dev "$dev" type gre encap fou encap-sport auto encap-dport 19999 >/dev/null 2>&1 && CHANGED=1
            fi

            ip link set dev "$dev" up mtu "$TARGET_MTU" >/dev/null 2>&1 || true
            if [[ -n "$DEV_IP" ]] && ! ip -o -4 addr show dev "$dev" 2>/dev/null | grep -q "${DEV_IP%/*}"; then
                ip addr add "$DEV_IP" dev "$dev" >/dev/null 2>&1 || true
            fi
            iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
                iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
        fi
    done

    python3 -c '
import json, os, sys, time
p = "'"$CARRIER_FILE"'"
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d["active_carrier"] = sys.argv[1]
d["last_switch"] = time.strftime("%Y-%m-%d %H:%M:%S")
d["switch_count"] = int(d.get("switch_count", 0)) + 1
with open(p + ".tmp", "w") as f:
    json.dump(d, f, indent=2)
os.replace(p + ".tmp", p)
os.chmod(p, 0o600)
' "$TARGET" 2>/dev/null || true
    return 0
}

carrier_apply_active() {
    local IFNAME="${1:-}"
    local ACT=""
    if [[ -n "$IFNAME" && -f "$PEERS_FILE" ]]; then
        ACT=$(python3 -c '
import json, sys
ifname = sys.argv[1]
try:
    with open("'"$PEERS_FILE"'") as f:
        d = json.load(f)
    for p in d.get("peers", []):
        if p.get("gre_if") == ifname and p.get("carrier"):
            print(p["carrier"])
            sys.exit(0)
except Exception:
    pass
' "$IFNAME" 2>/dev/null || true)
    fi
    [[ -z "$ACT" ]] && ACT=$(carrier_get_active)
    carrier_apply "$ACT" "$IFNAME"
}

carrier_cycle_next() {
    init_carrier_json
    local NEXT
    NEXT=$(python3 -c '
import json
path = "'"$CARRIER_FILE"'"
try:
    with open(path) as f:
        d = json.load(f)
    cur = d.get("active_carrier", "direct")
    p1, p2, wp = d.get("fou_port1", 443), d.get("fou_port2", 55555), d.get("wss_port", 8443)
    cands = d.get("candidates", ["direct", f"fou:{p1}", f"fou:{p2}", f"wss:{wp}"])
    idx = (cands.index(cur) + 1) % len(cands) if cur in cands else 0
    print(cands[idx] if cands else "direct")
except Exception:
    print("direct")
' 2>/dev/null || echo "direct")
    carrier_apply "$NEXT" >/dev/null 2>&1
    echo "$NEXT"
}

# ---- Setup Bundles ----
BUNDLE_PREFIX="hsh1_"
BUNDLE_PREFIX_BACKHAUL="bh1_"
BUNDLE_PREFIX_GRE_BACKHAUL="gh1_"

bundle_make() {
    local IRAN_PUB=$1 FRP_PORT=$2 IRAN_GRE=$3 FOREIGN_GRE=$4 TOKEN=$5 PORTS_SP=${6:-} FOU_ARG=${7:-} FRP_TRANS=${8:-}
    local PORTS_DASH=""
    [[ -n "$PORTS_SP" ]] && PORTS_DASH=$(echo "$PORTS_SP" | xargs | tr ' ' '-')
    if [[ -z "$FOU_ARG" ]]; then
        local P1 P2
        read -r P1 P2 <<< "$(carrier_get_fou_ports 2>/dev/null || echo '443 55555')"
        FOU_ARG="${P1}-${P2}"
    fi
    local TR_SUFFIX=""
    [[ -n "$FRP_TRANS" && "$FRP_TRANS" != "tcp" ]] && TR_SUFFIX="_tr-${FRP_TRANS}"
    if [[ -n "$PORTS_DASH" ]]; then
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}_${PORTS_DASH}_fou${FOU_ARG}${TR_SUFFIX}"
    else
        echo "${BUNDLE_PREFIX}${IRAN_PUB}_${FRP_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TOKEN}__fou${FOU_ARG}${TR_SUFFIX}"
    fi
}

bundle_make_backhaul() {
    local IRAN_PUB=$1 BH_PORT=$2 TRANSPORT=${3:-tcpmux} TOKEN=$4 PORTS=${5:-}
    local P_STR=""
    [[ -n "$PORTS" ]] && P_STR=$(echo "$PORTS" | tr ' ' ',' | tr -s ',')
    if [[ -n "$P_STR" ]]; then
        echo "${BUNDLE_PREFIX_BACKHAUL}${IRAN_PUB}_${BH_PORT}_${TRANSPORT}_${TOKEN}_${P_STR}"
    else
        echo "${BUNDLE_PREFIX_BACKHAUL}${IRAN_PUB}_${BH_PORT}_${TRANSPORT}_${TOKEN}"
    fi
}

bundle_make_gre_backhaul() {
    local IRAN_PUB=$1 BH_PORT=$2 IRAN_GRE=$3 FOREIGN_GRE=$4 TRANSPORT=${5:-tcpmux} TOKEN=$6 PORTS=${7:-}
    local P_STR=""
    [[ -n "$PORTS" ]] && P_STR=$(echo "$PORTS" | tr ' ' ',' | tr -s ',')
    if [[ -n "$P_STR" ]]; then
        echo "${BUNDLE_PREFIX_GRE_BACKHAUL}${IRAN_PUB}_${BH_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TRANSPORT}_${TOKEN}_${P_STR}"
    else
        echo "${BUNDLE_PREFIX_GRE_BACKHAUL}${IRAN_PUB}_${BH_PORT}_${IRAN_GRE}_${FOREIGN_GRE}_${TRANSPORT}_${TOKEN}"
    fi
}

bundle_parse() {
    local IN=$1
    if [[ "$IN" == ${BUNDLE_PREFIX_BACKHAUL}* ]]; then
        B_ENGINE="backhaul"; B_IRAN_PUB=""; B_FRP_PORT=""; B_TRANSPORT="tcpmux"; B_TOKEN=""; B_PORTS=""
        local rest=${IN#${BUNDLE_PREFIX_BACKHAUL}} a b c d e
        IFS=_ read -r a b c d e <<<"$rest"
        [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
        is_valid_ip "$a" && is_valid_port "$b" || return 1
        B_IRAN_PUB="$a"; B_FRP_PORT="$((10#$b))"; B_TRANSPORT="$c"; B_TOKEN="$d"; B_PORTS="${e:-}"
        return 0
    elif [[ "$IN" == ${BUNDLE_PREFIX_GRE_BACKHAUL}* ]]; then
        B_ENGINE="gre-backhaul"; B_IRAN_PUB=""; B_FRP_PORT=""; B_IRAN_GRE=""; B_FOREIGN_GRE=""; B_TRANSPORT="tcpmux"; B_TOKEN=""; B_PORTS=""
        local rest=${IN#${BUNDLE_PREFIX_GRE_BACKHAUL}} a b c d e f g
        IFS=_ read -r a b c d e f g <<<"$rest"
        [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" && -n "$f" ]] || return 1
        is_valid_ip "$a" && is_valid_port "$b" && is_valid_ip "$c" && is_valid_ip "$d" || return 1
        B_IRAN_PUB="$a"; B_FRP_PORT="$((10#$b))"; B_IRAN_GRE="$c"; B_FOREIGN_GRE="$d"; B_TRANSPORT="$e"; B_TOKEN="$f"; B_PORTS="${g:-}"
        return 0
    fi
    B_ENGINE="frp"; B_IRAN_PUB=""; B_FRP_PORT=""; B_IRAN_GRE=""; B_FOREIGN_GRE=""; B_TOKEN=""; B_PORTS=""; B_TRANSPORT="tcp"; B_FOU_P1=443; B_FOU_P2=55555
    local rest a b c d e f g h
    [[ "$IN" == ${BUNDLE_PREFIX}* ]] || return 1
    rest=${IN#${BUNDLE_PREFIX}}
    IFS=_ read -r a b c d e f g h <<<"$rest"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" && -n "$e" ]] || return 1
    is_valid_ip "$a" && is_valid_port "$b" && is_valid_ip "$c" && is_valid_ip "$d" || return 1
    local CLEANED="" p
    if [[ -n "${f:-}" && "$f" != fou* && "$f" != tr-* ]]; then
        for p in $(echo "$f" | tr -- '-,' '  '); do
            is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"
        done
        CLEANED=$(echo "$CLEANED" | xargs)
        [[ -n "$CLEANED" ]] || return 1
    fi
    local FOU_RAW=""
    for seg in "$f" "$g" "$h"; do
        if [[ "$seg" == tr-* ]]; then
            B_TRANSPORT="${seg#tr-}"
        elif [[ "$seg" == fou* ]]; then
            FOU_RAW="$seg"
        fi
    done
    if [[ -n "$FOU_RAW" ]]; then
        local FP1 FP2
        IFS=- read -r FP1 FP2 <<< "${FOU_RAW#fou}"
        is_valid_port "$FP1" && B_FOU_P1=$((10#$FP1))
        is_valid_port "$FP2" && B_FOU_P2=$((10#$FP2))
    fi
    B_IRAN_PUB=$a; B_FRP_PORT=$((10#$b)); B_IRAN_GRE=$c; B_FOREIGN_GRE=$d; B_TOKEN=$e; B_PORTS=$CLEANED
    return 0
}

prompt_ip() {
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        if [[ -n "$__def" ]]; then
            read -p "$__label [Default: $__def]: " __in
            __in=${__in:-$__def}
        else
            read -p "$__label: " __in
        fi
        if is_valid_ip "$__in"; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] Invalid IPv4 address: '${__in}'.${NC}"
    done
}

prompt_port() {
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -p "$__label [Default: $__def]: " __in
        __in=${__in:-$__def}
        if is_valid_port "$__in"; then printf -v "$__var" '%s' "$((10#$__in))"; return 0; fi
        echo -e "${RED}[!] Invalid port: '${__in}'. Must be 1-65535.${NC}"
    done
}

prompt_required() {
    local __var=$1 __label=$2 __in
    while true; do
        read -p "$__label: " __in
        if [[ -n "$__in" ]]; then printf -v "$__var" '%s' "$__in"; return 0; fi
        echo -e "${RED}[!] This field is required.${NC}"
    done
}

prompt_token() {
    local __var=$1 __label=$2 __def=$3 __in
    while true; do
        read -p "$__label [Press Enter for: $__def]: " __in
        __in="${__in:-$__def}"
        if [[ "$__in" == *"_"* ]]; then
            echo -e "${RED}[!] Token cannot contain underscores ('_').${NC}"
        else
            printf -v "$__var" '%s' "$__in"
            return 0
        fi
    done
}

prompt_ports() {
    local __var=$1 __label=$2 __in __ok p
    while true; do
        read -p "$__label (e.g. 443, 2083, 8080): " __in
        __ok=""
        for p in $(echo "$__in" | tr ',' ' '); do
            is_valid_port "$p" && __ok="$__ok $((10#$p))"
        done
        __ok=$(echo "$__ok" | xargs)
        if [[ -n "$__ok" ]]; then printf -v "$__var" '%s' "$__ok"; return 0; fi
        echo -e "${RED}[!] Enter at least one valid port (1-65535).${NC}"
    done
}

validate_setup_common() {
    local ok=1
    is_valid_ip "$1" || { echo -e "${RED}[!] Invalid local public IP: '$1'${NC}"; ok=0; }
    is_valid_ip "$2" || { echo -e "${RED}[!] Invalid remote public IP: '$2'${NC}"; ok=0; }
    is_valid_port "$3" || { echo -e "${RED}[!] Invalid FRP port: '$3'${NC}"; ok=0; }
    is_valid_ip "$4" || { echo -e "${RED}[!] Invalid local GRE IP: '$4'${NC}"; ok=0; }
    return $((1 - ok))
}

tunnel_present() {
    ip link show "$TUNNEL_NAME" >/dev/null 2>&1 && return 0
    ip tunnel show 2>/dev/null | grep -q "$TUNNEL_NAME" && return 0
    [[ -f "${CONFIG_DIR}/frps.toml" || -f "${CONFIG_DIR}/frpc.toml" ]] && return 0
    return 1
}

# ---- Dial Route (Foreign Side) ----
dial_env_file() { echo "${CONFIG_DIR}/dial.env"; }

dial_env_write() {
    mkdir -p "$CONFIG_DIR"
    printf 'DIAL_MODE=%s\nDIAL_KIND=%s\nDIAL_GRE=%s\nDIAL_PUBLIC=%s\n' "$1" "$2" "$3" "$4" > "$(dial_env_file)"
    chmod 600 "$(dial_env_file)" 2>/dev/null || true
}

dial_env_get() {
    local f; f="$(dial_env_file)"
    [[ -f "$f" ]] || return 1
    sed -n "s/^$1=//p" "$f" | head -n1
}

dial_conf_file() {
    if [[ "$1" == "backhaul" ]]; then echo "${BACKHAUL_CONFIG_DIR:-/etc/backhaul}/client.toml"; else echo "${CONFIG_DIR}/frpc.toml"; fi
}

dial_service() { [[ "$1" == "backhaul" ]] && echo backhaul-client || echo frpc; }

dial_current_addr() {
    local f; f="$(dial_conf_file "$1")"
    [[ -f "$f" ]] || return 1
    if [[ "$1" == "backhaul" ]]; then
        sed -n 's/^remote_addr[[:space:]]*=[[:space:]]*"\([^":]*\):[0-9]*".*/\1/p' "$f" | head -n1
    else
        sed -n 's/^serverAddr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1
    fi
}

dial_current_port() {
    local f; f="$(dial_conf_file "$1")"
    [[ -f "$f" ]] || return 1
    if [[ "$1" == "backhaul" ]]; then
        sed -n 's/^remote_addr[[:space:]]*=[[:space:]]*"[^":]*:\([0-9]*\)".*/\1/p' "$f" | head -n1
    else
        sed -n 's/^serverPort[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -n1
    fi
}

dial_gre_usable() {
    ping -c 2 -W 2 "$1" >/dev/null 2>&1 && return 0
    timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1 && return 0
    return 1
}

dial_pick() {
    case "$1" in
        gre)    echo "$2" ;;
        public) echo "$3" ;;
        *)      if dial_gre_usable "$2" "$4"; then echo "$2"; else echo "$3"; fi ;;
    esac
}

dial_apply_addr() {
    local f; f="$(dial_conf_file "$1")"
    [[ -f "$f" ]] || return 1
    if [[ "$1" == "backhaul" ]]; then
        sed -i -E "s|^remote_addr[[:space:]]*=.*|remote_addr = \"$2:$3\"|" "$f"
    else
        sed -i -E "s|^serverAddr[[:space:]]*=.*|serverAddr = \"$2\"|" "$f"
    fi
}

dial_env_ensure() {
    [[ -f "$(dial_env_file)" ]] && return 0
    local kind="" cur pub inner gre a b c d
    if [[ -f "${CONFIG_DIR}/frpc.toml" ]]; then kind=frp
    elif [[ -f "${BACKHAUL_CONFIG_DIR:-/etc/backhaul}/client.toml" ]]; then kind=backhaul
    else return 1; fi
    cur=$(dial_current_addr "$kind"); [[ -n "$cur" ]] || return 1
    pub=$(ip tunnel show "$TUNNEL_NAME" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="remote") print $(i+1)}' | head -n1)
    inner=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
    gre=""
    if [[ "$cur" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
        gre="$cur"
    elif [[ -n "$inner" ]]; then
        IFS=. read -r a b c d <<< "$inner"
        if (( d % 2 == 0 )); then gre="$a.$b.$c.$((d - 1))"; else gre="$a.$b.$c.$((d + 1))"; fi
    fi
    [[ -z "$pub" && "$cur" != "$gre" ]] && pub="$cur"
    [[ -n "$gre" && -n "$pub" ]] || return 1
    dial_env_write auto "$kind" "$gre" "$pub"
}

dial_reselect() {
    dial_env_ensure || return 1
    local mode kind gre pub port cur want
    kind=$(dial_env_get DIAL_KIND); gre=$(dial_env_get DIAL_GRE); pub=$(dial_env_get DIAL_PUBLIC)
    mode="${1:-$(dial_env_get DIAL_MODE)}"; mode="${mode:-auto}"
    port=$(dial_current_port "$kind"); cur=$(dial_current_addr "$kind")
    [[ -n "$kind" && -n "$port" && -n "$cur" ]] || return 1
    want=$(dial_pick "$mode" "$gre" "$pub" "$port")
    [[ -n "$want" ]] || return 1
    if [[ "$want" == "$cur" ]]; then
        echo "same:$cur"
    else
        dial_apply_addr "$kind" "$want" "$port" || return 1
        echo "changed:$want"
    fi
}

dial_connected() {
    ss -Htn state established 2>/dev/null | awk -v a="$1:$2" '$4==a {f=1} END {exit !f}'
}

dial_watch_tick() {
    [[ -f "$(dial_env_file)" ]] || return 0
    [[ "$(dial_env_get DIAL_MODE)" == "auto" ]] || return 0
    local kind gre pub port cur svc
    kind=$(dial_env_get DIAL_KIND); gre=$(dial_env_get DIAL_GRE); pub=$(dial_env_get DIAL_PUBLIC)
    port=$(dial_current_port "$kind"); cur=$(dial_current_addr "$kind")
    [[ -n "$port" && "$cur" == "$gre" ]] || return 0
    dial_connected "$cur" "$port" && return 0
    dial_gre_usable "$gre" "$port" && return 0
    dial_apply_addr "$kind" "$pub" "$port" || return 0
    svc=$(dial_service "$kind")
    systemctl restart "$svc" >/dev/null 2>&1 || true
    log_msg "tunnel" "WARN" "GRE path to ${gre} dead; ${svc} now dials Iran public ${pub}:${port}" 2>/dev/null || true
}

cli_dial() {
    local sub="${1:-status}"
    case "$sub" in
        status)
            if ! dial_env_ensure; then echo "available=0"; return 0; fi
            local kind cur port mode gre pub active
            kind=$(dial_env_get DIAL_KIND); gre=$(dial_env_get DIAL_GRE); pub=$(dial_env_get DIAL_PUBLIC)
            mode=$(dial_env_get DIAL_MODE); cur=$(dial_current_addr "$kind"); port=$(dial_current_port "$kind")
            active="other"; [[ "$cur" == "$gre" ]] && active=gre; [[ "$cur" == "$pub" ]] && active=public
            echo "available=1"; echo "mode=${mode:-auto}"; echo "active=$active"; echo "addr=$cur"
            echo "port=$port"; echo "gre=$gre"; echo "public=$pub"; echo "kind=$kind"
            ;;
        auto|gre|public)
            dial_env_ensure || { echo -e "${RED}[!] No foreign client config found.${NC}"; return 1; }
            sed -i -E "s/^DIAL_MODE=.*/DIAL_MODE=${sub}/" "$(dial_env_file)"
            local r; r=$(dial_reselect "$sub") || { echo -e "${RED}[!] Could not apply dial route.${NC}"; return 1; }
            if [[ "$r" == changed:* ]]; then
                systemctl restart "$(dial_service "$(dial_env_get DIAL_KIND)")" >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[✔️] Dial route: ${sub} (${r#*:})${NC}"
            ;;
        *) echo "Usage: hashem dial [status|auto|gre|public]"; return 1 ;;
    esac
}

check_root() {
    [[ "${HASHEM_NO_ROOT_CHECK:-0}" == "1" ]] && return 0
    if [[ ${EUID:-$(id -u 2>/dev/null || echo 1)} -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) FRP_ARCH="amd64" ;;
        aarch64|arm64) FRP_ARCH="arm64" ;;
        armv7l|armhf) FRP_ARCH="arm" ;;
        *) echo -e "${RED}[!] Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
}

get_latest_frp_version() {
    if [[ -n "${FRP_VERSION:-}" && "$FRP_VERSION" != "$DEFAULT_FRP_VERSION" ]]; then
        return 0
    fi
    local MIRROR_REPO="${HASHEM_MIRROR_REPO:-pdnczone/hashem-frp}"
    LATEST_VER=$(curl -sSL --connect-timeout 3 --max-time 6 "https://api.github.com/repos/${MIRROR_REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        LATEST_VER=$(curl -sSL --connect-timeout 3 --max-time 6 "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    fi
    FRP_VERSION="${LATEST_VER:-$DEFAULT_FRP_VERSION}"
}

is_valid_download() {
    local target="$1"
    [[ -s "$target" ]] || return 1
    if head -c 256 "$target" 2>/dev/null | grep -qiE "<!doctype|<html|<head|<title|404 not found|403 forbidden|access denied|rate limit"; then
        return 1
    fi
    if [[ "$target" == *.tar.gz || "$target" == *.tgz ]]; then
        gzip -t "$target" 2>/dev/null || return 1
    fi
    return 0
}

download_with_fallback() {
    local DEST="$1"
    local URL="$2"
    local TIMEOUT="${3:-45}"

    if is_valid_download "$DEST"; then
        return 0
    fi
    rm -f "$DEST" 2>/dev/null

    local DIRECT_CONNECT_TO=8
    local STALL=(--speed-limit 2048 --speed-time 10)
    if [[ "$URL" == https://github.com/* || "$URL" == https://raw.githubusercontent.com/* ]]; then
        DIRECT_CONNECT_TO=5
    fi

    if curl -fsSL --connect-timeout "$DIRECT_CONNECT_TO" --max-time "$TIMEOUT" "${STALL[@]}" -o "$DEST" "$URL" 2>/dev/null && is_valid_download "$DEST"; then
        return 0
    fi
    rm -f "$DEST" 2>/dev/null

    if [[ "$URL" == https://github.com/* || "$URL" == https://raw.githubusercontent.com/* ]]; then
        echo -e "${YELLOW}[*] Direct download timed out — trying mirror...${NC}"
        local MIRRORS=(
            "https://mirror.ghproxy.com/${URL}"
            "https://ghproxy.net/${URL}"
            "https://ghproxy.cc/${URL}"
            "https://gh-proxy.com/${URL}"
            "https://gh.ddlc.top/${URL}"
        )
        for M in "${MIRRORS[@]}"; do
            rm -f "$DEST" 2>/dev/null
            if curl -fsSL --connect-timeout 6 --max-time "$TIMEOUT" "${STALL[@]}" -o "$DEST" "$M" 2>/dev/null && is_valid_download "$DEST"; then
                echo -e "${GREEN}[✔️] Download succeeded via mirror: ${M%/*}${NC}"
                return 0
            fi
            rm -f "$DEST" 2>/dev/null
        done
    fi
    return 1
}

install_frp_binaries() {
    local ROLE="${1:-all}"
    [[ "$ROLE" == "server" && -x "${INSTALL_DIR}/frps" ]] && return 0
    [[ "$ROLE" == "client" && -x "${INSTALL_DIR}/frpc" ]] && return 0
    [[ -x "${INSTALL_DIR}/frps" && -x "${INSTALL_DIR}/frpc" ]] && return 0

    detect_arch
    get_latest_frp_version
    echo -e "${CYAN}[*] Downloading FRP v${FRP_VERSION} (${FRP_ARCH})...${NC}"

    mkdir -p "$CONFIG_DIR"
    local TMP_DIR TAR_FILE MIRROR_REPO DOWNLOAD_URL
    TMP_DIR=$(mktemp -d)
    TAR_FILE="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    MIRROR_REPO="${HASHEM_MIRROR_REPO:-pdnczone/hashem-frp}"
    DOWNLOAD_URL="https://github.com/${MIRROR_REPO}/releases/download/v${FRP_VERSION}/${TAR_FILE}"

    if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL" 45; then
        local FALLBACK_VER="0.61.1"
        local FALLBACK_TAR="frp_${FALLBACK_VER}_linux_${FRP_ARCH}.tar.gz"
        if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "https://github.com/${MIRROR_REPO}/releases/download/v${FALLBACK_VER}/${FALLBACK_TAR}" 45; then
            if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "https://github.com/fatedier/frp/releases/download/v${FALLBACK_VER}/${FALLBACK_TAR}" 45; then
                echo -e "${RED}[!] Failed to download FRP binaries.${NC}"
                rm -rf "$TMP_DIR"
                return 1
            fi
        fi
    fi

    if ! tar -xzf "${TMP_DIR}/${TAR_FILE}" -C "$TMP_DIR" 2>/dev/null; then
        echo -e "${RED}[!] Corrupted FRP archive.${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi
    local FOUND_FRPS FOUND_FRPC
    FOUND_FRPS=$(find "$TMP_DIR" -type f -name "frps" 2>/dev/null | head -1)
    FOUND_FRPC=$(find "$TMP_DIR" -type f -name "frpc" 2>/dev/null | head -1)
    [[ -n "$FOUND_FRPS" ]] && cp -f "$FOUND_FRPS" "$INSTALL_DIR/" 2>/dev/null
    [[ -n "$FOUND_FRPC" ]] && cp -f "$FOUND_FRPC" "$INSTALL_DIR/" 2>/dev/null
    chmod +x "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc" 2>/dev/null || true
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}[✔️] FRP installed to ${INSTALL_DIR}.${NC}"
}

BACKHAUL_CONFIG_DIR="/etc/backhaul"
DEFAULT_BACKHAUL_VERSION="v0.7.2"

install_backhaul_binaries() {
    [[ -x "${INSTALL_DIR}/backhaul" ]] && return 0
    detect_arch
    local BH_ARCH="$FRP_ARCH" BH_VER="$DEFAULT_BACKHAUL_VERSION"
    echo -e "${CYAN}[*] Downloading Backhaul ${BH_VER} (${BH_ARCH})...${NC}"

    mkdir -p "$BACKHAUL_CONFIG_DIR"
    local TMP_DIR TAR_FILE DOWNLOAD_URL
    TMP_DIR=$(mktemp -d)
    TAR_FILE="backhaul_linux_${BH_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/Musixal/Backhaul/releases/download/${BH_VER}/${TAR_FILE}"

    if ! download_with_fallback "${TMP_DIR}/${TAR_FILE}" "$DOWNLOAD_URL" 45; then
        echo -e "${RED}[!] Failed to download Backhaul.${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    tar -xzf "${TMP_DIR}/${TAR_FILE}" -C "$TMP_DIR" 2>/dev/null || { rm -rf "$TMP_DIR"; return 1; }
    local FOUND
    FOUND=$(find "$TMP_DIR" -type f -name "backhaul" 2>/dev/null | head -n 1)
    [[ -n "$FOUND" ]] && cp "$FOUND" "$INSTALL_DIR/" 2>/dev/null
    chmod +x "${INSTALL_DIR}/backhaul" 2>/dev/null
    rm -rf "$TMP_DIR"

    if [[ -x "${INSTALL_DIR}/backhaul" ]]; then
        mkdir -p "/root/backhaul-core" 2>/dev/null || true
        cp -f "${INSTALL_DIR}/backhaul" "/root/backhaul-core/backhaul_premium" 2>/dev/null || ln -sf "${INSTALL_DIR}/backhaul" "/root/backhaul-core/backhaul_premium"
        chmod +x "/root/backhaul-core/backhaul_premium" 2>/dev/null || true
        echo -e "${GREEN}[✔️] Backhaul installed to ${INSTALL_DIR}/backhaul.${NC}"
        return 0
    fi
    return 1
}

backhaul_ensure_tls() {
    mkdir -p "$BACKHAUL_CONFIG_DIR"
    if [[ ! -f "${BACKHAUL_CONFIG_DIR}/server.crt" || ! -f "${BACKHAUL_CONFIG_DIR}/server.key" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "${BACKHAUL_CONFIG_DIR}/server.key" \
            -out "${BACKHAUL_CONFIG_DIR}/server.crt" \
            -subj "/CN=backhaul" >/dev/null 2>&1 || true
        chmod 600 "${BACKHAUL_CONFIG_DIR}/server.key" 2>/dev/null || true
    fi
}

backhaul_is_v2() {
    local bin="${INSTALL_DIR:-/usr/local/bin}/backhaul" v
    [[ -x "$bin" ]] || bin="$(command -v backhaul 2>/dev/null)"
    [[ -n "$bin" ]] || return 1
    v="$("$bin" -v 2>/dev/null | head -n1)"
    [[ "$v" =~ ^v?2\. ]]
}

backhaul_write_server_conf_v1() {
    local CONF_FILE="$1" BIND_ADDR="$2" TRANSPORT="${3:-tcpmux}" TOKEN="$4" PORTS_LIST="$5"
    mkdir -p "$(dirname "$CONF_FILE")"
    [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]] && backhaul_ensure_tls
    cat <<EOF > "$CONF_FILE"
[server]
bind_addr = "${BIND_ADDR}"
transport = "${TRANSPORT}"
token = "${TOKEN}"
keepalive_period = 75
nodelay = true
heartbeat = 40
channel_size = 2048
sniffer = false
web_port = 0
sniffer_log = ""
log_level = "info"
EOF
    if [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]]; then
        cat <<EOF >> "$CONF_FILE"
tls_cert = "${BACKHAUL_CONFIG_DIR}/server.crt"
tls_key = "${BACKHAUL_CONFIG_DIR}/server.key"
EOF
    fi
    echo "ports = [" >> "$CONF_FILE"
    local FIRST=1
    IFS=',' read -ra ADDR <<< "$PORTS_LIST"
    for p in "${ADDR[@]}"; do
        p=$(echo "$p" | xargs)
        [[ -z "$p" ]] && continue
        if [[ $FIRST -eq 1 ]]; then echo "  \"$p\"" >> "$CONF_FILE"; FIRST=0
        else echo "  ,\"$p\"" >> "$CONF_FILE"; fi
    done
    echo "]" >> "$CONF_FILE"
}

backhaul_write_client_conf_v1() {
    local CONF_FILE="$1" REMOTE_ADDR="$2" TRANSPORT="${3:-tcpmux}" TOKEN="$4"
    mkdir -p "$(dirname "$CONF_FILE")"
    cat <<EOF > "$CONF_FILE"
[client]
remote_addr = "${REMOTE_ADDR}"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = 8
nodelay = true
retry_interval = 3
keepalive_period = 75
sniffer = false
web_port = 0
sniffer_log = ""
log_level = "info"
EOF
}

backhaul_write_server_conf_v2() {
    local CONF_FILE="$1" BIND_ADDR="$2" TRANSPORT="$3" TOKEN="$4" PORTS_LIST="$5"
    mkdir -p "$(dirname "$CONF_FILE")"
    [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]] && backhaul_ensure_tls
    {
        printf '[listener]\nbind_addr = "%s"\n\n' "$BIND_ADDR"
        printf '[transport]\ntype = "%s"\nnodelay = true\nkeepalive_period = 75\n\n' "$TRANSPORT"
        printf '[security]\ntoken = "%s"\n\n' "$TOKEN"
        [[ "$TRANSPORT" == *mux ]] && printf '[mux]\nmux_version = 1\n\n'
        if [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]]; then
            printf '[tls]\ntls_cert = "%s/server.crt"\ntls_key = "%s/server.key"\n\n' "$BACKHAUL_CONFIG_DIR" "$BACKHAUL_CONFIG_DIR"
        fi
        printf '[logging]\nlog_level = "info"\n\n[ports]\nmapping = [\n'
        local p
        IFS=',' read -ra _ADDR <<< "$PORTS_LIST"
        for p in "${_ADDR[@]}"; do
            p="$(echo "$p" | xargs)"
            [[ -z "$p" ]] && continue
            printf '    "%s",\n' "$p"
        done
        printf ']\n'
    } > "$CONF_FILE"
}

backhaul_write_client_conf_v2() {
    local CONF_FILE="$1" REMOTE_ADDR="$2" TRANSPORT="${3:-tcpmux}" TOKEN="$4"
    mkdir -p "$(dirname "$CONF_FILE")"
    {
        printf '[dialer]\nremote_addr = "%s"\ndial_timeout = 10\nretry_interval = 3\n\n' "$REMOTE_ADDR"
        printf '[transport]\ntype = "%s"\nconnection_pool = 8\nnodelay = true\nkeepalive_period = 75\n\n' "$TRANSPORT"
        printf '[security]\ntoken = "%s"\n\n' "$TOKEN"
        [[ "$TRANSPORT" == *mux ]] && printf '[mux]\nmux_version = 1\n\n'
        [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]] && printf '[tls]\nsni = "%s"\n\n' "${REMOTE_ADDR%%:*}"
        printf '[logging]\nlog_level = "info"\n'
    } > "$CONF_FILE"
}

backhaul_write_server_conf() {
    if backhaul_is_v2; then backhaul_write_server_conf_v2 "$@"; else backhaul_write_server_conf_v1 "$@"; fi
}

backhaul_write_client_conf() {
    if backhaul_is_v2; then backhaul_write_client_conf_v2 "$@"; else backhaul_write_client_conf_v1 "$@"; fi
}

setup_backhaul_server_systemd() {
    local SVC_NAME="${1:-backhaul-server}"
    local CONF_FILE="${2:-${BACKHAUL_CONFIG_DIR}/config.toml}"
    cat <<EOF > "/etc/systemd/system/${SVC_NAME}.service"
[Unit]
Description=Backhaul Server Tunnel (${SVC_NAME})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${CONF_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=1048576
CPUWeight=100

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SVC_NAME}.service" >/dev/null 2>&1 || true
    systemctl restart "${SVC_NAME}.service"
}

setup_backhaul_client_systemd() {
    local SVC_NAME="${1:-backhaul-client}"
    local CONF_FILE="${2:-${BACKHAUL_CONFIG_DIR}/client.toml}"
    cat <<EOF > "/etc/systemd/system/${SVC_NAME}.service"
[Unit]
Description=Backhaul Client Tunnel (${SVC_NAME})
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${CONF_FILE}
Restart=always
RestartSec=3s
LimitNOFILE=1048576
CPUWeight=100

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SVC_NAME}.service" >/dev/null 2>&1 || true
    systemctl restart "${SVC_NAME}.service"
}

setup_gre_systemd() {
    setup_gre_iface "$TUNNEL_NAME" "$1" "$2" "$3" "$4"
}

setup_gre_iface() {
    local IFNAME=$1 LOCAL_IP=$2 REMOTE_IP=$3 GRE_INTERNAL_IP=$4 PEER_INNER=$5
    local CLEAN_GRE_IP="${GRE_INTERNAL_IP%/*}"
    echo -e "${CYAN}[*] Configuring persistent GRE tunnel service (${IFNAME})...${NC}"
    ensure_hashem_bin

    local IP_BIN
    IP_BIN=$(command -v ip || echo "/sbin/ip")
    modprobe ip_gre >/dev/null 2>&1 || true
    modprobe fou >/dev/null 2>&1 || true

    "$IP_BIN" link del "$IFNAME" >/dev/null 2>&1 || "$IP_BIN" tunnel del "$IFNAME" >/dev/null 2>&1 || true

    local LOCAL_ARG=""
    if [[ -n "$LOCAL_IP" ]] && "$IP_BIN" -o addr show 2>/dev/null | grep -qw "$LOCAL_IP"; then
        LOCAL_ARG="local ${LOCAL_IP}"
    else
        local NIC_IP
        NIC_IP=$("$IP_BIN" route get "$REMOTE_IP" 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
        [[ -n "$NIC_IP" ]] && LOCAL_ARG="local ${NIC_IP}"
    fi

    if [[ -z "$PEER_INNER" ]]; then
        if [[ "$CLEAN_GRE_IP" =~ \.2$ ]]; then PEER_INNER="${CLEAN_GRE_IP%.*}.1"
        else PEER_INNER="${CLEAN_GRE_IP%.*}.2"; fi
    fi

    cat <<EOF > /etc/systemd/system/${IFNAME}.service
[Unit]
Description=GRE Tunnel Interface (${IFNAME})
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/bin/sh -c "modprobe ip_gre 2>/dev/null; modprobe fou 2>/dev/null; if [ -x /usr/local/bin/hashem ]; then /usr/local/bin/hashem carrier-kernel-init 2>/dev/null; fi; true"
ExecStartPre=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"
ExecStart=/bin/sh -c '(\
    ${IP_BIN} link add ${IFNAME} type gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre ${LOCAL_ARG} remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} link add ${IFNAME} type gre remote ${REMOTE_IP} ttl 255 2>/dev/null || \
    ${IP_BIN} tunnel add ${IFNAME} mode gre remote ${REMOTE_IP} ttl 255 2>/dev/null || true); \
    ${IP_BIN} link set dev ${IFNAME} up mtu 1380 && \
    (${IP_BIN} addr replace ${CLEAN_GRE_IP}/30 dev ${IFNAME} 2>/dev/null || ${IP_BIN} addr add ${CLEAN_GRE_IP}/30 dev ${IFNAME} 2>/dev/null || true) && \
    (${IP_BIN} route replace ${PEER_INNER}/32 dev ${IFNAME} 2>/dev/null || true)'
ExecStartPost=-/bin/sh -c "if [ -x /usr/local/bin/hashem ]; then /usr/local/bin/hashem carrier-apply-active ${IFNAME} 2>/dev/null; fi; true"
ExecStop=-/bin/sh -c "${IP_BIN} link del ${IFNAME} 2>/dev/null || ${IP_BIN} tunnel del ${IFNAME} 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl reset-failed "${IFNAME}.service" >/dev/null 2>&1 || true
    systemctl enable "${IFNAME}.service" >/dev/null 2>&1
    systemctl restart "${IFNAME}.service" >/dev/null 2>&1 || true

    if ! "$IP_BIN" link show "$IFNAME" >/dev/null 2>&1 || ! "$IP_BIN" -4 addr show dev "$IFNAME" 2>/dev/null | grep -q "${CLEAN_GRE_IP}"; then
        return 1
    fi

    carrier_apply_active "${IFNAME}" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340

    echo -e "${GREEN}[✔️] GRE Tunnel service active with IP ${CLEAN_GRE_IP} (MTU 1380, MSS 1340).${NC}"
}

purge_legacy_obfuscation() {
    local u
    for u in /etc/systemd/system/gre-chaff*.service /etc/systemd/system/hashem-chaff*.service /etc/systemd/system/hashem-dpi.service; do
        [[ -f "$u" ]] || continue
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
    done
    pkill -f "hashem-chaff.sh" >/dev/null 2>&1 || true
    rm -f /usr/local/bin/hashem-chaff.sh /usr/local/bin/gre-chaff.sh
}

# ---- Performance Controls ----
perf_apply() {
    init_perf_json
    local EFF_ENC=$(perf_get_enc)
    local EFF_COMP=$(perf_get_comp)
    local EFF_MUX=$(perf_get_tcpmux)
    local EFF_POOL EFF_MAXPOOL
    read -r EFF_POOL EFF_MAXPOOL <<< "$(pool_effective_values)"

    local IS_FOREIGN=0 IS_IRAN=0
    [[ -f "${CONFIG_DIR}/frpc.toml" ]] && IS_FOREIGN=1
    for f in "${CONFIG_DIR}"/frps*.toml; do [[ -f "$f" ]] && IS_IRAN=1; done

    if [[ "$IS_FOREIGN" -eq 0 && "$IS_IRAN" -eq 0 ]]; then
        echo -e "${YELLOW}[!] No frps.toml or frpc.toml found in ${CONFIG_DIR}.${NC}"
        return 1
    fi

    if [[ "$IS_FOREIGN" -eq 1 ]] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
path = "'"${CONFIG_DIR}/frpc.toml"'"
enc = ("'"$EFF_ENC"'".strip() in ("1", "true", "True"))
comp = ("'"$EFF_COMP"'".strip() in ("1", "true", "True"))
mux_raw = "'"$EFF_MUX"'".strip()
pool_cnt = "'"$EFF_POOL"'".strip()
with open(path, "r") as f:
    lines = f.read().splitlines()
sections, current = [], []
for line in lines:
    if line.strip().startswith("[[proxies]]"):
        if current: sections.append(current)
        current = [line]
    else:
        current.append(line)
if current: sections.append(current)
out_sections = []
for i, sec in enumerate(sections):
    if i == 0 and not sec[0].strip().startswith("[[proxies]]"):
        final_hdr = []
        for l in sec:
            s = l.strip()
            if s.startswith("transport.poolCount"): continue
            if mux_raw in ("0", "1") and (s.startswith("transport.tcpMux ") or s.startswith("transport.tcpMux=") or s.startswith("transport.tcpMuxKeepaliveInterval")):
                continue
            final_hdr.append(l)
        if mux_raw in ("0", "1"):
            final_hdr.append("transport.tcpMux = true" if mux_raw == "1" else "transport.tcpMux = false")
            if mux_raw == "1": final_hdr.append("transport.tcpMuxKeepaliveInterval = 30")
        final_hdr.append("transport.poolCount = " + pool_cnt)
        out_sections.append(final_hdr)
    else:
        new_sec = [l for l in sec if not l.strip().startswith(("transport.useEncryption", "transport.useCompression"))]
        is_tcp = any("type = \"tcp\"" in l or "type=\"tcp\"" in l for l in sec)
        while new_sec and new_sec[-1].strip() == "": new_sec.pop()
        if enc and is_tcp: new_sec.append("transport.useEncryption = true")
        if comp and is_tcp: new_sec.append("transport.useCompression = true")
        new_sec.append("")
        out_sections.append(new_sec)
with open(path, "w") as f:
    f.write("\n".join("\n".join(s) for s in out_sections).strip() + "\n")
'
        systemctl restart frpc
        autopool_state_set applied_pool="$EFF_POOL" last_restart="$(date +%s)"
        echo -e "${GREEN}[✔️] frpc.toml updated & frpc restarted.${NC}"
    fi

    if [[ "$IS_IRAN" -eq 1 ]] && command -v python3 >/dev/null 2>&1; then
        for TOML_FILE in "${CONFIG_DIR}"/frps*.toml; do
            [[ -f "$TOML_FILE" ]] || continue
            python3 -c '
path = "'"$TOML_FILE"'"
mux_raw = "'"$EFF_MUX"'".strip()
max_pool = "'"$EFF_MAXPOOL"'".strip()
with open(path, "r") as f:
    lines = f.read().splitlines()
new_lines = []
for l in lines:
    s = l.strip()
    if mux_raw in ("0", "1") and (s.startswith("transport.tcpMux ") or s.startswith("transport.tcpMux=") or s.startswith("transport.tcpMuxKeepaliveInterval")):
        continue
    if s.startswith("transport.maxPoolCount"):
        continue
    new_lines.append(l)
if mux_raw in ("0", "1"):
    new_lines.append("transport.tcpMux = true" if mux_raw == "1" else "transport.tcpMux = false")
    if mux_raw == "1": new_lines.append("transport.tcpMuxKeepaliveInterval = 30")
new_lines.append("transport.maxPoolCount = " + max_pool)
with open(path, "w") as f:
    f.write("\n".join(new_lines).strip() + "\n")
'
        done
        systemctl restart frps >/dev/null 2>&1 || true
        for s in /etc/systemd/system/frps-*.service; do
            [[ -f "$s" ]] && systemctl restart "$(basename "$s")" >/dev/null 2>&1 || true
        done
        autopool_state_set frps_restart_needed=false
        echo -e "${GREEN}[✔️] frps toml(s) updated & restarted.${NC}"
    fi
}

cli_perf() {
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            init_perf_json
            local ENC=$(perf_get_enc) COMP=$(perf_get_comp) MUX_CFG=$(perf_get_tcpmux) EP EM
            read -r EP EM <<< "$(pool_effective_values)"
            echo -e "\n${CYAN}=== Performance Status ===${NC}"
            echo -e "  Proxy Encryption:  $([[ "$ENC" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  Proxy Compression: $([[ "$COMP" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}")"
            echo -e "  TCP Multiplexing:  $([[ "$MUX_CFG" == "1" ]] && echo -e "${YELLOW}on${NC}" || echo -e "${GREEN}off${NC}")"
            echo -e "  Auto Pool:         $([[ "$(perf_get_auto_pool)" == "1" ]] && echo -e "${GREEN}on${NC}" || echo -e "${YELLOW}off${NC}") (poolCount=${EP}, maxPoolCount=${EM})"
            ;;
        enc)
            case "${2:-}" in
                on)  perf_set_val "proxy_encryption" "true" 1; echo -e "${GREEN}[✔️] Encryption ON.${NC}" ;;
                off) perf_set_val "proxy_encryption" "false" 1; echo -e "${GREEN}[✔️] Encryption OFF.${NC}" ;;
                *) echo "Usage: hashem perf enc on|off"; return 1 ;;
            esac ;;
        comp)
            case "${2:-}" in
                on)  perf_set_val "proxy_compression" "true" 1; echo -e "${GREEN}[✔️] Compression ON.${NC}" ;;
                off) perf_set_val "proxy_compression" "false" 1; echo -e "${GREEN}[✔️] Compression OFF.${NC}" ;;
                *) echo "Usage: hashem perf comp on|off"; return 1 ;;
            esac ;;
        tcpmux|mux)
            case "${2:-}" in
                on)  perf_set_val "tcp_mux" "true" 1; echo -e "${GREEN}[✔️] TCP Mux ON.${NC}" ;;
                off) perf_set_val "tcp_mux" "false" 1; echo -e "${GREEN}[✔️] TCP Mux OFF.${NC}" ;;
                *) echo "Usage: hashem perf tcpmux on|off"; return 1 ;;
            esac ;;
        autopool|auto-pool)
            case "${2:-status}" in
                on)  perf_set_val "auto_pool" "true" 1; echo -e "${GREEN}[✔️] Auto Pool ON.${NC}" ;;
                off) perf_set_val "auto_pool" "false" 1; echo -e "${GREEN}[✔️] Auto Pool OFF.${NC}" ;;
                tick) autopool_tick ;;
                status) pool_effective_values ;;
            esac ;;
        pool) pool_effective_values ;;
        apply) perf_apply ;;
        reset)
            init_perf_json
            perf_set_val "proxy_encryption" "false" 1
            perf_set_val "proxy_compression" "false" 1
            perf_set_val "tcp_mux" "false" 1
            perf_set_val "auto_pool" "true" 1
            perf_apply
            ;;
        *) echo "Usage: hashem perf status|enc on|off|comp on|off|tcpmux on|off|autopool on|off|apply|reset"; return 1 ;;
    esac
}

menu_perf() {
    while true; do
        cli_perf status
        echo ""
        echo "  1) Toggle Proxy Encryption (enc on/off)"
        echo "  2) Toggle Proxy Compression (comp on/off)"
        echo "  3) Toggle Auto Pool (autopool on/off)"
        echo "  4) Apply settings & restart tunnels"
        echo "  5) Toggle TCP Multiplexing (tcpmux on/off)"
        echo "  0) Back"
        echo ""
        read -p "Select an option [0-5]: " P_OPT
        case "$P_OPT" in
            1) [[ "$(perf_get_enc)" == "1" ]] && cli_perf enc off || cli_perf enc on ;;
            2) [[ "$(perf_get_comp)" == "1" ]] && cli_perf comp off || cli_perf comp on ;;
            3) [[ "$(perf_get_auto_pool)" == "1" ]] && cli_perf autopool off || cli_perf autopool on ;;
            4) cli_perf apply ;;
            5) [[ "$(perf_get_tcpmux)" == "1" ]] && cli_perf tcpmux off || cli_perf tcpmux on ;;
            0) return 0 ;;
        esac
    done
}

# ---- Native WSS TLS Terminator (No gre-panel binary required) ----
wss_front_port() {
    local p=$(( $1 + 2 ))
    (( p > 65535 )) && p=$(( $1 - 2 ))
    echo "$p"
}

ensure_native_tls_proxy() {
    mkdir -p /etc/frp/tls
    if [[ ! -f /etc/frp/tls/server.crt || ! -f /etc/frp/tls/server.key ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout /etc/frp/tls/server.key \
            -out /etc/frp/tls/server.crt \
            -subj "/CN=hashem-wss" >/dev/null 2>&1 || true
        chmod 600 /etc/frp/tls/server.key 2>/dev/null || true
    fi
    cat << 'PYEOF' > /usr/local/bin/hashem-tls-proxy.py
#!/usr/bin/env python3
import asyncio, ssl, sys

async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass

async def handle_client(client_reader, client_writer, target_host, target_port):
    try:
        remote_reader, remote_writer = await asyncio.open_connection(target_host, target_port)
        await asyncio.gather(pipe(client_reader, remote_writer), pipe(remote_reader, client_writer))
    except Exception:
        client_writer.close()

async def main():
    listen_host, listen_port = sys.argv[1].split(":")
    target_host, target_port = sys.argv[2].split(":")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("/etc/frp/tls/server.crt", "/etc/frp/tls/server.key")
    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, target_host, int(target_port)),
        listen_host, int(listen_port), ssl=ctx
    )
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
PYEOF
    chmod +x /usr/local/bin/hashem-tls-proxy.py
}

frps_wss_front_ensure() {
    local SUF="$1" CPORT="$2"
    local FPORT SVC="frps-wss${1}"
    FPORT=$(wss_front_port "$CPORT")
    ensure_native_tls_proxy
    cat > "${HASHEM_SYSTEMD_DIR:-/etc/systemd/system}/${SVC}.service" <<UNIT
[Unit]
Description=Hashem Native FRP WSS TLS Front (:${FPORT} -> 127.0.0.1:${CPORT})
After=network.target frps${SUF}.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=3s
LimitNOFILE=1048576
CPUWeight=100
ExecStart=/usr/bin/python3 /usr/local/bin/hashem-tls-proxy.py 0.0.0.0:${FPORT} 127.0.0.1:${CPORT}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$SVC" >/dev/null 2>&1 || true
    systemctl restart "$SVC" >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${FPORT}/tcp" >/dev/null 2>&1 || true
    fi
    echo -e "${GREEN}[✔️] Native WSS TLS front listening on :${FPORT} (-> frps :${CPORT})${NC}"
}

frps_wss_front_remove() {
    local SVC="frps-wss${1}"
    systemctl stop "$SVC" >/dev/null 2>&1 || true
    systemctl disable "$SVC" >/dev/null 2>&1 || true
    rm -f "${HASHEM_SYSTEMD_DIR:-/etc/systemd/system}/${SVC}.service"
}

# ---- Tunnel Setup Logic (Standalone CLI, No Web Panel) ----
setup_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$IRAN_GRE_IP} PEER_GRE=${6:-$FOREIGN_GRE_IP}
    local PORTS_CLEANED="${7:-}" FRP_TRANSPORT="${8:-tcp}"

    log_msg "tunnel" "INFO" "Starting IRAN server setup: GRE ${IP_IRAN} <-> ${IP_FOREIGN}, FRP port: ${BIND_PORT}"
    backup_configs "pre_setup_iran"
    ensure_dependencies_smart

    local STATUS_GRE="OK" STATUS_FRP="OK" GRE_ERR="" FRP_ERR=""

    if ! setup_gre_systemd "$IP_IRAN" "$IP_FOREIGN" "$LOCAL_GRE" "$PEER_GRE"; then
        STATUS_GRE="FAILED"
        GRE_ERR="GRE interface failed to start"
    fi

    if ! install_frp_binaries "server"; then
        STATUS_FRP="FAILED"
        FRP_ERR="FRP binary installation failed"
    fi

    local _POOL MAX_POOL
    read -r _POOL MAX_POOL <<< "$(pool_effective_values)"
    local QUIC_PORT=$((BIND_PORT + 1))
    (( QUIC_PORT > 65535 )) && QUIC_PORT=$((BIND_PORT - 1))
    mkdir -p "${CONFIG_DIR}"
    cat <<EOF > "${CONFIG_DIR}/frps.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
kcpBindPort = ${BIND_PORT}
quicBindPort = ${QUIC_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
$(perf_tcpmux_lines)
transport.tcpKeepalive = 15
transport.heartbeatTimeout = 45
transport.maxPoolCount = ${MAX_POOL}
EOF
    cat <<EOF > /etc/systemd/system/frps.service
[Unit]
Description=FRP Server Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10s
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
CPUWeight=100
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl reset-failed frps >/dev/null 2>&1 || true
    systemctl enable frps >/dev/null 2>&1
    command -v fuser >/dev/null 2>&1 && fuser -k "${BIND_PORT}/tcp" >/dev/null 2>&1 || true
    systemctl restart frps
    sleep 2

    if ! systemctl is-active --quiet frps 2>/dev/null; then
        STATUS_FRP="FAILED"
        FRP_ERR="frps service failed to start"
    fi

    if [[ "$FRP_TRANSPORT" == "wss" ]]; then
        frps_wss_front_ensure "" "$BIND_PORT" || { STATUS_FRP="FAILED"; FRP_ERR="WSS TLS front failed"; }
    else
        frps_wss_front_remove ""
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${BIND_PORT}/tcp" >/dev/null 2>&1
    fi

    tune_apply >/dev/null 2>&1 || true
    install_watchdog_units >/dev/null 2>&1 || true
    init_watchdog_json >/dev/null 2>&1 || true

    echo -e "\n=============================================================="
    echo "                   INSTALLATION SUMMARY"
    echo "=============================================================="
    [[ "$STATUS_GRE" == "OK" ]] && echo -e "[${GREEN}OK${NC}]     GRE Tunnel Interface (${TUNNEL_NAME}: ${LOCAL_GRE})" || echo -e "[${RED}FAILED${NC}] GRE Tunnel Interface (${GRE_ERR})"
    [[ "$STATUS_FRP" == "OK" ]] && echo -e "[${GREEN}OK${NC}]     FRP Server Service (frps listening on :${BIND_PORT})" || echo -e "[${RED}FAILED${NC}] FRP Server Service (${FRP_ERR})"
    echo "=============================================================="

    local BUNDLE_OUT
    BUNDLE_OUT=$(bundle_make "$IP_IRAN" "$BIND_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN" "$PORTS_CLEANED" "" "$FRP_TRANSPORT")
    echo -e "Setup Bundle:         ${CYAN}${BUNDLE_OUT}${NC}"
    echo -e "BUNDLE:${BUNDLE_OUT}"

    [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" ]] && return 0 || return 1
}

setup_foreign_server_noninteractive() {
    _setup_foreign_full "$@"
}

_setup_foreign_full() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$FOREIGN_GRE_IP} PEER_GRE=${6:-$IRAN_GRE_IP} PORTS_CLEANED=${7:-}
    local RELAY_IP=${8:-} PROXY_PROTOCOL=${9:-off} FRP_TRANSPORT=${10:-tcp} FRP_ENCRYPTION=${11:-off} FRP_COMPRESSION=${12:-off}

    log_msg "tunnel" "INFO" "Starting FOREIGN server setup: GRE ${IP_FOREIGN} <-> ${IP_IRAN}, serverPort: ${SERVER_PORT}"
    backup_configs "pre_setup_foreign"
    ensure_dependencies_smart

    local STATUS_GRE="OK" STATUS_PING="OK" STATUS_FRP="OK"

    carrier_init_kernel 2>/dev/null || true
    setup_gre_systemd "$IP_FOREIGN" "$IP_IRAN" "$LOCAL_GRE" "$PEER_GRE" || STATUS_GRE="FAILED"
    carrier_apply_active "$TUNNEL_NAME" >/dev/null 2>&1 || true

    echo -e "${CYAN}[*] Testing GRE internal ping to Iran (${PEER_GRE})...${NC}"
    ping -c 3 -W 2 "$PEER_GRE" >/dev/null 2>&1 || STATUS_PING="WARN"

    install_frp_binaries "client"
    local EFF_POOL _MAXPOOL
    read -r EFF_POOL _MAXPOOL <<< "$(pool_effective_values)"
    local EFF_SERVER_PORT="${SERVER_PORT}"
    if [[ "$FRP_TRANSPORT" == "quic" ]]; then
        EFF_SERVER_PORT=$((SERVER_PORT + 1))
        (( EFF_SERVER_PORT > 65535 )) && EFF_SERVER_PORT=$((SERVER_PORT - 1))
    elif [[ "$FRP_TRANSPORT" == "wss" ]]; then
        EFF_SERVER_PORT=$(wss_front_port "$SERVER_PORT")
    fi

    local DIAL_ADDR
    DIAL_ADDR=$(dial_pick "${FRP_DIAL:-auto}" "$PEER_GRE" "$IP_IRAN" "$EFF_SERVER_PORT")
    dial_env_write "${FRP_DIAL:-auto}" frp "$PEER_GRE" "$IP_IRAN"

    mkdir -p "${CONFIG_DIR}"
    cat <<EOF > "${CONFIG_DIR}/frpc.toml"
serverAddr = "${DIAL_ADDR}"
serverPort = ${EFF_SERVER_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
loginFailExit = false
transport.protocol = "${FRP_TRANSPORT}"
$(perf_tcpmux_lines)
transport.heartbeatInterval = 15
transport.heartbeatTimeout = 45
transport.dialServerTimeout = 10
transport.dialServerKeepalive = 15
transport.poolCount = ${EFF_POOL}

EOF
    local PROXY_TARGET_IP="${RELAY_IP:-127.0.0.1}"
    local PP_LINE="" ENC_LINE="" COMP_LINE=""
    [[ "$PROXY_PROTOCOL" == "v2" || "$PROXY_PROTOCOL" == "v1" ]] && PP_LINE="transport.proxyProtocolVersion = \"${PROXY_PROTOCOL}\""
    [[ "$FRP_ENCRYPTION" == "on" || "$FRP_ENCRYPTION" == "1" || "$FRP_ENCRYPTION" == "true" ]] && ENC_LINE="transport.useEncryption = true"
    [[ "$FRP_COMPRESSION" == "on" || "$FRP_COMPRESSION" == "1" || "$FRP_COMPRESSION" == "true" ]] && COMP_LINE="transport.useCompression = true"

    local PORT
    for PORT in $PORTS_CLEANED; do
        cat <<EOF >> "${CONFIG_DIR}/frpc.toml"
[[proxies]]
name = "tcp_${PORT}"
type = "tcp"
localIP = "${PROXY_TARGET_IP}"
localPort = ${PORT}
remotePort = ${PORT}
${PP_LINE:+$PP_LINE
}${ENC_LINE:+$ENC_LINE
}${COMP_LINE:+$COMP_LINE
}
[[proxies]]
name = "udp_${PORT}"
type = "udp"
localIP = "${PROXY_TARGET_IP}"
localPort = ${PORT}
remotePort = ${PORT}

EOF
    done

    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=FRP Client Reverse Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10s
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
CPUWeight=100
ExecStartPre=-/bin/sh -c "if [ -x /usr/local/bin/hashem ]; then timeout 30 /usr/local/bin/hashem dial-select >/dev/null 2>&1; fi; true"
ExecStart=${INSTALL_DIR}/frpc -c ${CONFIG_DIR}/frpc.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl reset-failed frpc >/dev/null 2>&1 || true
    systemctl enable frpc >/dev/null 2>&1
    systemctl restart frpc
    sleep 2

    systemctl is-active --quiet frpc 2>/dev/null || STATUS_FRP="FAILED"

    tune_apply >/dev/null 2>&1 || true
    install_watchdog_units >/dev/null 2>&1 || true
    init_watchdog_json >/dev/null 2>&1 || true

    echo -e "\n=============================================================="
    echo "                   INSTALLATION SUMMARY"
    echo "=============================================================="
    [[ "$STATUS_GRE" == "OK" ]] && echo -e "[${GREEN}OK${NC}]     GRE Tunnel Interface (${LOCAL_GRE})" || echo -e "[${RED}FAILED${NC}] GRE Tunnel Interface"
    [[ "$STATUS_FRP" == "OK" ]] && echo -e "[${GREEN}OK${NC}]     FRP Client Service (${DIAL_ADDR}:${EFF_SERVER_PORT} | Ports: ${PORTS_CLEANED})" || echo -e "[${RED}FAILED${NC}] FRP Client Service"
    echo "=============================================================="
    [[ "$STATUS_GRE" == "OK" && "$STATUS_FRP" == "OK" ]] && return 0 || return 1
}

setup_backhaul_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4 TRANSPORT=${5:-tcpmux} PORTS=${6:-}
    backup_configs "pre_setup_backhaul_iran"
    ensure_dependencies_smart
    install_backhaul_binaries || return 1
    backhaul_ensure_tls "$TRANSPORT"
    mkdir -p "${BACKHAUL_CONFIG_DIR}"
    backhaul_write_server_conf "${BACKHAUL_CONFIG_DIR}/config.toml" "0.0.0.0:${BIND_PORT}" "$TRANSPORT" "$TOKEN" "$PORTS"
    setup_backhaul_server_systemd "backhaul-server" "${BACKHAUL_CONFIG_DIR}/config.toml"
    sleep 2
    tune_apply >/dev/null 2>&1 || true
    local BUNDLE_STR
    BUNDLE_STR=$(bundle_make_backhaul "$IP_IRAN" "$BIND_PORT" "$TRANSPORT" "$TOKEN" "$PORTS")
    echo -e "Setup Bundle:         ${CYAN}${BUNDLE_STR}${NC}"
    echo -e "BUNDLE:${BUNDLE_STR}"
}

setup_backhaul_foreign_server_noninteractive() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4 TRANSPORT=${5:-tcpmux}
    backup_configs "pre_setup_backhaul_foreign"
    ensure_dependencies_smart
    install_backhaul_binaries || return 1
    backhaul_ensure_tls "$TRANSPORT"
    mkdir -p "${BACKHAUL_CONFIG_DIR}"
    backhaul_write_client_conf "${BACKHAUL_CONFIG_DIR}/client.toml" "${IP_IRAN}:${SERVER_PORT}" "$TRANSPORT" "$TOKEN"
    setup_backhaul_client_systemd "backhaul-client" "${BACKHAUL_CONFIG_DIR}/client.toml"
    sleep 2
    tune_apply >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] Backhaul Client active (${IP_IRAN}:${SERVER_PORT}).${NC}"
}

setup_gre_backhaul_iran_server_noninteractive() {
    local IP_IRAN=$1 IP_FOREIGN=$2 BIND_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$IRAN_GRE_IP} PEER_GRE=${6:-$FOREIGN_GRE_IP} TRANSPORT=${7:-tcpmux} PORTS=${8:-}
    backup_configs "pre_setup_gre_backhaul_iran"
    ensure_dependencies_smart
    setup_gre_systemd "$IP_IRAN" "$IP_FOREIGN" "$LOCAL_GRE" "$PEER_GRE" || return 1
    install_backhaul_binaries || return 1
    backhaul_ensure_tls "$TRANSPORT"
    mkdir -p "${BACKHAUL_CONFIG_DIR}"
    backhaul_write_server_conf "${BACKHAUL_CONFIG_DIR}/config.toml" "0.0.0.0:${BIND_PORT}" "$TRANSPORT" "$TOKEN" "$PORTS"
    setup_backhaul_server_systemd "backhaul-server" "${BACKHAUL_CONFIG_DIR}/config.toml"
    tune_apply >/dev/null 2>&1 || true
    local BUNDLE_STR
    BUNDLE_STR=$(bundle_make_gre_backhaul "$IP_IRAN" "$BIND_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TRANSPORT" "$TOKEN" "$PORTS")
    echo -e "Setup Bundle:         ${CYAN}${BUNDLE_STR}${NC}"
    echo -e "BUNDLE:${BUNDLE_STR}"
}

setup_gre_backhaul_foreign_server_noninteractive() {
    local IP_FOREIGN=$1 IP_IRAN=$2 SERVER_PORT=$3 TOKEN=$4
    local LOCAL_GRE=${5:-$FOREIGN_GRE_IP} PEER_GRE=${6:-$IRAN_GRE_IP} TRANSPORT=${7:-tcpmux}
    backup_configs "pre_setup_gre_backhaul_foreign"
    ensure_dependencies_smart
    setup_gre_systemd "$IP_FOREIGN" "$IP_IRAN" "$LOCAL_GRE" "$PEER_GRE" || return 1
    install_backhaul_binaries || return 1
    backhaul_ensure_tls "$TRANSPORT"
    local BH_DIAL
    BH_DIAL=$(dial_pick "${FRP_DIAL:-auto}" "$PEER_GRE" "$IP_IRAN" "$SERVER_PORT")
    dial_env_write "${FRP_DIAL:-auto}" backhaul "$PEER_GRE" "$IP_IRAN"
    backhaul_write_client_conf "${BACKHAUL_CONFIG_DIR}/client.toml" "${BH_DIAL}:${SERVER_PORT}" "$TRANSPORT" "$TOKEN"
    setup_backhaul_client_systemd "backhaul-client" "${BACKHAUL_CONFIG_DIR}/client.toml"
    tune_apply >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] GRE + Backhaul Client active (${BH_DIAL}:${SERVER_PORT}).${NC}"
}

# ---- Multi-Peer Tunnels ----
peer_init() {
    mkdir -p "$(dirname "$PEERS_FILE")" "$CONFIG_DIR"
    [[ -f "$PEERS_FILE" ]] || echo '{"peers":[]}' > "$PEERS_FILE"
}

peer_require_py() {
    command -v python3 >/dev/null 2>&1 || { echo -e "${RED}[!] python3 is required.${NC}"; return 1; }
}

peer_list() { peer_init; cat "$PEERS_FILE"; }

peer_next_id() {
    peer_require_py || return 1
    PEERS_F="$PEERS_FILE" MAX_PEERS="$MAX_PEERS" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); used={p["id"] for p in d.get("peers",[])}; ids=[i for i in range(1,int(os.environ["MAX_PEERS"])+1) if i not in used]; print(ids[0] if ids else 0)'
}

peer_ports_used() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); print(" ".join(str(p) + ":" + str(r.get("name","")) for r in d.get("peers",[]) for p in r.get("ports",[])))'
}

peer_get() {
    PEERS_F="$PEERS_FILE" PEER_ID="$1" python3 -c \
'import json,os; d=json.load(open(os.environ["PEERS_F"])); m=[p for p in d.get("peers",[]) if p["id"]==int(os.environ["PEER_ID"])]; print(json.dumps(m[0]) if m else "")'
}

peer_token() {
    peer_init; peer_require_py || return 1
    local ID=$1 rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] No peer with id $ID.${NC}"; return 1; }
    echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
    local B_TOK LIP FP LGRE PGRE PTS
    B_TOK=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
    LIP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_pub",""))')
    FP=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("frp_port",""))')
    LGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("local_gre",""))')
    PGRE=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("peer_gre",""))')
    PTS=$(echo "$rec" | python3 -c 'import json,sys; print(" ".join(str(x) for x in json.load(sys.stdin).get("ports",[])))')
    if is_valid_ip "$LIP" && is_valid_port "$FP" && is_valid_ip "$LGRE" && is_valid_ip "$PGRE"; then
        echo "BUNDLE:$(bundle_make "$LIP" "$FP" "$LGRE" "$PGRE" "$B_TOK" "$PTS")"
    fi
}

peer_write_frps() {
    local SUF=$1 BIND_PORT=$2 TOKEN=$3
    local _POOL MAX_POOL
    read -r _POOL MAX_POOL <<< "$(pool_effective_values)"
    cat <<EOF > "${CONFIG_DIR}/frps${SUF}.toml"
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
$(perf_tcpmux_lines)
transport.tcpKeepalive = 15
transport.heartbeatTimeout = 45
transport.maxPoolCount = ${MAX_POOL}
EOF
    local SVC="frps${SUF}"
    cat <<EOF > /etc/systemd/system/${SVC}.service
[Unit]
Description=FRP Server Service${SUF:+ (peer${SUF#-})}
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=10s
LimitNOFILE=1048576
LimitNPROC=512000
TasksMax=infinity
CPUWeight=100
ExecStart=${INSTALL_DIR}/frps -c ${CONFIG_DIR}/frps${SUF}.toml

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SVC" >/dev/null 2>&1
    systemctl restart "$SVC"
}

cli_add_peer() {
    local NAME="" LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" TOKEN="" LOCAL_GRE="" PEER_GRE="" PORTS="" FORCE=0 BUNDLE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) NAME="$2"; shift 2 ;;
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            *) shift ;;
        esac
    done
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || return 1
        [[ -z "$LOCAL_PUB" ]] && LOCAL_PUB=$B_IRAN_PUB
        [[ -z "$FRP_PORT" ]] && FRP_PORT=$B_FRP_PORT
        [[ -z "$LOCAL_GRE" ]] && LOCAL_GRE=$B_IRAN_GRE
        [[ -z "$PEER_GRE" ]] && PEER_GRE=$B_FOREIGN_GRE
        [[ -z "$TOKEN" ]] && TOKEN=$B_TOKEN
        [[ -z "$PORTS" ]] && PORTS=$B_PORTS
    fi
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    is_valid_ip "$PEER_GRE" || return 1
    [[ -n "$TOKEN" ]] || TOKEN=$(gen_token32)
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"; done
    CLEANED=$(echo "$CLEANED" | xargs)
    peer_init; peer_require_py || return 1
    local ID
    ID=$(peer_next_id)
    [[ "$ID" -ge 1 ]] || { echo -e "${RED}[!] Peer table full.${NC}"; return 1; }
    [[ -z "$NAME" ]] && NAME="peer-${ID}"
    install_frp_binaries "server" || return 1

    local GRE_IF FRPS_SVC LEGACY
    if [[ "$ID" -eq 1 ]] && ! tunnel_present; then
        setup_gre_systemd "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE"
        peer_write_frps "" "$FRP_PORT" "$TOKEN"
        GRE_IF="$TUNNEL_NAME"; FRPS_SVC="frps"; LEGACY=true
    else
        GRE_IF="gre-t${ID}"; FRPS_SVC="frps-${ID}"; LEGACY=false
        setup_gre_iface "$GRE_IF" "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE"
        peer_write_frps "-${ID}" "$FRP_PORT" "$TOKEN"
    fi

    local PORTS_JSON
    PORTS_JSON=$(echo "$CLEANED" | python3 -c 'import json,sys; print(json.dumps([int(x) for x in sys.stdin.read().split()]))')
    PEERS_F="$PEERS_FILE" python3 - "$ID" "$NAME" "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS_JSON" "$GRE_IF" "$FRPS_SVC" "$LEGACY" <<'PYEOF'
import json, os, sys
f = os.environ["PEERS_F"]
iid, name, lip, rip, fport, tok, lgre, pgre, pjson, gif, svc, leg = sys.argv[1:]
d = json.load(open(f))
d.setdefault("peers", []).append({"id": int(iid), "name": name, "local_pub": lip,
  "remote_pub": rip, "frp_port": int(fport), "token": tok, "local_gre": lgre,
  "peer_gre": pgre, "ports": json.loads(pjson), "gre_if": gif, "frps_svc": svc,
  "legacy": leg == "true"})
json.dump(d, open(f, "w"), indent=2)
PYEOF
    echo -e "${GREEN}[✔️] Peer '${NAME}' (id ${ID}) added.${NC}"
    echo -e "BUNDLE:$(bundle_make "$LOCAL_PUB" "$FRP_PORT" "$LOCAL_GRE" "$PEER_GRE" "$TOKEN" "$CLEANED")"
}

cli_remove_peer() {
    local ID="" FORCE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --id) ID="$2"; shift 2 ;; --force) FORCE=1; shift ;; *) shift ;; esac
    done
    [[ "$ID" =~ ^[0-9]+$ ]] || return 1
    peer_init; peer_require_py || return 1
    local rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || { echo -e "${RED}[!] No peer with id $ID.${NC}"; return 1; }
    local NAME GIF SVC LEG
    NAME=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    GIF=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["gre_if"])')
    SVC=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["frps_svc"])')
    LEG=$(echo "$rec" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin).get("legacy") else "0")')
    if [[ "$LEG" == "1" ]]; then
        remove_tunnel_force
    else
        frps_wss_front_remove "-${ID}"
        systemctl stop "$SVC" "${GIF}.service" >/dev/null 2>&1 || true
        systemctl disable "$SVC" "${GIF}.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${GIF}.service" "/etc/frp/frps-${ID}.toml" "/etc/backhaul/server-${ID}.toml"
        systemctl daemon-reload
        [[ "$GIF" != "none" && -n "$GIF" ]] && ip tunnel del "$GIF" >/dev/null 2>&1 || true
    fi
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" python3 -c \
'import json,os; f=os.environ["PEERS_F"]; d=json.load(open(f)); d["peers"]=[p for p in d.get("peers",[]) if p["id"]!=int(os.environ["PEER_ID"])]; json.dump(d,open(f,"w"),indent=2)' 2>/dev/null || true
    echo -e "${GREEN}[✔️] Peer '${NAME}' (id ${ID}) removed.${NC}"
}

cli_add_backhaul_peer() {
    local NAME="" LOCAL_PUB="" REMOTE_PUB="" PORT="" TOKEN="" LOCAL_GRE="" PEER_GRE="" PORTS="" TRANSPORT="tcpmux" NO_GRE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) NAME="$2"; shift 2 ;;
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --transport) TRANSPORT="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --no-gre) NO_GRE=1; shift ;;
            *) shift ;;
        esac
    done
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    PORT=${PORT:-$(gen_random_port)}
    [[ -n "$TOKEN" ]] || TOKEN=$(gen_token32)
    peer_init; peer_require_py || return 1
    local ID
    ID=$(peer_next_id)
    [[ -z "$NAME" ]] && NAME="peer-${ID}"
    install_backhaul_binaries || return 1
    backhaul_ensure_tls "$TRANSPORT"

    local GRE_IF="none" SVC_NAME="backhaul-server-${ID}" CONF_FILE="/etc/backhaul/server-${ID}.toml" ENGINE="backhaul"
    if [[ "$NO_GRE" -eq 1 ]]; then
        backhaul_write_server_conf "$CONF_FILE" "0.0.0.0:${PORT}" "$TRANSPORT" "$TOKEN" "$PORTS"
        setup_backhaul_server_systemd "$SVC_NAME" "$CONF_FILE"
    else
        ENGINE="gre-backhaul"
        GRE_IF="gre-t${ID}"
        setup_gre_iface "$GRE_IF" "$LOCAL_PUB" "$REMOTE_PUB" "$LOCAL_GRE" "$PEER_GRE"
        backhaul_write_server_conf "$CONF_FILE" "0.0.0.0:${PORT}" "$TRANSPORT" "$TOKEN" "$PORTS"
        setup_backhaul_server_systemd "$SVC_NAME" "$CONF_FILE"
    fi
    echo -e "${GREEN}[✔️] Backhaul Peer '${NAME}' (id ${ID}) added!${NC}"
}

cli_edit_peer() {
    local ID="" NAME="" REMOTE_PUB="" CARRIER="" PORTS=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --id) ID="$2"; shift 2 ;;
            --name) NAME="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --carrier) CARRIER="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ "$ID" =~ ^[0-9]+$ ]] || return 1
    peer_init; peer_require_py || return 1
    local rec
    rec=$(peer_get "$ID")
    [[ -n "$rec" ]] || return 1
    local CUR_GIF
    CUR_GIF=$(echo "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("gre_if",""))')
    if [[ -n "$REMOTE_PUB" ]] && is_valid_ip "$REMOTE_PUB"; then
        ip tunnel change "$CUR_GIF" remote "$REMOTE_PUB" >/dev/null 2>&1 || true
        sed -i -E "s/remote [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/remote ${REMOTE_PUB}/g" "/etc/systemd/system/${CUR_GIF}.service" 2>/dev/null || true
        systemctl daemon-reload && systemctl restart "${CUR_GIF}.service" >/dev/null 2>&1 || true
    fi
    [[ -n "$CARRIER" ]] && carrier_apply "$CARRIER" "$CUR_GIF"
    PEERS_F="$PEERS_FILE" PEER_ID="$ID" NEW_NAME="$NAME" NEW_REMOTE="$REMOTE_PUB" NEW_CARRIER="$CARRIER" NEW_PORTS="$PORTS" python3 <<'PYEOF'
import json, os
f = os.environ["PEERS_F"]
pid = int(os.environ["PEER_ID"])
d = json.load(open(f))
for p in d.get("peers", []):
    if p.get("id") == pid:
        if os.environ.get("NEW_NAME"): p["name"] = os.environ["NEW_NAME"]
        if os.environ.get("NEW_REMOTE"): p["remote_pub"] = os.environ["NEW_REMOTE"]
        if os.environ.get("NEW_CARRIER"): p["carrier"] = os.environ["NEW_CARRIER"]
        if os.environ.get("NEW_PORTS"):
            p["ports"] = [int(x) for x in os.environ["NEW_PORTS"].replace(",", " ").split() if x.isdigit()]
json.dump(d, open(f, "w"), indent=2)
PYEOF
    echo -e "${GREEN}[✔️] Peer #${ID} updated.${NC}"
}

cli_edit_peer_ports() {
    cli_edit_peer "$@"
}

peer_list_pretty() {
    peer_init; peer_require_py || return 1
    PEERS_F="$PEERS_FILE" python3 <<'PYEOF'
import json, os, subprocess
peers = json.load(open(os.environ["PEERS_F"])).get("peers", [])
if not peers:
    print("[*] No peer tunnels yet.")
    raise SystemExit(0)
tun = subprocess.run(["ip", "tunnel", "show"], capture_output=True, text=True).stdout
for p in sorted(peers, key=lambda x: x["id"]):
    gre = "up" if p.get("gre_if", "") in tun else "down"
    frp = subprocess.run(["systemctl", "is-active", p.get("frps_svc", "")], capture_output=True, text=True).stdout.strip()
    print(f"#{p['id']} {p['name']}: {p['remote_pub']} (GRE {p['local_gre']} <-> {p['peer_gre']}, {p['gre_if']} {gre}) | {p['frps_svc']} :{p['frp_port']} {frp} | ports: {','.join(map(str, p.get('ports', [])))}")
PYEOF
}

setup_iran_server() {
    echo -e "\n${YELLOW}=== CONFIGURING IRAN SERVER (GRE + FRPS) ===${NC}"
    local MY_PUBLIC_IP IP_IRAN IP_FOREIGN BIND_PORT AUTO_TOKEN TOKEN
    MY_PUBLIC_IP=$(get_public_ip)
    prompt_ip IP_IRAN "Enter IRAN Server Public IP" "$MY_PUBLIC_IP"
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" ""
    prompt_port BIND_PORT "Enter FRP Bind Port" "$(gen_random_port)"
    BIND_PORT=$(ensure_port_available "$BIND_PORT" "FRP Bind Port" 0) || return 1
    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Enter Secret Auth Token" "$AUTO_TOKEN"
    setup_iran_server_noninteractive "$IP_IRAN" "$IP_FOREIGN" "$BIND_PORT" "$TOKEN" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP"
}

menu_add_peer() {
    echo -e "\n${YELLOW}=== Add Peer Tunnel ===${NC}"
    peer_init
    local MYIP NAME LOCAL_IRAN IP_FOREIGN NEXT_ID SU_FP SU_LG SU_PG CPORT AUTO_TOKEN TOKEN LGRE PGRE PPORTS
    MYIP=$(get_public_ip)
    read -p "Peer name (e.g. germany-1) [Enter for auto]: " NAME
    prompt_ip LOCAL_IRAN "Enter IRAN Server Public IP" "$MYIP"
    prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" ""
    NEXT_ID=$(peer_next_id 2>/dev/null || echo 2)
    SU_FP=$(gen_random_port)
    SU_LG="10.1${NEXT_ID}.0.2"; SU_PG="10.1${NEXT_ID}.0.1"
    prompt_port CPORT "Enter FRP Control Port" "$SU_FP"
    AUTO_TOKEN=$(gen_token32)
    prompt_token TOKEN "Peer token" "$AUTO_TOKEN"
    prompt_ip LGRE "Local GRE IP" "$SU_LG"
    prompt_ip PGRE "Peer GRE IP" "$SU_PG"
    prompt_ports PPORTS "Ports to Reverse-Tunnel"
    cli_add_peer --name "$NAME" --local-pub "$LOCAL_IRAN" --remote-pub "$IP_FOREIGN" \
        --frp-port "$CPORT" --token "$TOKEN" --local-gre "$LGRE" --peer-gre "$PGRE" --ports "$PPORTS"
}

menu_remove_peer() {
    peer_list_pretty || return 1
    local ID
    read -p "Peer id to remove: " ID
    cli_remove_peer --id "$ID"
}

menu_edit_peer() {
    peer_list_pretty || return 1
    local ID NEW_NAME NEW_REMOTE CAR_OPT NEW_CARRIER="" NEW_PORTS
    read -p "Peer id to edit: " ID
    [[ "$ID" =~ ^[0-9]+$ ]] || return 1
    read -p "New Name [Enter to keep]: " NEW_NAME
    read -p "New Remote Public IP [Enter to keep]: " NEW_REMOTE
    read -p "Carrier [1=direct, 2=fou:443, 3=fou:55555, 4=wss:8443, Enter=keep]: " CAR_OPT
    case "$CAR_OPT" in
        1) NEW_CARRIER="direct" ;;
        2) NEW_CARRIER="fou:443" ;;
        3) NEW_CARRIER="fou:55555" ;;
        4) NEW_CARRIER="wss:8443" ;;
    esac
    read -p "Forwarded ports (comma-separated) [Enter to keep]: " NEW_PORTS
    local ARGS=(--id "$ID")
    [[ -n "$NEW_NAME" ]] && ARGS+=(--name "$NEW_NAME")
    [[ -n "$NEW_REMOTE" ]] && ARGS+=(--remote-pub "$NEW_REMOTE")
    [[ -n "$NEW_CARRIER" ]] && ARGS+=(--carrier "$NEW_CARRIER")
    [[ -n "$NEW_PORTS" ]] && ARGS+=(--ports "$NEW_PORTS")
    cli_edit_peer "${ARGS[@]}"
}

setup_foreign_server() {
    echo -e "\n${YELLOW}=== CONFIGURING FOREIGN SERVER (GRE + FRPC) ===${NC}"
    local MY_PUBLIC_IP BUNDLE_IN SERVER_PORT TOKEN INPUT_PORTS BUNDLE_USED=0 LOCAL_GRE_SET="$FOREIGN_GRE_IP" PEER_GRE_SET="$IRAN_GRE_IP" IP_FOREIGN="" IP_IRAN=""
    MY_PUBLIC_IP=$(get_public_ip)
    read -p "Enter Setup Bundle (hsh1_... / bh1_... / gh1_...) [Press Enter for manual]: " BUNDLE_IN
    if [[ -n "$BUNDLE_IN" ]] && bundle_parse "$BUNDLE_IN"; then
        cli_bundle_inspect "$BUNDLE_IN"
        BUNDLE_USED=1
        prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "$MY_PUBLIC_IP"
        if [[ "$B_ENGINE" == "backhaul" ]]; then
            setup_backhaul_foreign_server_noninteractive "$IP_FOREIGN" "$B_IRAN_PUB" "$B_FRP_PORT" "$B_TOKEN" "$B_TRANSPORT"
            return $?
        elif [[ "$B_ENGINE" == "gre-backhaul" ]]; then
            setup_gre_backhaul_foreign_server_noninteractive "$IP_FOREIGN" "$B_IRAN_PUB" "$B_FRP_PORT" "$B_TOKEN" "$B_FOREIGN_GRE" "$B_IRAN_GRE" "$B_TRANSPORT"
            return $?
        fi
        IP_IRAN=$B_IRAN_PUB; SERVER_PORT=$B_FRP_PORT; TOKEN=$B_TOKEN; LOCAL_GRE_SET=$B_FOREIGN_GRE; PEER_GRE_SET=$B_IRAN_GRE
        INPUT_PORTS=$(echo "$B_PORTS" | tr ' ' ',')
        [[ -z "$INPUT_PORTS" ]] && prompt_ports INPUT_PORTS "Enter Ports to Reverse-Tunnel"
    fi
    if [[ "$BUNDLE_USED" -ne 1 ]]; then
        prompt_ip IP_FOREIGN "Enter FOREIGN Server Public IP" "$MY_PUBLIC_IP"
        prompt_ip IP_IRAN "Enter IRAN Server Public IP" ""
        prompt_port SERVER_PORT "Enter FRP Server Port" "$(gen_random_port)"
        prompt_required TOKEN "Enter Secret Auth Token"
        prompt_ports INPUT_PORTS "Enter Ports to Reverse-Tunnel"
    fi
    _setup_foreign_full "$IP_FOREIGN" "$IP_IRAN" "$SERVER_PORT" "$TOKEN" "$LOCAL_GRE_SET" "$PEER_GRE_SET" "$(echo "$INPUT_PORTS" | tr ',' ' ')"
}

check_status() {
    echo -e "\n${YELLOW}=== Checking GRE & FRP / Backhaul Status ===${NC}"
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        ip addr show dev "$TUNNEL_NAME"
        local TARGET_PING="$IRAN_GRE_IP"
        ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP" && TARGET_PING="$FOREIGN_GRE_IP"
        ping -c 3 -W 2 "$TARGET_PING" && echo -e "${GREEN}[✔️] Ping OK.${NC}" || echo -e "${YELLOW}[!] Remote peer did not answer ping.${NC}"
    else
        echo -e "${YELLOW}[*] Interface ${TUNNEL_NAME} not found.${NC}"
    fi
    for svc in frps backhaul-server frpc backhaul-client; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "${GREEN}[✔️] ${svc} is ACTIVE.${NC}"
            systemctl status "$svc" --no-pager -l | head -n 15
        fi
    done
}

show_logs() {
    for svc in backhaul-server backhaul-client frps frpc; do
        if systemctl list-unit-files | grep -q "${svc}.service"; then
            journalctl -u "$svc" -n 50 -f
            return 0
        fi
    done
    echo -e "${RED}[!] No tunnel service found.${NC}"
}

restart_all() {
    echo -e "\n${CYAN}[*] Restarting GRE and FRP/Backhaul services...${NC}"
    local u
    for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-tunnel.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service /etc/systemd/system/backhaul*.service; do
        [[ -f "$u" ]] || continue
        systemctl restart "$(basename "$u")" >/dev/null 2>&1 && echo -e "${GREEN}[✔️] $(basename "$u") restarted.${NC}"
    done
}

# ---- Doctor & Health Check (No Web Panel dependency) ----
ensure_doctor_tools() {
    for cmd in iperf3 ping curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            { timeout 30 apt-get update -qq </dev/null && timeout 120 apt-get install -y -qq iperf3 iputils-ping curl </dev/null; } 2>/dev/null || true
            break
        fi
    done
}

doctor_diagnostics() {
    ensure_doctor_tools
    local TARGET_IP=""
    if ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$IRAN_GRE_IP"; then
        TARGET_IP="$FOREIGN_GRE_IP"
    elif ip addr show dev "$TUNNEL_NAME" 2>/dev/null | grep -q "$FOREIGN_GRE_IP"; then
        TARGET_IP="$IRAN_GRE_IP"
    fi
    [[ -z "$TARGET_IP" ]] && { echo -e "${RED}[!] Tunnel interface not active.${NC}"; return 1; }
    echo -e "${CYAN}[*] Pinging ${TARGET_IP} (10 packets)...${NC}"
    ping -c 10 -W 2 "$TARGET_IP" || true
    if command -v iperf3 >/dev/null 2>&1; then
        echo -e "${CYAN}[*] Attempting iPerf3 test to ${TARGET_IP}:5201...${NC}"
        iperf3 -c "$TARGET_IP" -t 3 || echo -e "${YELLOW}[i] Run 'hashem doctor server' on the remote peer first.${NC}"
    fi
}

doctor_apply_fixes() { tune_apply; }
doctor_start_server() { ensure_doctor_tools; pgrep -x iperf3 >/dev/null 2>&1 || iperf3 -s -D; echo -e "${GREEN}[✔️] iperf3 server listening on :5201.${NC}"; }
doctor_stop_server() { pkill -f "iperf3 -s" >/dev/null 2>&1 || true; echo -e "${GREEN}[✔️] iperf3 server stopped.${NC}"; }

doctor_health_check() {
    echo -e "\n${CYAN}=============================================================="
    echo "         HASHEM SYSTEM & TUNNEL HEALTH CHECK (CLI MODE)"
    echo -e "==============================================================${NC}"
    local FAIL_COUNT=0 WARN_COUNT=0
    report_item() {
        local badge
        case "$2" in
            PASS) badge="${GREEN}[PASS]${NC}" ;;
            WARN) badge="${YELLOW}[WARN]${NC}"; ((WARN_COUNT++)) ;;
            FAIL) badge="${RED}[FAIL]${NC}"; ((FAIL_COUNT++)) ;;
        esac
        printf "%-8b %-30s %s\n" "$badge" "$1" "$3"
    }
    report_item "Operating System & Arch" "PASS" "$(uname -s -m 2>/dev/null)"
    report_item "Linux Kernel Version" "PASS" "$(uname -r 2>/dev/null)"
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && report_item "IP Forwarding" "PASS" "Enabled (1)" || report_item "IP Forwarding" "WARN" "Disabled (0)"
    (lsmod 2>/dev/null | grep -q "ip_gre" || modprobe ip_gre 2>/dev/null) && report_item "Kernel Module (ip_gre)" "PASS" "Loaded" || report_item "Kernel Module (ip_gre)" "FAIL" "Missing"
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER_IP
        INNER_IP=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}')
        report_item "GRE Interface (${TUNNEL_NAME})" "PASS" "UP (${INNER_IP:-no-ip})"
    else
        report_item "GRE Interface (${TUNNEL_NAME})" "WARN" "Not found"
    fi
    for svc in frps frpc backhaul-server backhaul-client; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
            systemctl is-active --quiet "$svc" && report_item "Service (${svc})" "PASS" "Active & Running" || report_item "Service (${svc})" "FAIL" "Stopped/Failed"
        fi
    done
    report_item "Operation Mode" "PASS" "Standalone CLI (Web Panel Disabled)"
    echo -e "${CYAN}==============================================================${NC}\n"
}

cli_doctor() {
    case "${1:-}" in
        server) doctor_start_server ;;
        stop-server) doctor_stop_server ;;
        fix) doctor_apply_fixes ;;
        diag|speed) doctor_diagnostics ;;
        stress|stress-test|load) shift; cli_stress_test "$@" ;;
        *) doctor_health_check ;;
    esac
}

cli_revpath() {
    local apply=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --apply|--auto) apply=1; shift ;; *) shift ;; esac
    done
    echo -e "${CYAN}=== Reverse Path & Routing Audit ===${NC}"
    local rp_all rp_def
    rp_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)
    rp_def=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo 0)
    echo "net.ipv4.conf.all.rp_filter = $rp_all"
    echo "net.ipv4.conf.default.rp_filter = $rp_def"
    if (( apply == 1 )); then
        sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
        for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done
        restart_all_lite
        echo -e "${GREEN}[✔️] Reverse path filtering relaxed (rp_filter=0) and tunnel interfaces refreshed.${NC}"
    fi
}

cli_stress_test() {
    local TARGET_HOST="${1:-127.0.0.1}" TARGET_PORT="${2:-}" CONNS="${3:-200}"
    [[ -z "$TARGET_PORT" ]] && TARGET_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null || echo 7000)
    echo -e "\n${CYAN}=== Stress Testing ${TARGET_HOST}:${TARGET_PORT} (${CONNS} connections) ===${NC}"
    python3 - "$TARGET_HOST" "$TARGET_PORT" "$CONNS" <<'PY'
import socket, sys, time, concurrent.futures
host, port, conns = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def probe(_):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(4.0)
        s.connect((host, port))
        time.sleep(0.05)
        s.close()
        return True
    except Exception:
        return False
with concurrent.futures.ThreadPoolExecutor(max_workers=min(conns, 200)) as ex:
    res = list(ex.map(probe, range(conns)))
ok = sum(1 for r in res if r)
print(f"RESULT: Total={conns} Success={ok} Dropped={conns - ok}")
sys.exit(0 if ok == conns else 1)
PY
}

# ---- Uninstall & Teardown ----
uninstall_all() {
    read -p "Are you sure you want to uninstall EVERYTHING? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && uninstall_all_force || echo -e "${YELLOW}[*] Aborted.${NC}"
}

uninstall_all_force() {
    echo -e "${CYAN}[*] Performing complete uninstallation of Hashem...${NC}"
    systemctl stop 'frps-wss*' frps frpc "${TUNNEL_NAME}.service" hashem-watchdog.timer hashem-watchdog.service backhaul-server backhaul-client hashem-bagher.service hashem-bagher-frps.service hashem-bagher-frpc.service >/dev/null 2>&1 || true
    systemctl disable 'frps*' 'frpc*' 'backhaul*' 'gre-t*' "${TUNNEL_NAME}.service" hashem-watchdog.timer >/dev/null 2>&1 || true
    purge_legacy_obfuscation
    pkill -9 -f "${INSTALL_DIR}/frps" >/dev/null 2>&1 || true
    pkill -9 -f "${INSTALL_DIR}/frpc" >/dev/null 2>&1 || true
    pkill -9 -f "${INSTALL_DIR}/backhaul" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service /etc/systemd/system/backhaul*.service /etc/systemd/system/${TUNNEL_NAME}.service /etc/systemd/system/gre-t*.service /etc/systemd/system/hashem-watchdog.* /etc/systemd/system/hashem-bagher*.service
    systemctl daemon-reload
    for gif in "$TUNNEL_NAME" $(ip -d link show type gre 2>/dev/null | awk -F: '/^[0-9]+: / {print $2}' | tr -d ' '); do
        [[ -n "$gif" ]] && { ip link del "$gif" >/dev/null 2>&1 || ip tunnel del "$gif" >/dev/null 2>&1 || true; }
    done
    tune_restore >/dev/null 2>&1 || true
    rm -f "${INSTALL_DIR}/frps" "${INSTALL_DIR}/frpc" "${INSTALL_DIR}/backhaul" /usr/local/bin/hashem-tls-proxy.py
    rm -rf "$CONFIG_DIR" "$BACKHAUL_CONFIG_DIR" "$PANEL_CONFIG_DIR" /var/log/hashem*
    rm -f /usr/local/bin/hashem /usr/local/bin/hashem.sh /usr/local/bin/gre.sh
    echo -e "${GREEN}[✔️] Complete uninstallation finished.${NC}"
}

remove_tunnel() {
    read -p "Remove all tunnels from THIS server? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] && remove_tunnel_force || echo -e "${YELLOW}[*] Aborted.${NC}"
}

remove_tunnel_force() {
    echo -e "${CYAN}[*] Removing all tunnel components...${NC}"
    frps_wss_front_remove ""
    systemctl stop frps frpc "${TUNNEL_NAME}.service" backhaul-server backhaul-client 'frps*' 'frpc*' 'backhaul*' 'gre-t*' >/dev/null 2>&1 || true
    systemctl disable frps frpc "${TUNNEL_NAME}.service" backhaul-server backhaul-client 'frps*' 'frpc*' 'backhaul*' 'gre-t*' >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/frps*.service /etc/systemd/system/frpc.service /etc/systemd/system/backhaul*.service /etc/systemd/system/${TUNNEL_NAME}.service /etc/systemd/system/gre-t*.service
    systemctl daemon-reload
    for gif in "$TUNNEL_NAME" $(ip -d link show type gre 2>/dev/null | awk -F: '/^[0-9]+: / {print $2}' | tr -d ' '); do
        [[ -n "$gif" ]] && { ip link del "$gif" >/dev/null 2>&1 || ip tunnel del "$gif" >/dev/null 2>&1 || true; }
    done
    rm -rf "$CONFIG_DIR" "$BACKHAUL_CONFIG_DIR"
    rm -f "$PEERS_FILE"
    echo -e "${GREEN}[✔️] All tunnel components removed.${NC}"
}

# ---- Kernel & Network Optimization ----
TUNE_BACKUP="${PANEL_CONFIG_DIR}/tune.bak"

tune_scale_values() {
    local mem_mb="${1:-1024}"
    [[ "$mem_mb" =~ ^[0-9]+$ ]] && (( mem_mb > 0 )) || mem_mb=1024
    TUNE_MEM_MB="$mem_mb"
    TUNE_RMEM_DEFAULT=262144
    TUNE_TCP_RMEM="4096 131072 16777216"
    TUNE_TCP_WMEM="4096 131072 16777216"
    TUNE_CT_MAX=$(( mem_mb * 128 ))
    (( TUNE_CT_MAX < 65536 )) && TUNE_CT_MAX=65536
    (( TUNE_CT_MAX > 1048576 )) && TUNE_CT_MAX=1048576
    TUNE_CT_EST_TIMEOUT=3600
    TUNE_TW_BUCKETS=$(( mem_mb * 256 ))
    (( TUNE_TW_BUCKETS < 65536 )) && TUNE_TW_BUCKETS=65536
    TUNE_MAX_ORPHANS=$(( mem_mb * 32 ))
    (( TUNE_MAX_ORPHANS < 8192 )) && TUNE_MAX_ORPHANS=8192
}

tune_mem_mb() {
    local kb
    kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    [[ "$kb" =~ ^[0-9]+$ ]] && echo $(( kb / 1024 )) || echo 1024
}

tune_apply() {
    tune_scale_values "$(tune_mem_mb)"
    mkdir -p /etc/sysctl.d
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe nf_conntrack >/dev/null 2>&1 || true
    cat > /etc/sysctl.d/99-gre-tune.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = ${TUNE_RMEM_DEFAULT}
net.core.wmem_default = ${TUNE_RMEM_DEFAULT}
net.ipv4.tcp_rmem = ${TUNE_TCP_RMEM}
net.ipv4.tcp_wmem = ${TUNE_TCP_WMEM}
net.core.netdev_max_backlog = 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = ${TUNE_TW_BUCKETS}
net.ipv4.tcp_max_orphans = ${TUNE_MAX_ORPHANS}
fs.file-max = 2097152
fs.nr_open = 2097152
net.ipv4.ip_forward = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = ${TUNE_CT_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = ${TUNE_CT_EST_TIMEOUT}
EOF
    sysctl --system >/dev/null 2>&1 || true
    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || \
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1340 >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] Kernel BBR, buffers, conntrack & MSS clamping applied.${NC}"
}

tune_restore() {
    rm -f /etc/sysctl.d/99-gre-tune.conf
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}[✔️] Kernel tuning restored to system defaults.${NC}"
}

tune_status() {
    echo -e "${CYAN}=== Tunnel Optimization Status ===${NC}"
    echo "CC:        $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo ?)"
    echo "rmem_max:  $(sysctl -n net.core.rmem_max 2>/dev/null || echo ?)"
    echo "conntrack: $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo ?)"
    echo "forward:   $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)"
}

free_ram() {
    echo -e "${CYAN}[*] Optimizing RAM & Swap...${NC}"
    if [[ -f /etc/systemd/journald.conf ]]; then
        journalctl --vacuum-size=16M >/dev/null 2>&1 || true
    fi
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    if ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 2>/dev/null; then
            chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
            grep -q '/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    fi
    free -m | head -2
}

# ---- Watchdog & Encrypted Backups ----
ensure_backup_key() {
    mkdir -p "$PANEL_CONFIG_DIR"
    if [[ ! -f "${PANEL_CONFIG_DIR}/backup.key" ]]; then
        tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32 > "${PANEL_CONFIG_DIR}/backup.key"
        chmod 600 "${PANEL_CONFIG_DIR}/backup.key"
    fi
}

init_watchdog_json() {
    mkdir -p "$PANEL_CONFIG_DIR"
    if [[ ! -f "$WATCHDOG_FILE" ]]; then
        cat << 'EOF' > "$WATCHDOG_FILE"
{
  "enabled": false,
  "interval_sec": 60,
  "fail_threshold": 2,
  "auto_restart": true,
  "restart_every_hours": 0,
  "last_restart": 0,
  "tg_bot_token": "",
  "tg_chat_id": "",
  "tg_route": "direct",
  "tg_tunnel_port": 0,
  "backup_every_hours": 0,
  "backup_daily_at": "",
  "last_check": "",
  "consec_fails": 0,
  "last_alert": ""
}
EOF
        chmod 600 "$WATCHDOG_FILE" 2>/dev/null || true
    fi
}

watchdog_get_peer_gre() {
    if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
        local INNER
        INNER=$(ip -4 addr show dev "$TUNNEL_NAME" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
        if [[ "$INNER" == "$IRAN_GRE_IP" ]]; then echo "$FOREIGN_GRE_IP"; return 0
        elif [[ "$INNER" == "$FOREIGN_GRE_IP" ]]; then echo "$IRAN_GRE_IP"; return 0; fi
    fi
    echo ""
}

watchdog_check() {
    init_watchdog_json
    local PEER_GRE GRE_OK=0 FRP_OK=0
    PEER_GRE=$(watchdog_get_peer_gre)
    [[ -n "$PEER_GRE" ]] && ping -c 1 -W 2 "$PEER_GRE" >/dev/null 2>&1 && GRE_OK=1
    for svc in frpc frps backhaul-client backhaul-server; do
        systemctl is-active --quiet "$svc" 2>/dev/null && { FRP_OK=1; break; }
    done
    if [[ $GRE_OK -eq 1 && $FRP_OK -eq 1 ]]; then
        echo "WATCHDOG status=up detail=Tunnel healthy ($PEER_GRE)"
    else
        echo "WATCHDOG status=down detail=GRE_OK=${GRE_OK},SERVICE_OK=${FRP_OK}"
    fi
}

watchdog_send() {
    local TEXT="$1"
    [[ -z "$TEXT" ]] && return 1
    init_watchdog_json
    local CFG TG_TOKEN TG_CHAT_ID
    CFG=$(python3 -c "import json; d=json.load(open('$WATCHDOG_FILE')); print(f\"{d.get('tg_bot_token','')}\t{d.get('tg_chat_id','')}\")" 2>/dev/null)
    IFS=$'\t' read -r TG_TOKEN TG_CHAT_ID <<< "$CFG"
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]] && return 1
    curl -sS -f --max-time 15 -d "chat_id=${TG_CHAT_ID}" --data-urlencode "text=[Hashem $(hostname)] ${TEXT}" "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null
}

watchdog_test() {
    watchdog_send "✅ Hashem CLI Watchdog Test OK" && echo -e "${GREEN}[✔️] Telegram alert sent.${NC}" || echo -e "${RED}[!] Telegram send failed.${NC}"
}

restart_all_lite() {
    if [[ -f /etc/frp/frps.toml ]]; then
        for u in /etc/systemd/system/gre-t*.service /etc/systemd/system/gre-tunnel.service; do
            [[ -f "$u" ]] && systemctl restart "$(basename "$u")" >/dev/null 2>&1 || true
        done
        return 0
    fi
    for u in gre-tunnel.service frpc.service backhaul-client.service; do
        [[ -f "/etc/systemd/system/$u" ]] && systemctl restart "$u" >/dev/null 2>&1 || true
    done
}

watchdog_tick() {
    init_watchdog_json
    dial_watch_tick 2>/dev/null || true
    autopool_tick 2>/dev/null || true
    local CHECK_OUT
    CHECK_OUT=$(watchdog_check)
    if [[ "$CHECK_OUT" == *"status=down"* ]]; then
        restart_all_lite
    fi
}

install_watchdog_units() {
    cat << 'EOF' > /etc/systemd/system/hashem-watchdog.service
[Unit]
Description=Hashem Watchdog and Auto-Pool Tick
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hashem watchdog tick
EOF
    cat << 'EOF' > /etc/systemd/system/hashem-watchdog.timer
[Unit]
Description=Run Hashem Watchdog every minute
After=network.target

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

watchdog_on() {
    init_watchdog_json
    install_watchdog_units
    systemctl enable --now hashem-watchdog.timer >/dev/null 2>&1
    python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['enabled']=True; json.dump(d,open(p,'w'),indent=2)" 2>/dev/null || true
    echo -e "${GREEN}[✔️] Watchdog enabled.${NC}"
}

watchdog_off() {
    systemctl disable --now hashem-watchdog.timer >/dev/null 2>&1 || true
    python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['enabled']=False; json.dump(d,open(p,'w'),indent=2)" 2>/dev/null || true
    echo -e "${YELLOW}[*] Watchdog disabled.${NC}"
}

watchdog_status_full() {
    init_watchdog_json
    cat "$WATCHDOG_FILE"
    echo ""
    watchdog_check
}

cli_watchdog() {
    case "${1:-status}" in
        on) watchdog_on ;;
        off) watchdog_off ;;
        status) watchdog_status_full ;;
        test) watchdog_test ;;
        tick) watchdog_tick ;;
        check) watchdog_check ;;
    esac
}

menu_watchdog() {
    while true; do
        clear
        echo -e "${CYAN}=== Watchdog & Encrypted Backup ===${NC}"
        watchdog_check
        echo ""
        echo "  1) Enable Watchdog"
        echo "  2) Disable Watchdog"
        echo "  3) Set Telegram Bot Token & Chat ID"
        echo "  4) Test Telegram Alert"
        echo "  5) Backup Now (AES-256-CBC Encrypted)"
        echo "  6) Restore from Encrypted Backup"
        echo "  0) Back"
        read -p "Select [0-6]: " W_OPT
        case "$W_OPT" in
            1) watchdog_on; pause_prompt ;;
            2) watchdog_off; pause_prompt ;;
            3)
                read -p "Bot Token: " T_TOK
                read -p "Chat ID: " T_CID
                python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['tg_bot_token']='$T_TOK'; d['tg_chat_id']='$T_CID'; json.dump(d,open(p,'w'),indent=2)" 2>/dev/null || true
                echo -e "${GREEN}[✔️] Saved.${NC}"; pause_prompt ;;
            4) watchdog_test; pause_prompt ;;
            5) backup_now; pause_prompt ;;
            6)
                ls -lh "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null || true
                read -p "Backup file path: " BF
                [[ -n "$BF" ]] && backup_restore "$BF"
                pause_prompt ;;
            0) return 0 ;;
        esac
    done
}

backup_file_list() {
    local f
    for f in /etc/frp/*.toml /etc/backhaul/*.toml "$PANEL_CONFIG_DIR"/*.json "$PANEL_CONFIG_DIR"/backup.key /etc/systemd/system/gre-*.service /etc/systemd/system/frps*.service /etc/systemd/system/frpc*.service /etc/systemd/system/backhaul-*.service; do
        [[ -f "$f" ]] && echo "$f"
    done
}

backup_now() {
    mkdir -p "$BACKUP_DIR"
    ensure_backup_key
    local OUT_FILE="${BACKUP_DIR}/hashem-backup-$(date +%Y%m%d-%H%M%S).enc"
    local FILES=()
    mapfile -t FILES < <(backup_file_list)
    [[ ${#FILES[@]} -eq 0 ]] && { echo -e "${RED}[!] Nothing to back up.${NC}"; return 1; }
    tar -czf - "${FILES[@]}" 2>/dev/null | openssl enc -aes-256-cbc -pbkdf2 -pass file:"${PANEL_CONFIG_DIR}/backup.key" -out "$OUT_FILE"
    chmod 600 "$OUT_FILE" 2>/dev/null || true
    echo -e "${GREEN}[✔️] Encrypted backup created: ${OUT_FILE}${NC}"
}

backup_restore() {
    local FILE="$1"
    [[ -f "$FILE" ]] || { echo -e "${RED}[!] File not found: $FILE${NC}"; return 1; }
    ensure_backup_key
    local TMP_D
    TMP_D=$(mktemp -d)
    trap 'rm -rf "$TMP_D"' RETURN
    openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"${PANEL_CONFIG_DIR}/backup.key" -in "$FILE" -out "$TMP_D/backup.tar.gz" 2>/dev/null || { echo -e "${RED}[!] Decryption failed.${NC}"; return 1; }
    tar -xzf "$TMP_D/backup.tar.gz" -C /
    systemctl daemon-reload
    restart_all
    echo -e "${GREEN}[✔️] Backup restored and services restarted.${NC}"
}

cli_backup() {
    local SUB="${1:-status}"; shift || true
    case "$SUB" in
        now) backup_now "$@" ;;
        restore) backup_restore "$@" ;;
        status) ls -lh "$BACKUP_DIR"/hashem-backup-*.enc 2>/dev/null || echo "(no backups)" ;;
        schedule)
            init_watchdog_json
            case "${1:-}" in
                --every) python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['backup_every_hours']=int('${2:-6}'); json.dump(d,open(p,'w'),indent=2)" ;;
                --daily) python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['backup_daily_at']='${2:-03:00}'; json.dump(d,open(p,'w'),indent=2)" ;;
                --off)   python3 -c "import json; p='$WATCHDOG_FILE'; d=json.load(open(p)); d['backup_every_hours']=0; d['backup_daily_at']=''; json.dump(d,open(p,'w'),indent=2)" ;;
            esac
            echo -e "${GREEN}[✔️] Backup schedule updated.${NC}"
            ;;
    esac
}

# ---- Script Update (Standalone CLI — Never installs Web Panel) ----
update_all() {
    echo -e "${CYAN}[*] Updating Hashem CLI script...${NC}"
    local TMP_U
    TMP_U="$(mktemp -d)"
    trap 'rm -rf "$TMP_U"' RETURN
    if ! download_with_fallback "$TMP_U/hashem.sh" "${HASHEM_URL_BASE}/hashem.sh" 30; then
        echo -e "${RED}[!] Failed to download latest hashem.sh.${NC}"
        return 1
    fi
    # Patch downloaded script to keep standalone CLI mode active
    sed -i \
        -e 's/GRE_SKIP_PANEL:-0/GRE_SKIP_PANEL:-1/g' \
        -e 's/PANEL_STATUS=\$(get_component_status panel)/PANEL_STATUS="RUNNING"/g' \
        "$TMP_U/hashem.sh" 2>/dev/null || true
    bash -n "$TMP_U/hashem.sh" || { echo -e "${RED}[!] Syntax check failed.${NC}"; return 1; }
    cp "$TMP_U/hashem.sh" "$HASHEM_SCRIPT" 2>/dev/null && chmod +x "$HASHEM_SCRIPT" || true
    cp "$TMP_U/hashem.sh" "$HASHEM_BIN" 2>/dev/null && chmod +x "$HASHEM_BIN" || true
    ln -sf "$HASHEM_SCRIPT" /usr/local/bin/gre.sh 2>/dev/null || true
    echo -e "${GREEN}[✔️] Hashem CLI script updated successfully (Web Panel remains disabled).${NC}"
}

# ---- Carrier CLI & Menu ----
cli_carrier() {
    init_carrier_json
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            local MODE ACT P1 P2
            MODE=$(carrier_get_mode)
            ACT=$(carrier_get_active)
            read -r P1 P2 <<< "$(carrier_get_fou_ports)"
            echo -e "\n${CYAN}=== Tunnel Carrier Status ===${NC}"
            echo -e "Carrier Mode:   ${YELLOW}${MODE}${NC}"
            echo -e "Active Carrier: ${GREEN}${ACT}${NC}"
            echo -e "FOU UDP Ports:  ${P1}, ${P2}"
            ;;
        mode|set-mode)
            carrier_set_mode "${2:-direct}"
            carrier_apply "${2:-direct}"
            echo -e "${GREEN}[✔️] Carrier mode set and applied: ${2:-direct}${NC}"
            ;;
        set|set-active|apply)
            carrier_apply "${2:-direct}"
            echo -e "${GREEN}[✔️] Active carrier switched to: ${2:-direct}${NC}"
            ;;
        next|cycle)
            echo -e "${GREEN}[✔️] Cycled carrier to: $(carrier_cycle_next)${NC}"
            ;;
        set-ports)
            carrier_set_fou_ports "${2:-443}" "${3:-55555}"
            carrier_init_kernel
            echo -e "${GREEN}[✔️] FOU ports updated.${NC}"
            ;;
        init|kernel-init)
            carrier_init_kernel
            ;;
        *)
            echo "Usage: hashem carrier [status|mode <direct|fou:PORT|wss:PORT>|set <target>|next|set-ports <P1> <P2>]"
            return 1
            ;;
    esac
}

menu_carrier() {
    cli_carrier status
    echo ""
    echo "  1) Force Direct GRE (Raw Protocol 47)"
    echo "  2) Force FOU UDP (fou:443)"
    echo "  3) Force FOU UDP (fou:55555)"
    echo "  4) Force WSS Obfuscated Carrier (wss:8443)"
    echo "  5) Cycle to Next Candidate Now"
    echo "  0) Back"
    echo ""
    read -p "Select [0-5]: " C_OPT
    case "$C_OPT" in
        1) cli_carrier set direct ;;
        2) cli_carrier set fou:443 ;;
        3) cli_carrier set fou:55555 ;;
        4) cli_carrier set wss:8443 ;;
        5) cli_carrier next ;;
        0) return 0 ;;
    esac
    pause_prompt
}

# ---- Bagher Engine [PRO] (No Web Dashboard) ----
BAGHER_PSK="1234"

bagher_tcp_check() {
    local host="$1" port="$2" timeout_s="${3:-6}"
    timeout "$timeout_s" bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

bagher_last_error() {
    local svc="$1"
    journalctl -u "$svc" -n 50 --no-pager 2>/dev/null \
        | grep -Ei 'timed out|refused|permission denied|no route to host|could not resolve|name or service not known|connection closed by|banner exchange' \
        | tail -n 1
}

bagher_explain_error() {
    local err="$1"
    case "$err" in
        *"timed out"*)
            echo -e "  ${YELLOW}-> TCP connection never reached the remote host/port.${NC}"
            echo -e "     Most likely: the SSH port is blocked/filtered on the path from this server"
            echo -e "     (very common for plain port 22 on Iranian links), the remote server is down,"
            echo -e "     or the IP/port is wrong. Run: hashem bagher check (see below)."
            ;;
        *"refused"*)
            echo -e "  ${YELLOW}-> Remote host answered but is NOT listening on that port.${NC}"
            echo -e "     Check sshd is running on the remote server and listening on the port you used."
            ;;
        *"Permission denied"*)
            echo -e "  ${YELLOW}-> Reached the server, but authentication failed.${NC}"
            echo -e "     Make sure PasswordAuthentication is enabled in sshd_config on the remote server"
            echo -e "     and that its root/user password matches the Bagher PSK (\"${BAGHER_PSK}\")."
            ;;
        *"No route to host"*)
            echo -e "  ${YELLOW}-> No network route to that IP. Double-check the remote IP is correct and online.${NC}"
            ;;
        *"could not resolve"*|*"Name or service not known"*)
            echo -e "  ${YELLOW}-> Could not resolve the remote host. Double-check the address.${NC}"
            ;;
    esac
}

cli_bagher() {
    local SUB="${1:-status}"
    case "$SUB" in
        status)
            echo -e "${CYAN}=== Hashem Bagher Engine [PRO] Status ===${NC}"
            if systemctl is-active --quiet hashem-bagher.service 2>/dev/null; then
                echo -e "Bagher Carrier:    ${GREEN}active (running)${NC}"
            else
                local B_STATE B_ERR
                B_STATE=$(systemctl is-active hashem-bagher.service 2>/dev/null || echo "inactive")
                echo -e "Bagher Carrier:    ${YELLOW}${B_STATE}${NC}"
                B_ERR=$(bagher_last_error hashem-bagher.service)
                if [[ -n "$B_ERR" ]]; then
                    echo -e "  ${YELLOW}Last error:${NC} ${B_ERR}"
                    bagher_explain_error "$B_ERR"
                else
                    echo -e "  ${YELLOW}(no recent error line found — run: journalctl -u hashem-bagher.service -n 50)${NC}"
                fi
            fi
            if systemctl is-active --quiet hashem-bagher-frps.service 2>/dev/null; then
                echo -e "Bagher FRP Server: ${GREEN}active (running)${NC}"
            elif systemctl is-active --quiet hashem-bagher-frpc.service 2>/dev/null; then
                echo -e "Bagher FRP Client: ${GREEN}active (running)${NC}"
            fi
            ;;
        check)
            shift
            local CHK_HOST="${1:-}" CHK_PORT="${2:-22}"
            if [[ -z "$CHK_HOST" ]]; then
                echo "Usage: hashem bagher check <remote-host> [ssh-port]"
                return 1
            fi
            echo -e "${CYAN}[*] Checking ${CHK_HOST}:${CHK_PORT} reachability (TCP)...${NC}"
            if bagher_tcp_check "$CHK_HOST" "$CHK_PORT" 6; then
                echo -e "${GREEN}[✔️] ${CHK_HOST}:${CHK_PORT} is reachable from this server.${NC}"
            else
                echo -e "${RED}[!] Could not reach ${CHK_HOST}:${CHK_PORT} within 6s.${NC}"
                echo -e "${YELLOW}    Test ping separately: ping -c 3 ${CHK_HOST}${NC}"
                echo -e "${YELLOW}    If ping works but this still fails, port ${CHK_PORT} is almost certainly"
                echo -e "    blocked/filtered on the way out of this server (common for plain SSH/22 on"
                echo -e "    Iranian links) or blocked by a firewall/security-group on the remote side.${NC}"
                echo -e "${YELLOW}    Try adding a second sshd port (e.g. 443) on the remote server and re-run"
                echo -e "    enable with --ssh-port 443.${NC}"
            fi
            ;;
        enable)
            shift
            local REMOTE_HOST="" PORTS="443, 8443, 1020, 1030, 1040" SSH_PORT="22" USER="root" MODE="bagher" POOL_COUNT="25" FRP_PORT="55400"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --remote-host|--remote-pub|-r) REMOTE_HOST="$2"; shift 2 ;;
                    --mode|-m) MODE="$2"; shift 2 ;;
                    --ports|-p) PORTS="$2"; shift 2 ;;
                    --pool-count) POOL_COUNT="$2"; shift 2 ;;
                    --frp-port) FRP_PORT="$2"; shift 2 ;;
                    --ssh-port) SSH_PORT="$2"; shift 2 ;;
                    --user|-u) USER="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            [[ -z "$REMOTE_HOST" ]] && { echo -e "${RED}[!] --remote-host <IP> is required.${NC}"; return 1; }
            install_frp_binaries "all" || true
            command -v sshpass >/dev/null 2>&1 || {
                export DEBIAN_FRONTEND=noninteractive
                { timeout 30 apt-get update -qq </dev/null && timeout 60 apt-get install -y -qq sshpass </dev/null; } 2>/dev/null || true
            }

            echo -e "${CYAN}[*] Testing TCP reachability to ${REMOTE_HOST}:${SSH_PORT} before enabling...${NC}"
            if bagher_tcp_check "$REMOTE_HOST" "$SSH_PORT" 6; then
                echo -e "${GREEN}[✔️] ${REMOTE_HOST}:${SSH_PORT} is reachable.${NC}"
            else
                echo -e "${YELLOW}[!] Could not reach ${REMOTE_HOST}:${SSH_PORT} within 6s.${NC}"
                echo -e "${YELLOW}    This usually means port ${SSH_PORT} is blocked/filtered between this server"
                echo -e "    and ${REMOTE_HOST} (ISP/DPI filtering, a firewall or cloud security-group rule on"
                echo -e "    the remote server, or the remote IP/port is simply wrong).${NC}"
                echo -e "${YELLOW}    The service will still be installed and will keep retrying, but it will"
                echo -e "    very likely keep failing until this is fixed. Tip: if plain port 22 is blocked,"
                echo -e "    add a second line 'Port 443' to sshd_config on ${REMOTE_HOST}, restart sshd there,"
                echo -e "    then re-run this with --ssh-port 443.${NC}"
            fi
            local PORT_OPT=""
            [[ "$SSH_PORT" != "22" && -n "$SSH_PORT" ]] && PORT_OPT="-p $SSH_PORT"
            IFS=',' read -ra PORT_ARR <<< "$PORTS"

            if [[ "$MODE" == "bagher" || "$MODE" == "frp_ssh" ]]; then
                mkdir -p "${PANEL_CONFIG_DIR}/bagher"
                cat <<EOF > "${PANEL_CONFIG_DIR}/bagher/frps.toml"
bindAddr = "127.0.0.1"
bindPort = ${FRP_PORT}
proxyBindAddr = "0.0.0.0"
auth.token = "hashem-bagher-sec"
transport.tcpMux = false
EOF
                cat <<EOF > /etc/systemd/system/hashem-bagher-frps.service
[Unit]
Description=Hashem Bagher Engine FRP Server (Iran)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c ${PANEL_CONFIG_DIR}/bagher/frps.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
                cat <<EOF > /etc/systemd/system/hashem-bagher.service
[Unit]
Description=Hashem Bagher Engine Carrier (Reverse SSH tunnel)
After=network-online.target hashem-bagher-frps.service
StartLimitIntervalSec=0

[Service]
Environment=SSHPASS=${BAGHER_PSK}
ExecStart=/usr/bin/sshpass -e /usr/bin/ssh -N -o BatchMode=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o TCPKeepAlive=yes -R 127.0.0.1:${FRP_PORT}:127.0.0.1:${FRP_PORT} ${PORT_OPT} ${USER}@${REMOTE_HOST}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now hashem-bagher-frps.service hashem-bagher.service
                echo -e "${GREEN}[✔️] Bagher Engine [PRO] started.${NC}"
                echo -e "${YELLOW}[i] Make sure the SSH password on ${USER}@${REMOTE_HOST} is set to the shared PSK (\"${BAGHER_PSK}\") and that PasswordAuthentication is enabled in sshd_config on that server.${NC}"
            else
                local FWD_ARGS=""
                for p in "${PORT_ARR[@]}"; do
                    p=$(echo "$p" | tr -d ' ')
                    [[ -n "$p" ]] && FWD_ARGS="$FWD_ARGS -L 0.0.0.0:$p:127.0.0.1:$p"
                done
                cat <<EOF > /etc/systemd/system/hashem-bagher.service
[Unit]
Description=Hashem Bagher Engine Carrier (Direct SSH tunnel)
After=network-online.target
StartLimitIntervalSec=0

[Service]
Environment=SSHPASS=${BAGHER_PSK}
ExecStart=/usr/bin/sshpass -e /usr/bin/ssh -N -o BatchMode=no -o ConnectTimeout=15 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new ${PORT_OPT} ${FWD_ARGS} ${USER}@${REMOTE_HOST}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload
                systemctl enable --now hashem-bagher.service
                echo -e "${GREEN}[✔️] Direct SSH Forward started.${NC}"
                echo -e "${YELLOW}[i] Make sure the SSH password on ${USER}@${REMOTE_HOST} is set to the shared PSK (\"${BAGHER_PSK}\") and that PasswordAuthentication is enabled in sshd_config on that server.${NC}"
            fi
            ;;
        disable)
            systemctl disable --now hashem-bagher.service hashem-bagher-frps.service hashem-bagher-frpc.service >/dev/null 2>&1 || true
            echo -e "${YELLOW}[*] Bagher Engine disabled.${NC}"
            ;;
        start) systemctl start hashem-bagher.service hashem-bagher-frps.service 2>/dev/null || true ;;
        stop) systemctl stop hashem-bagher.service hashem-bagher-frps.service 2>/dev/null || true ;;
        restart) systemctl restart hashem-bagher.service hashem-bagher-frps.service 2>/dev/null || true ;;
        logs) journalctl -u hashem-bagher.service -u hashem-bagher-frps.service -n 50 --no-pager ;;
        clear-dnat)
            nft delete table inet hashem_dnat >/dev/null 2>&1 || true
            echo -e "${GREEN}[✔️] Cleared conflicting DNAT table.${NC}"
            ;;
        bundle)
            local MY_IP=$(get_public_ip)
            local B64=$(printf '{"v":1,"role":"foreign","iran_pub":"%s","frp_port":55400,"ports":[443,8443,1020,1030,1040],"token":"hashem-bagher-sec","pool_count":25,"psk":"%s","ssh_port":22}' "$MY_IP" "$BAGHER_PSK" | base64 | tr -d '\n\r ')
            echo "BAGHER:${B64}"
            ;;
        apply-bundle)
            shift
            local B64="${1#BAGHER:}"
            local DECODED=$(printf "%s" "$B64" | base64 -d 2>/dev/null || true)
            local FRP_PORT=$(echo "$DECODED" | grep -o '"frp_port":[0-9]*' | cut -d':' -f2)
            local POOL_COUNT=$(echo "$DECODED" | grep -o '"pool_count":[0-9]*' | cut -d':' -f2)
            FRP_PORT="${FRP_PORT:-55400}"; POOL_COUNT="${POOL_COUNT:-25}"
            install_frp_binaries "client" || true
            mkdir -p "${PANEL_CONFIG_DIR}/bagher"
            cat <<EOF > "${PANEL_CONFIG_DIR}/bagher/frpc.toml"
serverAddr = "127.0.0.1"
serverPort = ${FRP_PORT}
auth.token = "hashem-bagher-sec"
transport.tcpMux = false
transport.poolCount = ${POOL_COUNT}
loginFailExit = false

[[proxies]]
name = "p443"
type = "tcp"
localIP = "127.0.0.1"
localPort = 443
remotePort = 443

[[proxies]]
name = "p8443"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8443
remotePort = 8443
EOF
            cat <<EOF > /etc/systemd/system/hashem-bagher-frpc.service
[Unit]
Description=Hashem Bagher Engine Client (Foreign)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c ${PANEL_CONFIG_DIR}/bagher/frpc.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload && systemctl enable --now hashem-bagher-frpc.service
            echo -e "${GREEN}[✔️] Bagher client started (No web dashboard listening).${NC}"
            ;;
    esac
}
cli_sshfwd() { cli_bagher "$@"; }

# ---- Native Multi-Foreign Cluster & Load Balancer (No gre-panel required) ----
CLUSTER_FILE="${PANEL_CONFIG_DIR}/cluster.json"

init_cluster_json() {
    mkdir -p "$PANEL_CONFIG_DIR"
    if [[ ! -f "$CLUSTER_FILE" ]]; then
        cat <<EOF > "$CLUSTER_FILE"
{
  "enabled": true,
  "mode": "wrr",
  "active_node": "",
  "nodes": []
}
EOF
    fi
}

cli_cluster() {
    init_cluster_json
    local SUB="${1:-status}"
    shift || true
    case "$SUB" in
        status|peers)
            python3 - "$CLUSTER_FILE" <<'PY'
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
print(f"Cluster Strategy: {d.get('mode', 'wrr').upper()} | Active Primary: {d.get('active_node') or 'Auto'}")
nodes = d.get("nodes", [])
if not nodes:
    print("  (No foreign nodes in cluster pool)")
for i, n in enumerate(nodes, 1):
    ip = n.get("ip", "")
    ok = subprocess.run(["ping", "-c", "1", "-W", "1", ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    st = "ONLINE" if ok else "OFFLINE"
    print(f"  #{i} {n.get('name')} -> {ip}:{n.get('port',7000)} | Weight: {n.get('weight',1)} | Proto: {n.get('proto','gre')} | Status: {st}")
PY
            ;;
        add-foreign)
            local NAME="$1" IP="$2" PORT="${3:-7000}" WEIGHT="${4:-1}" PROTO="${5:-gre}"
            is_valid_ip "$IP" || { echo -e "${RED}[!] Invalid IP: $IP${NC}"; return 1; }
            python3 - "$CLUSTER_FILE" "$NAME" "$IP" "$PORT" "$WEIGHT" "$PROTO" <<'PY'
import json, sys
f, name, ip, port, weight, proto = sys.argv[1:7]
d = json.load(open(f))
d.setdefault("nodes", []).append({"name": name, "ip": ip, "port": int(port), "weight": int(weight), "proto": proto})
if not d.get("active_node"):
    d["active_node"] = name
json.dump(d, open(f, "w"), indent=2)
PY
            echo -e "${GREEN}[✔️] Added foreign server '${NAME}' (${IP}) to cluster.${NC}"
            ;;
        del-foreign)
            local TARGET="$1"
            python3 - "$CLUSTER_FILE" "$TARGET" <<'PY'
import json, sys
f, t = sys.argv[1:3]
d = json.load(open(f))
nodes = d.get("nodes", [])
d["nodes"] = [n for idx, n in enumerate(nodes, 1) if n.get("name") != t and str(idx) != t]
json.dump(d, open(f, "w"), indent=2)
PY
            echo -e "${GREEN}[✔️] Removed '${TARGET}' from cluster.${NC}"
            ;;
        switch-foreign)
            local TARGET="$1"
            local NEW_IP
            NEW_IP=$(python3 - "$CLUSTER_FILE" "$TARGET" <<'PY'
import json, sys
f, t = sys.argv[1:3]
d = json.load(open(f))
chosen = None
for idx, n in enumerate(d.get("nodes", []), 1):
    if n.get("name") == t or str(idx) == t:
        chosen = n
        break
if not chosen:
    sys.exit(1)
d["active_node"] = chosen["name"]
json.dump(d, open(f, "w"), indent=2)
print(chosen["ip"])
PY
            ) || { echo -e "${RED}[!] Node '$TARGET' not found.${NC}"; return 1; }
            if ip link show "$TUNNEL_NAME" >/dev/null 2>&1; then
                ip tunnel change "$TUNNEL_NAME" remote "$NEW_IP" >/dev/null 2>&1 || true
            fi
            echo -e "${GREEN}[✔️] Switched active foreign endpoint to ${TARGET} (${NEW_IP}).${NC}"
            ;;
        set-mode)
            local MODE="${1:-wrr}"
            python3 -c "import json; f='$CLUSTER_FILE'; d=json.load(open(f)); d['mode']='$MODE'; json.dump(d,open(f,'w'),indent=2)"
            echo -e "${GREEN}[✔️] Cluster balancing strategy set to: ${MODE}.${NC}"
            ;;
        revert)
            iptables -t nat -S PREROUTING 2>/dev/null | grep -E 'HASHEM-CLUSTER-FAILOVER|hashem_cluster' | while read -r line; do
                iptables -t nat -D ${line#-A } 2>/dev/null || true
            done
            echo -e "${GREEN}[✔️] Cluster failover rules cleared.${NC}"
            ;;
        *)
            echo "Usage: hashem cluster {status|peers|add-foreign|del-foreign|switch-foreign|set-mode|revert}"
            ;;
    esac
}

# ---- Interactive Menus (Standalone CLI — No Web Panel) ----
pause_prompt() {
    echo ""
    read -p "Press Enter to return to menu..." _dummy
}

setup_backhaul_iran_interactive() {
    local MYIP LOCAL_PUB REMOTE_PUB PORT TOKEN TRANSPORT PORTS
    MYIP=$(get_public_ip)
    prompt_ip LOCAL_PUB "Enter IRAN Server Public IP" "$MYIP"
    prompt_ip REMOTE_PUB "Enter FOREIGN Server Public IP" ""
    prompt_port PORT "Enter Backhaul Server Port" "$(gen_random_port)"
    prompt_token TOKEN "Enter Secret Auth Token" "$(gen_token32)"
    read -p "Transport [tcpmux/ws/wss] (default tcpmux): " TRANSPORT
    TRANSPORT=${TRANSPORT:-tcpmux}
    prompt_ports PORTS "Enter Ports to Reverse-Tunnel (e.g. 443, 2083)"
    setup_backhaul_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$TRANSPORT" "$PORTS"
}

setup_gre_backhaul_iran_interactive() {
    local MYIP LOCAL_PUB REMOTE_PUB PORT TOKEN TRANSPORT PORTS
    MYIP=$(get_public_ip)
    prompt_ip LOCAL_PUB "Enter IRAN Server Public IP" "$MYIP"
    prompt_ip REMOTE_PUB "Enter FOREIGN Server Public IP" ""
    prompt_port PORT "Enter Backhaul Server Port" "$(gen_random_port)"
    prompt_token TOKEN "Enter Secret Auth Token" "$(gen_token32)"
    read -p "Transport [tcpmux/ws/wss] (default tcpmux): " TRANSPORT
    TRANSPORT=${TRANSPORT:-tcpmux}
    prompt_ports PORTS "Enter Ports to Reverse-Tunnel (e.g. 443, 2083)"
    setup_gre_backhaul_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP" "$TRANSPORT" "$PORTS"
}

ensure_modified_backhaul_core() {
    mkdir -p "/root/backhaul-core" 2>/dev/null || true
    install_backhaul_binaries
}

menu_modified_backhaul() {
    ensure_modified_backhaul_core
    local SCRIPT_TARGET="/usr/local/bin/hashem-backhaul.sh"
    if [[ ! -f "$SCRIPT_TARGET" ]]; then
        download_with_fallback "$SCRIPT_TARGET" "https://raw.githubusercontent.com/pdnczone/hashem-panel/main/hashem-backhaul.sh" 30 || true
        chmod +x "$SCRIPT_TARGET" 2>/dev/null || true
    fi
    if [[ -x "$SCRIPT_TARGET" ]]; then
        bash "$SCRIPT_TARGET" "$@"
    else
        echo -e "${RED}[!] Could not locate or download hashem-backhaul.sh.${NC}"
        pause_prompt
    fi
}

show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
  _    _            _____ _    _ ______ __  __ 
 | |  | |   /\     / ____| |  | |  ____|  \/  |
 | |__| |  /  \   | (___ | |__| | |__  | \  / |
 |  __  | / /\ \   \___ \|  __  |  __| | |\/| |
 | |  | |/ ____ \  ____) | |  | | |____| |  | |
 |_|  |_/_/    \_\_____/|_|  |_|______|_|  |_|
EOF
    echo -e "${NC}"
    echo -e "${CYAN}==============================================================${NC}"
    echo -e "${GREEN}${BOLD}     HASHEM REVERSE TUNNEL MANAGER (Standalone CLI Mode)${NC}"
    echo -e "${CYAN}     Layer 3 GRE / FRP / Backhaul / Bagher Reverse Relay${NC}"
    echo -e "${CYAN}==============================================================${NC}"

    local ROLE="Unconfigured"
    if [[ -f "/etc/frp/frps.toml" || -f "/etc/backhaul/config.toml" ]]; then
        ROLE="IRAN HUB"
    elif [[ -f "/etc/frp/frpc.toml" || -f "/etc/backhaul/client.toml" ]]; then
        ROLE="FOREIGN SPOKE"
    fi
    local TUN_STAT="${RED}Inactive${NC}"
    tunnel_present 2>/dev/null && TUN_STAT="${GREEN}Active${NC}"
    echo -e " ${BOLD}Role:${NC} ${YELLOW}${ROLE}${NC} | ${BOLD}Tunnel:${NC} ${TUN_STAT} | ${BOLD}Mode:${NC} ${GREEN}Standalone CLI (No Web Panel)${NC}"
    echo -e "${CYAN}==============================================================${NC}"
}

menu_quick_setup() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}=== 🚀 QUICK TUNNEL SETUP ===${NC}"
        echo "  1) Setup Iran Server (Create Key & Bundle)"
        echo "  2) Setup Foreign Server via Bundle"
        echo "  3) Setup Backhaul Tunnel (TCPMux, ICMP, TUN)"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-3]: " QS_OPT
        case "$QS_OPT" in
            1) setup_iran_server; pause_prompt ;;
            2) setup_foreign_server; pause_prompt ;;
            3) menu_modified_backhaul ;;
            0|q) return 0 ;;
        esac
    done
}

menu_tunnel() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}--- [ TUNNEL MANAGEMENT ] ---${NC}"
        echo "  1) Setup IRAN Tunnel (GRE + FRPS / Backhaul Server)"
        echo "  2) Setup FOREIGN Tunnel (via Bundle string or Manual)"
        echo "  3) Add Peer Tunnel (Multi-foreign servers on Iran)"
        echo "  4) List Peers & Show Setup Bundle"
        echo "  5) Edit Peer Tunnel Configuration (Ports, IP, Carrier, Name)"
        echo "  6) Remove a Specific Peer Tunnel"
        echo "  7) Tunnel Health Status & GRE Ping Test"
        echo "  8) Restart All Tunnel Services"
        echo "  9) Teardown All Tunnels"
        echo "  10) Bagher Engine [PRO] (Hybrid Stealth Tunnel)"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-10]: " T_OPT
        case "$T_OPT" in
            1)
                echo "  1) GRE + FRP Server (Recommended)"
                echo "  2) Backhaul Server (No-GRE / TCPMux)"
                echo "  3) GRE + Backhaul Server"
                echo "  4) Modified Backhaul (IPX / ICMP / TUN)"
                read -p "Select [1-4]: " IR_PROTO
                case "$IR_PROTO" in
                    1) setup_iran_server ;;
                    2) setup_backhaul_iran_interactive ;;
                    3) setup_gre_backhaul_iran_interactive ;;
                    4) menu_modified_backhaul ;;
                esac
                pause_prompt ;;
            2) setup_foreign_server; pause_prompt ;;
            3) menu_add_peer; pause_prompt ;;
            4)
                peer_list_pretty
                local IP_IRAN BIND_PORT TOKEN
                IP_IRAN=$(get_public_ip)
                BIND_PORT=$(awk -F'=' '/bindPort/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
                TOKEN=$(awk -F'=' '/auth\.token/{gsub(/[ "]/,"",$2); print $2}' /etc/frp/frps.toml 2>/dev/null)
                if [[ -n "$IP_IRAN" && -n "$BIND_PORT" && -n "$TOKEN" ]]; then
                    echo -e "\n${GREEN}=== Iran Server Setup Bundle ===${NC}"
                    echo -e "BUNDLE: ${CYAN}$(bundle_make "$IP_IRAN" "$BIND_PORT" "$IRAN_GRE_IP" "$FOREIGN_GRE_IP" "$TOKEN")${NC}\n"
                fi
                pause_prompt ;;
            5) menu_edit_peer; pause_prompt ;;
            6) menu_remove_peer; pause_prompt ;;
            7) check_status; pause_prompt ;;
            8) restart_all; pause_prompt ;;
            9) remove_tunnel; pause_prompt ;;
            10) menu_bagher ;;
            0) return 0 ;;
        esac
    done
}

menu_bagher() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}--- BAGHER ENGINE [PRO] (Hybrid Stealth Tunnel) ---${NC}"
        cli_bagher status
        echo ""
        echo "  1) Enable Bagher Engine (Stealth Hybrid Pool)"
        echo "  2) Disable Bagher Engine"
        echo "  3) Start Bagher Engine Service"
        echo "  4) Stop Bagher Engine Service"
        echo "  5) Restart Bagher Engine Service"
        echo "  6) View Bagher Service Logs"
        echo "  7) Clear Conflicting DNAT Rules"
        echo "  8) Test Connectivity to a Remote Host:Port"
        echo "  0) Back"
        echo ""
        read -p "Select an option [0-8]: " SF_OPT
        case "$SF_OPT" in
            1)
                local R_IP R_PORTS R_POOL R_MODE R_SSHPORT
                read -p "Enter Remote Host (Foreign IP): " R_IP
                read -p "Enter Remote SSH Port [22]: " R_SSHPORT; R_SSHPORT=${R_SSHPORT:-22}
                read -p "Enter Ports to forward [443, 8443, 1020, 1030, 1040]: " R_PORTS
                R_PORTS=${R_PORTS:-"443, 8443, 1020, 1030, 1040"}
                read -p "Mode (1: Bagher Hybrid Pool, 2: Direct SSH) [1]: " R_MODE
                if [[ "$R_MODE" == "2" ]]; then
                    cli_bagher enable --remote-host "$R_IP" --ssh-port "$R_SSHPORT" --ports "$R_PORTS" --mode direct
                else
                    read -p "Enter Pool Count [25]: " R_POOL; R_POOL=${R_POOL:-25}
                    cli_bagher enable --remote-host "$R_IP" --ssh-port "$R_SSHPORT" --ports "$R_PORTS" --mode bagher --pool-count "$R_POOL"
                fi
                pause_prompt ;;
            2) cli_bagher disable; pause_prompt ;;
            3) cli_bagher start; pause_prompt ;;
            4) cli_bagher stop; pause_prompt ;;
            5) cli_bagher restart; pause_prompt ;;
            6) cli_bagher logs; pause_prompt ;;
            7) cli_bagher clear-dnat; pause_prompt ;;
            8)
                local CK_HOST CK_PORT
                read -p "Remote host/IP: " CK_HOST
                read -p "Port [22]: " CK_PORT; CK_PORT=${CK_PORT:-22}
                cli_bagher check "$CK_HOST" "$CK_PORT"
                pause_prompt ;;
            0) return 0 ;;
        esac
    done
}

menu_cluster() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}=== ⚖️ MULTI-FOREIGN CLUSTER & LOAD BALANCER ===${NC}"
        echo ""
        cli_cluster status
        echo ""
        echo "  1) View Foreign Cluster Pool & Latency / Weights"
        echo "  2) Add Foreign Server to Cluster"
        echo "  3) Remove Foreign Server from Cluster"
        echo "  4) Switch Active Foreign Server"
        echo "  5) Change Balancing Strategy (WRR / Failover / Lowest Latency)"
        echo "  6) Revert Failover / Clear Balancing Rules"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-6]: " CL_OPT
        case "$CL_OPT" in
            1) cli_cluster status; pause_prompt ;;
            2)
                read -p "Foreign Server Name (e.g. de-1): " FN_NAME
                read -p "Foreign Public IP: " FN_IP
                read -p "Tunnel Port [7000]: " FN_PORT; FN_PORT="${FN_PORT:-7000}"
                read -p "Traffic Weight (1-100) [1]: " FN_WEIGHT; FN_WEIGHT="${FN_WEIGHT:-1}"
                read -p "Protocol [gre/wss, default gre]: " FN_PROTO; FN_PROTO="${FN_PROTO:-gre}"
                cli_cluster add-foreign "$FN_NAME" "$FN_IP" "$FN_PORT" "$FN_WEIGHT" "$FN_PROTO"
                pause_prompt ;;
            3)
                read -p "Enter Foreign Server Name or #ID to remove: " FN_DEL
                cli_cluster del-foreign "$FN_DEL"
                pause_prompt ;;
            4)
                read -p "Enter Foreign Server Name or #ID to activate: " FN_SW
                cli_cluster switch-foreign "$FN_SW"
                pause_prompt ;;
            5)
                echo "  1) Weighted Round Robin (wrr)"
                echo "  2) Automatic Failover (failover)"
                echo "  3) Lowest Latency (lowest_latency)"
                read -p "Select [1-3]: " STRAT_OPT
                case "$STRAT_OPT" in
                    1) cli_cluster set-mode "wrr" ;;
                    2) cli_cluster set-mode "failover" ;;
                    3) cli_cluster set-mode "lowest_latency" ;;
                esac
                pause_prompt ;;
            6) cli_cluster revert; pause_prompt ;;
            0|q) return 0 ;;
        esac
    done
}

menu_optimization() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}--- [ PERFORMANCE, CARRIER & WATCHDOG ] ---${NC}"
        echo "  1) Network Optimization (BBR + sysctl TCP buffers + MTU clamp)"
        echo "  2) Tunnel Carrier Switch (Direct GRE <-> FOU UDP <-> WSS Obfuscated)"
        echo "  3) Tunnel Watchdog & Telegram Alerts"
        echo "  4) Performance & Encryption Toggles (Proxy crypto/comp, Auto Pool)"
        echo "  5) Dial Route Mode (Foreign: Auto / GRE / Public IP)"
        echo "  6) Free RAM & Cache (Cap journald 16MB + drop cache + 1GB swapfile)"
        echo "  7) Restore Network Tuning (Revert to default sysctl)"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-7]: " O_OPT
        case "$O_OPT" in
            1) tune_apply; pause_prompt ;;
            2) menu_carrier ;;
            3) menu_watchdog ;;
            4) menu_perf ;;
            5)
                cli_dial status
                read -p "Set dial mode [auto/gre/public, Enter to skip]: " DM
                [[ -n "$DM" ]] && cli_dial "$DM"
                pause_prompt ;;
            6) free_ram; pause_prompt ;;
            7) tune_restore; pause_prompt ;;
            0) return 0 ;;
        esac
    done
}

menu_diagnostics_backup() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}--- [ DIAGNOSTICS & BACKUP ] ---${NC}"
        echo "  1) Full System & Tunnel Health Check (Doctor audit)"
        echo "  2) Latency, Jitter, MTU & iPerf3 Speed Test"
        echo "  3) Check Listening Ports & Routing Table"
        echo "  4) Reverse Path (rp_filter) Check & Fix"
        echo "  5) View Live Service Logs (journalctl)"
        echo "  6) High-Concurrency Connection Stress Test"
        echo "  7) Backup Configurations Now (Encrypted)"
        echo "  8) Restore Backup from File"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-8]: " D_OPT
        case "$D_OPT" in
            1) doctor_health_check; pause_prompt ;;
            2) doctor_diagnostics; pause_prompt ;;
            3)
                ss -tulpn | grep -E "frps|frpc|backhaul" || ss -tulpn | head -15
                echo ""
                ip route show
                pause_prompt ;;
            4) cli_revpath --apply; pause_prompt ;;
            5) show_logs ;;
            6)
                read -p "Target Host [127.0.0.1]: " S_HOST; S_HOST=${S_HOST:-127.0.0.1}
                read -p "Target Port [7000]: " S_PORT; S_PORT=${S_PORT:-7000}
                read -p "Concurrent Connections [100]: " S_CONNS; S_CONNS=${S_CONNS:-100}
                cli_stress_test "$S_HOST" "$S_PORT" "$S_CONNS"
                pause_prompt ;;
            7) backup_now; pause_prompt ;;
            8)
                cli_backup status
                read -p "Enter backup file path to restore: " R_FILE
                [[ -n "$R_FILE" ]] && backup_restore "$R_FILE"
                pause_prompt ;;
            0) return 0 ;;
        esac
    done
}

menu_maintenance() {
    while true; do
        clear
        show_banner
        echo -e "${CYAN}--- [ MAINTENANCE & UPDATE ] ---${NC}"
        echo "  1) Update Script (hashem.sh CLI only — No Web Panel)"
        echo "  2) Pre-cache / Verify Core Binaries (FRP & Backhaul)"
        echo "  3) Install / Refresh System Dependencies"
        echo "  4) Check & Load Kernel Modules (GRE & FOU)"
        echo "  5) Show System Version & Tuning Status"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-5]: " M_OPT
        case "$M_OPT" in
            1) backup_configs "pre_update"; update_all; pause_prompt ;;
            2) install_frp_binaries "all" || true; install_backhaul_binaries || true; pause_prompt ;;
            3) rm -f "${PANEL_CONFIG_DIR}/.deps_installed"; ensure_dependencies_smart; pause_prompt ;;
            4) carrier_init_kernel; echo -e "${GREEN}[✔️] Kernel modules ip_gre & fou checked.${NC}"; pause_prompt ;;
            5) echo "Hashem Script Version: $HASHEM_VERSION"; tune_status; pause_prompt ;;
            0) return 0 ;;
        esac
    done
}

menu_uninstall() {
    while true; do
        clear
        show_banner
        echo -e "${RED}--- [ UNINSTALLATION ] ---${NC}"
        echo "  1) Remove Tunnel Components Only (Keep hashem CLI)"
        echo "  2) Full Clean System Wipe (Erase all tunnels, configs & CLI)"
        echo "  0) Back to Main Menu"
        echo ""
        read -p "Select an option [0-2]: " UN_OPT
        case "$UN_OPT" in
            1) remove_tunnel; pause_prompt ;;
            2) uninstall_all; exit 0 ;;
            0) return 0 ;;
        esac
    done
}

menu_loop() {
    trap 'echo -e "\n\n${CYAN}[*] Exiting Hashem Manager. Goodbye!${NC}"; exit 0' INT
    while true; do
        clear
        show_banner
        echo ""
        echo -e "${BOLD}MAIN MENU (Standalone CLI — Web Panel Disabled)${NC}"
        echo "  1) 🚀 Quick Tunnel Setup (Iran / Foreign / Backhaul)"
        echo "  2) 🌐 Tunnel & Multi-Peer Management"
        echo "  3) ⚖️ Multi-Foreign Cluster & Load Balancer"
        echo "  4) 🥷 Bagher Pro Stealth Hybrid Engine"
        echo "  5) ⚡ Auto-Pool & FRP Performance Tuning"
        echo "  6) 🛡️ Carrier Switch, Watchdog, BBR & RAM Optimization"
        echo "  7) 🩺 Diagnostics, Doctor, Speed & Stress Test"
        echo "  8) 📦 Encrypted Backup & System Maintenance"
        echo "  9) 🗑️ Uninstall Hashem"
        echo "  0) 🚪 Exit"
        echo ""
        read -p "Select an option [0-9]: " MAIN_OPT
        case "$MAIN_OPT" in
            1) menu_quick_setup ;;
            2) menu_tunnel ;;
            3) menu_cluster ;;
            4) menu_bagher ;;
            5) menu_perf ;;
            6) menu_optimization ;;
            7) menu_diagnostics_backup ;;
            8) menu_maintenance ;;
            9) menu_uninstall ;;
            0|exit|q)
                echo -e "${CYAN}Exiting Hashem Manager. Goodbye!${NC}"
                exit 0
                ;;
        esac
    done
}

main_menu() { menu_loop; }

usage_cli() {
    cat <<EOF
Usage (Standalone CLI Mode — No Web Panel):
  hashem                                       # Open interactive terminal management menu
  hashem setup-iran    --local-pub IP --remote-pub IP [--frp-port N] [--local-gre IP] [--peer-gre IP] [--token T] [--force]
  hashem setup-foreign --bundle hsh1_... | bh1_... | gh1_... [--ports "443, 2083"] [--force]
  hashem setup-backhaul-iran    --remote-pub IP --port P [--transport tcpmux] [--token K] [--ports "..."]
  hashem setup-backhaul-foreign --bundle bh1_... | --remote-pub IP --port P --token K [--transport tcpmux]
  hashem setup-gre-backhaul-iran    --remote-pub IP --port P [--transport tcpmux] [--ports "..."]
  hashem setup-gre-backhaul-foreign --bundle gh1_... | --remote-pub IP --port P --token K
  hashem add-peer | remove-peer --id N | edit-peer --id N ... | peer-list | peer-token --id N
  hashem status | logs | restart | remove-tunnel [--force] | uninstall [--force]
  hashem optimize | restore | tune-status | free-ram
  hashem carrier [status|mode <target>|set <target>|next|set-ports <P1> <P2>]
  hashem bagher [status|enable|disable|start|stop|restart|logs|bundle|apply-bundle|check <host> [port]]
  hashem cluster [status|peers|add-foreign|del-foreign|switch-foreign|set-mode|revert]
  hashem dial [status|auto|gre|public]
  hashem perf [status|enc on|off|comp on|off|tcpmux on|off|autopool on|off|apply|reset]
  hashem watchdog [on|off|status|test|tick|check]
  hashem backup [now|restore <file>|schedule|status]
  hashem doctor [check|diag|server|stop-server|fix|stress]
  hashem revpath [--apply]
  hashem download-cores | modified-backhaul | update
EOF
}

cli_setup_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="$IRAN_GRE_IP" PEER_GRE="$FOREIGN_GRE_IP" TOKEN="" FORCE=0 PORTS="" FRP_TRANSPORT="tcp"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --frp-transport) FRP_TRANSPORT="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            *) shift ;;
        esac
    done
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    [[ -z "$TOKEN" ]] && TOKEN=$(gen_token32)
    if tunnel_present && [[ "$FORCE" -ne 1 ]]; then
        echo -e "${RED}[!] Tunnel already exists — pass --force to overwrite.${NC}"
        return 1
    fi
    setup_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$PORTS" "$FRP_TRANSPORT"
}

cli_setup_foreign() {
    local LOCAL_PUB="" REMOTE_PUB="" FRP_PORT="" LOCAL_GRE="$FOREIGN_GRE_IP" PEER_GRE="$IRAN_GRE_IP" TOKEN="" PORTS="" FORCE=0 BUNDLE=""
    local RELAY_IP="" PROXY_PROTOCOL="off" FRP_TRANSPORT="tcp" FRP_ENCRYPTION="off" FRP_COMPRESSION="off"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --frp-port) FRP_PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            --relay-ip) RELAY_IP="$2"; shift 2 ;;
            --proxy-protocol) PROXY_PROTOCOL="$2"; shift 2 ;;
            --frp-transport) FRP_TRANSPORT="$2"; shift 2 ;;
            --encrypt) FRP_ENCRYPTION="on"; shift ;;
            --compress) FRP_COMPRESSION="on"; shift ;;
            --dial) FRP_DIAL="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            *) shift ;;
        esac
    done
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || return 1
        [[ "$B_ENGINE" == "backhaul" ]] && { cli_setup_backhaul_foreign --bundle "$BUNDLE" --force; return $?; }
        [[ "$B_ENGINE" == "gre-backhaul" ]] && { cli_setup_gre_backhaul_foreign --bundle "$BUNDLE" --force; return $?; }
        TOKEN=$B_TOKEN; REMOTE_PUB=$B_IRAN_PUB; FRP_PORT=$B_FRP_PORT; LOCAL_GRE=$B_FOREIGN_GRE; PEER_GRE=$B_IRAN_GRE
        [[ -z "$PORTS" && -n "$B_PORTS" ]] && PORTS=$B_PORTS
        [[ -n "$B_TRANSPORT" && "$FRP_TRANSPORT" == "tcp" ]] && FRP_TRANSPORT="$B_TRANSPORT"
    fi
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    FRP_PORT=${FRP_PORT:-$(gen_random_port)}
    validate_setup_common "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$LOCAL_GRE" || return 1
    local CLEANED="" p
    for p in $(echo "$PORTS" | tr ',' ' '); do is_valid_port "$p" && CLEANED="$CLEANED $((10#$p))"; done
    CLEANED=$(echo "$CLEANED" | xargs)
    [[ -n "$CLEANED" ]] || { echo -e "${RED}[!] --ports is required.${NC}"; return 1; }
    setup_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$FRP_PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$CLEANED" "$RELAY_IP" "$PROXY_PROTOCOL" "$FRP_TRANSPORT" "$FRP_ENCRYPTION" "$FRP_COMPRESSION"
}

cli_setup_backhaul_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" PORT="" TRANSPORT="tcpmux" TOKEN="" PORTS=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --transport) TRANSPORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    PORT=${PORT:-$(gen_random_port)}
    [[ -z "$TOKEN" ]] && TOKEN=$(gen_token32)
    setup_backhaul_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$TRANSPORT" "$PORTS"
}

cli_setup_backhaul_foreign() {
    local LOCAL_PUB="" REMOTE_PUB="" PORT="" TRANSPORT="tcpmux" TOKEN="" BUNDLE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --transport) TRANSPORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || return 1
        REMOTE_PUB=$B_IRAN_PUB; PORT=$B_FRP_PORT; TRANSPORT=$B_TRANSPORT; TOKEN=$B_TOKEN
    fi
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    setup_backhaul_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$TRANSPORT"
}

cli_setup_gre_backhaul_iran() {
    local LOCAL_PUB="" REMOTE_PUB="" PORT="" LOCAL_GRE="$IRAN_GRE_IP" PEER_GRE="$FOREIGN_GRE_IP" TRANSPORT="tcpmux" TOKEN="" PORTS=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --transport) TRANSPORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --ports) PORTS="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    PORT=${PORT:-$(gen_random_port)}
    [[ -z "$TOKEN" ]] && TOKEN=$(gen_token32)
    setup_gre_backhaul_iran_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$TRANSPORT" "$PORTS"
}

cli_setup_gre_backhaul_foreign() {
    local LOCAL_PUB="" REMOTE_PUB="" PORT="" LOCAL_GRE="$FOREIGN_GRE_IP" PEER_GRE="$IRAN_GRE_IP" TRANSPORT="tcpmux" TOKEN="" BUNDLE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --local-pub) LOCAL_PUB="$2"; shift 2 ;;
            --remote-pub) REMOTE_PUB="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --local-gre) LOCAL_GRE="$2"; shift 2 ;;
            --peer-gre) PEER_GRE="$2"; shift 2 ;;
            --transport) TRANSPORT="$2"; shift 2 ;;
            --token) TOKEN="$2"; shift 2 ;;
            --bundle) BUNDLE="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ -n "$BUNDLE" ]]; then
        bundle_parse "$BUNDLE" || return 1
        TOKEN=$B_TOKEN; REMOTE_PUB=$B_IRAN_PUB; PORT=$B_FRP_PORT; LOCAL_GRE=$B_FOREIGN_GRE; PEER_GRE=$B_IRAN_GRE; TRANSPORT=$B_TRANSPORT
    fi
    LOCAL_PUB=${LOCAL_PUB:-$(get_public_ip)}
    setup_gre_backhaul_foreign_server_noninteractive "$LOCAL_PUB" "$REMOTE_PUB" "$PORT" "$TOKEN" "$LOCAL_GRE" "$PEER_GRE" "$TRANSPORT"
}

# ---- Entrypoint ----
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help|help) usage_cli; exit 0 ;;
        bundle)
            shift
            case "${1:-}" in
                inspect) shift; cli_bundle_inspect "$@" ;;
                *) echo "Usage: hashem bundle inspect <bundle> [--show-token]"; exit 1 ;;
            esac
            exit $?
            ;;
    esac

    check_root
    case "$1" in
        menu) main_menu ;;
        setup-iran) shift; cli_setup_iran "$@" ;;
        setup-foreign) shift; cli_setup_foreign "$@" ;;
        setup-backhaul-iran) shift; cli_setup_backhaul_iran "$@" ;;
        setup-backhaul-foreign) shift; cli_setup_backhaul_foreign "$@" ;;
        setup-gre-backhaul-iran) shift; cli_setup_gre_backhaul_iran "$@" ;;
        setup-gre-backhaul-foreign) shift; cli_setup_gre_backhaul_foreign "$@" ;;
        add-peer) shift; cli_add_peer "$@" ;;
        add-backhaul-peer) shift; cli_add_backhaul_peer "$@" ;;
        remove-peer) shift; cli_remove_peer "$@" ;;
        edit-peer) shift; cli_edit_peer "$@" ;;
        edit-peer-ports) shift; cli_edit_peer_ports "$@" ;;
        peer-list) peer_list ;;
        peer-token)
            shift; ID=""
            while [[ $# -gt 0 ]]; do case "$1" in --id) ID="$2"; shift 2 ;; *) shift ;; esac; done
            peer_token "$ID" ;;
        logs) show_logs ;;
        restart) restart_all ;;
        restart-lite|tunnel-restart-lite) restart_all_lite ;;
        perf) shift; cli_perf "$@" ;;
        watchdog) shift; cli_watchdog "$@" ;;
        backup) shift; cli_backup "$@" ;;
        tgsend) shift; watchdog_send "$1" ;;
        update|update-all) shift; update_all "$@" ;;
        status) check_status ;;
        revpath) shift; cli_revpath "$@" ;;
        doctor|test|diagnose) shift; cli_doctor "$@" ;;
        stress-test|test-load|stress) shift; cli_stress_test "$@" ;;
        carrier) shift; cli_carrier "$@" ;;
        bagher|hashem-bagher|ssh-fwd|sshfwd) shift; cli_bagher "$@" ;;
        cluster|mesh) shift; cli_cluster "$@" ;;
        carrier-kernel-init) carrier_init_kernel ;;
        dial) shift; cli_dial "$@" ;;
        dial-select) dial_reselect >/dev/null 2>&1; exit 0 ;;
        carrier-apply-active) shift; carrier_apply_active "$1" ;;
        optimize) tune_apply ;;
        restore) tune_restore ;;
        tune-status) tune_status ;;
        free-ram|optimize-ram) free_ram ;;
        download-cores|cores)
            install_frp_binaries "all" && install_backhaul_binaries
            ;;
        modified-backhaul|backhaul-premium|mbh) shift; menu_modified_backhaul "$@" ;;
        remove-tunnel)
            [[ "${2:-}" == "--force" ]] && remove_tunnel_force || remove_tunnel ;;
        uninstall)
            [[ "${2:-}" == "--force" ]] && uninstall_all_force || uninstall_all ;;
        *) echo -e "${RED}[!] Unknown command: $1${NC}"; usage_cli; exit 1 ;;
    esac
    exit $?
fi

# ---- No arguments: Ensure basic dependencies on first run & open CLI menu ----
check_root
ensure_dependencies_smart >/dev/null 2>&1 || true
main_menu
