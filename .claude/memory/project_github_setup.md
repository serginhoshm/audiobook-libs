---
name: project-github-setup
description: "GitHub SSH setup for audiobook-libs — two GitHub accounts, personal key routes via github-personal host alias"
metadata: 
  node_type: memory
  type: project
  originSessionId: a12bfd88-ae16-43c2-b663-dd1ac446210d
---

Two GitHub accounts are in use on this machine:

- **Work account**: `serginhoshm-vinta` → key `~/.ssh/id_ed25519`, routes via `github.com`
- **Personal account**: `serginhoshm` (email: `serginhoshm@gmail.com`) → key `~/.ssh/id_ed25519_personal`, routes via `github-personal` SSH host alias

The `audiobook-libs` repo remote is set to `git@github-personal:serginhoshm/audiobook-libs.git` and the local git config uses `serginhoshm` / `serginhoshm@gmail.com`.

**Why:** The default SSH key was tied to the work account; a second key + SSH config alias was added to support the personal account without breaking work repos.

**How to apply:** For any new personal GitHub repos, use the `github-personal` host alias in the remote URL and set local git config to the personal identity.
