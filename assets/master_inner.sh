#!/system/bin/sh
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "[Pivoted Root] Preparing pivot..."
cd /data/local/tmp/lineage_stage/rootfs
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
$BB mount -t proc proc /proc

export PATH=/system/bin:/system/xbin

echo "[Pivoted Root] Setting up /data_mirror and /data/data mounts for Zygote isolation..."
$BB mount --bind /data/user/0 /data/data 2>/dev/null || true
$BB mount -t tmpfs tmpfs /data_mirror 2>/dev/null || true
mkdir -p /data_mirror/data_de/null/0 /data_mirror/data_ce/null/0 /data_mirror/cur_profiles /data_mirror/ref_profiles
chmod -R 777 /data_mirror
$BB mount --bind /data/user_de/0 /data_mirror/data_de/null/0 2>/dev/null || true
$BB mount --bind /data/user/0 /data_mirror/data_ce/null/0 2>/dev/null || true
mkdir -p /data/misc/profiles/cur /data/misc/profiles/ref
$BB mount --bind /data/misc/profiles/cur /data_mirror/cur_profiles 2>/dev/null || true
$BB mount --bind /data/misc/profiles/ref /data_mirror/ref_profiles 2>/dev/null || true

echo "[Pivoted Root] Setting up /data/media and emulated storage..."
mkdir -p /data/media/0/Android /data/media/0/Pictures/Screenshots /data/media/0/Download /data/media/0/DCIM /data/media/0/Documents
chown -R 1023:1023 /data/media 2>/dev/null || true
chmod -R 777 /data/media 2>/dev/null || true
$BB mount -t tmpfs tmpfs /storage 2>/dev/null || true
mkdir -p /storage/emulated/0
$BB mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true
mkdir -p /mnt/user/0
$BB mount -t tmpfs tmpfs /mnt/user/0 2>/dev/null || true
mkdir -p /mnt/user/0/emulated
$BB mount --bind /data/media/0 /mnt/user/0/emulated 2>/dev/null || true

echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"

echo "[Pivoted Root] Starting LineageOS SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting LineageOS BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting LineageOS Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# Wifi. switch_to_lineage.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting LineageOS wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"

# Guest idmap2d (see switch_to_lineage.sh): writes idmaps for the guest's
# fabricated theme overlays into the guest's /data/resource-cache.
if [ -x /system/bin/idmap2d ]; then
    echo "[Pivoted Root] Starting guest idmap2d..."
    /system/bin/idmap2d > /data/idmap2d.log 2>&1 &
    echo "[Pivoted Root] idmap2d PID: $!"
fi
# Guest artd: system_server's ArtService dexopts through it. Without it every
# app runs unoptimized (slow, more CPU). Boot-time dexopt stays skipped
# (patch_smali), so this only serves per-app and background compilation.
# IMPORTANT: /data/misc/apexdata must stay system:system 0771. Creating any
# child dir here as root would leave the parent root-owned on first run and
# NetworkStatsServiceInitializer in system_server (uid 1000) then crashes
# system_server with:
#   IllegalStateException: Cannot write into stats data directory:
#     /data/misc/apexdata/com.android.tethering/netstats
# So fix up the parent before starting artd (master_prepare pre-creates the
# tethering/netstats dir on disk, we only need to repair ownership here).
if [ -x /apex/com.android.art/bin/artd ]; then
    echo "[Pivoted Root] Starting guest artd..."
    mkdir -p /data/misc/apexdata/com.android.art/dalvik-cache
    chown -R 1000:1000 /data/misc/apexdata 2>/dev/null || true
    chmod 0771 /data/misc/apexdata 2>/dev/null || true
    /apex/com.android.art/bin/artd > /data/artd.log 2>&1 &
    echo "[Pivoted Root] artd PID: $!"
fi
sleep 1

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
NAV_IDMAP="/data/resource-cache/system@product@overlay@NavigationBarModeGestural@NavigationBarModeGesturalOverlay.apk@idmap"
NAV_OV="/system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
mkdir -p /data/resource-cache
if [ ! -s "$NAV_IDMAP" ] && [ -f "$NAV_OV" ]; then
    echo "[Pivoted Root] Generating gesture-nav overlay idmap..."
    /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
        --overlay-apk-path "$NAV_OV" --idmap-path "$NAV_IDMAP" --ignore-overlayable \
        > /data/idmap.log 2>&1 \
        && chmod 644 "$NAV_IDMAP" && chown system:system "$NAV_IDMAP" \
        && echo "[Pivoted Root] idmap OK ($(wc -c < "$NAV_IDMAP") bytes)" \
        || echo "[Pivoted Root] idmap FAILED: $(head -n1 /data/idmap.log 2>/dev/null)"
fi

# Newly installed apps have no data directories (the guest has no installd), and
# zygote kills their first launch with "Failed to mount /data_mirror/...". This
# sweep creates them while Lineage runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

# Classpaths are derived at runtime from what is actually mounted in this
# container (system + APEX classpath fragments), exactly as init does with
# derive_classpath on a real boot - so any GSI / host-APEX mix gets matching
# BOOTCLASSPATH etc. zygote_exec is built with --inherit-env and passes this
# environment straight to app_process64.
echo "[Pivoted Root] Deriving classpaths..."
mkdir -p /data/system/environ
CPF=/data/system/environ/classpath
rm -f "$CPF"
/apex/com.android.sdkext/bin/derive_classpath "$CPF" > /data/derive_classpath.log 2>&1
if ! grep -q "BOOTCLASSPATH" "$CPF" 2>/dev/null; then
    echo "[Pivoted Root] derive_classpath failed ($(tail -n1 /data/derive_classpath.log)); using /data/zygote_classpath.env"
    sed 's/^\([A-Z_]*\)=/export \1 /' /data/zygote_classpath.env 2>/dev/null | grep '^export' > "$CPF"
fi
ZENV=""
while read -r kw name val; do
    [ "$kw" = "export" ] && [ -n "$name" ] && ZENV="$ZENV $name=$val" && eval "$name=\$val"
done < "$CPF"
echo "[Pivoted Root] BOOTCLASSPATH: $(echo "$BOOTCLASSPATH" | tr ':' '\n' | grep -c .) jars, SYSTEMSERVERCLASSPATH: $(echo "$SYSTEMSERVERCLASSPATH" | tr ':' '\n' | grep -c .) jars"
cp -f "$CPF" /data/zygote_classpath.used 2>/dev/null
cp_missing=0
for jar in $(echo "$BOOTCLASSPATH:$SYSTEMSERVERCLASSPATH:$STANDALONE_SYSTEMSERVER_JARS" | tr ':' ' '); do
    [ -f "$jar" ] || { echo "[Pivoted Root] MISSING classpath jar: $jar"; cp_missing=$((cp_missing + 1)); }
done
echo "[Pivoted Root] classpath check: $cp_missing missing"

# Diagnostic: md5sums of the binaries the zygote is about to load. If the pivot
# is clean these should match the GSI image; a host-side build id in a crash
# dump then points at this list for the culprit.
echo "[Pivoted Root] pivoted-env binaries (md5 of what app_process64 and zygote will load):"
for f in /system/bin/app_process64 /system/lib64/libandroid_runtime.so \
         /system/lib64/libart.so /apex/com.android.art/lib64/libart.so \
         /system/framework/framework.jar /system/framework/services.jar \
         /system/lib64/libbinder.so /system/lib64/libnativeloader.so; do
    if [ -f "$f" ]; then
        s=$(md5sum "$f" 2>/dev/null | cut -c1-12)
        sz=$(stat -c %s "$f" 2>/dev/null)
        echo "  $s  $sz  $f"
    else
        echo "  MISSING          $f"
    fi
done
# Also show the actual loader namespace config
echo "[Pivoted Root] /linkerconfig head (what the linker sees for the system namespace):"
if [ -f /linkerconfig/ld.config.txt ]; then
    grep -E "^(dir\.|namespace\.default\.search\.paths|namespace\.default\.permitted\.paths|namespace\.system\.search\.paths)" /linkerconfig/ld.config.txt | head -20
else
    ls /linkerconfig 2>&1 | head -5
fi

echo "[Pivoted Root] Launching Zygote & SystemServer via zygote_exec..."
exec env -i ANDROID_SOCKET_zygote=3 ANDROID_SOCKET_usap_pool_primary=4 \
    PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data ANDROID_STORAGE=/storage \
    ANDROID_ART_ROOT=/apex/com.android.art ANDROID_I18N_ROOT=/apex/com.android.i18n \
    ANDROID_TZDATA_ROOT=/apex/com.android.tzdata EXTERNAL_STORAGE=/sdcard \
    ASEC_MOUNTPOINT=/mnt/asec ANDROID_ASSETS=/system/app $ZENV \
    /data/zygote_exec

