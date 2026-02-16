# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

Voice-first Computer Use Agent for the Anthropic Claude Code Virtual Hackathon (deadline Feb 16, 3 PM EST). Solo builder. Goal: make computer use accessible to non-technical users through natural conversation. See `HACKATHON.md` for full context, judging criteria (Demo 30%, Opus Use 25%, Impact 25%, Depth 20%), and architecture direction.

## Build & Run

```bash
swift build                                    # Build (output: .build/debug/CUA)
.build/debug/CUA                               # Text mode (REPL)
.build/debug/CUA --voice                       # Voice mode (STT/TTS)
```

Requires `ANTHROPIC_API_KEY` in `.env` or environment. macOS 14.0+, Swift 6.0. No external dependencies — pure Apple frameworks.

macOS permissions needed: Screen Recording, Accessibility (for CGEvent), Microphone, Speech Recognition.

No test suite exists yet.

## Architecture

Two-model computer use agent: **Opus plans, Sonnet executes, Opus evaluates**.

```
Voice/Text Input → [Opus] planPipeline() → WorkBlocks + Clarifications
                                              ↓
                   executePipeline() ← blocks run sequentially
                        ↓
                   [Sonnet] runActionLoop() → tool_use actions → ActionExecutor
                        ↓                         ↓
                   [Opus] evaluateBlock()    ScreenCapture (screenshot after each batch)
                        ↓
                   ok → next block | failed → [Opus] replan() (max 2 replans)
```

### Key files (all in `Sources/CUA/`)

- **main.swift** — Entry point, `planAndExecute()` orchestration, `executePipeline()` loop, `runActionLoop()` for Sonnet, `ClarificationBridge` for parallel voice Q&A, voice/text mode runners
- **Orchestrator.swift** — Opus calls: `planPipeline()` returns `PipelineResponse` (blocks + clarifications), `evaluateBlock()` checks expected outcome against screenshot, `replan()` / `replanWithClarification()` for recovery
- **Models.swift** — Anthropic API types (`APIRequest`, `Message`, `ContentBlock`, `ComputerAction` enum), tool definitions. `ComputerAction` is parsed from Sonnet's `tool_use` JSON
- **AnthropicClient.swift** — HTTP client for `api.anthropic.com/v1/messages`. Supports `.opus` and `.sonnet` model selection. Tools are optional (Opus gets none)
- **ActionExecutor.swift** — CGEvent-based mouse/keyboard. Type uses pasteboard+Cmd+V. Key name → virtual keycode mapping
- **ScreenCapture.swift** — `screenshotBase64()` captures at native resolution, downscales to logical coords, returns JPEG base64. Hides overlay during capture
- **VoiceManager.swift** — `listen()` streams STT via SFSpeechRecognizer (2s silence timeout), `speak()`/`speakAndWait()` for TTS. 600ms settle buffer prevents echo
- **OverlayManager.swift** — Floating CALayer pill showing state (listening/thinking/acting/speaking). Hidden from screenshots
- **Logger.swift** — Timestamped session logs to `./logs/session_*.log`

### Execution flow details

`planAndExecute()` is the main entry point for both modes. It:
1. Calls Opus `planPipeline()` with screenshot + user request
2. If clarifications exist, drops the last block (depends on answer) and starts voice Q&A in parallel
3. Runs `executePipeline()` on the safe blocks
4. After blocks finish, waits for clarification answer, calls `replanWithClarification()`, executes remaining work

`runActionLoop()` drives Sonnet for a single block:
- Maintains conversation history (screenshot + directive → Sonnet response → actions → new screenshot → loop)
- Trims to 3 most recent screenshots to bound context size
- Repeat-click detection: warns Sonnet after 2+ clicks near same spot, directs to keyboard-only approach

### Coordinate system

Logical pixels throughout. ScreenCapture reports logical dimensions to API. CGEvent uses logical points. No conversion needed.

### Concurrency model

`NSApplication.shared.run()` owns the main thread (required for AppKit overlay). All async work runs in Swift Tasks. `ClarificationBridge` uses NSLock + CheckedContinuation for thread-safe voice↔action communication. Voice loop runs in main `while true`, action tasks run as detached Tasks that can be cancelled by new voice commands.

## Session logs

Logs at `./logs/session_YYYY-MM-DD_HH-mm-ss.log` capture API requests/responses, block directives, evaluations, actions, timing, and errors. Primary debugging tool.

## Using Codex Spark for Fast Implementation

For large refactors or multi-step implementation plans, use OpenAI's Codex Spark model via the `codex` CLI as a fast executor. Spark runs at 1000+ tokens/sec — much faster than burning Sonnet/Opus tokens for mechanical code changes.

**Workflow**: Opus plans, Spark implements, Opus evaluates. Sequential steps (not parallel) — safer and easier to manage.

```bash
# Execute a single step via Spark
codex exec "step directive here" -m gpt-5.3-codex-spark --full-auto --skip-git-repo-check

# Flags:
#   -m gpt-5.3-codex-spark   — fast Spark model (1000+ tok/s, 128k context, text-only)
#   --full-auto               — no approval prompts, sandboxed to workspace writes
#   --skip-git-repo-check     — needed if not in a git repo
#   --ephemeral               — don't persist session files (optional)
```

**Loop pattern** (Claude drives this natively via Bash tool, no script needed):
1. Read the plan
2. Run `codex exec "step N directive" -m gpt-5.3-codex-spark --full-auto` via Bash
3. Read changed files, evaluate the diff
4. If good → next step. If bad → adjust directive and re-run
5. Repeat until plan is complete

## Daily development notes

`claudes-daily-notes/YYYY-MM-DD.md` — cumulative log of decisions, bugs fixed, and observations per session.
