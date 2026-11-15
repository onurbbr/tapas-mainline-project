#!/bin/sh
# Does normal playback still work after the topology change, and does the
# voice graph start with the backends opened afterwards?
systemctl stop tapas-voice-call-watch.service 2>/dev/null

echo "=== HiFi playback sanity ==="
sudo -u onur env XDG_RUNTIME_DIR=/run/user/1000 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | head -6

echo "=== voice graph, ordered like the watch script ==="
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
amixer -c0 -q sset "RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1" on
dmesg -C
echo start > /sys/kernel/debug/q6apm-voice/ctl && echo "start ok" || echo "start FAILED"
sleep 1
aplay -q -D hw:0,0 -f S16_LE -r 48000 -c 2 /dev/zero 2>/tmp/ap.err &
apid=$!
sleep 2
echo "aplay alive: $(kill -0 $apid 2>/dev/null && echo yes || echo no) err:[$(cat /tmp/ap.err)]"
dmesg | grep -iE "voice-poc|DSP returned|system error" | tail -5
kill $apid 2>/dev/null

echo "=== earpiece path check during graph ==="
for n in 37 104 105 106 97 98 4; do printf "numid=%-4s " $n; amixer -c0 cget numid=$n 2>/dev/null | sed -n 's/.*: values=//p'|head -1; done
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
