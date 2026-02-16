# Hold My Mouse

**Talk to your Mac. It does the rest.**

Computer use agents exist, but they're built for developers. For hundreds of millions of non-tech-savvy people, there's no product that replicates having a patient, knowledgeable person sitting next to you helping with your laptop. Hold My Mouse is that product.

Just speak naturally, and the agent plans, acts, and narrates what it's doing on your screen.

[holdmymouse.app](https://holdmymouse.app)

---

## What you can say

- "Help me find cheap flights to Tokyo for next month"
- "Can you fill out this job application for me? My resume is on the desktop"
- "I need to cancel my subscription to that streaming service"
- "Make a nice-looking presentation about climate change"
- "My printer isn't working, can you help me fix it?"
- "Find that email from my landlord and reply saying I'll be late on rent"
- "Help me set up two-factor authentication on my accounts"

No menus. No right-clicking. No "have you tried turning it off and on again." You talk, it does.

## Install

### Download (recommended)

1. Download **CUA.dmg** from [Releases](https://github.com/adiarora7/cua/releases)
2. Open the DMG and drag **CUA** to Applications
3. Right-click CUA.app → **Open** (required first time — app is unsigned)
4. Grant permissions when prompted: **Screen Recording**, **Accessibility**, **Microphone**

A demo API key is bundled — it just works out of the box.

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
# Voice mode — talk to your Mac
CUA --voice

# Text mode — type commands
CUA
```

To use your own API key (optional):

```bash
export ANTHROPIC_API_KEY=your_key_here
```

## How it works

Two-model orchestration powered by Claude:

1. **Opus plans** — breaks your request into work blocks, asks clarifying questions if needed, reasons deeply about multi-step tasks
2. **Sonnet executes** — runs the fast action loop: takes screenshots, moves the mouse, clicks, types, reads the screen
3. **Opus evaluates** — checks each step succeeded against expected outcomes, replans with error recovery if something went wrong

A floating overlay pill shows the agent's current state — listening, thinking, acting, speaking — so you always know what's happening.

## Architecture

Native macOS Swift app. Zero external dependencies (aside from WhisperKit for on-device speech-to-text).

| Component | Technology |
|---|---|
| Planning & evaluation | Claude Opus 4.6 |
| Action execution | Claude Sonnet |
| Voice input | On-device SFSpeechRecognizer |
| Voice output | AVSpeechSynthesizer |
| Screen capture | CoreGraphics (CGWindowListCreateImage) |
| Mouse & keyboard | CGEvent API |
| UI overlay | AppKit + CALayer |

The separation lets each model do what it's best at — Opus reasons deeply about multi-step plans and handles recovery, Sonnet handles high-frequency perception and tool use.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- Permissions: Screen Recording, Accessibility, Microphone, Speech Recognition

---

Built for the [Anthropic Claude Code Hackathon](https://claude.ai/code).
