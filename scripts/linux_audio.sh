#!/usr/bin/env bash
# Linux equivalent of BlackHole: PulseAudio null sinks. Idempotent; run before Zoom starts.
#   DevinMic    sink   -> play TTS here (paplay --device=devin_mic x.wav, or PULSE_SINK=devin_mic espeak-ng ...)
#   DevinMicSrc source -> Zoom microphone (a remap of devin_mic.monitor; Zoom ignores raw *.monitor sources)
#   ZoomOut     sink   -> Zoom speaker; capture it with parecord --device=zoom_out.monitor
# Needs: sudo apt-get install -y pulseaudio pulseaudio-utils
set -euo pipefail

pulseaudio --check 2>/dev/null || pulseaudio --start --exit-idle-time=-1

have() { pactl list short "$1" | awk '{print $2}' | grep -qx "$2"; }

have sinks devin_mic || pactl load-module module-null-sink sink_name=devin_mic \
  sink_properties=device.description=DevinMic >/dev/null
have sinks zoom_out || pactl load-module module-null-sink sink_name=zoom_out \
  sink_properties=device.description=ZoomOut >/dev/null
have sources devin_mic_src || pactl load-module module-remap-source master=devin_mic.monitor \
  source_name=devin_mic_src source_properties=device.description=DevinMicSrc >/dev/null

pactl set-default-sink devin_mic
pactl set-default-source devin_mic_src
pactl list short sinks
pactl list short sources
