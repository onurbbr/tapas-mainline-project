systemctl stop tapas-voice-call-watch.service 2>/dev/null
for d in /run/user/*; do
  [ -S "$d/bus" ] || continue
  u=$(stat -c %U "$d")
  su -s /bin/sh "$u" -c "export XDG_RUNTIME_DIR=$d; systemctl --user stop wireplumber.service pipewire.service pipewire.socket pipewire-pulse.socket" 2>/dev/null
done
sleep 2
md5sum /lib/firmware/qcom/sm6225/voice-*.bin
modprobe_out=$(insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>&1)
[ -n "$modprobe_out" ] && echo "insmod: $modprobe_out"
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START_OK; else echo START_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -12
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
