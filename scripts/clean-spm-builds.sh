#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

find "$repo_root" \
    -path "$repo_root/.git" -prune -o \
    -type d -name .build -prune -print -exec rm -rf {} +
