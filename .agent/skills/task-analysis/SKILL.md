# Evidence-Based Task Analysis

Use this skill before implementation so the next agent receives a bounded,
testable plan instead of a restatement of the issue.

1. Separate observable requirements from suggested implementation details.
2. Inspect the repository architecture, relevant instructions, callers, tests,
   and existing conventions.
3. Classify the task and identify the smallest ownership boundary that can
   satisfy it.
4. Record evidence for important conclusions and label unsupported assumptions.
5. Produce a concrete file-level plan and validation plan.
6. Escalate ambiguity only when different reasonable interpretations would
   produce materially different behavior.

The analysis artifact is a handoff contract. It must help the implementer act,
but it must remain open to correction when repository evidence disagrees.
