pkill -f "aplay -q -D hw:0,0"
sleep 1
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START_OK_NOBACKEND; else echo START_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -4
echo stop > /sys/kernel/debug/q6apm-voice/ctl 2>/dev/null
rmmod q6apm_voice_poc 2>/dev/null
