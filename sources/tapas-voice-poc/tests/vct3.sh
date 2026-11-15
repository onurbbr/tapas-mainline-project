#!/bin/sh
# Bring the DSP up in a known state and try the voice graphs once.
echo "=== modem ==="
mmcli -m 0 2>/dev/null | grep -E "state:|access tech:|signal quality" | head -3

echo "=== load module ==="
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>&1
ls -l /sys/kernel/debug/q6apm-voice/ctl 2>&1

echo "=== keep the playback PCM running (the DSP takes the downlink from it) ==="
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero >/dev/null 2>&1 &
APID=$!
sleep 1

dmesg -C
echo start > /sys/kernel/debug/q6apm-voice/ctl 2>&1
RC=$?
echo "start rc=$RC"
sleep 2
echo "=== dmesg ==="
dmesg | grep -iE "voice-poc|qcom-apm|DSP returned" | head -20

echo "=== dsp state ==="
dmesg | grep -icE "system error|SYS_ERROR"

echo "=== stop ==="
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>&1
kill $APID 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
dmesg | grep -iE "voice-poc" | tail -8
