# Agent identity boundary — POC

Build a **negative test suite** that proves or disproves one claim:

> An agent holding tier-scoped credentials cannot perform action X, even though the operator can.

Everything else here is scaffolding for that sentence.

---

## Guardrails — read before any write operation

- **Personal GitHub account only.** Do not create GitHub Apps in, install anything on, or write to
  the `radix-health` org. This is a throwaway repo on Will's personal account.
- `gh` is currently authenticated as the **work** account `wcollani-pivotalhealth`
  (scopes: `gist`, `read:org`, `repo`). Add the personal account with `gh auth login`, switch with
  `gh auth switch`, and **run `gh api user --jq .login` immediately before every write** to confirm
  which identity is active. Getting this wrong writes to production infrastructure.
- Do not "fix" anything in the work repos. A prior session audited them read-only; findings are
  already written up. This session builds a POC and nothing else.
- Creating the GitHub App requires browser clicks. It cannot be automated — hand that step to Will
  with exact settings rather than trying to script it.

---

## Why this exists

Will's work GitHub account holds **org admin**, so any cloud agent acting as him inherits it.
`AGENTS.md` cannot bound that: it is a prompt, not a policy, and it lives in the repository the agent
can write to.

The design principle this POC tests:

> An agent's effective authority should be a strict subset of the operator's — and neither should be
> able to edit the thing that bounds them.

Real-world instances being modelled (measured 2026-09-01 in the work org, do not go re-verify):

- `terraform-live`'s ruleset (id `3401225`) lists `OrganizationAdmin` and repository-admin as
  **bypass actors** at `bypass_mode: "pull_request"`. For admins the PR requirement is advisory.
- That same ruleset already sets `require_extra_approval_for_unattributed_changes: true`.
- The HCP `owners` team has 14 members out of ~20 engineers.

Full background: the Terraform/HCP practice review, **Part five — permissions & boundaries**.
Artifact: https://claude.ai/code/artifact/219af7f1-4178-4590-bf2e-20511f4b9430
Local copy: `~/repos/Reports/2026-09-01-terraform-hcp-practice-review.html`

---

## Two layers — test them separately, they are not the same thing

**Layer 1 — remote identity (GitHub App).** Bounds what reaches GitHub. Enforced by GitHub, outside
the agent's reach. This is the part that generalises to any tool.

**Layer 2 — local tool scope (subagent definitions).** Subagents inherit the parent process's
environment *and credentials*, so you cannot give a subagent a weaker GitHub identity through
GitHub's model. The enforceable local boundary is the `tools:` allowlist in `.claude/agents/*.md`,
which the harness applies before a call is made.

As of 2026-09-01 neither `~/.claude/agents/` nor `~/repos/.claude/agents/` exists — so layer 2 is
currently unbounded: every subagent spawned has the full toolset and the operator's credentials.
Demonstrating that is part of the POC.

---

## Build

1. Throwaway repo on the personal account (e.g. `agent-boundary-poc`).
2. Ruleset on `main`: require a PR, 1 approval, **no bypass actors**.
3. One GitHub App owned by the personal account. Permissions: `contents: write`,
   `pull_requests: write`, `metadata: read`. **Nothing else.** Install on that one repo only.
4. Private key at `~/.config/agent-poc/key.pem`, `chmod 600`. Never commit it; add to `.gitignore`.
5. Deliverables in this directory:
   - `mint-token.sh` — installation token from the App private key (JWT → installation token)
   - `assert.sh` (or `.py`) — runs the matrix below, records **observed** HTTP status per row
   - `.claude/agents/poc-readonly.md` and `.claude/agents/poc-propose.md` — two subagent
     definitions with different `tools:` allowlists, to exercise layer 2

## Assertion matrix — record observed, not expected

| Operation | Operator | `agent-propose` App |
|---|---|---|
| read / clone | pass | pass |
| push a branch | pass | pass |
| open a PR | pass | pass |
| push directly to `main` | ? | expect fail |
| merge own PR | pass | expect fail |
| edit the ruleset | pass | expect fail |
| delete the repo | pass | expect fail |
| touch a *different* repo | pass | expect fail — not installed there |

The last row is the strongest property: install scope is not a permission check, the App genuinely
cannot see repos it is not installed on.

---

## The three unknowns — this is the actual value, answer them explicitly with evidence

1. **Does a GitHub App's review satisfy a required approval?**
   If yes, an `agent-release` tier could effectively self-approve and the gate is void.

2. **Is ruleset bypass role-based enough that an admin's fine-grained PAT still bypasses?**
   If a scoped PAT still bypasses because the *user* is an admin, PATs are off the table entirely
   and it must be Apps or nothing. This was flagged unverified when the tier design was proposed.

3. **Does `require_extra_approval_for_unattributed_changes` fire on App-authored commits?**
   This one can invert the recommendation. That rule is already live on `terraform-live` — if App
   commits trip it, moving agents onto App identity *increases* review burden instead of reducing
   it, and the tiered-App design needs rethinking before anyone builds it.

---

## Done looks like

- The matrix filled in with **observed** results and the HTTP status / error for each denial.
- The three unknowns answered, each with the specific evidence that settled it.
- A re-runnable script, so the suite can be replayed when GitHub changes behaviour. Key results by
  `(credential-tier, operation)` — that shape feeds the eval-harness project.
- A short findings file written to `~/repos/Reports/`, dated, following the existing convention there.

## Gotchas hit in the prior session

- The Bash sandbox denied reading `~/.terraform.d/credentials.tfrc.json` and denied a Python heredoc
  that edited a file under `Reports/`. If shell writes get blocked, use the `Write`/`Edit` tools
  instead of shelling out — same result, no prompt.
- `gh api repos/OWNER/REPO/branches/main/protection` returns **404 for ruleset-protected repos**.
  That does not mean unprotected. Always also check `repos/OWNER/REPO/rules/branches/main`, which
  returns effective rules including org-inherited ones with a `ruleset_source_type` field.
