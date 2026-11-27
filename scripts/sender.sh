#!/usr/bin/env bash
# Part 1: command-line (gst-launch-1.0) implementation of the sender.
# Usage: ./scripts/sender.sh [--headless] [--output FILE]
# Stop with Ctrl-C: "-e" turns SIGINT into an EOS so the recording is finalized.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_team_config

preview_sink="autovideosink sync=true"
output_file="$ARTIFACTS_DIR/sender-recording.$RECORDING_EXTENSION"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless) preview_sink="fakesink sync=true"; shift ;;
        --output) output_file="$2"; shift 2 ;;
        *) log_error "unknown argument: $1"; exit 1 ;;
    esac
done
mkdir -p "$(dirname "$output_file")"

case "$OVERLAY_POSITION" in
    top-left)     text_valign=top;    text_halign=left;   time_valign=bottom ;;
    top-center)   text_valign=top;    text_halign=center; time_valign=bottom ;;
    bottom-right) text_valign=bottom; text_halign=right;  time_valign=top ;;
    *) log_error "unsupported OVERLAY_POSITION=$OVERLAY_POSITION"; exit 1 ;;
esac

keyframe_interval=$((FPS * 2))
if [[ "$NETWORK_CODEC" == h264 ]]; then
    network_branch="x264enc tune=zerolatency speed-preset=ultrafast key-int-max=$keyframe_interval ! rtph264pay config-interval=1 pt=96"
else
    network_branch="jpegenc quality=85 ! rtpjpegpay pt=26"
fi

log_info "Sending $PATTERN ${WIDTH}x${HEIGHT}@${FPS}fps, RTP/$NETWORK_CODEC to 127.0.0.1:$PORT, recording to $output_file"
# shellcheck disable=SC2086
exec gst-launch-1.0 -e \
    videotestsrc is-live=true pattern="$PATTERN" \
    ! "video/x-raw,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1" \
    ! videoconvert \
    ! videobalance name=video_balance \
    ! textoverlay text="$TEAM_MEMBERS | ${WIDTH}x${HEIGHT} @ $FPS fps" valignment=$text_valign halignment=$text_halign font-desc="Sans 14" shaded-background=true \
    ! timeoverlay valignment=$time_valign halignment=left font-desc="Sans 14" shaded-background=true \
    ! videoconvert \
    ! "video/x-raw,format=I420,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1" \
    ! tee name=split \
    split. ! queue max-size-buffers=5 leaky=downstream ! videoconvert ! $preview_sink \
    split. ! queue ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=$keyframe_interval ! h264parse ! $RECORDING_MUXER ! filesink location="$output_file" \
    split. ! queue ! $network_branch ! udpsink host=127.0.0.1 port="$PORT" sync=false async=false
