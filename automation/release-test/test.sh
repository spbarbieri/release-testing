#!/bin/bash

# This script checks the node's logs for any error messages or warnings
# It searches for common error and warning patterns in log files

LOG_DIR="/var/log"  # Change this to your node's log directory
LOG_FILES=("node.log" "application.log" "system.log")  # Add your log file names here

# Search for error and warning patterns in each log file
for log_file in "${LOG_FILES[@]}"; do
    log_path="${LOG_DIR}/${log_file}"
    if [ -f "$log_path" ]; then
        echo "Checking $log_path for errors and warnings..."
        echo "Errors found:"
        grep -i "error" "$log_path" || echo "No errors found."
        echo "Warnings found:"
        grep -i "warning" "$log_path" || echo "No warnings found."
        echo "----------------------------------------"
    else
        echo "Log file $log_path not found."
    fi
done