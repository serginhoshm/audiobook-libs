# GitHub SSH Multi-Account (Repo Scoped)

This document records the fix applied when this repository was pushing with the wrong GitHub identity.

## Context

Two SSH identities exist in the same machine:

- `sergio.marchiori@vinta.com.br` (must not be changed)
- `serginhoshm` identity for this repository

The repository `serginhoshm/audiobook-libs` must always push with the `serginhoshm` identity.

## Symptom

Push fails with permission denied for the wrong account:

```bash
ERROR: Permission to serginhoshm/audiobook-libs.git denied to serginhoshm-vinta.
fatal: Could not read from remote repository.
```

## Root Cause

Remote was using `github.com` default host, which authenticated with a different SSH key/account than the one that owns this repository.

## Safe Fix (Repo Only)

Do not change global credentials and do not rotate the Vinta key.

1. Keep SSH config aliases in `~/.ssh/config`:

```sshconfig
Host github-vinta
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_serginhoshm-vinta
  IdentitiesOnly yes

Host github-sergio85
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github_sergio85
  IdentitiesOnly yes
```

2. Set this repository remote to the correct alias:

```bash
git remote set-url origin git@github-sergio85:serginhoshm/audiobook-libs.git
```

3. Validate identity and access:

```bash
ssh -T git@github-sergio85
git push --dry-run origin HEAD:main
```

Expected identity check:

```text
Hi serginhoshm! You've successfully authenticated, but GitHub does not provide shell access.
```

Expected push dry-run output includes:

```text
To github-sergio85:serginhoshm/audiobook-libs.git
```

## Quick Diagnostics

Check local repo identity:

```bash
git config --local --get user.name
git config --local --get user.email
git remote -v
```

Check which account default `github.com` is using:

```bash
ssh -T git@github.com
```

If it returns the Vinta account, this is still fine. Only this repository remote must point to `github-sergio85`.

## Guardrails

- Never overwrite or remove the key/comment for `sergio.marchiori@vinta.com.br`.
- Prefer repo-scoped fixes (`git remote set-url`) over global Git/SSH changes.
- Use `git push --dry-run` before first real push after any auth adjustment.

## Pre-Push Checklist

Run this checklist before pushing from this repository:

1. Confirm remote alias is repo-scoped to `github-sergio85`:

```bash
git remote get-url origin
```

Expected:

```text
git@github-sergio85:serginhoshm/audiobook-libs.git
```

2. Confirm explicit identity works:

```bash
ssh -T git@github-sergio85
```

Expected:

```text
Hi serginhoshm! You've successfully authenticated, but GitHub does not provide shell access.
```

3. If remote is still `github.com`, use one-shot push with explicit key (do not edit Vinta entry):

```bash
GIT_SSH_COMMAND='ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_github_sergio85 -o StrictHostKeyChecking=accept-new' \
  git push origin main
```

4. Final verify:

```bash
git status -sb
```

Expected: no pending changes and no ahead/behind after successful sync.
