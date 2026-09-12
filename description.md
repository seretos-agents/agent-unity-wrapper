# agent-unity-wrapper

Pairs the external Unity MCP server with a skill so Claude can drive the Unity editor — inspecting scenes, GameObjects, and assets — through structured MCP operations instead of guessing project state.

## Key features

<!-- Finalize these once the Unity MCP is wired and its tool surface is known. -->

- **Wraps an existing Unity MCP server** — no separate binary to build; the skill teaches Claude when and how to reach for the MCP's tools.
- **Editor-aware operations** — inspect and act on scenes, GameObjects, components, and assets through structured calls instead of free-text guessing.
- **Dual-host** — installs on both Claude Code and Codex from a single marketplace release.
