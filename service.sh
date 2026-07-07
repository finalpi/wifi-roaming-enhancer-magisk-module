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
WPA_CLI_TIMEOUT=5
CMD_WIFI_TIMEOUT=5

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

run_timeout() {
    SECONDS_LIMIT="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$SECONDS_LIMIT" "$@"
    else
        "$@"
    fi
}

wpa() {
    run_timeout "$WPA_CLI_TIMEOUT" "$WPA_CLI" "$@"
}

cmd_wifi() {
    run_timeout "$CMD_WIFI_TIMEOUT" cmd wifi "$@"
}

mkdir -p "$STATE_DIR" "$TMP_DIR"

default_config() {
    ENABLED=1
    CONTROL_MODE=auto
    WIFI_IFACE=auto
    SCAN_INTERVAL=10
    DISABLE_RSSI=-75
    RECOVERY_RSSI=-67
    MIN_AVAILABLE_NETWORKS=1
    MAX_DISABLE_PER_SCAN=3
    FALLBACK_WIFI_OFF_SECONDS=3
    FALLBACK_COOLDOWN_SECONDS=120
    FALLBACK_WEAK_COUNT=2
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
    FALLBACK_WIFI_OFF_SECONDS=$(clamp_int "$FALLBACK_WIFI_OFF_SECONDS" 1 120 3)
    FALLBACK_COOLDOWN_SECONDS=$(clamp_int "$FALLBACK_COOLDOWN_SECONDS" 30 3600 120)
    FALLBACK_WEAK_COUNT=$(clamp_int "$FALLBACK_WEAK_COUNT" 1 10 2)
    LOG_ENABLED=$(clamp_int "$LOG_ENABLED" 0 1 1)
    LOG_MAX_LINES=$(clamp_int "$LOG_MAX_LINES" 50 1000 200)

    case "$CONTROL_MODE" in
        auto|wpa_cli|wifi_restart) ;;
        *) CONTROL_MODE=auto ;;
    esac

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

cmd_wifi_status() {
    cmd_wifi status 2>/dev/null
}

cmd_wifi_rssi() {
    cmd_wifi_status | awk '
        index($0, "RSSI:") > 0 {
            line=$0
            sub(/^.*RSSI:[ ]*/, "", line)
            sub(/[^0-9-].*$/, "", line)
            print line
            exit
        }
        index($0, "SignalStrength:") > 0 {
            line=$0
            sub(/^.*SignalStrength:[ ]*/, "", line)
            sub(/[^0-9-].*$/, "", line)
            print line
            exit
        }
    '
}

write_status() {
    STATUS_MODE="$1"
    RSSI="$2"
    {
        echo "enabled=$ENABLED"
        echo "control_mode=$CONTROL_MODE"
        echo "effective_mode=$STATUS_MODE"
        echo "iface=$WIFI_IFACE_RESOLVED"
        echo "wpa_cli=$WPA_CLI"
        echo "disable_rssi=$DISABLE_RSSI"
        echo "recovery_rssi=$RECOVERY_RSSI"
        echo "scan_interval=$SCAN_INTERVAL"
        echo "fallback_wifi_off_seconds=$FALLBACK_WIFI_OFF_SECONDS"
        echo "fallback_cooldown_seconds=$FALLBACK_COOLDOWN_SECONDS"
        echo "fallback_weak_count=$FALLBACK_WEAK_COUNT"
        echo "fallback_weak_cycles=$FALLBACK_WEAK_CYCLES"
        echo "fallback_last_restart=$LAST_FALLBACK_RESTART"
        echo "cmd_wifi_rssi=$RSSI"
        echo "last_update=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        if [ "$STATUS_MODE" = "wifi_restart" ]; then
            if [ -f "$TMP_DIR/cmd_wifi_status" ]; then
                grep -E '^(Wifi is|WifiInfo:|NetworkCapabilities:|==== ClientModeManager|.*RSSI:|.*SignalStrength:)' "$TMP_DIR/cmd_wifi_status"
            else
                cmd_wifi_status | grep -E '^(Wifi is|WifiInfo:|NetworkCapabilities:|==== ClientModeManager|.*RSSI:|.*SignalStrength:)'
            fi
        else
            wpa -i "$WIFI_IFACE_RESOLVED" status 2>/dev/null | grep -E '^(wpa_state|ssid|bssid|ip_address)='
        fi
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
    [ -f "$DISABLED_FILE" ] || return

    if [ -z "$WIFI_IFACE_RESOLVED" ] || ! wpa -i "$WIFI_IFACE_RESOLVED" status >/dev/null 2>&1; then
        return
    fi

    while IFS='|' read -r ID SSID; do
        [ -z "$ID" ] && continue
        if wpa -i "$WIFI_IFACE_RESOLVED" enable_network "$ID" >/dev/null 2>&1; then
            log_msg "re-enabled network id=$ID ssid=$SSID reason=all"
        fi
    done < "$DISABLED_FILE"

    : > "$DISABLED_FILE"
}

cleanup() {
    if [ "$FALLBACK_WIFI_DISABLED" = "1" ]; then
        cmd_wifi set-wifi-enabled enabled >/dev/null 2>&1
    fi
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
        if wpa -i "$WIFI_IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$WIFI_IFACE"
            return 0
        fi
    fi

    for IFACE in wlan0 wlan1 wifi0; do
        if wpa -i "$IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$IFACE"
            return 0
        fi
    done

    for IFACE in $(ip link show 2>/dev/null | awk -F: '/^[0-9]+: / {gsub(/ /,"",$2); print $2}' | grep -E '^(wlan|wl|wifi)'); do
        if wpa -i "$IFACE" status >/dev/null 2>&1; then
            WIFI_IFACE_RESOLVED="$IFACE"
            return 0
        fi
    done

    WIFI_IFACE_RESOLVED="wlan0"
    log_msg "wpa_cli unavailable or timed out path=$WPA_CLI iface=$WIFI_IFACE_RESOLVED"
    return 1
}

build_saved_file() {
    OUT="$1"
    wpa -i "$WIFI_IFACE_RESOLVED" list_networks 2>/dev/null | awk -F '\t' '
        NR > 1 && $1 ~ /^[0-9]+$/ {
            print $1 "|" $2 "|" $4
        }
    ' > "$OUT"
    [ -s "$OUT" ]
}

build_scan_file() {
    OUT="$1"
    wpa -i "$WIFI_IFACE_RESOLVED" scan >/dev/null 2>&1
    sleep 2
    wpa -i "$WIFI_IFACE_RESOLVED" scan_results 2>/dev/null | awk -F '\t' '
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
            if wpa -i "$WIFI_IFACE_RESOLVED" enable_network "$ID" >/dev/null 2>&1; then
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

        if wpa -i "$WIFI_IFACE_RESOLVED" disable_network "$ID" >/dev/null 2>&1; then
            add_disabled_id "$ID" "$SSID"
            AVAILABLE=$((AVAILABLE - 1))
            DISABLED_THIS_SCAN=$((DISABLED_THIS_SCAN + 1))
            log_msg "disabled weak network id=$ID ssid=$SSID rssi=$RSSI threshold=$DISABLE_RSSI"
        else
            log_msg "failed to disable id=$ID ssid=$SSID rssi=$RSSI"
        fi
    done < "$VISIBLE"
}

run_wpa_cli_cycle() {
    write_status "wpa_cli" ""

    [ "$ENABLED" = "1" ] || return

    SAVED_FILE="$TMP_DIR/saved"
    SCAN_FILE="$TMP_DIR/scan"
    VISIBLE_FILE="$TMP_DIR/visible"

    if ! build_saved_file "$SAVED_FILE"; then
        log_msg "skip cycle: no saved networks or list_networks failed"
        return
    fi

    if ! build_scan_file "$SCAN_FILE"; then
        log_msg "skip cycle: no scan results or scan failed"
        return
    fi

    if ! build_visible_saved_file "$SAVED_FILE" "$SCAN_FILE" "$VISIBLE_FILE"; then
        log_msg "skip cycle: no visible saved networks"
        return
    fi

    recover_networks "$VISIBLE_FILE"
    disable_weak_networks "$VISIBLE_FILE"

    if wpa -i "$WIFI_IFACE_RESOLVED" status 2>/dev/null | grep -F 'wpa_state=COMPLETED' >/dev/null 2>&1; then
        DISCONNECTED_CYCLES=0
    else
        DISCONNECTED_CYCLES=$((DISCONNECTED_CYCLES + 1))
        if [ "$DISCONNECTED_CYCLES" -ge 3 ]; then
            log_msg "emergency re-enable: disconnected_cycles=$DISCONNECTED_CYCLES"
            reenable_all_module_disabled
            DISCONNECTED_CYCLES=0
        fi
    fi
}

fallback_restart_wifi() {
    NOW=$(date +%s 2>/dev/null)
    [ -z "$NOW" ] && NOW=0

    if [ "$LAST_FALLBACK_RESTART" -gt 0 ] && [ $((NOW - LAST_FALLBACK_RESTART)) -lt "$FALLBACK_COOLDOWN_SECONDS" ]; then
        log_msg "fallback skip restart reason=cooldown rssi=$CMD_WIFI_RSSI cooldown=$FALLBACK_COOLDOWN_SECONDS"
        return
    fi

    log_msg "fallback restarting wifi rssi=$CMD_WIFI_RSSI threshold=$DISABLE_RSSI off_seconds=$FALLBACK_WIFI_OFF_SECONDS"
    FALLBACK_WIFI_DISABLED=1
    if ! cmd_wifi set-wifi-enabled disabled >/dev/null 2>&1; then
        FALLBACK_WIFI_DISABLED=0
        log_msg "fallback failed to disable wifi"
        return
    fi
    sleep "$FALLBACK_WIFI_OFF_SECONDS"
    if cmd_wifi set-wifi-enabled enabled >/dev/null 2>&1; then
        log_msg "fallback re-enabled wifi"
    else
        log_msg "fallback failed to re-enable wifi"
    fi
    FALLBACK_WIFI_DISABLED=0
    LAST_FALLBACK_RESTART="$NOW"
    FALLBACK_WEAK_CYCLES=0
}

run_wifi_restart_cycle() {
    CMD_WIFI_RSSI=$(cmd_wifi_rssi)
    write_status "wifi_restart" "$CMD_WIFI_RSSI"

    [ "$ENABLED" = "1" ] || return

    if ! is_int "$CMD_WIFI_RSSI"; then
        FALLBACK_WEAK_CYCLES=0
        log_msg "fallback skip: cannot parse RSSI from cmd wifi status"
        return
    fi

    if [ "$CMD_WIFI_RSSI" -lt "$DISABLE_RSSI" ]; then
        FALLBACK_WEAK_CYCLES=$((FALLBACK_WEAK_CYCLES + 1))
        log_msg "fallback weak sample rssi=$CMD_WIFI_RSSI threshold=$DISABLE_RSSI count=$FALLBACK_WEAK_CYCLES/$FALLBACK_WEAK_COUNT"
        if [ "$FALLBACK_WEAK_CYCLES" -ge "$FALLBACK_WEAK_COUNT" ]; then
            fallback_restart_wifi
        fi
    else
        [ "$FALLBACK_WEAK_CYCLES" -ne 0 ] && log_msg "fallback signal recovered rssi=$CMD_WIFI_RSSI"
        FALLBACK_WEAK_CYCLES=0
    fi
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
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

load_config
WIFI_IFACE_RESOLVED="wlan0"
log_msg "service started iface=$WIFI_IFACE_RESOLVED wpa_cli=$WPA_CLI control_mode=$CONTROL_MODE"
reenable_all_module_disabled
DISCONNECTED_CYCLES=0
FALLBACK_WEAK_CYCLES=0
LAST_FALLBACK_RESTART=0
FALLBACK_WIFI_DISABLED=0
WPA_CLI_FAILED=0
CMD_WIFI_RSSI=""

while true; do
    load_config

    case "$CONTROL_MODE" in
        wifi_restart)
            run_wifi_restart_cycle
            ;;
        wpa_cli)
            if resolve_iface; then
                run_wpa_cli_cycle
            else
                write_status "wpa_cli" ""
                log_msg "wifi interface not ready for wpa_cli mode, iface=$WIFI_IFACE_RESOLVED"
            fi
            ;;
        auto|*)
            if [ "$WPA_CLI_FAILED" != "1" ] && resolve_iface; then
                run_wpa_cli_cycle
            else
                WPA_CLI_FAILED=1
                log_msg "auto mode falling back to wifi_restart because wpa_cli is unavailable"
                run_wifi_restart_cycle
            fi
            ;;
    esac

    sleep "$SCAN_INTERVAL"
done
