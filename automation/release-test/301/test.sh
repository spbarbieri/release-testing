#!/bin/bash
# This script finds the process that is using the most CPU
# It uses the 'ps' command with the 'aux' options to list all processes
# The 'sort' command sorts the output by percentage of CPU usage
# The 'head' command prints the first line, which is the process using the most CPU
ps aux | sort -nk 4 | head -n 1