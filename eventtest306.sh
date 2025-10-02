#!/bin/bash
# This script runs 'vmstat 1 5' to monitor system resource usage continuously for five seconds at one-second intervals.
# 'vmstat' provides a snapshot of system statistics including processes, memory, paging, block I/O, traps, and CPU activity.
# The output can be used to identify resource bottlenecks such as high disk I/O wait times or CPU saturation.

# Execute vmstat command with specified parameters
vmstat 1 5

# Optional: To store the output in a file for later analysis
# vmstat 1 5 >> vmstat_output.txt