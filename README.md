# Hold My Mouse

**Talk to your Mac. It does the rest.**

A voice-first computer use agent that lets you control your Mac through natural conversation. No clicking, no typing — just speak.

[holdmymouse.app](https://holdmymouse.app)

---

## Install

### Download (recommended)

1. Download `CUA.dmg` from [Releases](https://github.com/adiarora7/cua/releases)
2. Open the DMG and drag **CUA** to Applications
3. Right-click CUA.app → **Open** (required first time — app is unsigned)
4. Grant permissions when prompted: **Screen Recording**, **Accessibility**, **Microphone**

### Build from source

Requires macOS 14+ and Swift 6.0.

```bash
git clone https://github.com/adiarora7/cua.git
cd cua
swift build -c release
.build/release/CUA --voice
```

## Usage

```bash
# Voice mode (talk to your Mac)
CUA --voice

# Text mode (type commands)
CUA
```

A demo API key is included with limited usage. To use your own:

```bash
export ANTHROPIC_API_KEY=your_key_here
```

Or create a `.env` file in the same directory:

```
ANTHROPIC_API_KEY=your_key_here
```

## How it works

Two-model architecture powered by Claude:

1. **Opus plans** — breaks your request into steps, asks clarifying questions if needed
2. **Sonnet executes** — takes screenshots, moves the mouse, clicks, types
3. **Opus evaluates** — checks each step succeeded, replans if something went wrong

You speak naturally ("book me a flight to SF next Friday", "find that PDF I downloaded yesterday"), and the agent figures out the clicks and keystrokes.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- Permissions: Screen Recording, Accessibility, Microphone, Speech Recognition

## Built with

- Swift + AppKit (zero external dependencies aside from WhisperKit for on-device STT)
- Claude Opus 4.6 + Claude Sonnet for the two-model agent loop
- Anthropic tool use API with custom computer control tools
- CGEvent for mouse/keyboard automation
- Core Graphics for screen capture

Built for the [Anthropic Claude Code Hackathon](https://claude.ai/code).
