insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null
cp /tmp/voice-rx5-open.bin /tmp/voice-tx-open.bin /lib/firmware/qcom/sm6225/
md5sum /lib/firmware/qcom/sm6225/voice-rx5-open.bin
dmesg -C
if echo start > /sys/kernel/debug/q6apm-voice/ctl; then echo START_OK; else echo START_FAIL; fi
sleep 1
dmesg | grep -iE "voice-poc|DSP returned" | tail -14
