# Voice-task capture — macOS 27 acceptance pass (BAK-286)

Manual smoke test of push-to-talk capture on real hardware. Everything below
needs a live microphone, the real panels, and a human's eyes — which is why it
isn't in the automated suite.

**Run it:** `./build-app.sh && open build/Mustard.app`, then grant Microphone
when asked (Settings → Voice Setup… shows every grant).

## Environment

| Field | Value |
|---|---|
| macOS | 27.0 (26A5388g) |
| Xcode / SDK | 27.0 (27A5194q), macOS 27 SDK |
| Locale | |
| Apple Intelligence enabled | |
| Date run | |

## Step 1 — Objective smoke results

Hold **⌃⌥Space**, say *"buy oat milk from Coles tomorrow"*, release.

| Check | Result |
|---|---|
| Pill appears while held (top-centre, under the notch) | |
| Live text appears as you speak — roughly how long until the first word? | |
| Finalization delay between release and the task landing | |
| Task appears in Inbox with the right title | |
| Raw transcript kept verbatim (task detail → capture transcript) | |
| Quick-edit card opens below the notch and takes keyboard focus | |
| Drafted fields (title / notes / area / schedule / links) look sensible | |
| Manual edit made **during** drafting survived the model result | |

## Step 2 — Failure paths

| Scenario | Expected | Result |
|---|---|---|
| Apple Intelligence off (System Settings) | Task stays raw + editable; card offers **Draft Again** | |
| Tap the hotkey (<0.3s) | Nothing captured, pill flashes "Nothing captured" | |
| Hold but stay silent | Same — no empty task created | |
| Hotkey conflict (another app owns ⌃⌥Space) | Voice Setup → SHORTCUTS shows "In use by another app" | |
| Add a URL in the card, press Return | Link chip appears; junk text is rejected | |
| Two captures back to back | First card's edits are **saved**, not discarded; one card visible | |
| **Open Fully** on the card | Main window comes forward with the task drawer open | |
| **Escape** on the card | Card closes, task survives with pre-edit values | |

## Notes / anything surprising

## Verdict

- [ ] Acceptance criteria met — capture is usable day to day
- [ ] Issues found (list them above; file follow-ups in Linear)
