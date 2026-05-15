#!/bin/bash
# host_setup_pin.sh - main container's pinning loop for Fedora.

echo "STATUS: [pin] Module-holder starting."

# Idempotent insmod
if ! lsmod | grep -q '^xocl '; then
    echo "STATUS: [pin] insmod /lib/modules-xrt/xocl.ko"
    insmod /lib/modules-xrt/xocl.ko || {
        if lsmod | grep -q '^xocl '; then
            echo "STATUS: [pin] xocl loaded after insmod returned non-zero (race)"
        else
            echo "ERROR: [pin] insmod xocl.ko failed"
            exit 1
        fi
    }
fi
if ! lsmod | grep -q '^xclmgmt '; then
    echo "STATUS: [pin] insmod /lib/modules-xrt/xclmgmt.ko"
    insmod /lib/modules-xrt/xclmgmt.ko || echo "WARNING: [pin] insmod xclmgmt.ko returned non-zero"
fi

# Find the user-PF BDF
USER_BDF=$(ls /sys/bus/pci/drivers/xocl/ 2>/dev/null | grep -E '^[0-9a-f]{4}:' | head -1)
MGMT_BDF=$(ls /sys/bus/pci/drivers/xclmgmt/ 2>/dev/null | grep -E '^[0-9a-f]{4}:' | head -1)
echo "STATUS: [pin] user PF: $USER_BDF | mgmt PF: $MGMT_BDF"

# If the user-PF's VBNV is empty, the mailbox sync didn't complete during the
# initial probe (race between xclmgmt and xocl). Rebind xocl to force a fresh
# probe — by now xclmgmt is fully up so the handshake will succeed.
if [ -n "$USER_BDF" ]; then
    VBNV=$(cat /sys/bus/pci/devices/$USER_BDF/rom*/VBNV 2>/dev/null)
    if [ -z "$VBNV" ] || ! echo "$VBNV" | grep -q '_'; then
        echo "STATUS: [pin] VBNV empty/malformed (got '$VBNV'); rebinding xocl."
        echo "$USER_BDF" > /sys/bus/pci/drivers/xocl/unbind 2>/dev/null
        sleep 3
        echo "$USER_BDF" > /sys/bus/pci/drivers/xocl/bind 2>/dev/null
        sleep 5
        VBNV=$(cat /sys/bus/pci/devices/$USER_BDF/rom*/VBNV 2>/dev/null)
        echo "STATUS: [pin] post-rebind VBNV='$VBNV'"
    else
        echo "STATUS: [pin] VBNV already populated: '$VBNV'"
    fi
fi

# Wait for /dev nodes to settle (after rebind they may move)
MGMT="" USER=""
for i in {1..30}; do
    MGMT=$(ls /dev/xclmgmt* 2>/dev/null | head -1)
    USER=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
    if [[ -n "$MGMT" && -n "$USER" ]]; then break; fi
    echo "[pin] Waiting for /dev nodes (attempt $i): mgmt=$MGMT user=$USER"
    sleep 2
done

if [[ -z "$MGMT" ]]; then
    echo "ERROR: [pin] /dev/xclmgmt* never appeared."
    exit 1
fi
if [[ -z "$USER" ]]; then
    echo "WARNING: [pin] /dev/dri/renderD* not found."
fi

echo "STATUS: [pin] Pinning mgmt=$MGMT user=$USER"
exec 3<>"$MGMT" || { echo "ERROR: [pin] failed to open $MGMT"; exit 1; }
if [[ -n "$USER" ]]; then
    exec 4<>"$USER" || echo "WARNING: [pin] failed to open $USER"
fi

echo "STATUS: [pin] Pinned. Pod is now holding XRT modules loaded."
lsmod | grep -E '^xocl|^xclmgmt'

# Confirm VBNV is now usable
VBNV=$(cat /sys/bus/pci/devices/$USER_BDF/rom*/VBNV 2>/dev/null)
echo "STATUS: [pin] Final VBNV: '$VBNV'"

cleanup() {
    echo "STATUS: [pin] SIGTERM received. Releasing fds and rmmod."
    exec 3<&-
    exec 4<&- 2>/dev/null
    sleep 2
    if lsmod | grep -q '^xclmgmt '; then
        rmmod xclmgmt 2>/dev/null && echo "  xclmgmt unloaded" || echo "  xclmgmt rmmod failed"
    fi
    if lsmod | grep -q '^xocl '; then
        rmmod xocl 2>/dev/null && echo "  xocl unloaded" || echo "  xocl rmmod failed"
    fi
    exit 0
}
trap cleanup TERM INT

sleep infinity &
wait $!
