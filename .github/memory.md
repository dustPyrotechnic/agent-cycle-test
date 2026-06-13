# GitHub Configuration Memory

GitHub is the control plane for the agent cycle.

- Opt-in label: `solve-it`
- Runtime labels: `agent-running`, `agent-done`, `agent-blocked`
- Task branch convention: `agent/issue-<number>`
- Pull requests target the current default branch.
- Workflow permissions are declared explicitly and limited to contents, issues, and pull requests.

Model credentials are accepted only from Actions secrets.

GitHub Agents variables are a separate Copilot cloud agent scope and are not available through the Actions `vars` context.
