#!/usr/bin/env bash
# RTP/UDP receiver.
# Usage: ./scripts/receiver.sh [display|test]
#   display (default): decode and show the received video in a window
#   test             : decode and send frames to fakesink; every decoded frame
#                      is printed as a "last-message = chain" line on stdout so
#                      reception can be checked without looking at a window.
# Stop with Ctrl-C (or SIGINT).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_team_config

receiver_mode="${1:-display}"
rtp_caps="$(rtp_caps_for_codec "$NETWORK_CODEC")"

if [[ "$NETWORK_CODEC" == h264 ]]; then
    decode_chain="rtph264depay ! h264parse ! avdec_h264"
else
    decode_chain="rtpjpegdepay ! jpegdec"
fi

case "$receiver_mode" in
    display) output_sink="autovideosink sync=false"; verbose_flag="" ;;
    test)    output_sink="fakesink name=received_frames silent=false sync=false"; verbose_flag="-v" ;;
    *) log_error "unknown mode '$receiver_mode' (use display or test)"; exit 1 ;;
esac

log_info "Receiving RTP/$NETWORK_CODEC on UDP port $PORT (mode: $receiver_mode)"
# shellcheck disable=SC2086
exec gst-launch-1.0 $verbose_flag -e \
    udpsrc port="$PORT" caps="$rtp_caps" \
    ! rtpjitterbuffer latency=100 \
    ! $decode_chain \
    ! videoconvert \
    ! $output_sink
