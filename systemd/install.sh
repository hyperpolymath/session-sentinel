#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Session Sentinel — Install script
# Installs the systemd service, default config, and binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Session Sentinel Installer ==="
echo ""

# ── 1. Create directories ───────────────────────────────────────────────
mkdir -p ~/.config/session-sentinel
mkdir -p ~/.local/share/session-sentinel
mkdir -p ~/.config/systemd/user
mkdir -p /tmp/session-sentinel

# ── 2. Install default config (don't overwrite existing) ────────────────
if [ ! -f ~/.config/session-sentinel/config.toml ]; then
    cp "$REPO_DIR/config/session-sentinel.toml" ~/.config/session-sentinel/config.toml
    echo "Installed default config to ~/.config/session-sentinel/config.toml"
else
    echo "Config already exists at ~/.config/session-sentinel/config.toml (preserved)"
fi

# ── 3. Install systemd service ──────────────────────────────────────────
cp "$SCRIPT_DIR/session-sentinel.service" ~/.config/systemd/user/
echo "Installed systemd service"

# ── 4. Replace old claude-hygiene timer (superseded) ────────────────────
if systemctl --user is-active claude-hygiene.timer &>/dev/null; then
    echo "Disabling old claude-hygiene.timer (superseded by session-sentinel)..."
    systemctl --user disable --now claude-hygiene.timer
fi

# ── 5. Reload and enable ────────────────────────────────────────────────
systemctl --user daemon-reload
systemctl --user enable session-sentinel.service
echo ""
echo "Installed! Start with:"
echo "  systemctl --user start session-sentinel.service"
echo ""
echo "Check status:"
echo "  systemctl --user status session-sentinel.service"
echo ""
echo "View logs:"
echo "  journalctl --user -u session-sentinel -f"
