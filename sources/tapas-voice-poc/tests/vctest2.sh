#!/bin/sh
# Voice-call graph test with the playback backend running, which is what the
# watch script does: stock's device sub-graph names a CODEC_DMA sink instance
# that only exists once the playback PCM has opened it.
KO=/lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko

echo "=== keeping hw:0,0 busy ==="
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero &
APLAY=$!
sleep 2
kill -0 $APLAY 2>/dev/null && echo "aplay running (pid $APLAY)" || echo "aplay died"

dmesg -C
insmod "$KO" 2>/dev/null
printf 'start' > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
echo "start rc=$?"
sleep 2
dmesg | grep -iE "voice-poc|DSP returned"

echo "=== rx ts ==="
cat /sys/class/remoteproc/remoteproc1/state

kill $APLAY 2>/dev/null
