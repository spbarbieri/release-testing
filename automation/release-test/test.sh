#!/bin/bash
# This script will recursively find all files with the extension '.txt' in the current directory and its subdirectories,
# and then print the contents of those files to the console.
find . -type f -name "*.txt" -exec cat {} \;