#!/bin/bash
# This script uses the 'perf' command to check the system load average over a few minutes.
# It runs 'perf stat' for 120 seconds (2 minutes) and measures the system load.

perf stat -a -- sleep 120