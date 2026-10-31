#!/system/bin/sh
# Return to One UI / Safe State Restoration
BACKUP_DIR="/data/local/tmp/lineage_backups"

# Run in init's mount namespace. Started from the app inside the guest, su puts
# this script in the guest's namespace, where every umount below misses: the
# guest's /data/dalvik-cache stayed bridged over One UI's, its zygote aborted
# ("Error changing dalvik-cache ownership") and RescueParty rebooted the phone.
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    NSBB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
    exec "$NSBB" nsenter -t 1 -m -- /system/bin/sh "$0" "$@"
fi

echo "=== [1/5] Terminating Container Supervision & Zygote ==="
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Guest idmap2d/artd (started by master_inner.sh); the host's are lazy
# services that init restarts on demand.
kill -9 $(pidof idmap2d) $(pidof artd) 2>/dev/null || true
# Stop the adb watchdog started by switch_to_lineage.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
# Stop the suppressors started by switch_to_lineage.sh so One UI's own
# media.codec and rescue_boot_count handling is restored.
pkill -9 -f "media_codec_suppress" 2>/dev/null || true
pkill -9 -f "rescue_boot_suppress" 2>/dev/null || true
pkill -9 -f "system_server" 2>/dev/null || true
pkill -9 -f org.lineageos 2>/dev/null || true
pkill -9 -x zygote64 2>/dev/null || true
kill -9 $(pidof surfaceflinger) 2>/dev/null || true

# Kill every remaining guest daemon: anything whose executable lives on the
# guest's system image (same filesystem device as the staged rootfs). The one
# that matters most is the guest vold from master_inner.sh: it shares the binder
# servicemanager and took over the "vold" name from the host's vold. Left alive
# (or dead with the name gone), One UI's ActivityManager fails
# vold.commitChanges() at boot-complete and reboots the phone with
# "reboot,checkpoint_commit_failed" right after the boot animation.
GUEST_DEV=$(stat -c %d /data/local/tmp/lineage_stage/rootfs/system/bin/vold 2>/dev/null)
if [ -n "$GUEST_DEV" ]; then
    for p in /proc/[0-9]*; do
        [ "$(stat -L -c %d $p/exe 2>/dev/null)" = "$GUEST_DEV" ] || continue
        echo "killing guest process $(basename $p) ($(cat $p/comm 2>/dev/null))"
        kill -9 $(basename $p) 2>/dev/null || true
    done
fi
# The host vold is still running but its "vold" registration was taken over by
# the guest's. It must NOT be restarted (init reboots the phone with
# "reboot,vold-failed"); svcstub kept its binder when the guest started, so have
# it register that binder again. This must happen before One UI's system_server
# comes back, or its vold.commitChanges() fails and it reboots the phone.
touch /data/local/tmp/svcstub.restore
i=0
while [ "$i" -lt 20 ] && ! grep -q "^restored vold$" /data/local/tmp/svcstub.log 2>/dev/null; do
    sleep 0.5; i=$((i + 1))
done
grep -E "^(restored|restore failed)" /data/local/tmp/svcstub.log 2>/dev/null
# svcstub exits after restoring; its placeholder services (One UI's
# system_server publishes the real ones) go with it.
pkill -9 -f "onelineage.stub.ServiceStub" 2>/dev/null || true
rm -f /data/local/tmp/svcstub.restore

# Put the host's own /data trees back FIRST: master_prepare.sh bridges the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/5] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/5] Unmounting Container Overlays ==="
umount -l /data/local/tmp/lineage_stage/rootfs/* 2>/dev/null || true
umount -l /data/local/tmp/lineage_stage/rootfs/apex/* 2>/dev/null || true
umount -l /data/local/tmp/lineage_stage/product_overlay 2>/dev/null || true
# Match mount points only: the guest's /system/product overlayfs carries
# "lowerdir=/data/local/tmp/lineage_stage/rootfs/..." in its options.
i=0
while [ "$i" -lt 100 ] && awk '$2 ~ "^/data/local/tmp/lineage_stage/rootfs" { f = 1 } END { exit !f }' /proc/mounts; do
    umount -l /data/local/tmp/lineage_stage/rootfs 2>/dev/null || true
    sleep 0.1; i=$((i + 1))
done
BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
if [ -x "$BB" ]; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
fi

echo "=== [4/5] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true

# Restore One UI's dexopt settings (switch_to_lineage.sh turned background
# dexopt down for the guest). Empty values are restored as empty, which is what
# getprop reported for a property that was unset.
DEXOPT_SAVED=/data/local/tmp/lineage_stage/host_dexopt.props
if [ -f "$DEXOPT_SAVED" ]; then
    RP=$(which resetprop 2>/dev/null || echo /data/adb/ksu/bin/resetprop)
    while IFS='=' read -r k v; do
        [ -n "$k" ] || continue
        if [ -x "$RP" ]; then
            if [ -n "$v" ]; then "$RP" "$k" "$v"; else "$RP" -d "$k"; fi
        else
            setprop "$k" "$v"
        fi
    done < "$DEXOPT_SAVED"
    # Saved by an older version that didn't record it; One UI leaves it unset.
    if ! grep -q '^pm.dexopt.disable_bg_dexopt=' "$DEXOPT_SAVED"; then
        if [ -x "$RP" ]; then "$RP" -d pm.dexopt.disable_bg_dexopt; else setprop pm.dexopt.disable_bg_dexopt false; fi
    fi
    rm -f "$DEXOPT_SAVED"
fi

# ro.lineage.* were added for the guest (master_prepare.sh step 9e).
LRP=$(which resetprop 2>/dev/null || echo /data/adb/ksu/bin/resetprop)
for k in $(getprop | sed -n 's/^\[\(ro\.lineage[a-z]*\.[^]]*\)\].*/\1/p'); do
    "$LRP" -d "$k" 2>/dev/null
done

echo "=== [5/5] Starting One UI Display & Host Services ==="

# Reset battery statistics. The guest system_server writes its own BatteryStats
# while it runs, and those values survive into One UI where they manifest as
# "1% battery" / "charging" false-positive on the first One UI boot after a
# Lineage session. Dumping and clearing before One UI starts avoids that.
dumpsys batterystats --reset 2>/dev/null || true
rm -f /data/system/batterystats.bin 2>/dev/null || true

# Reset biometric enrollment state. The Lineage FingerprintService writes to
# /data/system/users/0/fpdata and /data/vendor_de/0/fpdata during a session. If
# the guest enrolls or queries fingerprints those writes can corrupt the Samsung
# TrustZone biometric DB, and the fingerprint sensor stops responding in One UI.
# Force the fingerprint HAL to re-sync from TrustZone on next One UI boot.
setprop ctl.stop vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.stop vendor.biometrics.fingerprint.inscreen 2>/dev/null || true
sleep 1
setprop ctl.start vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.start vendor.biometrics.fingerprint.inscreen 2>/dev/null || true

setprop ctl.start surfaceflinger
setprop ctl.start zygote
setprop ctl.start audioserver
setprop ctl.start cameraserver
# switch_to_lineage.sh stops the host media codec stack (its IMediaCodecList AIDL
# hash does not match the GSI's, which spins the guest's MediaCodecList); bring it
# back for One UI.
for svc in media media.extractor media.codec media.metrics wificond; do
    setprop ctl.start $svc 2>/dev/null || true
done
# Hand /dev/softdog back to One UI. Keep feeding it until the host system_server
# is back (it re-opens the softdog itself), then stop the feeder so the two do
# not race for the single-open device.
setprop vendor.hotboot.rom 0 2>/dev/null || true
if ps -ef 2>/dev/null | grep -v grep | grep -q "softdog_feeder.sh"; then
    nohup /system/bin/sh -c '
        i=0
        while [ "$i" -lt 90 ] && ! pidof system_server >/dev/null 2>&1; do
            sleep 1; i=$((i + 1))
        done
        sleep 10
        pkill -9 -f "softdog_[f]eeder.sh"
    ' </dev/null >/dev/null 2>&1 &
fi
am force-stop com.sec.android.app.launcher 2>/dev/null || true
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true

# switch_to_lineage.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "One UI restored successfully."
