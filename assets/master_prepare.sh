#!/system/bin/sh
STAGE="/data/local/tmp/lineage_stage"
ROOTFS="$STAGE/rootfs"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "=== 1. Ensuring Watchdog Feeder is Active ==="
if ! ps -ef | grep -v grep | grep -q "/dev/watchdog"; then
    echo "Starting watchdog feeder..."
    nohup $BB sh -c "while true; do echo -n 1 > /dev/watchdog 2>/dev/null; sleep 2; done" </dev/null >/dev/null 2>&1 &
fi

echo "=== 2. Creating Loop Device Nodes ==="
for i in $(seq 50 150); do
    minor=$((i * 8))
    rm -f /dev/block/loop$i /dev/loop$i 2>/dev/null || true
    mknod /dev/block/loop$i b 7 $minor
    mknod /dev/loop$i b 7 $minor
done

echo "=== 3. Mounting system.raw if needed ==="
if mount | grep -q "$ROOTFS "; then
    STALE=0
    # Any loop device whose backing file is NOT the current system.raw is a
    # leftover from an earlier GSI (install_gsi.bat replaced system.raw but
    # the previous mount kept the old inode open). Pivoting into that leaves
    # /system/lib64/libandroid_runtime.so pointing at the OLD GSI's lib while
    # the newly staged jars bind in from the current one - zygote then crashes
    # on a JNI signature mismatch.
    CURRENT_INO=$(stat -c %i "$STAGE/system.raw" 2>/dev/null)
    for l in $($BB losetup -a | grep -F "$ROOTFS" | cut -d: -f1); do
        BACKING=$($BB losetup "$l" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')
        [ -z "$BACKING" ] && BACKING=$($BB losetup -l "$l" 2>/dev/null | awk 'NR==2 {print $6}')
        BACK_INO=$(stat -c %i "$BACKING" 2>/dev/null)
        if [ -n "$CURRENT_INO" ] && [ -n "$BACK_INO" ] && [ "$CURRENT_INO" != "$BACK_INO" ]; then
            echo "Rootfs mount is stale (loop $l backs inode $BACK_INO, system.raw is now inode $CURRENT_INO). Unmounting..."
            STALE=1
            break
        fi
    done
    if [ ! -f "$ROOTFS/system/bin/sh" ] || [ ! -f "$ROOTFS/init.environ.rc" ]; then
        echo "Rootfs mount is invalid or stale. Unmounting..."
        STALE=1
    fi
    if [ "$STALE" = 1 ]; then
        while mount | grep -q "$ROOTFS"; do
            $BB umount -l "$ROOTFS" 2>/dev/null || true
            sleep 0.1
        done
        for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
            $BB losetup -d "$l" 2>/dev/null || true
        done
    else
        echo "Rootfs already mounted and healthy."
    fi
fi

mkdir -p "$ROOTFS"
if ! mount | grep -q "$ROOTFS "; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$STAGE/system.raw"
    echo "Using LOOP: $LOOP"
    $BB mount -t ext4 -o ro "$LOOP" "$ROOTFS"
fi

mkdir -p "$ROOTFS/postinstall" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" \
    "$ROOTFS/linkerconfig" "$ROOTFS/vendor" "$ROOTFS/odm" "$ROOTFS/vendor_dlkm" \
    "$ROOTFS/mnt" "$ROOTFS/storage" "$ROOTFS/apex" "$ROOTFS/data"

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
# Bind the host's whole /sys tree (like /dev below), not a fresh sysfs: Android 17
# system_server needs the submounts - cgroup v2 at /sys/fs/cgroup (zygote's
# createProcessGroup() for system_server fails with ENOENT without it), plus
# /sys/fs/bpf (netd maps) and /sys/fs/selinux. rprivate so unmounting the
# container copy on return never propagates to the host's /sys.
if mount | grep -q "$ROOTFS/sys " && [ ! -e "$ROOTFS/sys/fs/cgroup/cgroup.controllers" ]; then
    $BB umount -l "$ROOTFS/sys" 2>/dev/null || true   # stale plain sysfs from an older run
fi
if ! mount | grep -q "$ROOTFS/sys "; then
    $BB mount --rbind /sys "$ROOTFS/sys"
    $BB mount --make-rprivate "$ROOTFS/sys"
fi
[ -e "$ROOTFS/sys/fs/cgroup/cgroup.controllers" ] && echo "cgroup v2 visible in container" || echo "!!! WARNING: /sys/fs/cgroup not visible in container"

if [ ! -e /dev/binderfs/binder ]; then
    mount -t binder binder /dev/binderfs 2>/dev/null || true
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null || true
fi

$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

if ! mount | grep -q "$ROOTFS/dev "; then
    $BB mount --rbind /dev "$ROOTFS/dev"
    $BB mount --make-rprivate "$ROOTFS/dev"
fi

mount | grep -q "$ROOTFS/linkerconfig " || $BB mount --rbind /linkerconfig "$ROOTFS/linkerconfig"
mount | grep -q "$ROOTFS/vendor " || $BB mount --bind /vendor "$ROOTFS/vendor"
mount | grep -q "$ROOTFS/odm " || $BB mount --bind /odm "$ROOTFS/odm"
mount | grep -q "$ROOTFS/vendor_dlkm " || $BB mount --bind /vendor_dlkm "$ROOTFS/vendor_dlkm"
# apexd is a HOST daemon: it reports the Samsung apex set (/system/apex,
# /system_ext/apex, /vendor/apex) to the container system_server, which then
# tries to parse those exact paths inside this namespace. Keep the apex
# directories identical to what host apexd sees (an empty tmpfs or the GSI's
# own .capex layout makes PMS abort with "Unable to parse" at boot).
# Resolve a path *inside the rootfs*. GSIs make /system_ext and /product
# absolute symlinks (/system/system_ext, /system/product); followed from the
# host they point at the HOST's /system/..., so binds must use the resolved
# in-rootfs target or they silently land on the host instead.
in_rootfs() {
    _l=$(readlink "$ROOTFS$1" 2>/dev/null)
    case "$_l" in
        "") echo "$ROOTFS$1" ;;
        /*) echo "$ROOTFS$_l" ;;
        *)  echo "$ROOTFS$(dirname "$1")/$_l" ;;
    esac
}
SYSEXT_APEX="$(in_rootfs /system_ext)/apex"
if [ -d /system_ext/apex ] && [ -d "$SYSEXT_APEX" ]; then
    mount | grep -q " $SYSEXT_APEX " || $BB mount --bind /system_ext/apex "$SYSEXT_APEX"
    echo "Bound host /system_ext/apex -> $SYSEXT_APEX"
fi
# Android 17 Samsung builds also preinstall an APEX on /product
# (com.google.android.gmssystem). Bind it if the GSI has a product/apex dir;
# otherwise the apex-info-list filter (step 9b) drops the entry.
# Host apexd reports every active APEX to the container's PackageManager, which
# aborts boot if any reported path can't be opened - so the host's /product/apex
# must exist in the container even when the GSI has no product/apex dir (Google's
# GSI doesn't). In that case lay a tmpfs-backed overlay over the GSI's product
# partition (its files stay visible, the image is untouched) to create the dir.
PRODUCT_DIR="$(in_rootfs /product)"
PRODUCT_APEX="$PRODUCT_DIR/apex"
if [ -d /product/apex ] && [ ! -d "$PRODUCT_APEX" ] && [ -d "$PRODUCT_DIR" ]; then
    OV="$STAGE/product_overlay"
    mkdir -p "$OV"
    mount | grep -q " $OV " || $BB mount -t tmpfs tmpfs "$OV"
    mkdir -p "$OV/upper/apex" "$OV/work"
    if mount -t overlay overlay -o "lowerdir=$PRODUCT_DIR,upperdir=$OV/upper,workdir=$OV/work" "$PRODUCT_DIR" 2>/dev/null; then
        echo "Overlaid $PRODUCT_DIR to add an apex/ mountpoint"
    else
        echo "!!! WARNING: could not overlay $PRODUCT_DIR - host /product/apex APEXes will be missing"
    fi
fi
if [ -d /product/apex ] && [ -d "$PRODUCT_APEX" ]; then
    mount | grep -q " $PRODUCT_APEX " || $BB mount --bind /product/apex "$PRODUCT_APEX"
    echo "Bound host /product/apex -> $PRODUCT_APEX"
fi
mount | grep -q "$ROOTFS/mnt " || $BB mount --rbind /mnt "$ROOTFS/mnt"
if [ -f "$STAGE/services_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/services_patched.jar" "$ROOTFS/system/framework/services.jar"
    echo "Bound services_patched.jar -> $ROOTFS/system/framework/services.jar"
    echo "  services_patched.jar md5 $(md5sum "$STAGE/services_patched.jar" | cut -c1-12)"
fi
if [ -f "$STAGE/framework_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework_patched.jar" "$ROOTFS/system/framework/framework.jar"
    echo "Bound framework_patched.jar -> $ROOTFS/system/framework/framework.jar"
    echo "  framework_patched.jar md5 $(md5sum "$STAGE/framework_patched.jar" | cut -c1-12)"
fi
if [ -f "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so"
    echo "Bound libaudio_aidl_conversion_common_cpp_patched.so"
fi
if [ -f "$STAGE/libaudioclient_aidl_conversion_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudioclient_aidl_conversion_patched.so" "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so"
    echo "Bound libaudioclient_aidl_conversion_patched.so"
fi
if [ -f "$STAGE/framework-res_patched.apk" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework-res.apk" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework-res_patched.apk" "$ROOTFS/system/framework/framework-res.apk"
    echo "Bound framework-res_patched.apk -> $ROOTFS/system/framework/framework-res.apk"
fi

if [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk"
    PERM_APK=$(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null | head -n 1)
    if [ -n "$PERM_APK" ]; then
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK"
        echo "Bound PermissionController_patched.apk -> $PERM_APK"
    fi
fi



echo "=== 5. Setting up Isolated Data & Bridges ==="
mkdir -p "$STAGE/data/adb" "$STAGE/data/apex" "$STAGE/data/dalvik-cache/arm64"

# Give the guest the host's authorised ADB keys. The container has no
# AdbDebuggingManager (the guest system_server registers no "adb" service), so a
# guest adbd or wireless-debugging session cannot answer an authorisation prompt;
# pre-seeding the keys is the only way it can accept this machine silently.
# Pre-seed adb_enabled=1 into the guest's settings before its system_server runs.
# The in-boot fix (in fix_app_dirs.sh) only lands once the framework is up, but
# UsbDeviceManager drops the adb USB function within seconds of system_server
# starting -- which is why adb dies right after Lineage boots and macOS stops
# seeing the phone entirely. Writing the XML now keeps the gadget stable through
# the whole boot.
GSET="$STAGE/data/system/users/0/settings_global.xml"
if [ -f "$GSET" ]; then
    if grep -q 'id="adb_enabled"' "$GSET" 2>/dev/null; then
        sed -i 's/id="adb_enabled"\([^>]*\)value="[^"]*"/id="adb_enabled"\1value="1"/' "$GSET" 2>/dev/null
    else
        sed -i 's#</settings>#    <setting id="adb_enabled" name="adb_enabled" value="1" package="android" />\n</settings>#' "$GSET" 2>/dev/null
    fi
    echo "Pre-seeded adb_enabled=1 in guest settings_global.xml"
fi

if [ -f /data/misc/adb/adb_keys ]; then
    mkdir -p "$STAGE/data/misc/adb"
    cp -f /data/misc/adb/adb_keys "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        chmod 640 "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        echo "Copied host adb_keys into the guest /data"
fi
if [ -f "$STAGE/zygote_exec" ]; then
    cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
    chmod 755 "$STAGE/data/zygote_exec"
fi
mkdir -p "$STAGE/data/user/0" "$STAGE/data/user_de/0"
mkdir -p "$STAGE/data/system/users/0" "$STAGE/data/system_de/0/spblob" "$STAGE/data/system_ce/0"
mkdir -p "$STAGE/data/misc/user/0" "$STAGE/data/misc_de/0" "$STAGE/data/misc_ce/0"
mkdir -p "$STAGE/data/anr" "$STAGE/data/app" "$STAGE/data/rollback" "$STAGE/data/incremental"

for pkg in com.android.providers.settings \
           com.android.providers.telephony \
           com.android.phone \
           com.android.systemui \
           com.android.settings \
           com.android.launcher3 \
           com.android.inputmethod.latin \
           com.android.providers.media \
           com.android.providers.downloads \
           com.android.providers.contacts \
           com.android.providers.calendar \
           org.lineageos.lineagesettings \
           com.wewaffles.onelineage; do
    mkdir -p "$STAGE/data/user_de/0/$pkg/databases" \
             "$STAGE/data/user_de/0/$pkg/shared_prefs" \
             "$STAGE/data/user_de/0/$pkg/files/datastore/education" \
             "$STAGE/data/user/0/$pkg/databases" \
             "$STAGE/data/user/0/$pkg/shared_prefs" \
             "$STAGE/data/user/0/$pkg/files"
done

mkdir -p "$STAGE/data/resource-cache"
chmod 771 "$STAGE/data/resource-cache"
chown 1000:1000 "$STAGE/data/resource-cache"

rm -rf "$STAGE/data/data" 2>/dev/null || true
mkdir -p "$STAGE/data/data"

chmod -R 777 "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/anr" "$STAGE/data/data" 2>/dev/null || true
chown -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
chown -R 10109:10109 "$STAGE/data/user_de/0/com.android.inputmethod.latin" "$STAGE/data/user/0/com.android.inputmethod.latin" 2>/dev/null || true

# Create the bluetooth stack's storage before the guest ever starts. The GSI's
# GD stack asserts out of storage_module.cc if it cannot persist bt_config.conf,
# and the staged tree never had this directory, so com.android.bluetooth
# crash-looped every 4 s from early boot. uid 1002 = bluetooth.
mkdir -p "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null
chown 1002:1002 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true
chmod 0770 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true

# APEX data dirs. On a real boot apexd creates these when it activates each
# module (/data/misc/apexdata/<module>/...). The container loop-mounts the
# GSI's APEXes directly, so apexd never touches them. system_server then dies
# in NetworkStatsServiceInitializer with "Cannot write into stats data
# directory: /data/misc/apexdata/com.android.tethering/netstats", because the
# tethering APEX is 'com.android.tethering' in the GSI (host apexd creates
# only 'com.google.android.tethering'). Pre-create the dirs with the system
# ownership and permissions apexd would have applied.
mkdir -p "$STAGE/data/misc/apexdata/com.android.tethering/netstats" \
         "$STAGE/data/misc/apexdata/com.android.art/dalvik-cache" \
         "$STAGE/data/misc/apexdata/com.android.permission" \
         "$STAGE/data/misc/apexdata/com.android.wifi" \
         "$STAGE/data/misc/apexdata/com.android.appsearch" 2>/dev/null
chown -R 1000:1000 "$STAGE/data/misc/apexdata" 2>/dev/null || true
chmod 0771 "$STAGE/data/misc/apexdata" 2>/dev/null || true

# SELinux labels matter just as much as modes here. Every directory below lives
# under /data/local/tmp, so it is created as u:object_r:shell_data_file:s0. The
# guest's system_server runs in u:r:system_server:s0 (Samsung policy) and is
# denied both read and write on shell_data_file: chmod 777 does not help, because
# the denial is MAC, not DAC. That broke UserManagerService (users/0.xml EACCES),
# EntropyMixer/BatteryStats/PackageWatchdog ("Failed to create directory for
# *.new") and finally the settings provider:
#   SQLiteCantOpenDatabaseException: /data/user_de/0/com.android.providers.settings/databases/settings.db
# Relabel the staged tree the way a real /data is labeled. The host bind mounts
# that live inside this tree (/data/apex, /data/adb, /data/media) are deliberately
# excluded so host data never gets relabeled.
echo "=== 5b. Relabeling staged /data for guest SELinux ==="
$BB chcon u:object_r:system_data_file:s0 "$STAGE/data" 2>/dev/null || true
for d in data/system data/system_de data/system_ce data/user data/user_de \
         data/misc data/misc_de data/misc_ce data/anr data/dalvik-cache \
         data/local data/resource-cache data/app data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
for d in "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    if [ -d "$d" ]; then
        $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
        $BB chcon -R u:object_r:app_data_file:s0 "$d"/* 2>/dev/null || true
    fi
done
# data/apex (host /data/apex) and data/adb (host /data/adb) are left alone: they
# are the host's own directories bind-mounted in, already labeled correctly, and
# chcon-ing a bind mount would relabel the host's copy.

echo "=== 5c. Fixing staged /data ownership and modes ==="
# The stage tree is created by root under /data/local/tmp, so its top-level
# directories come out root:root 0755. A real /data is system:system 0771, and
# system_server (uid 1000) has to be able to create /data/app/vmdl*.tmp:
#   Failed to prepare session dir: /data/app/vmdl10992519.tmp
# With 0755 root:root that mkdir gets EACCES and *every* install fails, which is
# what "non-system apps / downloads crash" looked like from the outside.
$BB chown system:system "$STAGE/data" 2>/dev/null || true
$BB chmod 0771 "$STAGE/data" 2>/dev/null || true
for d in app app-staging anr dalvik-cache incremental property resource-cache rollback ss system; do
    [ -e "$STAGE/data/$d" ] || mkdir -p "$STAGE/data/$d" 2>/dev/null || continue
    $BB chown system:system "$STAGE/data/$d" 2>/dev/null || true
    $BB chmod 0771 "$STAGE/data/$d" 2>/dev/null || true
done
mkdir -p "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0" 2>/dev/null || true
$BB chown system:system "$STAGE/data/misc" "$STAGE/data/misc/profiles" 2>/dev/null || true
for d in "$STAGE/data/misc/profiles/cur" "$STAGE/data/misc/profiles/ref" \
         "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0"; do
    [ -d "$d" ] && $BB chown system:system "$d" 2>/dev/null || true
done

echo "=== 5d. Bridging host /data app trees into the staged /data ==="
# installd and artd are HOST daemons (started by Samsung init, they cannot be
# moved into the container namespace). Left alone they create every app data
# dir, dalvik-cache entry and dexopt profile in the real /data, which the guest
# can never see - so every app process the guest zygote forks dies with:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>:
#   No such file or directory
# ("Failed to attach" / "start timeout" in ActivityManager.) Bind the staged
# equivalents over those host paths for the duration of the session, so those
# daemons write into the guest's data. One UI is not running meanwhile and
# return_to_oneui.sh removes the binds again.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    mkdir -p "$STAGE/data/$d" 2>/dev/null || true
    if [ -d "/data/$d" ] && ! mount | grep -q " /data/$d "; then
        $BB mount --bind "$STAGE/data/$d" "/data/$d" 2>/dev/null && echo "Bridged /data/$d -> $STAGE/data/$d"
    fi
done

mount | grep -q "$ROOTFS/data " || $BB mount --bind "$STAGE/data" "$ROOTFS/data"
mount | grep -q "$ROOTFS/data/adb " || $BB mount --bind /data/adb "$ROOTFS/data/adb"
mount | grep -q "$ROOTFS/data/apex " || $BB mount --bind /data/apex "$ROOTFS/data/apex"
mkdir -p "$ROOTFS/data/media"
mount | grep -q "$ROOTFS/data/media " || $BB mount --bind /data/media "$ROOTFS/data/media" 2>/dev/null || true

echo "=== 5e. Writing per-package data-dir helper ==="
# Apps installed before the /data bridge existed have no CE/DE data dirs in the
# guest tree, and the guest zygote refuses to fork them:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>
# This helper recreates the dirs for every package the guest knows about, with
# the uid PMS reports. switch_to_lineage.sh runs it once the container is up.
mkdir -p "$STAGE/data/local/tmp" 2>/dev/null || true
cat > "$STAGE/data/local/tmp/fix_app_dirs.sh" <<'FIXAPPDIRS'
#!/system/bin/sh
# Create missing CE/DE data dirs (and dexopt profile dirs) for every installed
# package, using the uid PMS reports. Idempotent.
created=0
profile_dirs=0
pkg=""
for tok in $(pm list packages -U 2>/dev/null); do
    case "$tok" in
        package:*) pkg="${tok#package:}"; uid="" ;;
        uid:*)     uid="${tok#uid:}" ;;
        *)         continue ;;
    esac
    [ -n "$pkg" ] && [ -n "$uid" ] || continue
    for d in "/data/user/0/$pkg" "/data/user_de/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0700 "$d" 2>/dev/null
            created=$((created + 1))
        fi
    done
    for d in "/data/misc/profiles/cur/0/$pkg" "/data/misc/profiles/ref/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0771 "$d" 2>/dev/null
            profile_dirs=$((profile_dirs + 1))
        fi
    done
    pkg=""; uid=""
done
echo "[fix_app_dirs] created $created data dirs, $profile_dirs profile dirs"

# Realign ownership of pre-existing data dirs with the uid PMS assigned.
# The staged /data tree was restored from a backup, so some app dirs are still
# owned by system:system with 0777 perms. ART then refuses to load any dex from
# them ("Writable dex file ... is not allowed"), and GMS/SQLite cannot chmod its
# own files ("FileUtils.setPermissions" warnings) and the app dies. Only dirs
# whose top-level owner is wrong are touched, so later boots stay cheap.
realigned=0
if [ -f /data/system/packages.list ]; then
    while read -r pkg auid rest; do
        case "$auid" in ''|*[!0-9]*) continue ;; esac
        for base in /data/user/0 /data/user_de/0; do
            d="$base/$pkg"
            [ -d "$d" ] || continue
            cur=$(stat -c %u "$d" 2>/dev/null)
            [ "$cur" = "$auid" ] && continue
            chown -R "$auid:$auid" "$d" 2>/dev/null
            chmod -R go-w "$d" 2>/dev/null
            realigned=$((realigned + 1))
        done
    done < /data/system/packages.list
fi
echo "[fix_app_dirs] realigned $realigned data dirs to their app uid"

# Gesture navigation. The UI activator writes navigation_mode too, but it can
# run before the settings provider is ready, which leaves the value at 0 and
# the navbar back to 3-button. Do it again here, after boot completed.
cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null
settings put secure navigation_mode 2 2>/dev/null

# Keep Messaging as the default SMS app. Without a holder of
# android.app.role.SMS the framework's InboundSmsHandler drops every incoming
# text before it reaches the provider, so a delivered code would vanish.
if [ "$(settings get secure sms_default_application)" != "com.android.messaging" ]; then
    cmd role add-role-holder --user 0 android.app.role.SMS com.android.messaging 2>/dev/null
    settings put secure sms_default_application com.android.messaging 2>/dev/null
    echo "[fix_app_dirs] restored default SMS app"
fi

# Bluetooth's GD stack asserts out of `storage_module.cc SaveImmediately` when
# it cannot persist its own config, and com.android.bluetooth then restarts
# every ~4 seconds for the rest of the session (1880 tombstones in one boot).
# The staged tree had no /data/misc/bluedroid at all; create it with the
# bluetooth uid (1002) so the stack can save bt_config.conf.
if [ ! -d /data/misc/bluedroid ]; then
    mkdir -p /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chown 1002:1002 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chmod 0770 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    echo "[fix_app_dirs] created /data/misc/bluedroid for the bluetooth stack"
fi

# Code files must not be writable by the app that loads them. ART rejects any
# dex/apk/jar the calling uid could modify ("Writable dex file ... is not
# allowed"), which crash-looped GMS: its Dynamite modules in
# /data/user_de/0/.../app_chimera were installed 0755. The ownership pass above
# only touches dirs whose *top-level* owner is wrong, so GMS was skipped even
# though its files were wrong. Do this on both storages, cheaply.
code_files=0
for root in /data/user/0 /data/user_de/0; do
    [ -d "$root" ] || continue
    for f in $(find "$root" -type f \( -name '*.apk' -o -name '*.jar' -o -name '*.dex' \) -perm -0200 2>/dev/null); do
        chmod a-w "$f" 2>/dev/null && code_files=$((code_files + 1))
    done
done
echo "[fix_app_dirs] made $code_files code files read-only"

# The guest's Settings.Global.ADB_ENABLED defaults to null (treated as 0), and
# the guest's UsbDeviceManager drops the adb function from the USB gadget as
# soon as it starts. That is what kills the host adbd we rely on: adb dies
# seconds after Lineage boots and macOS stops seeing the phone at all. Turn it
# on so the gadget keeps adb, and read back what actually happened.
adb_before=$(getprop sys.usb.state)
settings put global adb_enabled 1 2>/dev/null
sleep 2
echo "[fix_app_dirs] adb_enabled=1 (usb.state was '$adb_before', now '$(getprop sys.usb.state)')"

# Record system services that failed to start (e.g. AdbService: "Failure
# starting ..."), so a problem behind a later crash can be traced without
# guessing from a fresh boot.
# SystemServer reports a service that threw during startup as
# "BOOT FAILURE starting X" (reportWtf) or "Failure starting X": catch both,
# plus anything mentioning AdbService, since that is the one we care about.
{
    logcat -d -b system 2>/dev/null | grep -a -E "BOOT FAILURE|Failure starting" | head -40
    echo "--- AdbService mentions ---"
    logcat -d -b system 2>/dev/null | grep -a -i "AdbService" | tail -10
} > /data/boot_failures.log 2>/dev/null || true
FIXAPPDIRS
chmod 755 "$STAGE/data/local/tmp/fix_app_dirs.sh" 2>/dev/null || true

# The guest has no installd, so nothing creates an app's data directories when
# it is installed. PMS records the package, then zygote aborts the first launch
# with "Failed to mount /data_mirror/data_de/null/0/<pkg> to
# /data/user_de/0/<pkg>: No such file or directory". Every app installed from
# inside Lineage -- Play Store, Aurora, adb -- used to crash on launch this way.
# Create the scaffolding installd would; /data_mirror is a bind of these trees.
cat > "$STAGE/data/local/tmp/ensure_app_storage.sh" <<'ENSUREAPP'
#!/system/bin/sh
created=0
[ -f /data/system/packages.list ] || exit 0
realigned=0
while read -r pkg auid rest; do
    case "$auid" in ''|*[!0-9]*) continue ;; esac
    for d in "/data/user/0/$pkg:0771" "/data/user_de/0/$pkg:0700"; do
        p=${d%:*}; mode=${d##*:}
        if [ -d "$p" ]; then
            # Reinstalling a package can assign a NEW uid while the old data
            # dirs survive (uninstall has no installd to delete them), and the
            # app then fails with "SQLiteCantOpenDatabaseException: unable to
            # open database file" because it cannot write its own directory.
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:$auid" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:$auid" "$p" 2>/dev/null
        chmod "$mode" "$p" 2>/dev/null
        created=$((created + 1))
    done
    # External storage: owner is the app, group is ext_data_rw (1078).
    for kind in data media obb; do
        p="/data/media/0/Android/$kind/$pkg"
        if [ -d "$p" ]; then
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:1078" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:1078" "$p" 2>/dev/null
        chmod 0770 "$p" 2>/dev/null
        created=$((created + 1))
    done
done < /data/system/packages.list

# Shared storage skeleton. Without it MediaProvider cannot create
# /storage/emulated/0/Pictures/Screenshots and taking a screenshot crashes
# SystemUI ("Failed to create directory: .../.pending-NNN"), and every save
# dialog has nowhere to put its file.
for d in Pictures Pictures/Screenshots DCIM DCIM/Camera Movies Music Documents \
         Alarms Notifications Podcasts Ringtones Download; do
    p="/data/media/0/$d"
    [ -d "$p" ] && continue
    mkdir -p "$p" 2>/dev/null || continue
    chown 1023:1023 "$p" 2>/dev/null
    chmod 0775 "$p" 2>/dev/null
    created=$((created + 1))
done

if [ "$created" -gt 0 ] || [ "$realigned" -gt 0 ]; then
    echo "[ensure_app_storage] created $created dirs, realigned $realigned to new uids"
fi
exit 0
ENSUREAPP
chmod 755 "$STAGE/data/local/tmp/ensure_app_storage.sh" 2>/dev/null || true

# A new install only becomes launchable once the dirs above exist, so sweep
# while Lineage is running instead of at boot only. Started by master_inner.
cat > "$STAGE/data/local/tmp/net_fix.sh" <<'NETFIX'
#!/system/bin/sh
# The guest's ConnectivityService cannot install its routes into the host's
# netd: every addRoute fails with "No such file or directory", so the final
# catch-all ip rule keeps pointing at a table from a previous network and all
# traffic ends in the "unreachable" rule. Symptom: the modem reports
# MOBILE[LTE] CONNECTED / VALIDATED, yet every app (Aurora, Play Store) says
# "check your internet connection" and even ping to the gateway fails.
# Keep a private table (4242) in sync with the live interface - wifi first,
# else mobile/CLAT - and point a catch-all rule at it. Idempotent.
have_v4() { ip -4 addr show "$1" 2>/dev/null | grep -q "inet "; }
iface=""
if have_v4 wlan0; then
    iface=wlan0
else
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^rmnet_data'); do
        if have_v4 "$d"; then iface=$d; break; fi
    done
fi
[ -z "$iface" ] && exit 0
subnet=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$2=="dev" && $3==d && $0 ~ /scope link/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
[ -z "$subnet" ] && exit 0
gw=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d && $3 ~ /^[0-9]+\./ {print $3; exit}')
# no IPv4 default anywhere (netd never installed one): assume the first host
[ -z "$gw" ] && gw="${subnet%.*}.1"
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
ip route replace default via "$gw" dev "$iface" table 4242 2>/dev/null
# Priority must beat the per-uid rules netd already installed for previous
# networks (15040/29040/29998): app sockets carry an fwmark, so a catch-all
# placed after those still sends them into a dead table even though root's
# unmarked pings work.
cur=$(ip rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
if [ "$cur" != "4242" ]; then
    ip rule del priority 14999 2>/dev/null
    ip rule add from all lookup 4242 priority 14999 2>/dev/null
    ip rule del priority 31999 2>/dev/null
    echo "net route repaired: $iface $subnet gw $gw"
fi
exit 0
NETFIX
chmod 755 "$STAGE/data/local/tmp/net_fix.sh" 2>/dev/null || true

cat > "$STAGE/data/local/tmp/app_storage_loop.sh" <<'APPLOOP'
#!/system/bin/sh
# Pre-creates per-package data dirs so zygote fork-and-specialize can bind
# /data_mirror/data_de/null/0/<pkg> -> /data/user_de/0/<pkg> without the
# source-ENOENT -> JNI FatalError -> zygote death sequence we hit on
# every app whose dir doesn't exist yet. Runs tight during boot (direct-
# boot-aware system apps like MediaProvider, DownloadProvider must have
# their dirs the moment PMS registers them, which is well before
# sys.boot_completed) and backs off once boot completes.
last=""
booted=0
while true; do
    if [ "$booted" = 0 ]; then
        sleep 1
        case "$(getprop sys.boot_completed)" in 1) booted=1 ;; esac
    else
        sleep 10
        netout=$(/system/bin/sh /data/local/tmp/net_fix.sh 2>/dev/null)
        [ -n "$netout" ] && echo "$(date) $netout" >> /data/app_storage.log
    fi
    cur=$(md5sum /data/system/packages.list 2>/dev/null | cut -d' ' -f1)
    out=$(/system/bin/sh /data/local/tmp/ensure_app_storage.sh 2>/dev/null)
    if [ "$booted" = 1 ] && [ -n "$last" ] && { [ "$cur" != "$last" ] || [ -n "$out" ]; }; then
        # A package appeared or went away. LauncherApps caches the app list, so
        # something installed from Aurora or Play Store is missing from both the
        # drawer and app search until the launcher re-queries. Restarting the
        # launcher forces that and does not touch whatever app is in front.
        am force-stop com.android.launcher3 2>/dev/null
        echo "$(date) package list changed -> launcher refreshed ${out:+($out)}" >> /data/app_storage.log
    elif [ -n "$out" ]; then
        echo "$(date) $out" >> /data/app_storage.log
    fi
    last=$cur
done
APPLOOP
chmod 755 "$STAGE/data/local/tmp/app_storage_loop.sh" 2>/dev/null || true

echo "=== 6. Setting up /system/xbin/su (KernelSU Bridge) ==="
if ! mount | grep -q "$ROOTFS/system/xbin "; then
    $BB mount -t tmpfs tmpfs "$ROOTFS/system/xbin"
    SU_SRC="/data/adb/ksud"
    [ -f "$SU_SRC" ] || SU_SRC=$(which su 2>/dev/null)
    [ -f "$SU_SRC" ] || SU_SRC=$(find /data/adb /system/bin -name su 2>/dev/null | head -n 1)
    [ -f "$SU_SRC" ] && cp "$SU_SRC" "$ROOTFS/system/xbin/su" && chmod 755 "$ROOTFS/system/xbin/su"
fi

echo "=== 7. Setting up Fresh APEX tmpfs ==="
# Clean any stale submounts and ensure a clean, writable tmpfs
for m in $(cat /proc/mounts 2>/dev/null | grep "$ROOTFS/apex" | awk '{print $2}' | sort -r); do
    $BB umount -l "$m" 2>/dev/null || true
done
$BB umount -l "$ROOTFS/apex" 2>/dev/null || true
$BB mount -t tmpfs tmpfs "$ROOTFS/apex"

# NOTE: the list is only a hint; apexd (host daemon) owns the preinstalled set
# and PMS parses the paths it reports. That is why the host's apex directories
# are bound into this rootfs (see the /system_ext/apex and /system/apex binds):
# every path in this list must resolve after the pivot.
if [ -f "$STAGE/clean_apex_info_list.xml" ]; then
    cp "$STAGE/clean_apex_info_list.xml" "$ROOTFS/apex/apex-info-list.xml"
else
    cp -a /apex/apex-info-list.xml "$ROOTFS/apex/" 2>/dev/null || true
fi
chmod 644 "$ROOTFS/apex/apex-info-list.xml" 2>/dev/null || true

echo "=== 8. Direct Mounting Extracted APEX Payloads ==="
# Payload images are cached in $STAGE; they belong to one specific system.raw.
# Drop the cache when the image changes (e.g. LineageOS -> Google GSI).
RAW_STAMP=$(stat -c '%s %Y' "$STAGE/system.raw" 2>/dev/null)
if [ "$(cat "$STAGE/payload_cache.stamp" 2>/dev/null)" != "$RAW_STAMP" ]; then
    echo "system.raw changed - clearing cached APEX payloads"
    rm -f "$STAGE"/*_payload.img
    echo "$RAW_STAMP" > "$STAGE/payload_cache.stamp"
fi
GSI_ID=$(grep -m1 "^ro.build.display.id=" "$ROOTFS/system/build.prop" 2>/dev/null | cut -d= -f2)
echo "GSI: ${GSI_ID:-unknown} ($(grep -m1 '^ro.build.flavor=\|^ro.system.build.type=' "$ROOTFS/system/build.prop" 2>/dev/null | cut -d= -f2))"
mount_payload() {
    NAME="$1"
    TARGET="$2"
    IMG="$STAGE/${NAME}_payload.img"
    DEST="$ROOTFS/apex/$TARGET"
    if [ ! -f "$IMG" ]; then
        # AOSP/LineageOS name these com.android.<name>.{capex,apex}; Google's
        # GSI uses com.google.android.<name>.apex (often compressed despite the
        # extension). Detect compression by content, not by filename.
        SRC=""
        for c in "com.android.${NAME}.capex" "com.android.${NAME}.apex" \
                 "com.google.android.${NAME}.capex" "com.google.android.${NAME}_compressed.apex" \
                 "com.google.android.${NAME}.apex"; do
            [ -f "$ROOTFS/system/apex/$c" ] && { SRC="$ROOTFS/system/apex/$c"; break; }
        done
        if [ -n "$SRC" ]; then
            if $BB unzip -l "$SRC" 2>/dev/null | grep -q " original_apex$"; then
                $BB unzip -p "$SRC" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
                $BB unzip -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
                rm -f "$STAGE/temp_${NAME}.apex"
            else
                $BB unzip -p "$SRC" apex_payload.img > "$IMG" 2>/dev/null
            fi
            [ -s "$IMG" ] || rm -f "$IMG"
        fi
    fi
    [ -f "$IMG" ] || return 0
    if mount | grep "$DEST " | grep -q "/dev/block/dm-"; then
        $BB umount -l "$DEST" 2>/dev/null || true
        for vdir in "$ROOTFS/apex/${TARGET}"@*; do
       [ -d "$vdir" ] && $BB umount -l "$vdir" 2>/dev/null || true
        done
    fi
    if mount | grep "$DEST " | grep -q "/dev/block/loop"; then
        echo "$NAME already mounted on loop at $DEST"
        return 0
    fi
    mkdir -p "$DEST"
    $BB umount -l "$DEST" 2>/dev/null || true
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$IMG"
    FSTYPE=ext4
    $BB mount -t ext4 -o ro "$LOOP" "$DEST" 2>/dev/null || { FSTYPE=erofs; mount -t erofs -o ro "$LOOP" "$DEST"; }
    echo "Direct mounted $NAME ($FSTYPE) on $LOOP -> $DEST"
    for vdir in "$ROOTFS/apex/${TARGET}"@*; do
        if [ -d "$vdir" ]; then
       $BB umount -l "$vdir" 2>/dev/null || true
       mount -t "$FSTYPE" -o ro "$LOOP" "$vdir"
       echo "Direct mounted $NAME on $LOOP -> $vdir"
        fi
    done
}

mount_payload "art" "com.android.art"
mount_payload "i18n" "com.android.i18n"
mount_payload "runtime" "com.android.runtime"
mount_payload "sdkext" "com.android.sdkext"
mount_payload "nfcservices" "com.android.nfcservices"
# tethering: chosen per GSI, three cases.
#  1) A TrebleDroid-based GSI (phhusson lineage: RestlessOS, TrebleDroid, ...)
#     ships treble-overlay-tethering-nobpf.apk which activates when
#     persist.sys.phh.tethering.nobpf=1. The overlay makes the connectivity
#     service tolerate missing BPF maps ("Failed initialization BpfMaps,
#     doing without it"). Use the GSI's own tethering + the property; every
#     package stays on the GSI's single key, and the host-BPF mismatch
#     (host-signed vs GSI-signed with same android.uid.networkstack shared
#     UID) never comes up.
#  2) A Google-signed GSI (com.google.android.tethering) shares the host's
#     signing identity, so it can be used as long as the BPF maps it needs
#     are pinned by the host.
#  3) Fall back to the host's tethering module. The GSI's NetworkStack APK
#     then collides with the host tethering APEX on android.uid.networkstack
#     and must be hidden.
BPF=/sys/fs/bpf/netd_shared
NOBPF_OVERLAY="$ROOTFS/system/product/overlay/treble-overlay-tethering-nobpf.apk"
echo "host BPF permission maps: $(ls $BPF 2>/dev/null | grep -c permission) ($(ls $BPF 2>/dev/null | grep permission | tr '\n' ' '))"
if [ -f "$NOBPF_OVERLAY" ]; then
    echo "tethering: using the GSI's own module (TrebleDroid nobpf overlay available; same signer as GSI's NetworkStack)"
    setprop persist.sys.phh.tethering.nobpf 1 2>/dev/null || true
    getprop persist.sys.phh.tethering.nobpf | awk '{print "persist.sys.phh.tethering.nobpf = " $0}'
    mount_payload "tethering" "com.android.tethering"
    # BpfNetMaps.setL4sEnabled() invokes BpfBoolean.set() on sL4sEnabledMap, which
    # is never populated when the nobpf overlay has disabled BPF-map setup. The
    # overlay stubs the main netd path but leaves this L4S toggle, so later in
    # boot ConnectivityService.handleNetworkL4sChanged() NPEs on the ConnectivityServiceThread
    # and takes system_server with it (seen at phase 550, right before BOOT_COMPLETED).
    # Overlay a patched service-connectivity.jar that returns-void from setL4sEnabled.
    # Mount paths: the APEX exports /javalib/service-connectivity.jar at both
    # /apex/com.android.tethering/javalib/service-connectivity.jar and the
    # versioned @NNNN mount. The bind must sit on the resolved mount point.
    if [ -f "$STAGE/service-connectivity_patched.jar" ]; then
        for apex_dir in "$ROOTFS/apex/com.android.tethering" "$ROOTFS"/apex/com.android.tethering@*; do
            jar="$apex_dir/javalib/service-connectivity.jar"
            if [ -f "$jar" ] && ! mount | grep -q " $jar "; then
                $BB mount --bind "$STAGE/service-connectivity_patched.jar" "$jar" && \
                    echo "Bound service-connectivity_patched.jar -> $jar (L4S null-guard)"
            fi
        done
    fi
elif ls "$ROOTFS/system/apex/com.google.android.tethering"* >/dev/null 2>&1 \
   && [ -e "$BPF/map_netd_uid_permission_map" ] && [ -e "$BPF/map_netd_uid_permission_chunk_map" ]; then
    echo "tethering: using the GSI's Google-signed module (host pins the maps it needs)"
    mount_payload "tethering" "com.android.tethering"
else
    echo "tethering: using the host's module"
    # When PMS reconciles the host tethering APEX (Google-signed NetworkStack
    # inside) with the GSI's /system/priv-app/NetworkStack (RestlessOS- or
    # LineageOS-signed), both declare android:sharedUserId="android.uid.networkstack"
    # and the signature mismatch is fatal:
    #   FATAL EXCEPTION IN SYSTEM PROCESS: main
    #   IllegalStateException: Signature mismatch on system package
    #     com.google.android.networkstack.tethering ... for shared user
    #     SharedUserSetting{... android.uid.networkstack/1073}
    # Hide the GSI's copy by bind-mounting an empty tmpfs over its directory;
    # the host's APEX-provided NetworkStack remains, so no package is lost.
    NS_DIR="$ROOTFS/system/priv-app/NetworkStack"
    if [ -d "$NS_DIR" ] && ! mount | grep -q " $NS_DIR "; then
        $BB mount -t tmpfs -o size=1M tmpfs "$NS_DIR" && \
            echo "Hid GSI's NetworkStack ($NS_DIR) - host tethering APEX signatures own this shared UID"
    fi
fi
# Otherwise tethering is NOT mounted from the GSI. Its BPF programs/maps under /sys/fs/bpf
# are loaded at boot by the HOST's tethering module (Google mainline, e.g.
# 372038420), and the GSI's AOSP build (370399999) expects maps the host never
# pinned -> system_server dies in BpfNetMaps ("Cannot open uid permission map",
# ENOENT). Step 9 binds the host's /apex/com.android.tethering instead, whose
# connectivity code matches the maps in the kernel.
mount_payload "crashrecovery" "com.android.crashrecovery"
mount_payload "cellbroadcast" "com.android.cellbroadcast"
mount_payload "extservices" "com.android.extservices"
mount_payload "permission" "com.android.permission"
mount_payload "wifi" "com.android.wifi"
mount_payload "appsearch" "com.android.appsearch"
mount_payload "mediaprovider" "com.android.mediaprovider"
mount_payload "adservices" "com.android.adservices"
mount_payload "rkpd" "com.android.rkpd"
mount_payload "healthfitness" "com.android.healthfitness"
mount_payload "ondevicepersonalization" "com.android.ondevicepersonalization"
mount_payload "configinfrastructure" "com.android.configinfrastructure"
mount_payload "bt" "com.android.bt"
# Android 17: framework-telecom.jar / service-telecom.jar moved into the
# telephonycore APEX. Samsung's copy doesn't ship them (One UI keeps telecom in
# /system), so the guest must use the GSI's own telephonycore.
mount_payload "telephonycore" "com.android.telephonycore"

# Payload extractions above used the GSI's own /system/apex files. Now that the
# images are cached, present the HOST's /system/apex to the container so the
# preinstalled paths reported by host apexd all resolve (see the note above
# about /system_ext/apex).
if [ -d /system/apex ]; then
    mkdir -p "$ROOTFS/system/apex"
    mount | grep -q "$ROOTFS/system/apex " || $BB mount --bind /system/apex "$ROOTFS/system/apex"
fi

echo "=== 9. Bind-mounting Remaining Non-Payload APEXes ==="
for a in /apex/*; do
    [ -d "$a" ] || continue
    base=$(basename "$a")
    case "$base" in
        *samsung*)
       continue
       ;;
    esac
    # Skip if already mounted
    if ! mount | grep -q "$ROOTFS/apex/$base "; then
        mkdir -p "$ROOTFS/apex/$base"
        $BB mount --bind "$a" "$ROOTFS/apex/$base" 2>/dev/null || true
        echo "Bound $base -> $ROOTFS/apex/$base"
    fi
done

echo "=== 9b. Filtering apex-info-list to paths that resolve in the container ==="
# PackageManager aborts boot ("Unable to parse <path>") on any listed APEX it
# can't open, so drop entries whose modulePath doesn't exist inside the rootfs
# (checked via chroot, so the GSI's own symlinks are honoured).
AIL="$ROOTFS/apex/apex-info-list.xml"
if [ -f "$AIL" ] && ! $BB chroot "$ROOTFS" /system/bin/sh -c "[ -e /system/build.prop ]" 2>/dev/null; then
    echo "  chroot test unavailable - leaving apex-info-list unfiltered"
elif [ -f "$AIL" ]; then
    { head -n 2 "$AIL" | grep -v "<apex-info "; } > "$AIL.new"
    grep "<apex-info " "$AIL" | while IFS= read -r line; do
        mp=$(echo "$line" | sed -n 's/.* modulePath="\([^"]*\)".*/\1/p')
        if $BB chroot "$ROOTFS" /system/bin/sh -c "[ -e '$mp' ]" 2>/dev/null; then
            echo "$line" >> "$AIL.new"
        else
            echo "  dropped (not in container): $mp"
        fi
    done
    echo "</apex-info-list>" >> "$AIL.new"
    mv -f "$AIL.new" "$AIL"; chmod 644 "$AIL"
    echo "apex-info-list: $(grep -c '<apex-info ' "$AIL") entries"
fi

# PermissionController patch, second pass. The same block near step 4 runs
# before the apex set is mounted, so find(1) finds nothing and Samsung's
# PermissionController stays behind. Samsung's build requires
# android.permission.RANGING, which the GSI platform does not define, so every
# runtime-permission dialog dies with
#   IllegalStateException: android.permission.RANGING not defined by platform
#   -> "Permission controller keeps stopping"
# and Gallery/Phone/Calendar can never be granted anything. Bind it now that
# /apex/com.android.permission actually exists.
if [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk" 2>/dev/null || true
    for PERM_APK in $(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null); do
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK" 2>/dev/null && echo "Bound PermissionController_patched.apk (late) -> $PERM_APK"
    done
else
    # Android 17 / LineageOS 24 defines android.permission.RANGING unconditionally
    # (23.2 hid it behind a disabled feature flag), so the host's stock
    # PermissionController is used as-is.
    echo "Using host PermissionController (no patch needed on LineageOS 24)"
fi

echo "=== ALL MOUNTS PREPARED SUCCESSFULLY ==="
