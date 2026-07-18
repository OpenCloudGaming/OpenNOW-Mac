#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT=${1:-"$SCRIPT_DIR/pam-auth-helper"}

cc -O2 -Wall -Wextra -o "$OUTPUT" "$SCRIPT_DIR/pam-auth-helper.c" -lpam
echo "$OUTPUT"
