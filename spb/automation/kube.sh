#!/bin/bash

deployment_name="your_deployment_name"

# Verify the current state of the deployment
kubectl get deployments "$deployment_name" -o yaml