systemctl stop tapas-voice-call-watch.service 2>/dev/null
for d in /run/user/*; do
  [ -S "$d/bus" ] || continue
  u=$(stat -c %U "$d")
  su -s /bin/sh "$u" -c "export XDG_RUNTIME_DIR=$d; systemctl --user stop wireplumber.service pipewire.service pipewire.socket pipewire-pulse.socket" 2>/dev/null
done
sleep 2
fuser /dev/snd/pcmC0D0p /dev/snd/pcmC0D1p 2>&1 | tail -2
cp /tmp/voice-rx5-open.bin /tmp/voice-tx-open.bin /tmp/voice-rx5-cfg.bin /tmp/voice-tx-cfg.bin /lib/firmware/qcom/sm6225/ 2>/dev/null
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START_OK; else echo START_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -6
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
