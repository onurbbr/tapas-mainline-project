#!/bin/sh
# Start the voice graph first, then bring the ALSA backends up.
ctl=/sys/kernel/debug/q6apm-voice/ctl
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null

dmesg -C
echo start > $ctl && echo "start rc=0" || echo "start rc=$?"
sleep 1

echo "=== now open the backends ==="
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero 2>/tmp/ap.err &
apid=$!
arecord -q -D hw:0,3 -f S16_LE -r 48000 -c 2 /dev/null 2>/tmp/ar.err &
rpid=$!
sleep 3
echo "aplay alive: $(kill -0 $apid 2>/dev/null && echo yes || echo no) err:[$(cat /tmp/ap.err)]"
echo "arecord alive: $(kill -0 $rpid 2>/dev/null && echo yes || echo no) err:[$(cat /tmp/ar.err)]"

echo "=== dmesg ==="
dmesg | grep -iE "voice-poc|DSP returned|SYS_ERROR|system error" | tail -8

echo "=== stop ==="
echo stop > $ctl 2>/dev/null
kill $apid $rpid 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
dmesg | tail -4
