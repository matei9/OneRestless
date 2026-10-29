#!/system/bin/sh
# Collect OneLineage boot diagnostics into one file.
#   adb push tools/collect_logs.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/collect_logs.sh"
#   adb pull /data/local/tmp/ol_debug.txt
STAGE=/data/local/tmp/lineage_stage
OUT=${OUT:-/data/local/tmp/ol_debug.txt}
BB=$(ls /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox 2>/dev/null | head -n1)
[ -n "$BB" ] || BB=busybox
sec() { echo; echo "================ $1"; }
tailf() { sec "$1 (last ${2:-150} lines)"; [ -f "$1" ] && tail -n "${2:-150}" "$1" || echo "(missing)"; }
{
  sec "date / props"; date; getprop ro.product.model; getprop ro.build.display.id; getprop sys.boot_completed
  echo "selinux: $(getenforce)"; echo "busybox: $BB"; echo "running as: $(id)"
  ls -l /system/bin/su /system/xbin/su /data/adb/ksud 2>&1
  sec "staged engine files (md5)"
  for f in services_patched.jar framework_patched.jar zygote_exec master_prepare.sh; do echo "$(md5sum $STAGE/$f 2>/dev/null | cut -c1-12)  $f"; done
  sec "networking reference (host modules, BPF maps, guest connectivity startup)"
  grep -o '<apex-info moduleName="com.android.\(tethering\|resolv\)"[^>]*' /apex/apex-info-list.xml 2>/dev/null | grep -o 'moduleName="[^"]*"\|versionCode="[^"]*"\|isActive="[^"]*"' | paste - - - 2>/dev/null
  echo "-- /sys/fs/bpf/netd_shared:"; ls /sys/fs/bpf/netd_shared 2>&1 | tr '\n' ' '; echo
  echo "-- guest connectivity / DNS startup lines:"
  logcat -d -b main,system,crash 2>/dev/null | grep -aE "ConnectivityService|BpfNetMaps|DnsManager|DnsResolver|resolv|getUnstableInterface|NetworkStack|Tethering" | grep -av "Finsky" | tail -n 120
  sec "processes"
  ps -A -o PID,PPID,USER,NAME,ARGS 2>/dev/null | grep -aiE "zygote|system_server|surfaceflinger|bootanim|servicemanager|vold|app_process|master_inner|unshare" | grep -v grep
  SS=$(pidof system_server | awk '{print $1}')
  Z=$(pidof zygote64 | awk '{print $1}')
  echo "system_server=$SS zygote64=$Z"
  sec "mount ns: host=$(readlink /proc/1/ns/mnt) ss=$( [ -n "$SS" ] && readlink /proc/$SS/ns/mnt) zyg=$( [ -n "$Z" ] && readlink /proc/$Z/ns/mnt)"
  sec "df /data"; df -h /data
  tailf $STAGE/takeover_app.log 200
  tailf $STAGE/data/takeover.log 300
  tailf $STAGE/data/anim.log 40
  tailf $STAGE/data/vold.log 40
  tailf $STAGE/data/idmap.log 20
  tailf $STAGE/data/boot_failures.log 60
  tailf /data/local/tmp/ui_activator.log 40
  sec "logcat crash buffer"; logcat -d -b crash 2>/dev/null | tail -n 300
  sec "logcat main/system: fatal + boot path (last 600)"
  logcat -d -b main,system 2>/dev/null | grep -aE "FATAL|AndroidRuntime|Zygote|SystemServer|SystemServiceManager|PackageManager|ApexManager|ActivityManager: Start proc|Unable to parse|Exception|Watchdog|ServiceManager|art  |linker|init:.*(zygote|surfaceflinger)" | tail -n 600
  # any process living in the container's mount namespace (surfaceflinger
  # survives even when zygote/system_server are dead)
  HOSTNS=$(readlink /proc/1/ns/mnt); CP=""
  for p in $SS $Z $(pidof surfaceflinger) $(pidof bootanimation); do
    [ -n "$p" ] && [ "$(readlink /proc/$p/ns/mnt)" != "$HOSTNS" ] && { CP=$p; break; }
  done
  if [ -n "$CP" ]; then
    P=$CP
    sec "container apex paths from apex-info-list (pid $P)"
    $BB nsenter -t $P -m sh -c 'for f in $(grep -o " modulePath=\"[^\"]*\"" /apex/apex-info-list.xml | cut -d\" -f2); do ls -lL "$f" 2>&1 | head -1; done; echo; ls -la /system_ext /system_ext/apex /system/system_ext/apex 2>&1; mount | grep -E "system_ext|product/apex" ' 2>&1
  fi
  if [ -n "$CP" ]; then
    sec "inside container ns (pid $P): rootfs check"
    $BB nsenter -t $P -m sh -c 'ls /system/framework/services.jar /system/framework/framework.jar; getprop ro.build.version.sdk; ls /apex | head -80; cat /apex/apex-info-list.xml | head -c 400' 2>&1
  fi
  sec "tail of full logcat (last 400)"; logcat -d 2>/dev/null | tail -n 400
} > $OUT 2>&1
chmod 644 $OUT
echo "wrote $OUT ($(wc -c < $OUT) bytes)"
