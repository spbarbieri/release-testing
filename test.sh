#!/bin/bash
set -euo pipefail

# Directory to search
TARGET_DIR="/tmp"

# Verify that the target directory exists and is readable
if [[ ! -d "$TARGET_DIR" ]] ; then
    echo "Error: Directory '$TARGET_DIR' does not exist or is not accessible." >&2
    exit 1
fi

# Use GNU find's -printf to emit "<size> <full_path>" lines,
# sort numerically descending, and pick the first line.
# The pipeline is protected against errors from missing files.
largest_entry=$(find "$TARGET_DIR" -type f -printf '%s %p\n' 2>/dev/null \
                | sort -nr \
                | head -n1 || true)

# If nothing was returned, there were no regular files.
if [[ -z "$largest_entry" ]] ; then
    echo "No regular files found in '$TARGET_DIR'."
    exit 0
fi

# Split the result into size and path components.
read -r max_size max_path <<< "$largest_entry"

# Output the result.
echo "Largest file: $max_path"
echo "Size: $max_size bytes"