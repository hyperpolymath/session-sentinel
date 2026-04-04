<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# TOPOLOGY.md — session-sentinel

## Purpose

Multi-AI session health monitor with system tray, self-healing, and PanLL panel. Watches storage consumption across multiple AI tools (Claude, Copilot, Ollama, LM Studio, Continue.dev, Cursor, Aider, custom providers), provides real-time health status via KDE system tray, automatically cleans up stale sessions, and exposes fine-grained analysis/control via PanLL panel.

## Module Map

```
session-sentinel/
├── src/                 # Deno TypeScript source
│   ├── health-zones.ts  # Health monitoring zones
│   ├── providers/       # AI provider integrations
│   ├── tray/           # System tray integration (KDE)
│   └── panel/          # PanLL panel interface
├── .machine_readable/   # Checkpoint files
└── .github/workflows/   # CI/CD pipelines
```

## Data Flow

```
[AI Provider Session Data] ──► [Health Monitor] ──► [Tray Icon] ──► [Visual Feedback]
                                       ↓
                              [Storage Scanner] ──► [Auto-Cleanup] ──► [Stale Session Removal]
                                       ↓
                              [PanLL Panel] ──► [Fine-Grained Control]
```

## Health Zones

- **Storage**: Disk usage per provider
- **Session Count**: Active/stale session tracking
- **Cleanup Status**: Last maintenance run timestamp
- **Provider Health**: Integration status per AI tool
