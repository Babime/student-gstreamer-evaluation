#!/usr/bin/env bash
# Automated functional verification of the video monitoring system.
# Runs the receiver (test mode) and the native sender (headless, finite
# duration), then checks RTP reception, EOS handling and the recording.
# Outputs: artifacts/{verification.log,verification-summary.txt,sender.log,
#          receiver.log,test-recording.<ext>}
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$REPOSITORY_ROOT" || exit 1

VERIFY_DURATION_SECONDS=15
SENDER_TIMEOUT_SECONDS=$((VERIFY_DURATION_SECONDS + 20))
RECEIVER_TIMEOUT_SECONDS=$((VERIFY_DURATION_SECONDS + 40))

mkdir -p "$ARTIFACTS_DIR"
VERIFICATION_LOG="$ARTIFACTS_DIR/verification.log"
SUMMARY_FILE="$ARTIFACTS_DIR/verification-summary.txt"
SENDER_LOG="$ARTIFACTS_DIR/sender.log"
RECEIVER_LOG="$ARTIFACTS_DIR/receiver.log"
DOT_DIR="$ARTIFACTS_DIR/dot"
rm -f "$VERIFICATION_LOG" "$SUMMARY_FILE" "$SENDER_LOG" "$RECEIVER_LOG"
rm -rf "$DOT_DIR"
exec > >(tee -a "$VERIFICATION_LOG") 2>&1

CHECK_NAMES=(DEPENDENCIES CONFIG REQUIRED_FILES BUILD HELP_OPTION INVALID_ARGUMENTS
             SENDER_START RECEIVER_START RTP_RECEPTION EOS_HANDLING DYNAMIC_PROPERTY
             RECORDING_CREATED RECORDING_DECODABLE CLEAN_TERMINATION)
declare -A CHECK_RESULT
for check_name in "${CHECK_NAMES[@]}"; do CHECK_RESULT[$check_name]=FAIL; done

sender_pid=""
receiver_pid=""

pass() { CHECK_RESULT[$1]=PASS; echo "[PASS] $1${2:+ - $2}"; }
fail() { CHECK_RESULT[$1]=FAIL; echo "[FAIL] $1${2:+ - $2}"; }

# Stops a process started by this script: SIGINT first (clean EOS), SIGKILL as a last resort.
stop_process() {
    local process_pid="$1" process_label="$2" waited=0
    [[ -z "$process_pid" ]] && return 0
    kill -0 "$process_pid" 2>/dev/null || { wait "$process_pid" 2>/dev/null; return 0; }
    log_info "Stopping $process_label (pid $process_pid) with SIGINT"
    kill -INT "$process_pid" 2>/dev/null
    while kill -0 "$process_pid" 2>/dev/null && [[ $waited -lt 10 ]]; do sleep 1; waited=$((waited + 1)); done
    if kill -0 "$process_pid" 2>/dev/null; then
        log_error "$process_label did not stop after SIGINT, sending SIGKILL"
        kill -KILL "$process_pid" 2>/dev/null
    fi
    wait "$process_pid" 2>/dev/null
}

cleanup_processes() {
    stop_process "$sender_pid" "sender"
    stop_process "$receiver_pid" "receiver"
}
trap cleanup_processes EXIT
trap 'log_error "verification interrupted"; exit 130' INT TERM

write_summary() {
    local overall=PASS
    : >"$SUMMARY_FILE"
    for check_name in "${CHECK_NAMES[@]}"; do
        echo "$check_name=${CHECK_RESULT[$check_name]}" >>"$SUMMARY_FILE"
        [[ "${CHECK_RESULT[$check_name]}" == PASS ]] || overall=FAIL
    done
    echo "OVERALL=$overall" >>"$SUMMARY_FILE"
    echo
    echo "===== Verification summary ($SUMMARY_FILE) ====="
    cat "$SUMMARY_FILE"
    [[ "$overall" == PASS ]]
}

wait_for_log_line() {  # file pattern timeout_seconds
    local waited=0
    while [[ $waited -lt $3 ]]; do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 1; waited=$((waited + 1))
    done
    return 1
}

# ---------------------------------------------------------------- 1. dependencies
log_info "Step 1: checking required commands and GStreamer elements"
missing_items=()
for required_command in gst-launch-1.0 gst-inspect-1.0 gst-discoverer-1.0 cmake timeout grep awk; do
    command -v "$required_command" >/dev/null 2>&1 || missing_items+=("command:$required_command")
done

# ---------------------------------------------------------------- 2. configuration
log_info "Step 2: reading $CONFIG_FILE"
if load_team_config; then
    pass CONFIG "$PATTERN ${WIDTH}x${HEIGHT}@${FPS}fps port=$PORT container=$CONTAINER codec=$NETWORK_CODEC"
    RECORDING_FILE="$ARTIFACTS_DIR/test-recording.$RECORDING_EXTENSION"
    required_elements=(videotestsrc videoconvert videobalance textoverlay timeoverlay tee queue
                       fakesink autovideosink x264enc h264parse "$RECORDING_MUXER" filesink
                       udpsink udpsrc rtpjitterbuffer filesrc decodebin)
    if [[ "$NETWORK_CODEC" == h264 ]]; then
        required_elements+=(rtph264pay rtph264depay avdec_h264)
    else
        required_elements+=(jpegenc rtpjpegpay rtpjpegdepay jpegdec)
    fi
    if command -v gst-inspect-1.0 >/dev/null 2>&1; then
        for element_name in "${required_elements[@]}"; do
            gst-inspect-1.0 --exists "$element_name" || missing_items+=("element:$element_name")
        done
    fi
else
    fail CONFIG "cannot read configuration"
    RECORDING_FILE=""
fi
if [[ ${#missing_items[@]} -eq 0 && -n "$RECORDING_FILE" ]]; then
    pass DEPENDENCIES
else
    fail DEPENDENCIES "missing: ${missing_items[*]:-unchecked (no configuration)}"
fi

# ---------------------------------------------------------------- 3. files
log_info "Step 3: checking source and documentation files"
missing_files=()
for required_file in README.md architecture.md CONTRIBUTIONS.md debug-report.md \
                     experiment.md CMakeLists.txt src/monitor_sender.c config/team.conf \
                     scripts/build.sh scripts/clean.sh scripts/sender.sh scripts/receiver.sh \
                     scripts/play-recording.sh scripts/run-experiment.sh scripts/verify.sh \
                     evidence/pipeline.png evidence/measurements.csv; do
    [[ -s "$required_file" ]] || missing_files+=("$required_file")
done
if [[ ${#missing_files[@]} -eq 0 ]]; then pass REQUIRED_FILES; else fail REQUIRED_FILES "missing: ${missing_files[*]}"; fi

# ---------------------------------------------------------------- build
if [[ ! -x "$SENDER_BINARY" ]]; then
    log_info "monitor_sender not built yet, running scripts/build.sh"
    "$REPOSITORY_ROOT/scripts/build.sh"
fi
if [[ -x "$SENDER_BINARY" ]]; then pass BUILD "$SENDER_BINARY"; else fail BUILD "$SENDER_BINARY not found"; fi

# ---------------------------------------------------------------- 4. --help
log_info "Step 4: monitor_sender --help"
if [[ -x "$SENDER_BINARY" ]] && help_output="$(timeout 10s "$SENDER_BINARY" --help 2>&1)" \
   && grep -q "Usage" <<<"$help_output"; then
    pass HELP_OPTION
else
    fail HELP_OPTION "--help failed or printed no usage"
fi

# ---------------------------------------------------------------- 5. invalid arguments
log_info "Step 5: invalid arguments must be rejected"
valid_arguments=(--pattern smpte --width 640 --height 360 --fps 10 --port 5999 --output "$ARTIFACTS_DIR/invalid.mkv")
invalid_cases=(
    "no arguments|"
    "missing --output|--pattern smpte --width 640 --height 360 --fps 10 --port 5999"
    "non-numeric width|--pattern smpte --width abc --height 360 --fps 10 --port 5999 --output $ARTIFACTS_DIR/invalid.mkv"
    "zero fps|--pattern smpte --width 640 --height 360 --fps 0 --port 5999 --output $ARTIFACTS_DIR/invalid.mkv"
    "port out of range|--pattern smpte --width 640 --height 360 --fps 10 --port 99999 --output $ARTIFACTS_DIR/invalid.mkv"
    "unsupported pattern|--pattern rainbow --width 640 --height 360 --fps 10 --port 5999 --output $ARTIFACTS_DIR/invalid.mkv"
    "unsupported file format|--pattern smpte --width 640 --height 360 --fps 10 --port 5999 --output $ARTIFACTS_DIR/invalid.avi"
    "unknown option|${valid_arguments[*]} --bogus 1"
)
invalid_failures=0
if [[ -x "$SENDER_BINARY" ]]; then
    for invalid_case in "${invalid_cases[@]}"; do
        case_label="${invalid_case%%|*}"
        read -r -a case_arguments <<<"${invalid_case#*|}"
        timeout 10s "$SENDER_BINARY" "${case_arguments[@]}" >/dev/null 2>&1
        case_status=$?
        if [[ $case_status -ne 0 && $case_status -ne 124 ]]; then
            echo "  rejected ($case_status): $case_label"
        else
            echo "  NOT rejected ($case_status): $case_label"; invalid_failures=$((invalid_failures + 1))
        fi
    done
    rm -f "$ARTIFACTS_DIR/invalid.mkv"
    if [[ $invalid_failures -eq 0 ]]; then pass INVALID_ARGUMENTS; else fail INVALID_ARGUMENTS "$invalid_failures case(s) accepted"; fi
else
    fail INVALID_ARGUMENTS "no binary"
fi

# ---------------------------------------------------------------- 6-8. receiver + sender run
if [[ "${CHECK_RESULT[BUILD]}" == PASS && "${CHECK_RESULT[CONFIG]}" == PASS && "${CHECK_RESULT[DEPENDENCIES]}" == PASS ]]; then
    rm -f "$RECORDING_FILE"

    log_info "Step 6: starting receiver in test mode (log: $RECEIVER_LOG)"
    timeout --signal=INT --kill-after=5s "${RECEIVER_TIMEOUT_SECONDS}s" \
        "$REPOSITORY_ROOT/scripts/receiver.sh" test >"$RECEIVER_LOG" 2>&1 &
    receiver_pid=$!
    if wait_for_log_line "$RECEIVER_LOG" "Setting pipeline to PLAYING" 10 && kill -0 "$receiver_pid" 2>/dev/null; then
        pass RECEIVER_START
    else
        fail RECEIVER_START "receiver did not reach PLAYING"
    fi

    log_info "Step 7-8: starting sender headless for ${VERIFY_DURATION_SECONDS}s (log: $SENDER_LOG)"
    mkdir -p "$DOT_DIR"
    sender_start_time=$(date +%s)
    GST_DEBUG_DUMP_DOT_DIR="$DOT_DIR" timeout --signal=INT --kill-after=10s "${SENDER_TIMEOUT_SECONDS}s" \
        "$SENDER_BINARY" --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --fps "$FPS" \
        --port "$PORT" --codec "$NETWORK_CODEC" --overlay-position "$OVERLAY_POSITION" \
        --team "$TEAM_MEMBERS" --output "$RECORDING_FILE" \
        --duration "$VERIFY_DURATION_SECONDS" --headless >"$SENDER_LOG" 2>&1 &
    sender_pid=$!
    if wait_for_log_line "$SENDER_LOG" "Pipeline is PLAYING" 10; then
        pass SENDER_START
    else
        fail SENDER_START "sender did not reach PLAYING"
    fi

    wait "$sender_pid"
    sender_status=$?
    sender_pid=""
    log_info "Sender exited with status $sender_status after $(( $(date +%s) - sender_start_time ))s"
    [[ $sender_status -eq 124 || $sender_status -eq 137 ]] && log_error "sender TIMED OUT after ${SENDER_TIMEOUT_SECONDS}s"

    sleep 1
    stop_process "$receiver_pid" "receiver"
    receiver_pid=""

    # 9. network data actually decoded by the receiver
    received_frame_count=$(grep -c "last-message = chain" "$RECEIVER_LOG" || true)
    minimum_frame_count=$((FPS * 5))
    if [[ $received_frame_count -ge $minimum_frame_count ]]; then
        pass RTP_RECEPTION "$received_frame_count decoded frames received (minimum $minimum_frame_count)"
    else
        fail RTP_RECEPTION "$received_frame_count decoded frames received (minimum $minimum_frame_count)"
    fi

    # 14. EOS processed by the sender
    if grep -q "Sending EOS to the pipeline (duration elapsed)" "$SENDER_LOG" && grep -q "EOS received" "$SENDER_LOG"; then
        pass EOS_HANDLING
    else
        fail EOS_HANDLING "no EOS message in sender log"
    fi

    dynamic_change_count=$(grep -c "DYNAMIC_PROPERTY element=video_balance" "$SENDER_LOG" || true)
    if [[ $dynamic_change_count -ge 2 ]]; then
        pass DYNAMIC_PROPERTY "$dynamic_change_count logged changes"
    else
        fail DYNAMIC_PROPERTY "$dynamic_change_count logged changes (expected >= 2)"
    fi

    # 10-11. recording exists and is non-empty
    if [[ -s "$RECORDING_FILE" ]]; then
        pass RECORDING_CREATED "$(stat -c %s "$RECORDING_FILE") bytes"
    else
        fail RECORDING_CREATED "$RECORDING_FILE missing or empty"
    fi

    # 12. recording can be discovered and fully decoded
    if [[ -s "$RECORDING_FILE" ]]; then
        discoverer_output="$(timeout 30s gst-discoverer-1.0 "$RECORDING_FILE" 2>&1)"
        discoverer_status=$?
        echo "$discoverer_output" | sed 's/^/  discoverer: /'
        duration_seconds=$(awk '/Duration:/ { split($2, t, ":"); print int(t[1]*3600 + t[2]*60 + t[3]); exit }' <<<"$discoverer_output")
        timeout 60s gst-launch-1.0 -q filesrc location="$RECORDING_FILE" ! decodebin ! fakesink >/dev/null 2>&1
        decode_status=$?
        if [[ $discoverer_status -eq 0 && $decode_status -eq 0 ]] && grep -qi "video" <<<"$discoverer_output" \
           && [[ ${duration_seconds:-0} -ge $((VERIFY_DURATION_SECONDS / 2)) ]]; then
            pass RECORDING_DECODABLE "duration ${duration_seconds}s, full decode OK"
        else
            fail RECORDING_DECODABLE "discoverer=$discoverer_status decode=$decode_status duration=${duration_seconds:-?}s"
        fi
    else
        fail RECORDING_DECODABLE "no recording"
    fi

    # 13. clean termination: exit 0, pipeline set to NULL, no process left behind
    if [[ $sender_status -eq 0 ]] && grep -q "Stopping pipeline (state NULL)" "$SENDER_LOG" \
       && ! pgrep -f "$SENDER_BINARY" >/dev/null && ! pgrep -f "udpsrc port=$PORT" >/dev/null; then
        pass CLEAN_TERMINATION "exit status 0, no remaining process"
    else
        fail CLEAN_TERMINATION "sender status $sender_status or process still running"
    fi
else
    log_error "skipping runtime tests: build, configuration or dependencies failed"
fi

# ---------------------------------------------------------------- 15-16. logs and summary
log_info "Logs saved in $ARTIFACTS_DIR (sender.log, receiver.log, verification.log)"
write_summary
