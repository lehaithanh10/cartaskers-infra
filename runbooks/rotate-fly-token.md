# Runbook: Rotate Fly deploy token

**Trigger:** quarterly (Fly tokens expire every 90 days), or immediately if a token is suspected leaked (e.g. appeared in a workflow log, screenshot, paste).

**Severity:** P2 (scheduled) / P1 (suspected leak).

**Time to complete:** ~5 minutes per app, zero downtime.

---

## When to run

- Calendar reminder fires (every 90 days).
- GitHub workflow run fails with `403 unauthorized` from `flyctl` → token expired.
- You see the token value in a screenshot, paste, or log.
- An ex-collaborator had access.

## Pre-checks

```bash
# Confirm which tokens currently exist on each app
flyctl tokens list -a cartaskers-be-staging
flyctl tokens list -a cartaskers-be-production
```

Note the `ID` of the token you intend to replace (named `github-actions-staging` / `github-actions-production`).

## Procedure (zero-downtime rotation)

Do this for **one app at a time** — confirm the next deploy succeeds before rotating the other.

### 1. Create the new token

```bash
flyctl tokens create deploy \
  -a cartaskers-be-staging \
  --name "github-actions-staging-$(date +%Y%m%d)" \
  --expiry 2160h
```

Copy the output (starts with `FlyV1 fm2_…`). It will not be shown again.

### 2. Push it to the matching GitHub environment secret

```bash
gh secret set FLY_API_TOKEN \
  --repo lehaithanh10/CarTasker-Backend \
  --env staging \
  --body-file -
# (paste the token, then Ctrl-D)
```

### 3. Trigger a noop deploy to prove the new token works

```bash
# Easiest: push an empty commit on main
cd ~/Developers/CarTasker-Backend
git commit --allow-empty -m "chore: verify rotated FLY_API_TOKEN"
git push
```

Watch the workflow in the Actions tab. If it deploys successfully, the new token is good.

### 4. Revoke the old token

Find the old token ID from step 0 and:

```bash
flyctl tokens revoke <OLD_TOKEN_ID> -a cartaskers-be-staging
```

### 5. Repeat for production

Same five steps with `cartaskers-be-production` and `--env production`.

## Verification

```bash
# Both apps should now show exactly one github-actions-* token, dated today
flyctl tokens list -a cartaskers-be-staging
flyctl tokens list -a cartaskers-be-production

# Both repo environments should have FLY_API_TOKEN updated recently
gh secret list --env staging    --repo lehaithanh10/CarTasker-Backend
gh secret list --env production --repo lehaithanh10/CarTasker-Backend
```

## If it fails

- **`flyctl: 403 unauthorized`** — your local flyctl session expired. Run `flyctl auth login` and try again.
- **`gh: ... not found`** — wrong repo or env name; check spelling against `gh repo view lehaithanh10/CarTasker-Backend --json defaultBranchRef`.
- **Deploy in step 3 still fails after new token** — old token wasn't the issue. Check `flyctl logs -a <app>` for the actual error before continuing.

## Escalation

If rotation fails repeatedly or you can't revoke the old token, contact Fly support (https://fly.io/support) — there's no immediate security risk as long as the new token is in place; the old one will still auto-expire on its original schedule.

## See also

- [scripts/bootstrap.sh](../scripts/bootstrap.sh) — the original token creation path, same flags.
- [Fly access tokens docs](https://fly.io/docs/security/tokens/)
