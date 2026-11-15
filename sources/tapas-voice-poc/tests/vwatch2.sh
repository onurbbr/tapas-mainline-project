#!/bin/sh
# Temporary watcher for the self contained voice graph: the graph owns the
# codec DMA sink, so no ALSA PCM may be open while it runs.
ctl=/sys/kernel/debug/q6apm-voice/ctl
log() { echo "vwatch2: $*" | systemd-cat -t vwatch2 2>/dev/null || echo "vwatch2: $*"; }

systemctl stop tapas-voice-call-watch.service 2>/dev/null
for d in /run/user/*; do
	[ -S "$d/bus" ] || continue
	u=$(stat -c %U "$d")
	su -s /bin/sh "$u" -c "export XDG_RUNTIME_DIR=$d; systemctl --user stop wireplumber.service pipewire.service pipewire.socket pipewire-pulse.socket" 2>/dev/null
done
sleep 2
insmod /lib/modules/$(uname -r)/kernel/sound/soc/qcom/qdsp6/q6apm-voice-poc.ko 2>/dev/null

on=0
while true; do
	if mmcli -m any --voice-list-calls 2>/dev/null | grep -q "(active)"; then
		if [ $on = 0 ]; then
			amixer -c0 -q cset numid=104 1
			amixer -c0 -q cset numid=37 on
			amixer -c0 -q cset numid=105 on
			amixer -c0 -q cset numid=98 on
			amixer -c0 -q cset numid=106 off
			amixer -c0 -q cset numid=97 off
			amixer -c0 -q cset numid=4 16
			if echo start > "$ctl"; then log "graphs up"; else log "start failed"; fi
			on=1
		fi
	elif [ $on = 1 ]; then
		echo stop > "$ctl" 2>/dev/null
		log "graphs down"
		on=0
	fi
	sleep 1
done
