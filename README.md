# Denver's Linux Setup and Configuration

This repository contains a setup script and relevant config files.

The goal is to allow me to run the script on a fresh install of linux, and have all of my standard development tools and configurations set up automatically.

Sway shortcuts (Windows/Super key):

- Windows+W: WiFi selection.
- Windows+A: audio output selection.
- Windows+P: power menu; choose Power off to shut down.
- Windows+Up/Down: next/previous desktop on the current monitor. Down does nothing on desktop 1. Numbered startup desktops and monitor-specific desktops share the same numbering, and navigation reuses an existing desktop on that monitor.

The workspace helper uses the installer's pinned Zig 0.15.2 compiler. Run `zig build test` in `tools/sway-workspace` with that version to check navigation.
