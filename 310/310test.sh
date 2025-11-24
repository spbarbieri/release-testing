#!/bin/bash

# Fetch the list of top CPU consumers using 'top' command
# -b: batch mode, -n 1: run once, -o %CPU: sort by CPU usage
# head -n 10: display top 10 processes
top -b -n 1 -o %CPU | head -n 10