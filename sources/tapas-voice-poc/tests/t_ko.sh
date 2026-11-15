KO=/lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko
[ -f /tmp/q6apm-voice-poc.ko ] || { echo "no ko"; exit 1; }
cp /tmp/q6apm-voice-poc.ko "$KO"
rmmod q6apm_voice_poc 2>/dev/null
systemctl stop tapas-voice-call-watch.service 2>/dev/null
for d in /run/user/*; do
  if [ -S "$d/bus" ]; then
    u=$(stat -c %U "$d")
    su -s /bin/sh "$u" -c "export XDG_RUNTIME_DIR=$d; systemctl --user stop wireplumber.service pipewire.service pipewire.socket pipewire-pulse.socket"
  fi
done
sleep 2
insmod "$KO" || echo "insmod failed"
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START_OK; else echo START_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -14
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
