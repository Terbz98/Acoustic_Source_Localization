#!/bin/bash
# Double-click this file in Finder to start the live sound tracker.
# It opens in the Terminal app, which has the Camera and Microphone permission.
cd "$(dirname "$0")"
.venv/bin/python live_tracker.py "$@"
echo
read -p "Tracker stopped. Press Enter to close this window..."
