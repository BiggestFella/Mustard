# Deep-review — PR #150 Gmail inbox (high-risk)

**Verdict: HELD (panel not unanimous).** 2 of 3 lenses blocked. Merge held; fixes in-run.

## Panel

| Lens | Model | Verdict |
|------|-------|---------|
| Spec-faithfulness | sonnet | clear |
| Correctness | sonnet | **block** |
| Security/risk | opus | **block** |

## Blocking findings

**S1 (security, critical) — untrusted email text reaches an unrestricted `claude -p`.**
`GmailService.poll` embeds ≤4000 chars of sender-controlled body into the triage prompt and
calls `ClaudeRunner.run`, whose argv is only `-p/--output-format json` — no tool/MCP/permission
restriction. On Leon's machine the CLI runs `defaultMode: bypassPermissions` with live tokens in
its env and cwd over a tree containing tracked secrets. Prompt-text framing is not a boundary →
unattended arbitrary code execution + secret exfiltration on a 5-min cadence once activated.
Fix: give triage a locked-down invocation (deny Bash/Write/Edit/WebFetch/WebSearch/Task, strict
MCP off, non-bypass settings) via the existing `ClaudeInvoke` seam.

**S2 (security) — grounding cwd too wide.** Single-route `groundingDirectory` grounds at the KB's
*parent*, widening S1's reach. Ground at the KB itself for one route.

**S3 (security/availability) — unparseable triage re-loops forever.** `.unparseable` never marks
ids seen, so an injection that makes the model emit prose re-sends itself every interval. Add a
per-id failed-attempt cap.

**C1 (correctness, important) — action buttons never render for Jira/Shortcut-labelled Gmail.**
`IngestNormalizer.normalize` → `SourceClassifier` reclassifies `source` to `jira`/`shortcut` before
insert, so `rec.source != "gmail"` for exactly the headline case; `gmailActions` gates on
`rec.source == gmail` and vanishes. Gate on the durable Gmail permalink (`sourceURL`) instead.

## Non-blocking (fixing the cheap/high-value ones in-run)

- Send confirmation dialog doesn't show the resolved recipient (spoof-Reply-To risk). Show it.
- `strippedHTML` runs unbounded regex on full body before the 4000-cap (ReDoS). Truncate first.
- `poll()` re-entrancy (manual "Poll now" vs scheduler tick) wastes a claude run. Add `isPolling` guard.
- `lastPollSummary`/`Triage failed: <raw>` surfaces raw claude stdout unbounded. Cap/redact.
- Gate `release` not in `defer` (safe today, fragile). Use `defer`.
- `GmailSyncState.lastPolledAt` persisted but never read; scheduler uses in-memory `lastPolled` so
  cadence resets on relaunch. Wire `isDue` to the persisted value.

## Residual accepted (→ ADR + Leon sign-off)

Read/Grep/Glob stay enabled for grounding, so a read secret could still be echoed into a *local*
card field (capped). This cannot be sent anywhere without Leon reviewing the exact draft and
clicking send. Network/exec exfil is eliminated by S1's tool-deny. The tool restriction's
precedence over the machine's `bypassPermissions` default is empirically machine-specific → Leon
verifies before first activation (feature ships disabled; needs his OAuth client id to poll).
