#!/bin/sh
# Is the RX GRAPH_OPEN dependent on the playback sub-graph being open?
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
ctl=/sys/kernel/debug/q6apm-voice/ctl

echo "=== A: backends open, then start ==="
dmesg -C
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero 2>/tmp/ap.err &
apid=$!
arecord -q -D hw:0,3 -f S16_LE -r 48000 -c 2 /dev/null 2>/tmp/ar.err &
rpid=$!
sleep 1
echo "aplay alive: $(kill -0 $apid 2>/dev/null && echo yes || echo no)  err: $(cat /tmp/ap.err)"
echo "arecord alive: $(kill -0 $rpid 2>/dev/null && echo yes || echo no)  err: $(cat /tmp/ar.err)"
echo start > $ctl && echo "start rc=0" || echo "start rc=$?"
sleep 1
dmesg | grep -i voice-poc | tail -3

echo
echo "=== stop, release the backends ==="
echo stop > $ctl 2>/dev/null
sleep 1
kill $apid $rpid 2>/dev/null
sleep 1

echo "=== B: no backends open, then start ==="
dmesg -C
echo start > $ctl && echo "start rc=0" || echo "start rc=$?"
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -4

echo stop > $ctl 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
