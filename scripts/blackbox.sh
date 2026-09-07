#!/bin/sh
# A black box for the next lock-up.
#
# The UI froze once and recovered on its own, and afterwards the only evidence was
# a single kernel line. Nothing was watching, so there is nothing to diagnose from.
# This watches, cheaply, and writes what it sees to /var.
#
# TWO RULES IT IS BUILT AROUND, both learned the hard way on this machine:
#
#   THE LOG HAS TO OUTLIVE THE NETWORK. A lock-up may take SSH with it, so this
#   writes to /var and never reports anywhere. Read it afterwards.
#
#   A PROBE MUST DISTINGUISH *CHANGED* FROM *UNREADABLE*. A recovery ladder here
#   once reported success because a counter it read had ceased to exist: the read
#   returned empty, empty != the old value, and it called that "recovered". Every
#   check below treats an unreadable value as UNKNOWN, never as a change.
#
# Run it detached and forget it:
#     nohup sh blackbox.sh > /dev/null 2>&1 &
# Stop it:
#     touch /var/blackbox.stop
#
# Costs: one sample every 10 s of a few /proc reads. The log is capped and rotated.

LOG=/var/blackbox.log
STOP=/var/blackbox.stop
INTERVAL=10
MAX_BYTES=2000000

rm -f "$STOP"

read_or_unknown() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "UNKNOWN"; }

pid_of() {
    for d in /proc/[0-9]*; do
        n=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$n" in $1) basename "$d"; return 0 ;; esac
    done
    echo ""
}

cpu_ticks() {
    [ -n "$1" ] && [ -r "/proc/$1/stat" ] || { echo "UNKNOWN"; return; }
    awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo "UNKNOWN"
}

proc_state() {
    [ -n "$1" ] && [ -r "/proc/$1/stat" ] || { echo "GONE"; return; }
    awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo "UNKNOWN"
}

snapshot() {
    echo "  --- snapshot: $1"
    echo "  uptime $(cut -d. -f1 /proc/uptime) load $(cat /proc/loadavg)"
    grep -E "MemFree|MemAvailable" /proc/meminfo | sed 's/^/  /'
    echo "  processes:"
    for d in /proc/[0-9]*; do
        n=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$n" in
            *las-frontend*|*scsynth\ -u*|*sclang*|*las-sc*|*las-dwm*|*Xorg*|*X\ *)
                echo "    pid $(basename "$d") state $(awk '{print $3}' "$d/stat") wchan $(read_or_unknown "$d/wchan") :: $(echo "$n" | cut -c1-50)"
                ;;
        esac
    done
    echo "  net:"
    grep -E "ethext|usbint" /proc/net/dev | sed 's/^/    /'
    echo "  new kernel messages:"
    dmesg | tail -40 | sed 's/^/    /'
    echo "  --- end snapshot"
}

# Baselines. Every one may be UNKNOWN, and UNKNOWN never counts as a change.
last_dmesg=$(dmesg 2>/dev/null | wc -l)
fe_pid=$(pid_of "*las-frontend*")
sc_pid=$(pid_of "*scsynth -u*")
last_fe=$(cpu_ticks "$fe_pid")
net_err=$(awk '/ethext|usbint/ {s+=$4+$5+$12+$13} END {print s+0}' /proc/net/dev 2>/dev/null || echo UNKNOWN)

{
    echo "=== blackbox started $(date) uptime $(cut -d. -f1 /proc/uptime)s"
    echo "    watching las-frontend pid ${fe_pid:-none}, scsynth pid ${sc_pid:-none}"
    snapshot "baseline"
} >> "$LOG"

while [ ! -e "$STOP" ]; do
    sleep "$INTERVAL"

    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt "$MAX_BYTES" ]; then
        mv "$LOG" "$LOG.1"
        echo "=== rotated $(date)" > "$LOG"
    fi

    why=""

    now_dmesg=$(dmesg 2>/dev/null | wc -l)
    case "$now_dmesg" in
        ''|*[!0-9]*) : ;;   # unreadable -> not a change
        *) [ "$now_dmesg" -gt "$last_dmesg" ] && why="$why new-kernel-messages"
           last_dmesg=$now_dmesg ;;
    esac

    st=$(proc_state "$sc_pid")
    [ "$st" = "GONE" ] && why="$why scsynth-gone"
    st=$(proc_state "$fe_pid")
    [ "$st" = "GONE" ] && why="$why frontend-gone"
    [ "$st" = "D" ] && why="$why frontend-uninterruptible"

    now_fe=$(cpu_ticks "$fe_pid")
    if [ "$now_fe" != "UNKNOWN" ] && [ "$last_fe" != "UNKNOWN" ]; then
        # A frozen UI shows up either as a process using NO cpu at all or as one
        # pinned spinning. Both are worth a snapshot; neither is normal idle.
        delta=$((now_fe - last_fe))
        [ "$delta" -eq 0 ] && why="$why frontend-idle"
        [ "$delta" -gt $((INTERVAL * 90)) ] && why="$why frontend-spinning"
        last_fe=$now_fe
    fi

    free_kb=$(awk '/^MemFree:/ {print $2}' /proc/meminfo 2>/dev/null)
    case "$free_kb" in
        ''|*[!0-9]*) : ;;
        *) [ "$free_kb" -lt 4000 ] && why="$why memory-low-${free_kb}kB" ;;
    esac

    now_err=$(awk '/ethext|usbint/ {s+=$4+$5+$12+$13} END {print s+0}' /proc/net/dev 2>/dev/null || echo UNKNOWN)
    if [ "$now_err" != "UNKNOWN" ] && [ "$net_err" != "UNKNOWN" ] && [ "$now_err" -gt "$net_err" ]; then
        why="$why net-errors-$net_err-to-$now_err"
    fi
    [ "$now_err" != "UNKNOWN" ] && net_err=$now_err

    if [ -n "$why" ]; then
        { echo "=== $(date) uptime $(cut -d. -f1 /proc/uptime)s TRIGGER:$why"
          snapshot "$why"; } >> "$LOG"
    fi
done

echo "=== blackbox stopped $(date)" >> "$LOG"
rm -f "$STOP"
