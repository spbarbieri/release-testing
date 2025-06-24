#!/bin/bash
# This script will SSH into a VM and log in as root.
# Replace 'vm_ip' with the IP address of your VM.
# Replace 'password' with the root password of your VM.

# SSH command to connect to the VM as root
# -o "StrictHostKeyChecking no" disables strict host key checking
# -o "UserKnownHostsFile=/dev/null" disables known_hosts file
# -o "ConnectTimeout=5" sets the timeout for the connection attempt
# -o "ServerAliveInterval=60" sends a null packet every 60 seconds to prevent the session from timing out
ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile=/dev/null" -o "ConnectTimeout=5" -o "ServerAliveInterval=60" root@vm_ip password