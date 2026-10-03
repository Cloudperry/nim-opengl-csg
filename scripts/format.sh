#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

find . -type f \( -name "*.nim" -o -name "*.nims" -o -name "*.nimble" \) \
  -print0 | xargs -0 -r nph "$@"
