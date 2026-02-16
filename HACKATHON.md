# Hackathon Context

## The Problem
Computer use agents exist but they're built for technical users. They live in separate browser windows, require text input, and feel like developer tools. For hundreds of millions of non-tech-savvy people, these tools are inaccessible. The inspiration: Adi's mother asking for help with websites — there's no product that replicates having a patient, knowledgeable person sitting next to you helping with your laptop.

## The Vision
A macOS app that lets anyone control their computer through natural conversation. Voice-first, not text-first. Conversational, not transactional. Runs alongside you on your screen. Learns over time. Your mom can use it.

## Event Details
- **Builder:** Adi (solo)
- **Event:** Anthropic Claude Code Virtual Hackathon
- **Deadline:** Feb 16th, 3:00 PM EST
- **Constraints:** Fully open source, built from scratch during hackathon, team of up to 2

## Judging Criteria

| Criterion | Weight | Our Angle |
|-----------|--------|-----------|
| **Demo** | 30% | A non-technical user (family member) successfully using the app via voice. The "holy shit" moment. |
| **Opus 4.6 Use** | 25% | Opus as intelligent orchestrator — planning, reasoning, memory decisions, conversational context. Not wrapping Opus, but using it for what it's uniquely good at while fast models handle perception. |
| **Impact** | 25% | Problem Statement Two (Break the Barriers): making computer use accessible to everyone. |
| **Depth & Execution** | 20% | Multi-model architecture, memory system, voice UX — deep engineering, not a weekend hack. |

### Problem Statement Fit
- **Primary:** Problem Statement Two — Break the Barriers
- **Secondary:** Problem Statement One — Build a Tool That Should Exist

### Special Prize Target
- **Most Creative Opus 4.6 Exploration ($5K):** Opus as orchestrator over multiple models showcases what Opus specifically excels at.

## Product Differentiation
- Existing CUAs are for power users. This is for everyone.
- Voice-first removes intimidation of chat interfaces.
- Conversational narration ("I'm clicking on the search bar now...") makes the invisible visible.
- Memory across sessions = personal agent, not stateless tool.
- Visual indicator showing where agent is looking builds user trust.

## Technical Differentiation
- Current CUAs use one model for everything (slow). We split: large model reasons/plans, small fast models perceive/ground.
- Building for the model 6 months ahead: orchestration + memory + UX improve for free as models get better.

## Boris Cherny's Principles (hackathon kickoff)
- "Build for the model 6 months ahead, not for the model today."
- "Don't make users do a new thing, make their existing thing easier." — People already talk to ask for help.
- "Look at what the model is doing, and make that easier." — Models already do computer use. We make them better at it.

## Architecture Direction

### Core: Hierarchical Model Orchestration
Opus 4.6 as master orchestrator — reasons, plans, converses, decides. Lighter models handle high-frequency perception/grounding.

### Model Roles (Directional)

| Role | Direction |
|------|-----------|
| Orchestrator / Planner | Claude Opus 4.6 — complex reasoning, planning, conversational context, error recovery, memory |
| Action Executor | Claude Sonnet — fast action loop, tool use |
| Screen Understanding | Fast open-source vision model (Qwen2.5-VL, Moondream, etc.) — future |
| UI Grounding | OmniParser (Microsoft) or similar — future |
| Voice Input | SFSpeechRecognizer (streaming, on-device) |
| Voice Output | AVSpeechSynthesizer (premium Zoe voice); Kokoro-82M as stretch goal |
| Mouse/Keyboard | Native macOS CGEvent APIs |
| Screen Capture | CoreGraphics with JPEG compression |
| Memory | JSON file, Opus decides what to remember |

## Ideas Worth Exploring
- **Pre-emptive observation:** Screen understanding runs continuously. User opens Google Flights → agent says "I see you're on Google Flights — want me to help?"
- **Speculative execution:** Opus plans ahead. Execute N+1 immediately if screen matches predictions.
- **Filler audio:** "Let me take a look..." while Opus thinks. What a real person would do.
- **Visual feedback overlay:** Green circle showing where agent is about to click.
- **Memory as demo star:** "I remember you like aisle seats, so I selected that for you."

## Demo Strategy (3 minutes)
1. Quick context — "Computer use agents exist but they're built for developers. We built one for everyone."
2. Brief architecture visual — multi-model orchestration
3. Voice-driven task completion on a real website
4. Memory moment — agent remembering something from previous session
5. The closer — family member using the app via voice, no help needed

## Prior Art
- **Archon** (3rd place OpenAI GPT-5 Hackathon): Same hierarchical architecture but built for power users, no memory, no voice-first UX. Blog: https://blog.sdan.io/archon/

## Opus 4.6 Features to Leverage
- **Agent Teams:** Multiple Claude Code sessions in parallel for building the project itself
- **Agent SDK:** Programmatic agent loop, tool use, structured handoffs
- **Adaptive Thinking:** Simple actions = minimal thinking, complex situations = deep reasoning
- **Context Compaction:** Maintain coherence over long sessions
