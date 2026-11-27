#!/usr/bin/env bash
# Removes every generated file (build/ and artifacts/).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log_info "Removing $BUILD_DIR and $ARTIFACTS_DIR"
rm -rf "$BUILD_DIR" "$ARTIFACTS_DIR"
log_info "Clean done"
