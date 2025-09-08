#!/bin/bash
set -e

# Script: Initialize Radius workspace and environment
# This script creates the default group, workspace, and environment

echo "Initializing Radius workspace and environment..."
rad group create default
rad workspace create kubernetes default --group default --force
rad group switch default
rad env create default
rad env switch default

echo "✅ Workspace and environment initialization completed successfully"