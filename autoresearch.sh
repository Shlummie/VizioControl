#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

export SWIFT_DETERMINISTIC_HASHING=1
swift build --configuration release --product BurstButtonLatencyBenchmark --quiet
"$ROOT/.build/release/BurstButtonLatencyBenchmark"
