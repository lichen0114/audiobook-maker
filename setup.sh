#!/bin/bash
#
# AI Audiobook Fast - One-Command Setup
#
# This script installs all dependencies needed to run the audiobook generator.
# It's designed for macOS users who may not have development tools installed.
#
# Usage:
#   ./setup.sh
#

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the macOS setup script
source "$SCRIPT_DIR/scripts/setup-macos.sh"
