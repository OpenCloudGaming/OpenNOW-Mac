#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
warn_gb=${SPM_BUILD_SIZE_WARN_GB:-8}
warn_kb=$((warn_gb * 1024 * 1024))

build_dirs=$(find "$repo_root" \
    -path "$repo_root/.git" -prune -o \
    -type d -name .build -prune -print)

if [ -z "$build_dirs" ]; then
    printf 'No SwiftPM .build directories found.\n'
    exit 0
fi

printf 'SwiftPM .build directories:\n'
printf '%s\n' "$build_dirs" | while IFS= read -r dir; do
    rel=${dir#"$repo_root"/}
    du -sh "$dir" | awk -v rel="$rel" '{ print $1 "\t" rel }'
done

total_kb=$(printf '%s\n' "$build_dirs" | while IFS= read -r dir; do
    du -sk "$dir"
done | awk '{ total += $1 } END { print total + 0 }')

total_gb=$(awk -v kb="$total_kb" 'BEGIN { printf "%.2f", kb / 1024 / 1024 }')

printf '\nTotal SwiftPM generated size: %sG\n' "$total_gb"

sentry_dirs=$(find "$repo_root" \
    -path "$repo_root/.git" -prune -o \
    -path '*/artifacts/sentry-cocoa' -type d -prune -print)

if [ -n "$sentry_dirs" ]; then
    sentry_count=$(printf '%s\n' "$sentry_dirs" | awk 'END { print NR }')
    printf 'Sentry artifact extractions: %s\n' "$sentry_count"
    printf '%s\n' "$sentry_dirs" | while IFS= read -r dir; do
        rel=${dir#"$repo_root"/}
        du -sh "$dir" | awk -v rel="$rel" '{ print $1 "\t" rel }'
    done
else
    printf 'Sentry artifact extractions: 0\n'
fi

if [ "$total_kb" -gt "$warn_kb" ]; then
    printf '\nWARNING: SwiftPM generated files exceed %sG.\n' "$warn_gb" >&2
    printf 'Use scripts/clean-spm-builds.sh, then build and test with --scratch-path .build/shared.\n' >&2
    exit 1
fi
