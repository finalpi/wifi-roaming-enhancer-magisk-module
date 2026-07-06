# WiFi Roaming Enhancer Ultimate

A Magisk / KernelSU module that avoids weak Wi-Fi. It supports two control backends:

- `wpa_cli`: temporarily disables weak saved network profiles with `disable_network`, then re-enables them when signal recovers.
- `wifi_restart`: fallback mode that briefly turns Wi-Fi off/on with `cmd wifi set-wifi-enabled` when the current connection is weak, letting Android scan and auto-connect again.

The module does **not** remove saved networks and does **not** write permanent supplicant configuration.

## Features

- **Weak Wi-Fi avoidance:** uses `DISABLE_RSSI` as the weak-signal threshold.
- **Automatic backend selection:** `CONTROL_MODE=auto` prefers per-network `wpa_cli` control and falls back to Wi-Fi restart if `wpa_cli` is unavailable or times out.
- **Per-network mode:** temporarily disables saved networks whose best visible RSSI is below `DISABLE_RSSI`, then restores them at `RECOVERY_RSSI`.
- **Wi-Fi restart fallback:** briefly restarts Wi-Fi on weak current signal for ROMs that do not expose usable per-network commands.
- **Anti-flap controls:** configurable weak-sample count, restart cooldown, scan interval, and RSSI hysteresis.
- **KernelSU WebUI:** configure common settings and view status/logs from KernelSU.
- **Magisk fallback:** edit `config.conf` manually if WebUI is unavailable.

## Installation

1. Package this repository as a module zip.
2. Install it from Magisk Manager or KernelSU Manager.
3. Reboot.

The canonical module path is:

```text
/data/adb/modules/wifi_roaming_enhancer
```

## Configuration

KernelSU users can open the module WebUI and edit settings there.

Magisk users can edit:

```text
/data/adb/modules/wifi_roaming_enhancer/config.conf
```

Default config:

```sh
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
```

### Control modes

- `CONTROL_MODE=auto`: recommended default. The daemon tries `wpa_cli` first. If `wpa_cli` is missing, restricted, or times out, it uses `wifi_restart` fallback.

- `CONTROL_MODE=wpa_cli`: only use per-network temporary disable/re-enable. This is the most precise behavior, but it requires working `wpa_cli status`, `list_networks`, `scan_results`, `disable_network`, and `enable_network` support.

- `CONTROL_MODE=wifi_restart`: only use the fallback restart behavior. This does not disable a single saved network. It briefly turns all Wi-Fi off, waits `FALLBACK_WIFI_OFF_SECONDS`, then turns Wi-Fi on again so Android chooses a saved network.

### RSSI thresholds

RSSI is measured in dBm. Higher is better:

- `-60` is stronger than `-80`.
- `DISABLE_RSSI=-75` means signal below `-75 dBm` is considered weak.
- In `wpa_cli` mode, visible saved networks weaker than `DISABLE_RSSI` may be temporarily disabled.
- In `wifi_restart` mode, the current connection is restarted when its RSSI is below `DISABLE_RSSI` for enough consecutive samples.
- `RECOVERY_RSSI=-67` is used by `wpa_cli` mode to re-enable module-disabled networks once signal improves.

Keep `RECOVERY_RSSI` higher than `DISABLE_RSSI` to avoid flapping.

### Fallback tuning

These settings apply to `wifi_restart` mode and to `auto` when fallback is active:

- `FALLBACK_WIFI_OFF_SECONDS=3`: how long Wi-Fi stays off before being enabled again. Increase this if the ROM needs more time to fully tear down Wi-Fi.
- `FALLBACK_COOLDOWN_SECONDS=120`: minimum time between restart attempts. Increase this to reduce repeated restarts.
- `FALLBACK_WEAK_COUNT=2`: consecutive weak RSSI samples required before restart. Increase this to avoid reacting to short signal dips.

If Wi-Fi restarts too often, make `DISABLE_RSSI` more negative, increase `FALLBACK_COOLDOWN_SECONDS`, or increase `FALLBACK_WEAK_COUNT`.

## KernelSU WebUI

The WebUI is located in `webroot/` and provides:

- Module enable/disable switch.
- Control mode selection (`auto`, `wpa_cli`, or `wifi_restart`).
- RSSI threshold and scan interval.
- Advanced fallback settings for Wi-Fi-off wait time, cooldown, and weak-sample count.
- Advanced `wpa_cli` safety settings.
- Current status, module-disabled networks, and recent logs.
- A **Re-enable all** button for networks temporarily disabled by this module.

## Safety notes

- `wpa_cli` mode only uses `disable_network` and `enable_network`.
- It does not call `remove_network`.
- It does not call `save_config`.
- It tracks only network IDs that it disabled in `state/disabled_by_module`.
- If the device remains disconnected for several `wpa_cli` scan cycles, it re-enables all module-disabled networks as emergency recovery.
- `wifi_restart` mode interrupts all Wi-Fi briefly. Android usually reconnects automatically, but it may reconnect to the same weak network if no better saved network is available.
- Duplicate SSIDs are handled conservatively by using the best RSSI seen for each SSID.

## Troubleshooting

Check the log:

```text
/data/adb/modules/wifi_roaming_enhancer/state/service.log
```

Check the latest status:

```text
/data/adb/modules/wifi_roaming_enhancer/state/status
```

If Wi-Fi behaves unexpectedly:

1. Open KernelSU WebUI and tap **Re-enable all**.
2. Or set `ENABLED=0` in `config.conf` and reboot.
3. Or disable/remove the module from Magisk / KernelSU Manager and reboot.

Compatibility depends on the ROM. Some Android builds expose usable `wpa_cli` commands to root; others only allow coarse framework commands such as `cmd wifi status` and `cmd wifi set-wifi-enabled`.
