# Regression Verification

Use this skill after implementation and before code review.

1. Verify the reported symptom or acceptance condition, not just test-suite exit
   status.
2. Re-run the same reproduction used during analysis when practical.
3. Run the narrowest relevant test first, then broader affected regression tests.
4. Check important boundary and failure cases identified by the analyst.
5. Inspect the actual diff to identify affected behavior the implementation
   report may have omitted.
6. Record exact commands and observed outcomes.
7. Distinguish product failures from unavailable infrastructure.

Do not repair the code. A verifier that edits the implementation destroys the
independence of the verification gate.

Methodology inspired by Agentless patch validation, SWE-agent reproduction
checks, and the MIT-licensed `obra/superpowers` verification-before-completion
skill.
