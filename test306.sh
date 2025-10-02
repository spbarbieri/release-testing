#!/bin/bash
# This script uses podman top to monitor real-time CPU usage of a container.
# Replace 'container_name' with the actual name of your container.

podman top --format "{{.CpuPercent}}" container_name

while true; do
  sleep 2
  podman top --format "{{.CpuPercent}}" container_name
done