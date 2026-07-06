#!/system/bin/sh
# Start service.sh from this module directory during boot.
MODDIR=${0%/*}
/system/bin/sh "$MODDIR/service.sh" &
