#!/bin/sh
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>&1
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero >/dev/null 2>&1 &
APID=$!
sleep 1
dmesg -C
echo start > /sys/kernel/debug/q6apm-voice/ctl
echo "start rc=$?"
for i in 1 2 3 4 5 6; do
	sleep 2
	n=$(dmesg | grep -icE "sys_error|system error|voice-poc:.*failed")
	echo "t=$i errors=$n"
done
echo "=== dmesg tail ==="
dmesg | tail -15
echo "=== remoteproc ==="
cat /sys/class/remoteproc/remoteproc1/state
echo stop > /sys/kernel/debug/q6apm-voice/ctl
echo "stop rc=$?"
sleep 1
kill $APID 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
dmesg | tail -6
