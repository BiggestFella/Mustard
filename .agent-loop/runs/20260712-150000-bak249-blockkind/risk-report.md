# Risk report — BAK-249 (initial)

- **Declared labels:** `risk:medium`, `Feature` → medium (task_label_risk).
- **Expected touched paths:** `Sources/MustardKit/Logic/NoteDecoration.swift`,
  possibly a new `Sources/MustardKit/Logic/BlockKind.swift`, `Tests/MustardTests/`.
  Path risk: `Sources/` ⇒ medium; `Tests/` ⇒ low. No high-risk substring
  (auth/oauth/secret/ClaudeRunner/TrustPolicy/RecommendationAction/.github/.env).
- **Outward actions:** none (no release, no remote deletion, no secrets, no force
  push). PR open + squash-merge only.
- **Class: MEDIUM** → auto-merge on green required checks + passing fresh-context
  review, per `.agent-loop/risk.yml`.

Re-verify against actual `git diff --stat` before merge-policy.
