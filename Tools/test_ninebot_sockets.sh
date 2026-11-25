#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
ninebot_socket_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/carwithin-ninebot-sockets.XXXXXX")"
trap 'rm -rf "$ninebot_socket_test_dir"' EXIT
"${SWIFTC:-swiftc}" -swift-version 5 "$project_root/App/NinebotUDPSocket.swift" \
    "$project_root/Tools/NinebotSocketSmoke.swift" -o "$ninebot_socket_test_dir/socket-tests"
"$ninebot_socket_test_dir/socket-tests"
