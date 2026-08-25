#!/usr/bin/env bash
set -euo pipefail

export PATH=/ucrt64/bin:/usr/bin:$PATH
cd "$(dirname "$0")"
exec make "$@"
