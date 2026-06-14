# Evidence-Based Code Review

Use this skill for an independent final review.

1. Start from the issue's observable outcome and acceptance checks.
2. Inspect the actual diff and affected callers; do not rely on the implementation
   report alone.
3. Look first for correctness bugs, regressions, security issues, data loss,
   missing error handling, and missing tests.
4. Verify that the change addresses the identified cause or requirement rather
   than only a symptom.
5. Check that verifier evidence was produced after the final relevant edit.
6. Do not duplicate the verifier's broad test work. Run a focused diagnostic
   only when needed to confirm or reject a concrete review finding.
7. Report only concrete findings. Separate blockers from optional improvements.
8. Approve completion only with fresh verifier evidence.

Methodology inspired by the MIT-licensed `obra/superpowers` requesting-code-review
and verification-before-completion skills.
