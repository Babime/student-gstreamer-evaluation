#!/usr/bin/env bash
# Plays a recording produced by the sender.
# Usage: ./scripts/play-recording.sh [FILE]   (default: artifacts/test-recording.<ext>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_team_config

recording_file="${1:-$ARTIFACTS_DIR/test-recording.$RECORDING_EXTENSION}"
if [[ ! -s "$recording_file" ]]; then
    log_error "recording '$recording_file' does not exist or is empty (run ./scripts/verify.sh first)"
    exit 1
fi

log_info "Playing $recording_file"
exec gst-launch-1.0 filesrc location="$recording_file" ! decodebin ! videoconvert ! autovideosink
