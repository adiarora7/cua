# Game Plan

**Deadline:** Feb 16, 3:00 PM EST
**Builder:** Adi (solo)

## What Winning Looks Like

A non-technical person speaks to their Mac, the agent responds conversationally, acts quickly and visibly on screen, and completes what they asked for — all while feeling like a helpful companion, not a developer tool. The demo makes judges say "holy shit."

## Experience Pillars

Everything we build serves one of these:

| Pillar | What it means | Current state |
|--------|--------------|---------------|
| **Fast** | No awkward silences. Immediate acknowledgment, visible progress, filler while thinking. | ~8-10s before first action. Silence during Opus planning. |
| **Reliable** | No stuck loops, no clicking the same spot 10 times. Recovers gracefully or explains why. | Google Flights form = total failure. Gmail compose = works. Simple nav = works. |
| **Engaging** | Narrates what it's doing. Asks smart questions. Feels conversational, not robotic. | Clarification Q&A works. But no narration during actions, TTS voice is decent (Zoe). |
| **Personal** | Remembers things. Gets better over time. Feels like YOUR agent. | No memory system yet. |

## Benchmark Tasks (for measurement, not the goal)

Used to track progress across the pillars. Run before and after each stage.

| Task | Difficulty | Tests |
|------|-----------|-------|
| "Open Chrome" | Simple | Speed, basic reliability |
| "Google search for best restaurants in Lisbon" | Medium | URL navigation, speed |
| "Open Gmail and compose an email to mom about dinner" | Medium | Form interaction, reliability |
| "Find flights from Amsterdam to Lisbon for next Friday" | Hard | Complex UI grounding, clarification |
| "Go to Amazon and search for wireless headphones" | Hard | Search site interaction |

Metrics per task: success (yes/no), total time, number of replans, user had to intervene (yes/no).

Also benchmark Claude's native computer use API on the same tasks as a comparison point.

---

## Stage 0: Baseline (Feb 11 evening)

**Objective:** Know exactly where we stand. Numbers, not vibes.

- [ ] Run all 5 benchmark tasks, record results (success, time, replans)
- [ ] Run Claude native computer use on 2-3 tasks for comparison
- [ ] Identify the top 3 experience gaps (likely: speed of first action, grounding on complex forms, silence during planning)

**Exit criteria:** Baseline numbers documented. Clear list of what to fix first.

---

## Stage 1: Reliable & Fast Core (Feb 12)

**Objective:** The agent doesn't embarrass itself. When it acts, it acts correctly and quickly.

### Reliability
- [ ] URL-parameter navigation for search sites (Google Flights, Amazon, Google Search) — bypass unreliable form clicking entirely
- [ ] Smarter error recovery: if clicking fails 2x, immediately switch strategy (don't burn 8 more iterations)
- [ ] Reduce max iterations per block from 10 → 6 (fail fast, replan sooner)
- [ ] Test on all 5 benchmark tasks — target: 4/5 succeed

### Speed
- [ ] Filler audio immediately after voice input ("Let me look at that..." / "On it.") — already have "Working on it" but could be more natural/varied
- [ ] Measure and reduce Opus planning latency — can we use a lighter system prompt? Cache the system prompt?
- [ ] Parallel: start Sonnet on block 1 while Opus evaluates (currently sequential)
- [ ] Target: first visible action within 5s of voice input

**Exit criteria:** 4/5 benchmarks pass. First action within 5s. No stuck loops lasting >30s.

---

## Stage 2: Engaging Experience (Feb 13)

**Objective:** It feels like talking to a person, not commanding a robot.

### Narration
- [ ] Sonnet narrates key actions via short TTS snippets ("Opening Chrome...", "Typing in the search...") — not every action, just transitions
- [ ] Opus speaks a brief plan summary before execution ("I'll open Google Flights and search for those flights")
- [ ] On failure/replan: explain what happened ("That didn't work, let me try a different approach")

### Visual Feedback
- [ ] Click indicator: brief green circle at click location (fades after 500ms)
- [ ] Overlay shows current task description, not just state

### Voice Polish
- [ ] Varied filler phrases (not always "Working on it")
- [ ] Natural pacing — brief pause before speaking results

**Exit criteria:** A full task run feels conversational. Observer can follow what's happening without looking at terminal.

---

## Stage 3: Memory & Personal Touch (Feb 14)

**Objective:** "I remember you like aisle seats" moment works in demo.

### Memory System
- [ ] `~/.cua/memory.json` — simple list of facts Opus decides to remember
- [ ] Opus gets a `remember` tool: `{"fact": "User prefers aisle seats", "context": "flight booking"}`
- [ ] Memory loaded into Opus system prompt at session start
- [ ] Opus uses memory naturally in conversation ("Last time you preferred aisle seats — should I select that again?")

### Memory Demo Flow
- [ ] Session 1: Book a flight, mention preference → Opus remembers
- [ ] Session 2: Book another flight → Opus recalls and applies preference
- [ ] This IS the demo moment

**Exit criteria:** Memory round-trip works (remember → restart → recall). Feels natural, not forced.

---

## Stage 4: Demo Production (Feb 15-16)

**Objective:** 3-minute video that makes judges want to give us the prize.

### Narrative Arc
1. **The problem** (15s): "Computer use agents exist, but they're built for developers. What about everyone else?"
2. **The vision** (10s): "We built a voice-first agent that anyone can use."
3. **Architecture flash** (15s): Quick visual of Opus orchestrating Sonnet + memory
4. **Live demo 1** (60s): Adi uses voice to complete a real task. Agent narrates, acts fast, looks polished.
5. **Memory moment** (30s): Agent remembers something from a previous session. The "holy shit."
6. **The real test** (45s): Family member (mom/sister) uses it with zero guidance. Voice only. It works.
7. **Closing** (15s): "Built in 6 days. Solo. Voice-first computer use for everyone."

### Production
- [ ] Script the narrative, but keep demo segments real (not scripted clicks)
- [ ] Screen record with OBS or native macOS
- [ ] Pick 2-3 tasks that showcase all pillars (fast, reliable, engaging, personal)
- [ ] Record family member segment — real reaction, no coaching
- [ ] Edit for pacing, add architecture diagram overlay
- [ ] Submit before 3 PM EST Feb 16

**Exit criteria:** Video uploaded. Submission complete.

---

## Daily Rhythm

| Time | Activity |
|------|----------|
| Morning | Run benchmark tasks, note improvements from yesterday |
| Day | Build toward stage objectives |
| Evening | Test end-to-end, update daily notes, plan tomorrow |

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Grounding still fails on complex sites | Demo looks bad (30% weight) | URL parameter approach + pick demo-friendly sites |
| Opus latency makes it feel slow | Demo drags | Filler audio + parallel execution + prompt caching |
| Memory feels gimmicky | Doesn't land as "holy shit" | Make it contextual and natural, not a party trick |
| Family member can't use it | Kills the closer | Practice run day before, pick a simple task |
| Run out of time on polish | Rough demo | Stage 4 has 2 days buffer. Cut scope, not quality. |
