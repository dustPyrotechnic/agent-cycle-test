# Test-Driven Change

Use this skill while implementing behavior changes and bug fixes.

1. Translate the requirement or reproduced failure into an observable check.
2. Prefer adding or identifying a check that fails for the original behavior.
3. Implement the smallest change that makes the check pass.
4. Re-run the targeted check after the final code edit.
5. Run broader affected validation when practical.
6. Preserve test intent; never weaken assertions or remove coverage to obtain a
   passing result.
7. Report exact commands and outcomes, including failures and unavailable checks.

For documentation or configuration changes where executable regression coverage
is not practical, use the strongest relevant static validation and explain the
limit.

Methodology inspired by the MIT-licensed `obra/superpowers`
test-driven-development and verification-before-completion skills.
