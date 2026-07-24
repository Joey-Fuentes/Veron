#!/bin/busybox sh
# PID 1 for the tcc-userland spike.
#
# Everything running here -- this shell, busybox, and the libc under both --
# was compiled by tcc. The kernel beneath was compiled by gcc. That works
# because Linux's syscall ABI is the contract between them: the kernel does
# not know or care which compiler produced the binaries issuing svc #0.
/bin/busybox mount -t proc none /proc 2>/dev/null
/bin/busybox mount -t sysfs none /sys 2>/dev/null
echo "==== VERON USERLAND ALIVE ===="
echo "uname : $(/bin/busybox uname -a)"
echo "pid1  : $(/bin/busybox readlink /proc/self/exe 2>/dev/null)"
echo "shell and busybox: compiled by tcc"
echo "kernel under them: compiled by gcc"
/bin/busybox echo "arithmetic check: $(( 6 * 7 ))"
echo "==== VERON BOOT OK ===="
/bin/busybox poweroff -f
