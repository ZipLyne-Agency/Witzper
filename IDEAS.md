# Witzper — Feature Ideas Backlog

A running list of features that would make the Witzper dictation experience better. Organized by impact-to-effort ratio. Not committed to — these are candidates to pull from when picking what to build next.

---

## 🔥 High-impact, low effort

### 1. Streaming partial transcripts in the HUD
The HUD currently just says "Listening…". Wispr Flow shows your words live as you speak. We can do this with `parakeet-mlx`'s streaming API: feed audio chunks in real time, render the partial transcript inside the HUD panel, finalize on key release. Massive perceived-quality jump for ~half a day of work.

### 2. Pre-flight ASR (start transcribing before you stop talking)
When you release the hotkey we currently do ASR + cleanup serially. We can run ASR continuously while you're speaking (via streaming), so by the time you release, the raw transcript is *already done* and only the LLM cleanup remains. Cuts perceived latency roughly in half.

### 3. Auto-stop on long silence
Right now it's pure push-to-talk. Adding an auto-endpoint after ~1.2s of silence (Silero VAD already handles this) means you can tap-and-go instead of holding. Toggle in Settings: hold-to-talk vs. tap-to-toggle vs. auto-stop.

### 4. "Last utterance" undo
⌘⇧Z (or a menu item) restores the field to what it was before the last paste. Implementation is trivial — we already snapshot the clipboard and we know the text we inserted. Saves you when the LLM gets something weird.

### 5. Edit-the-last-transcript-with-voice
Hold a different hotkey, say "actually change Tuesday to Wednesday," and Witzper rewrites the *previously inserted text* using the shared cleanup LLM (Qwen3-30B-A3B). This is what makes Wispr Flow's "AI Commands" feel magic. The model is already warm in memory; just need to wire the second hotkey + grab surrounding text via AX and replace it.

### 6. Audible feedback for low confidence
When the cleanup guardrail fires (raw used instead of cleaned), play a different "Pop" tone so you know the LLM bailed. Trivial UX win, no model changes.

---

## 🎯 Accuracy / quality wins

### 7. Top-N rerank
Parakeet returns multiple hypotheses internally; we currently take only the top one. Pass the top 5 to the cleanup LLM as "ASR alternatives" (the field is already in our prompt). The LLM picks "run the *tests*" over "run the *bests*" using sentence context. Free accuracy bump.

### 8. Custom wake-word for AI Commands
"Hey Witzper, summarize this email" → triggers Command Mode without a separate hotkey. Local wake-word detection with `openwakeword` is tiny and runs on CPU.

### 9. Speaker enrollment / "this is my voice"
Record 30 seconds of you reading text, fine-tune Parakeet with a tiny LoRA on your specific voice. Every user gets a personalized acoustic model after their first day. We already have the LoRA training scaffolding in `flow/personalize/train_lora.py`.

### 10. Domain modes (Superwhisper concept)
Pick a "mode" via menu — `Coding`, `Meeting Notes`, `Email`, `Brainstorm` — and Witzper swaps in a different system prompt, different few-shot examples, different temperature, even a different cleanup model. Coding mode skips punctuation cleanup and preserves identifiers verbatim. Meeting Notes mode formats as bullet points. Brainstorm uses excited tone.

### 11. ASR alternative voting via small ensemble
Run Parakeet AND Qwen3-ASR (when wired up) in parallel, then have the LLM pick the better transcript. ~+50 ms latency for measurable accuracy gains in noisy environments.

---

## 🧠 Personalization that compounds

### 12. Real correction loop
The edit watcher exists but doesn't actually read post-insertion edits via AX yet. Wiring this properly turns every typo-fix into a training example. After two weeks of use, your personal LoRA adapter would be a noticeable accuracy upgrade — and it's the actual moat over Wispr Flow because they don't fine-tune per user, they only update the dictionary.

### 13. Per-recipient tone learning
When you dictate in Slack DMs to Bob vs. Slack channels vs. emails to your boss, you write differently. Witzper could learn "Bob = casual, no-period," "Boss = formal" by watching your edits. Stored as a `recipient → style` map in SQLite.

### 14. Smart snippet suggestions
When you dictate the same phrase 3+ times, Witzper proposes "Want to make this a snippet?" via a notification. Removes the cold-start friction with snippets.

### 15. Time/date variables in snippets
Wispr Flow doesn't have this (their docs explicitly say it's not supported). Easy win for us: `{date}`, `{time}`, `{cursor}` placeholders in snippet expansions. "today's standup notes" → "Standup notes — 2026-04-09".

---

## ⚙️ Power features

### 16. Multi-language code-switching
Hardest one technically. Parakeet v3 supports 25 languages including code-switching, but our cleanup prompt is English-only. Detect language per utterance, route to a per-language cleanup prompt.

### 17. Voice macros (chained snippets)
"Send standup" → expands to a multi-line standup template with cursor jump points. Beyond Wispr's snippets — closer to TextExpander's snippet groups.

### 18. Selection-aware Command Mode
When you have text selected and trigger Command Mode, "fix the grammar" or "make it shorter" rewrites the selection in place. Already 70% there in `command.py`; just needs the AX-set-selected-text path on the Swift side.

### 19. Cross-app context
When dictating in Slack thread reply, scroll the *thread above* into the cleanup LLM as context so pronouns and references resolve correctly. Read from AX. This is the Wispr secret-sauce trick.

### 20. Markdown awareness
In Notion / Notes / VS Code comments, dictate "header one welcome" and get `# Welcome`. "Bullet point one buy milk bullet point two pay rent" becomes a real list. Just a richer system prompt for those app categories.

---

## 🎨 Polish

### 21. Onboarding wizard
First launch: walk through hotkey pick, mic test with live waveform, AX permission grant flow with screenshots, dictate-something-now confirmation. Cuts the "I have no idea what's going on" period down to ~60 seconds.

### 22. Floating mini-pill instead of full HUD
A small Wispr Flow-style pill at the bottom of the screen with a live waveform during dictation, instead of the big black box. Less intrusive.

### 23. Latency indicator in HUD
After insertion, the HUD briefly shows "320 ms" before fading out. Builds trust in the speed.

### 24. Daily/weekly stats
"You dictated 14,000 words this week (84% faster than typing)." Local-only, calculated from the corrections store. Free motivation/showoff.

### 25. Export everything
"Export my snippets / dictionary / corrections to JSON." Trust win — users feel safer knowing they can leave with their data.

---

## 🚀 Wild ideas (probably 2.0)

### 26. Voice diff for code
Select a function in VS Code, hold Command Mode hotkey, say "make this async and add error handling." The shared Qwen3-30B cleanup model rewrites it — zero extra RAM since it's already warm.

### 27. Witzper-as-a-keyboard
Replace the macOS dictation system entirely — install Witzper as an Input Method so it works in *any* text field, including ones that block paste/clipboard tricks (password fields, terminal apps, sandboxed apps).

### 28. Multi-modal context
Screenshot the focused window before dictation, feed it to a small VLM (Qwen2.5-VL) so when you say "click the second button" or "summarize what's on screen," Witzper actually sees what you're looking at. Probably too expensive for hot path but viable for Command Mode.

### 29. Voice journal mode
A dedicated capture surface that records continuously (with VAD pauses), transcribes, and writes to a Markdown daily note. No insertion, no app switching — just talk and walk.

### 30. Macro recording from edits
Watch a sequence of (dictation → edit → dictation → edit) and turn it into a reusable transformation. "Whenever I dictate in this Notion database, always prefix with the date and add a #standup tag."

---

## Recommended next-up (priority order)

If we were ranking *what to build next* for the most leverage:

1. **#1 streaming partials in HUD** — biggest "wow this feels like Wispr" delta
2. **#5 voice command mode (edit last text)** — the actual Wispr "AI Commands" feature; reuses the already-warm cleanup model
3. **#3 auto-stop / tap-to-toggle** — kills hold-to-talk fatigue
4. **#10 domain modes (Coding / Email / Notes)** — single biggest accuracy lever after ASR
5. **#12 + #21 real correction loop + onboarding** — turns it from "demo" into "I use this every day"
