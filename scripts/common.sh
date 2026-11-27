#!/usr/bin/env bash
# Shared helpers sourced by the other scripts (not meant to be run directly).

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPOSITORY_ROOT/config/team.conf"
ARTIFACTS_DIR="$REPOSITORY_ROOT/artifacts"
BUILD_DIR="$REPOSITORY_ROOT/build"
SENDER_BINARY="$BUILD_DIR/monitor_sender"

log_info()  { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

load_team_config() {
    if [[ ! -r "$CONFIG_FILE" ]]; then
        log_error "configuration file $CONFIG_FILE is missing or unreadable"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    local required_key
    for required_key in TEAM_MEMBERS PATTERN WIDTH HEIGHT FPS PORT OVERLAY_POSITION CONTAINER NETWORK_CODEC RUNTIME; do
        if [[ -z "${!required_key:-}" ]]; then
            log_error "$required_key is not defined in $CONFIG_FILE"
            return 1
        fi
    done
    case "$CONTAINER" in
        matroska) RECORDING_EXTENSION=mkv; RECORDING_MUXER=matroskamux ;;
        mpegts)   RECORDING_EXTENSION=ts;  RECORDING_MUXER=mpegtsmux ;;
        *) log_error "unsupported CONTAINER=$CONTAINER (matroska or mpegts)"; return 1 ;;
    esac
    case "$NETWORK_CODEC" in
        h264|jpeg) ;;
        *) log_error "unsupported NETWORK_CODEC=$NETWORK_CODEC (h264 or jpeg)"; return 1 ;;
    esac
}

# Receiver-side RTP caps: udpsrc cannot guess them from raw UDP packets.
rtp_caps_for_codec() {
    case "$1" in
        h264) echo "application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ;;
        jpeg) echo "application/x-rtp,media=video,clock-rate=90000,encoding-name=JPEG,payload=26" ;;
    esac
}
