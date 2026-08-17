#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

export SWIFT_DETERMINISTIC_HASHING=1
swift build --configuration release --product ButtonPressLatencyBenchmark --quiet
"$ROOT/.build/release/ButtonPressLatencyBenchmark"
