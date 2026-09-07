#!/bin/sh
# Apply the device-side fixes from BUGS.md, for the parts that are not open source.
#
# DRY RUN BY DEFAULT. Every subcommand prints what it would change and exits.
# Pass --apply to perform the change. Anything replaced is backed up first, with a
# timestamp, and nothing is ever deleted.
#
# Run on the instrument, as root:
#     sh apply.sh status
#     sh apply.sh rt-throttle
#     sh apply.sh rt-throttle --apply
#
# BusyBox ash compatible: no bashisms, no arrays, no `local`.

set -e

APPLY=0
CMD=""
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) CMD="$arg" ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/var/moog-fixes-backup-$STAMP"

say()  { echo "  $*"; }
would() { if [ "$APPLY" = "1" ]; then echo "  DO   $*"; else echo "  WOULD $*"; fi; }

backup() {
    [ -e "$1" ] || return 0
    if [ "$APPLY" = "1" ]; then
        mkdir -p "$BACKUP"
        cp -a "$1" "$BACKUP/" && say "backed up $1 -> $BACKUP/"
    else
        say "WOULD back up $1 -> $BACKUP/"
    fi
}

# ---------------------------------------------------------------- status

cmd_status() {
    say "scsynth:"
    for d in /proc/[0-9]*; do
        n=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$n" in
            *scsynth\ -u*)
                pid=$(basename "$d")
                say "  pid $pid"
                # Bit 12 is SIGPIPE. Present in neither mask means the default
                # action applies, and the default action is terminate.
                say "  $(grep SigIgn "$d/status" 2>/dev/null)  <- bit 12 set means SIGPIPE ignored"
                say "  $(grep SigCgt "$d/status" 2>/dev/null)"
                ;;
        esac
    done
    say ""
    say "realtime scheduling budget:"
    say "  sched_rt_runtime_us = $(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null)"
    say "  sched_rt_period_us  = $(cat /proc/sys/kernel/sched_rt_period_us 2>/dev/null)"
    if dmesg 2>/dev/null | grep -q "RT throttling activated"; then
        say "  RT THROTTLING HAS FIRED since boot (see BUGS.md finding 4)"
    else
        say "  no RT throttling logged since boot"
    fi
    say ""
    say "core dumps:"
    say "  core_pattern = $(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
    say "  ulimit -c    = $(ulimit -c)"
    say ""
    say "LadspaUGen:"
    ls -la /usr/lib/SuperCollider/plugins/LadspaUGen.so 2>/dev/null | sed 's/^/    /' || say "    not found"
}

# ------------------------------------------------------------ rt-throttle

cmd_rt_throttle() {
    cur=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo "?")
    say "sched_rt_runtime_us is currently $cur out of a"
    say "sched_rt_period_us of $(cat /proc/sys/kernel/sched_rt_period_us 2>/dev/null || echo '?')."
    say ""
    say "scsynth runs SCHED_FIFO. When realtime tasks exceed that budget the kernel"
    say "forcibly deschedules them, which is an audio dropout. This unit logged"
    say "'sched: RT throttling activated' 17 minutes after boot while idle."
    say ""
    say "THE TRADEOFF IS REAL AND IT IS NOT OURS TO MAKE. Raising the budget"
    say "reduces the kernel's protection against a spinning realtime thread locking"
    say "the machine out entirely. 980000 leaves 2% for everything else, which is"
    say "enough to get a shell in; -1 removes the limit and the protection with it."
    say ""
    would "echo 980000 > /proc/sys/kernel/sched_rt_runtime_us"
    if [ "$APPLY" = "1" ]; then
        echo 980000 > /proc/sys/kernel/sched_rt_runtime_us
        say "now: $(cat /proc/sys/kernel/sched_rt_runtime_us)"
        say ""
        say "This does NOT persist across a reboot. To make it permanent it belongs"
        say "in the init that starts the audio engine, not in a sysctl file that may"
        say "run after it."
    fi
}

# ------------------------------------------------------------- core-dumps

cmd_core_dumps() {
    say "Enables core dumps so the crash in BUGS.md finding 1 produces a backtrace"
    say "naming the faulting library and function, rather than just a dead server."
    say ""
    say "/var is the only sensible target: /tmp is a 248 MB tmpfs and a core from a"
    say "process with -m 100000 will not fit beside the memory it is dumping."
    say ""
    would "mkdir -p /var/cores"
    would "echo '/var/cores/core.%e.%p' > /proc/sys/kernel/core_pattern"
    would "ulimit -c unlimited   (in the shell that starts scsynth -- see below)"
    say ""
    say "A running scsynth keeps the RLIMIT_CORE it was started with, so the limit"
    say "has to be raised BEFORE it starts. Add 'ulimit -c unlimited' to"
    say "/usr/share/las-fx/launch-sc-1 above the sclang line, restart, then run"
    say "repro/ladspa_free_crash.py and look in /var/cores."
    if [ "$APPLY" = "1" ]; then
        mkdir -p /var/cores
        echo '/var/cores/core.%e.%p' > /proc/sys/kernel/core_pattern
        say "core_pattern is now: $(cat /proc/sys/kernel/core_pattern)"
        say "launch-sc-1 has NOT been modified -- do that by hand and restart."
    fi
}

# ------------------------------------------------------------ ladspa-ugen

cmd_ladspa_ugen() {
    target=/usr/lib/SuperCollider/plugins/LadspaUGen.so
    src=$(dirname "$0")/LadspaUGen.so
    say "Installs a LadspaUGen.so built from sc3-plugins with"
    say "patches/0001-ladspa-null-handle.patch applied."
    say ""
    if [ ! -f "$src" ]; then
        say "NOT FOUND: $src"
        say ""
        say "Build it first, against this unit's toolchain and SuperCollider"
        say "headers -- an .so built for the wrong ABI will not load, and scsynth"
        say "will start without the UGen and fail every effect synthdef."
        say ""
        say "Verify before installing: the file must be ARM 32-bit ELF and must"
        say "export ladspa_descriptor lookup the same way the existing one does."
        return 0
    fi
    backup "$target"
    would "install -m 0755 $src $target"
    if [ "$APPLY" = "1" ]; then
        install -m 0755 "$src" "$target"
        say "installed. Restart the audio engine for it to take effect."
    fi
}

case "$CMD" in
    status)       cmd_status ;;
    rt-throttle)  cmd_rt_throttle ;;
    core-dumps)   cmd_core_dumps ;;
    ladspa-ugen)  cmd_ladspa_ugen ;;
    *)
        echo "usage: sh apply.sh {status|rt-throttle|core-dumps|ladspa-ugen} [--apply]"
        echo ""
        echo "  status        report what is currently set (read-only, always safe)"
        echo "  rt-throttle   raise the realtime scheduling budget (finding 4)"
        echo "  core-dumps    enable cores so finding 1 yields a backtrace"
        echo "  ladspa-ugen   install a patched LadspaUGen.so (finding 1)"
        echo ""
        echo "Without --apply every subcommand only prints what it would do."
        exit 2
        ;;
esac
