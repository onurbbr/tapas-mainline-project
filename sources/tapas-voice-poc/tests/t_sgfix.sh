systemctl stop tapas-voice-call-watch.service 2>/dev/null
for d in /run/user/*; do
  [ -S "$d/bus" ] || continue
  u=$(stat -c %U "$d")
  su -s /bin/sh "$u" -c "export XDG_RUNTIME_DIR=$d; systemctl --user stop wireplumber.service pipewire.service pipewire.socket pipewire-pulse.socket" 2>/dev/null
done
sleep 2
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START1_OK; else echo START1_FAIL; fi
sleep 1
if echo stop > /sys/kernel/debug/q6apm-voice/ctl; then echo STOP_OK; else echo STOP_FAIL; fi
sleep 2
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START2_OK; else echo START2_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -10
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
