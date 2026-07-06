# WiFi Roaming Enhancer Ultimate

A Magisk / KernelSU module that avoids weak saved Wi-Fi networks. When a saved network is visible but its signal is below your configured RSSI threshold, the module temporarily disables that saved network profile with `wpa_cli disable_network`. When the signal recovers, it re-enables the same profile with `wpa_cli enable_network`.

The module does **not** remove saved networks and does **not** write permanent supplicant configuration.

## Features

- **Weak Wi-Fi avoidance:** temporarily disables saved networks whose best visible RSSI is below `DISABLE_RSSI`.
- **Automatic recovery:** re-enables module-disabled networks when RSSI reaches `RECOVERY_RSSI`.
- **Hysteresis:** separate disable and recovery thresholds reduce repeated connect/disconnect flapping.
- **Safety guardrails:** keeps at least one visible saved network enabled, rate-limits disables per scan, and re-enables module-disabled networks after repeated disconnected cycles.
- **KernelSU WebUI:** configure thresholds and view status/logs from KernelSU.
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
WIFI_IFACE=auto
SCAN_INTERVAL=10
DISABLE_RSSI=-75
RECOVERY_RSSI=-67
MIN_AVAILABLE_NETWORKS=1
MAX_DISABLE_PER_SCAN=3
LOG_ENABLED=1
LOG_MAX_LINES=200
```

### RSSI thresholds

RSSI is measured in dBm. Higher is better:

- `-60` is stronger than `-80`.
- `DISABLE_RSSI=-75` means visible saved networks weaker than `-75 dBm` may be temporarily disabled.
- `RECOVERY_RSSI=-67` means module-disabled networks are re-enabled once signal reaches `-67 dBm` or better.

Keep `RECOVERY_RSSI` higher than `DISABLE_RSSI` to avoid flapping.

## KernelSU WebUI

The WebUI is located in `webroot/` and provides:

- Module enable/disable switch.
- Wi-Fi interface selection (`auto` or explicit interface such as `wlan0`).
- RSSI thresholds and scan interval.
- Safety options.
- Current status, module-disabled networks, and recent logs.
- A **Re-enable all** button for networks temporarily disabled by this module.

## Safety notes

- The module only uses `disable_network` and `enable_network`.
- It does not call `remove_network`.
- It does not call `save_config`.
- It tracks only network IDs that it disabled in `state/disabled_by_module`.
- If the device remains disconnected for several scan cycles, it re-enables all module-disabled networks as emergency recovery.
- Duplicate SSIDs are handled conservatively by using the best RSSI seen for each SSID.

## Troubleshooting

Check the log:

```text
/data/adb/modules/wifi_roaming_enhancer/state/service.log
```

If Wi-Fi behaves unexpectedly:

1. Open KernelSU WebUI and tap **Re-enable all**.
2. Or set `ENABLED=0` in `config.conf` and reboot.
3. Or disable/remove the module from Magisk / KernelSU Manager and reboot.

Compatibility depends on whether your ROM exposes usable `wpa_cli` commands to root. Some Android builds may restrict or replace supplicant control behavior.
