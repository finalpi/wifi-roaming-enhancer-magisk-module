#!/system/bin/sh

MODDIR=$(cd "${0%/*}/.." 2>/dev/null && pwd)
CONFIG="$MODDIR/config.conf"
STATE_DIR="$MODDIR/state"
DISABLED_FILE="$STATE_DIR/disabled_by_module"
STATUS_FILE="$STATE_DIR/status"
LOG_FILE="$STATE_DIR/service.log"
LOCK_DIR="$STATE_DIR/lock"
SERVICE="$MODDIR/service.sh"

mkdir -p "$STATE_DIR"

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g; s///g; s/$/\\n/' | tr -d '\n'
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

load_current() {
    ENABLED=1
    WIFI_IFACE=auto
    SCAN_INTERVAL=10
    DISABLE_RSSI=-75
    RECOVERY_RSSI=-67
    MIN_AVAILABLE_NETWORKS=1
    MAX_DISABLE_PER_SCAN=3
    LOG_ENABLED=1
    LOG_MAX_LINES=200
    [ -f "$CONFIG" ] && . "$CONFIG"
}

validate_values() {
    ENABLED=$(clamp_int "$ENABLED" 0 1 1)
    SCAN_INTERVAL=$(clamp_int "$SCAN_INTERVAL" 5 300 10)
    DISABLE_RSSI=$(clamp_int "$DISABLE_RSSI" -100 -30 -75)
    RECOVERY_RSSI=$(clamp_int "$RECOVERY_RSSI" -100 -30 -67)
    MIN_AVAILABLE_NETWORKS=$(clamp_int "$MIN_AVAILABLE_NETWORKS" 1 20 1)
    MAX_DISABLE_PER_SCAN=$(clamp_int "$MAX_DISABLE_PER_SCAN" 1 20 3)
    LOG_ENABLED=$(clamp_int "$LOG_ENABLED" 0 1 1)
    LOG_MAX_LINES=$(clamp_int "$LOG_MAX_LINES" 50 1000 200)

    case "$WIFI_IFACE" in
        ''|*[!A-Za-z0-9_.:-]*) WIFI_IFACE=auto ;;
    esac

    if [ "$RECOVERY_RSSI" -le "$DISABLE_RSSI" ]; then
        RECOVERY_RSSI=$((DISABLE_RSSI + 5))
        [ "$RECOVERY_RSSI" -gt -30 ] && RECOVERY_RSSI=-30
    fi
}

write_config() {
    TMP="$CONFIG.tmp"
    {
        echo "# WiFi Roaming Enhancer configuration"
        echo "ENABLED=$ENABLED"
        echo "WIFI_IFACE=$WIFI_IFACE"
        echo "SCAN_INTERVAL=$SCAN_INTERVAL"
        echo "DISABLE_RSSI=$DISABLE_RSSI"
        echo "RECOVERY_RSSI=$RECOVERY_RSSI"
        echo "MIN_AVAILABLE_NETWORKS=$MIN_AVAILABLE_NETWORKS"
        echo "MAX_DISABLE_PER_SCAN=$MAX_DISABLE_PER_SCAN"
        echo "LOG_ENABLED=$LOG_ENABLED"
        echo "LOG_MAX_LINES=$LOG_MAX_LINES"
    } > "$TMP" && mv "$TMP" "$CONFIG"
}

service_pid() {
    PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "$PID"
        return 0
    fi
    return 1
}

print_config_json() {
    load_current
    validate_values
    printf '{"enabled":%s,"wifi_iface":"%s","scan_interval":%s,"disable_rssi":%s,"recovery_rssi":%s,"min_available_networks":%s,"max_disable_per_scan":%s,"log_enabled":%s,"log_max_lines":%s}\n' \
        "$ENABLED" "$WIFI_IFACE" "$SCAN_INTERVAL" "$DISABLE_RSSI" "$RECOVERY_RSSI" "$MIN_AVAILABLE_NETWORKS" "$MAX_DISABLE_PER_SCAN" "$LOG_ENABLED" "$LOG_MAX_LINES"
}

print_status_json() {
    STATUS=""
    DISABLED=""
    LOGS=""
    PID=$(service_pid)
    RUNNING=0
    [ -n "$PID" ] && RUNNING=1

    if [ -f "$STATUS_FILE" ]; then
        STATUS=$(cat "$STATUS_FILE" | json_escape)
    else
        STATUS=$(printf 'service_running=%s\nservice_pid=%s\nmodule_dir=%s\nstatus_file=missing\n' "$RUNNING" "$PID" "$MODDIR" | json_escape)
    fi

    [ -f "$DISABLED_FILE" ] && DISABLED=$(cat "$DISABLED_FILE" | json_escape)
    [ -f "$LOG_FILE" ] && LOGS=$(tail -n 80 "$LOG_FILE" 2>/dev/null | json_escape)

    printf '{"running":%s,"pid":"%s","status":"%s","disabled":"%s","logs":"%s"}\n' "$RUNNING" "$PID" "$STATUS" "$DISABLED" "$LOGS"
}

resolve_iface() {
    load_current
    validate_values

    if [ "$WIFI_IFACE" != "auto" ] && wpa_cli -i "$WIFI_IFACE" status >/dev/null 2>&1; then
        echo "$WIFI_IFACE"
        return
    fi

    for IFACE in wlan0 wlan1 wifi0; do
        if wpa_cli -i "$IFACE" status >/dev/null 2>&1; then
            echo "$IFACE"
            return
        fi
    done

    echo wlan0
}

start_service() {
    PID=$(service_pid)
    if [ -n "$PID" ]; then
        printf '{"ok":true,"message":"Service is already running. PID: %s"}\n' "$PID"
        return
    fi

    rm -rf "$LOCK_DIR" 2>/dev/null
    chmod 755 "$SERVICE" 2>/dev/null
    /system/bin/sh "$SERVICE" >/dev/null 2>&1 &
    sleep 1

    PID=$(service_pid)
    if [ -n "$PID" ]; then
        printf '{"ok":true,"message":"Service started. PID: %s"}\n' "$PID"
    else
        echo '{"ok":false,"message":"Service did not start. Check module permissions and service.sh."}'
    fi
}

reenable_all() {
    IFACE=$(resolve_iface)
    [ -f "$DISABLED_FILE" ] || {
        echo '{"ok":true,"message":"No module-disabled networks."}'
        return
    }

    COUNT=0
    while IFS='|' read -r ID SSID; do
        [ -z "$ID" ] && continue
        if wpa_cli -i "$IFACE" enable_network "$ID" >/dev/null 2>&1; then
            COUNT=$((COUNT + 1))
        fi
    done < "$DISABLED_FILE"

    : > "$DISABLED_FILE"
    printf '{"ok":true,"message":"Re-enabled %s module-tracked network(s)."}\n' "$COUNT"
}

save_from_args() {
    load_current

    for ARG in "$@"; do
        KEY=${ARG%%=*}
        VALUE=${ARG#*=}
        case "$KEY" in
            ENABLED) ENABLED="$VALUE" ;;
            WIFI_IFACE) WIFI_IFACE="$VALUE" ;;
            SCAN_INTERVAL) SCAN_INTERVAL="$VALUE" ;;
            DISABLE_RSSI) DISABLE_RSSI="$VALUE" ;;
            RECOVERY_RSSI) RECOVERY_RSSI="$VALUE" ;;
            MIN_AVAILABLE_NETWORKS) MIN_AVAILABLE_NETWORKS="$VALUE" ;;
            MAX_DISABLE_PER_SCAN) MAX_DISABLE_PER_SCAN="$VALUE" ;;
            LOG_ENABLED) LOG_ENABLED="$VALUE" ;;
            LOG_MAX_LINES) LOG_MAX_LINES="$VALUE" ;;
        esac
    done

    validate_values
    write_config
    echo '{"ok":true,"message":"Config saved. The daemon reloads it on the next scan."}'
}

CMD="$1"
shift 2>/dev/null || true

case "$CMD" in
    get_config) print_config_json ;;
    get_status) print_status_json ;;
    save_config) save_from_args "$@" ;;
    start_service) start_service ;;
    reenable_all) reenable_all ;;
    *) echo '{"ok":false,"message":"Unknown command."}' ;;
esac
