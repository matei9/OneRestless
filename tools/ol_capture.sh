#!/system/bin/sh
# OneLineage boot capture. Run as root on the phone:
#   sh /data/local/tmp/ol_capture.sh start   (before tapping Switch)
#   sh /data/local/tmp/ol_capture.sh pull    (after returning to One UI / reboot)
T=/data/local/tmp
LOG=$T/ol_boot_logcat.txt
# The guest's codec enumeration floods ~200k lines/s with these tags (README
# known issue) and would rotate the boot out of the capture - silence them.
QUIET="AString:S libbinder.Parcel:S MediaCodecList:S"
case "$1" in
start)
    pkill -f ol_boot_logcat 2>/dev/null
    rm -f $LOG* $T/ol_boot_capture_all.txt
    {
        echo "== host snapshot $(date)"
        getprop ro.product.model; getprop ro.build.display.id
        echo "-- host tethering/resolv modules:"
        for m in com.android.tethering com.android.resolv; do
            grep -o "<apex-info moduleName=\"$m\"[^>]*" /apex/apex-info-list.xml \
                | grep -o 'modulePath="[^"]*"\|versionCode="[^"]*"\|isActive="[^"]*"' | tr '\n' ' '
            echo
        done
        echo "-- /sys/fs/bpf/netd_shared:"; ls /sys/fs/bpf/netd_shared
    } > $T/ol_host_net.txt 2>&1
    logcat -c
    setsid nohup logcat -b main,system,crash -v threadtime -f $LOG -r 16384 -n 16 $QUIET </dev/null >/dev/null 2>&1 &
    sleep 1
    if pgrep -f ol_boot_logcat >/dev/null; then echo CAPTURE_RUNNING; else echo CAPTURE_FAILED; exit 1; fi
    ;;
pull)
    pkill -f ol_boot_logcat 2>/dev/null
    {
        cat $T/ol_host_net.txt
        echo; echo "==== logcat"
        for i in 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1; do [ -f $LOG.$i ] && cat $LOG.$i; done
        cat $LOG
    } > $T/ol_boot_capture_all.txt 2>&1
    chmod 644 $T/ol_boot_capture_all.txt
    ls -l $T/ol_boot_capture_all.txt
    ;;
*) echo "usage: $0 start|pull"; exit 2 ;;
esac
