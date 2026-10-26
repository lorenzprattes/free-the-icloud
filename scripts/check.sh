#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --disable-sandbox -c release CoreChecks
