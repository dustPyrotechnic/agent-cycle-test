# Systematic Debugging

Apply this skill to bugs, failing tests, unexpected behavior, and build/runtime
failures.

1. Reproduce the symptom with the smallest practical command or scenario.
2. Capture what was expected, what happened, and the relevant error boundary.
3. Trace data and control flow backward until the earliest incorrect assumption,
   state transition, or input is identified.
4. Distinguish root cause from downstream symptoms.
5. Compare with nearby working behavior when useful.
6. Propose the smallest fix at the root-cause boundary.
7. Define a regression check that would fail before the fix and pass after it.

Do not recommend speculative edits before gathering evidence. If reproduction is
not practical, state why and identify the evidence that still supports the
hypothesis.

Methodology inspired by the MIT-licensed `obra/superpowers` systematic-debugging
skill and SWE-agent's reproduce-before-fix prompt pattern.
