#!/bin/bash

# Define the log file path
LOG_FILE="/var/log/node.log"

# Check if the log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file $LOG_FILE does not exist."
    exit 1
fi

# Search for error messages in the log file
echo "Searching for error messages in $LOG_FILE..."
grep -i "error" "$LOG_FILE"

# Search for warning messages in the log file
echo "Searching for warning messages in $LOG_FILE..."
grep -i "warning" "$LOG_FILE"

# Check if no error or warning messages were found
if [ $? -ne 0 ]; then
    echo "No error or warning messages found in $LOG_FILE."
fi