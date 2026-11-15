#!/bin/sh
U="sudo -u onur env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
rd() {
	printf "  %-14s" "$1"
	amixer -c0 cget numid=$2 2>/dev/null | sed -n 's/.*: values=//p' | head -1
}
dump() {
	rd Speaker 97; rd Receiver 98; rd EAR_RDAC 105; rd AUX_RDAC 106
}

echo "--- HiFi"
dump
echo "--- switch to Voice Call"
$U pactl set-card-profile alsa_card.platform-sound "Voice Call"
sleep 1
dump
echo "--- back to HiFi"
$U pactl set-card-profile alsa_card.platform-sound "HiFi"
sleep 1
dump
echo "--- active"
$U pactl list cards 2>/dev/null | sed -n 's/^[[:space:]]*Active Profile: /ACTIVE: /p'
$U pactl list sinks short
$U pactl list sources short
