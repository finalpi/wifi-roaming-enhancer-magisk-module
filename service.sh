#!/system/bin/sh

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=$(pwd)
CONFIG="$MODDIR/config.conf"
STATE_DIR="$MODDIR/state"
DISABLED_FILE="$STATE_DIR/disabled_by_module"
STATUS_FILE="$STATE_DIR/status"
LOG_FILE="$STATE_DIR/service.log"
LOCK_DIR="$STATE_DIR/lock"
TMP_DIR="$STATE_DIR/tmp"
WPA_CLI=wpa_cli

find_wpa_cli() {
    for CANDIDATE in /vendor/bin/wpa_cli /system/bin/wpa_cli /system_ext/bin/wpa_cli /product/bin/wpa_cli wpa_cli; do
        case "$CANDIDATE" in
            /*)
                if [ -x "$CANDIDATE" ]; then
                    WPA_CLI="$CANDIDATE"
                    return 0
                fi
                ;;
            *)
                FOUND=$(command -v "$CANDIDATE" 2>/dev/null)
                if [ -n "$FOUND" ]; then
                    WPA_CLI="$FOUND"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

find_wpa_cli
mkdir -p "$STATE_DIR" "$TMP_DIR"

default_config() {
    ENABLED=1
    WIFI_IFACE=auto
    SCAN_INTERVAL=10
    DISABLE_RSSI=-75
    RECOVERY_RSSI=-67
    MIN_AVAILABLE_NETWORKS=1
    MAX_DISABLE_PER_SCAN=3
    LOG_ENABLED=1
    LOG_MAX_LINES=200
}

is_int() {
    case "$1" in
        ''|*[!0-9-]*) return 1 ;;
        -) return 1 ;;
        *) return 0 ;;
    esac
}

clamp_int() {
    VALUE="$1"
    MIN="$2"
    MAX="$3"
    DEFAULT="$4"

    if ! is_int "$VALUE"; then
        echo "$DEFAULT"
        return
    fi

    if [ "$VALUE" -lt "$MIN" ]; then
        echo "$MIN"
    elif [ "$VALUE" -gt "$MAX" ]; then
        echo "$MAX"
    else
        echo "$VALUE"
    fi
}

load_config() {
    default_config
    [ -f "$CONFIG" ] && . "$CONFIG"

    ENABLED=$(clamp_int "$ENABLED" 0 1 1)
    SCAN_INTERVAL=$(clamp_int "$SCAN_INTERVAL" 5 300 10)
    DISABLE_RSSI=$(clamp_int "$DISABLE_RSSI" -100 -30 -75)
    RECOVERY_RSSI=$(clamp_int "$RECOVERY_RSSI" -100 -30 -67)
    MIN_AVAILABLE_NETWORKS=$(clamp_int "$MIN_AVAILABLE_NETWORKS" 1 20 1)
    MAX_DISABLE_PER_SCAN=$(clamp_int "$MAX_DISABLE_PER_SCAN" 1 20 3)
    LOG_ENABLED=$(clamp_int "$LOG_ENABLED" 0 1 1)
    LOG_MAX_LINES=$(clamp_int "$LOG_MAX_LINES" 50 1000 200)

    if [ "$RECOVERY_RSSI" -le "$DISABLE_RSSI" ]; then
        RECOVERY_RSSI=$((DISABLE_RSSI + 5))
        [ "$RECOVERY_RSSI" -gt -30 ] && RECOVERY_RSSI=-30
    fi

    case "$WIFI_IFACE" in
        ''|*[!A-Za-z0-9_.:-]*) WIFI_IFACE=auto ;;
    esac
}

log_msg() {
    [ "$LOG_ENABLED" = "1" ] || return
    mkdir -p "$STATE_DIR"
    TS=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    [ -z "$TS" ] && TS="now"
    echo "$TS $*" >> "$LOG_FILE"

    if [ -f "$LOG_FILE" ]; then
        LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
        if is_int "$LINES" && [ "$LINES" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

write_status() {
    {
        echo "enabled=$ENABLED"
        echo "iface=$WIFI_IFACE_RESOLVED"
        echo "disable_rssi=$DISABLE_RSSI"
        echo "recovery_rssi=$RECOVERY_RSSI"
        echo "scan_interval=$SCAN_INTERVAL"
        echo "last_update=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" status 2>/dev/null | grep -E '^(wpa_state|ssid|bssid|ip_address)='
    } > "$STATUS_FILE.tmp"
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

has_disabled_id() {
    [ -f "$DISABLED_FILE" ] || return 1
    grep -F "${1}|" "$DISABLED_FILE" >/dev/null 2>&1
}

add_disabled_id() {
    ID="$1"
    SSID="$2"
    has_disabled_id "$ID" && return
    echo "$ID|$SSID" >> "$DISABLED_FILE"
}

remove_disabled_id() {
    ID="$1"
    [ -f "$DISABLED_FILE" ] || return
    grep -Fv "${ID}|" "$DISABLED_FILE" > "$DISABLED_FILE.tmp" 2>/dev/null || true
    mv "$DISABLED_FILE.tmp" "$DISABLED_FILE"
}

reenable_all_module_disabled() {
    [ -n "$WIFI_IFACE_RESOLVED" ] || return
    [ -f "$DISABLED_FILE" ] || return

    while IFS='|' read -r ID SSID; do
        [ -z "$ID" ] && continue
        if "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" enable_network "$ID" >/dev/null 2>&1; then
            log_msg "re-enabled network id=$ID ssid=$SSID reason=all"
        fi
    done < "$DISABLED_FILE"

    : > "$DISABLED_FILE"
}

cleanup() {
    reenable_all_module_disabled
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR/cmd" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
}

is_our_pid() {
    PID="$1"
    [ -n "$PID" ] || return 1
    kill -0 "$PID" 2>/dev/null || return 1
    CMD=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
    echo "$CMD" | grep -F "$MODDIR/service.sh" >/dev/null 2>&1
}

resolve_iface() {
    if [ "$WIFI_IFACE" != "auto" ]; then
        if "$WPA_CLI" -i "$WIFI_IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$WIFI_IFACE"
            return 0
        fi
    fi

    for IFACE in wlan0 wlan1 wifi0; do
        if "$WPA_CLI" -i "$IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$IFACE"
            return 0
        fi
    done

    for IFACE in $(ip link show 2>/dev/null | awk -F: '/^[0-9]+: / {gsub(/ /,"",$2); print $2}' | grep -E '^(wlan|wl|wifi)'); do
        if "$WPA_CLI" -i "$IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$IFACE"
            return 0
        fi
    done

    WIFI_IFACE_RESOLVED="wlan0"
    return 1
}

build_saved_file() {
    OUT="$1"
    "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" list_networks 2>/dev/null | awk -F '\t' '
        NR > 1 && $1 ~ /^[0-9]+$/ {
            print $1 "|" $2 "|" $4
        }
    ' > "$OUT"
    [ -s "$OUT" ]
}

build_scan_file() {
    OUT="$1"
    "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" scan >/dev/null 2>&1
    sleep 2
    "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" scan_results 2>/dev/null | awk -F '\t' '
        NR > 1 && $3 ~ /^-?[0-9]+$/ && $5 != "" {
            ssid=$5
            for (i=6; i<=NF; i++) ssid=ssid "\t" $i
            if (!(ssid in best) || $3 > best[ssid]) best[ssid]=$3
        }
        END {
            for (ssid in best) print ssid "|" best[ssid]
        }
    ' > "$OUT"
    [ -s "$OUT" ]
}

build_visible_saved_file() {
    SAVED="$1"
    SCAN="$2"
    OUT="$3"
    awk -F '|' '
        FNR==NR { rssi[$1]=$2; next }
        ($2 in rssi) { print $1 "|" $2 "|" $3 "|" rssi[$2] }
    ' "$SCAN" "$SAVED" > "$OUT"
    [ -s "$OUT" ]
}

count_enabled_visible() {
    FILE="$1"
    COUNT=0
    while IFS='|' read -r ID SSID FLAGS RSSI; do
        [ -z "$ID" ] && continue
        echo "$FLAGS" | grep -F '[DISABLED]' >/dev/null 2>&1 && continue
        has_disabled_id "$ID" && continue
        COUNT=$((COUNT + 1))
    done < "$FILE"
    echo "$COUNT"
}

recover_networks() {
    VISIBLE="$1"
    [ -f "$DISABLED_FILE" ] || return

    while IFS='|' read -r ID SSID; do
        [ -z "$ID" ] && continue
        MATCH=$(awk -F '|' -v id="$ID" '$1 == id { print $4; exit }' "$VISIBLE")
        if [ -z "$MATCH" ]; then
            continue
        fi
        if is_int "$MATCH" && [ "$MATCH" -ge "$RECOVERY_RSSI" ]; then
            if "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" enable_network "$ID" >/dev/null 2>&1; then
                log_msg "re-enabled network id=$ID ssid=$SSID rssi=$MATCH threshold=$RECOVERY_RSSI"
                remove_disabled_id "$ID"
            fi
        fi
    done < "$DISABLED_FILE"
}

disable_weak_networks() {
    VISIBLE="$1"
    AVAILABLE=$(count_enabled_visible "$VISIBLE")
    DISABLED_THIS_SCAN=0

    while IFS='|' read -r ID SSID FLAGS RSSI; do
        [ -z "$ID" ] && continue
        is_int "$RSSI" || continue
        [ "$RSSI" -lt "$DISABLE_RSSI" ] || continue
        echo "$FLAGS" | grep -F '[DISABLED]' >/dev/null 2>&1 && continue
        has_disabled_id "$ID" && continue

        if [ "$AVAILABLE" -le "$MIN_AVAILABLE_NETWORKS" ]; then
            log_msg "skip disable id=$ID ssid=$SSID rssi=$RSSI reason=min_available available=$AVAILABLE"
            continue
        fi

        if [ "$DISABLED_THIS_SCAN" -ge "$MAX_DISABLE_PER_SCAN" ]; then
            log_msg "skip disable id=$ID ssid=$SSID rssi=$RSSI reason=max_per_scan"
            continue
        fi

        if "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" disable_network "$ID" >/dev/null 2>&1; then
            add_disabled_id "$ID" "$SSID"
            AVAILABLE=$((AVAILABLE - 1))
            DISABLED_THIS_SCAN=$((DISABLED_THIS_SCAN + 1))
            log_msg "disabled weak network id=$ID ssid=$SSID rssi=$RSSI threshold=$DISABLE_RSSI"
        else
            log_msg "failed to disable id=$ID ssid=$SSID rssi=$RSSI"
        fi
    done < "$VISIBLE"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if is_our_pid "$OLD_PID"; then
        exit 0
    fi
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        exit 0
    fi
fi

echo $$ > "$LOCK_DIR/pid"
echo "$MODDIR/service.sh" > "$LOCK_DIR/cmd"
trap cleanup INT TERM EXIT

load_config
resolve_iface
log_msg "service started iface=$WIFI_IFACE_RESOLVED wpa_cli=$WPA_CLI"
reenable_all_module_disabled
DISCONNECTED_CYCLES=0

while true; do
    load_config

    if ! resolve_iface; then
        log_msg "wifi interface not ready, fallback=$WIFI_IFACE_RESOLVED"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    write_status

    if [ "$ENABLED" != "1" ]; then
        sleep "$SCAN_INTERVAL"
        continue
    fi

    SAVED_FILE="$TMP_DIR/saved"
    SCAN_FILE="$TMP_DIR/scan"
    VISIBLE_FILE="$TMP_DIR/visible"

    if ! build_saved_file "$SAVED_FILE"; then
        log_msg "skip cycle: no saved networks or list_networks failed"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    if ! build_scan_file "$SCAN_FILE"; then
        log_msg "skip cycle: no scan results or scan failed"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    if ! build_visible_saved_file "$SAVED_FILE" "$SCAN_FILE" "$VISIBLE_FILE"; then
        log_msg "skip cycle: no visible saved networks"
        sleep "$SCAN_INTERVAL"
        continue
    fi

    recover_networks "$VISIBLE_FILE"
    disable_weak_networks "$VISIBLE_FILE"

    if "$WPA_CLI" -i "$WIFI_IFACE_RESOLVED" status 2>/dev/null | grep -F 'wpa_state=COMPLETED' >/dev/null 2>&1; then
        DISCONNECTED_CYCLES=0
    else
        DISCONNECTED_CYCLES=$((DISCONNECTED_CYCLES + 1))
        if [ "$DISCONNECTED_CYCLES" -ge 3 ]; then
            log_msg "emergency re-enable: disconnected_cycles=$DISCONNECTED_CYCLES"
            reenable_all_module_disabled
            DISCONNECTED_CYCLES=0
        fi
    fi

    sleep "$SCAN_INTERVAL"
done
