#!/usr/bin/env bash
# Engineering experiment: H.264/RTP versus JPEG/RTP (only the network codec changes).
# Each configuration runs the native sender headless for EXPERIMENT_DURATION_SECONDS.
# Measured: sender average CPU (pidstat), RTP packets/bytes received on the UDP
# port (raw udpsrc -> fakesink, no decoding), startup time, warnings, recording size.
# Results: evidence/measurements.csv ; raw logs: artifacts/experiment/
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$REPOSITORY_ROOT" || exit 1
load_team_config || exit 1

EXPERIMENT_DURATION_SECONDS="${EXPERIMENT_DURATION_SECONDS:-45}"
EXPERIMENT_DIR="$ARTIFACTS_DIR/experiment"
MEASUREMENTS_FILE="$REPOSITORY_ROOT/evidence/measurements.csv"

for required_command in pidstat gst-launch-1.0 awk; do
    command -v "$required_command" >/dev/null || { log_error "missing command: $required_command (sudo apt install sysstat)"; exit 1; }
done
[[ -x "$SENDER_BINARY" ]] || { log_error "build first: ./scripts/build.sh"; exit 1; }

mkdir -p "$EXPERIMENT_DIR" "$(dirname "$MEASUREMENTS_FILE")"
echo "configuration,network_codec,width,height,fps,duration_s,avg_cpu_percent,rtp_packets,rtp_bytes,rtp_kbit_per_s,startup_ms,warnings,recording_bytes" >"$MEASUREMENTS_FILE"

run_configuration() {
    local configuration_name="$1" network_codec="$2"
    local sender_log="$EXPERIMENT_DIR/$configuration_name-sender.log"
    local counter_log="$EXPERIMENT_DIR/$configuration_name-rtp-counter.log"
    local cpu_log="$EXPERIMENT_DIR/$configuration_name-pidstat.log"
    local recording_file="$EXPERIMENT_DIR/$configuration_name.$RECORDING_EXTENSION"
    local counter_pid sender_pid pidstat_pid start_ns playing_ns startup_ms

    log_info "Configuration $configuration_name: codec=$network_codec, ${EXPERIMENT_DURATION_SECONDS}s"
    rm -f "$recording_file"

    # Raw RTP counter: every UDP packet appears as one "last-message = chain ... (N bytes" line.
    timeout --signal=INT $((EXPERIMENT_DURATION_SECONDS + 30))s \
        gst-launch-1.0 -v udpsrc port="$PORT" ! fakesink silent=false sync=false >"$counter_log" 2>&1 &
    counter_pid=$!
    sleep 2

    start_ns=$(date +%s%N)
    timeout --signal=INT $((EXPERIMENT_DURATION_SECONDS + 20))s \
        "$SENDER_BINARY" --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --fps "$FPS" \
        --port "$PORT" --codec "$network_codec" --overlay-position "$OVERLAY_POSITION" \
        --team "$TEAM_MEMBERS" --output "$recording_file" \
        --duration "$EXPERIMENT_DURATION_SECONDS" --headless >"$sender_log" 2>&1 &
    sender_pid=$!
    while ! grep -q "Pipeline is PLAYING" "$sender_log" 2>/dev/null && kill -0 "$sender_pid" 2>/dev/null; do sleep 0.02; done
    playing_ns=$(date +%s%N)
    startup_ms=$(( (playing_ns - start_ns) / 1000000 ))

    # sender_pid is the "timeout" wrapper: measure its child, the real monitor_sender.
    local measured_pid
    measured_pid=$(pgrep -P "$sender_pid" -x monitor_sender || echo "$sender_pid")
    LC_ALL=C pidstat -h -u -p "$measured_pid" 1 >"$cpu_log" 2>&1 &
    pidstat_pid=$!
    wait "$sender_pid"
    kill -INT "$pidstat_pid" 2>/dev/null; wait "$pidstat_pid" 2>/dev/null
    sleep 1
    kill -INT "$counter_pid" 2>/dev/null; wait "$counter_pid" 2>/dev/null

    local avg_cpu rtp_packets rtp_bytes rtp_kbps warnings recording_bytes
    # pidstat -h: one data line per second, %CPU is the 8th column.
    avg_cpu=$(awk '$1 ~ /^[0-9:]+$/ && $NF == "monitor_sender" { sum += $8; n++ } END { if (n) printf "%.1f", sum / n; else print "NA" }' "$cpu_log")
    rtp_packets=$(grep -c "last-message = chain" "$counter_log" || true)
    rtp_bytes=$(grep -o "([0-9]* bytes" "$counter_log" | awk '{ gsub("\\(", "", $1); sum += $1 } END { print sum + 0 }')
    rtp_kbps=$(awk -v b="$rtp_bytes" -v d="$EXPERIMENT_DURATION_SECONDS" 'BEGIN { printf "%.1f", b * 8 / d / 1000 }')
    warnings=$(grep -c "^WARNING" "$sender_log" || true)
    recording_bytes=$(stat -c %s "$recording_file" 2>/dev/null || echo 0)

    echo "$configuration_name,$network_codec,$WIDTH,$HEIGHT,$FPS,$EXPERIMENT_DURATION_SECONDS,$avg_cpu,$rtp_packets,$rtp_bytes,$rtp_kbps,$startup_ms,$warnings,$recording_bytes" >>"$MEASUREMENTS_FILE"
    log_info "  cpu=${avg_cpu}% packets=$rtp_packets bytes=$rtp_bytes rate=${rtp_kbps}kbit/s startup=${startup_ms}ms warnings=$warnings"
}

run_configuration A-h264 h264
run_configuration B-jpeg jpeg

log_info "Results written to $MEASUREMENTS_FILE"
cat "$MEASUREMENTS_FILE"
