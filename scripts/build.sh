#!/usr/bin/env bash
# Configures and compiles monitor_sender into build/. Log: artifacts/build.log
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mkdir -p "$ARTIFACTS_DIR"
build_log="$ARTIFACTS_DIR/build.log"

log_info "Building monitor_sender (log: $build_log)"
{
    cmake -S "$REPOSITORY_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release &&
    cmake --build "$BUILD_DIR" -j"$(nproc)"
} >"$build_log" 2>&1
build_status=$?

if [[ $build_status -ne 0 || ! -x "$SENDER_BINARY" ]]; then
    tail -n 20 "$build_log" >&2
    log_error "build failed (see $build_log)"
    exit 1
fi
log_info "Build succeeded: $SENDER_BINARY"
