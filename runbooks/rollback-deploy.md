# Runbook: Roll back a bad deploy

**Trigger:** error rate spike, 5xx surge, or critical bug reported in the minutes after a deploy completes.

**Severity:** P1.

**Time to mitigate:** 2 minutes.

---

## Rule

**Roll back first. Diagnose second.** Customers benefit from a working old version more than from a heroic forward-fix that takes 30 minutes.

The only exception: if the previous version had a known critical bug worse than the current one. Otherwise, roll back.

## Symptom

One or more of:
- Grafana **API Overview** dashboard shows error rate >2% started within ~5 min of a deploy.
- New Sentry issues with `release: backend@<latest-sha>` and high event count.
- Better Stack uptime alert fires for the API.
- A user reports a specific bug that wasn't there yesterday.

## Decision tree

```
Was the last deploy <30 min ago?
├── YES → ROLL BACK (this runbook)
└── NO  → likely an unrelated issue → see db-unreachable.md or fly logs
```

## Pre-checks (30 seconds)

```bash
# Confirm there was a recent deploy and identify the previous version
flyctl releases -a cartaskers-be-production | head -5
```

You should see something like:
```
VERSION  STATUS    CREATED               DESCRIPTION
v42      running   2 minutes ago         Deploy image registry.fly.io/...:deployment-...
v41      released  3 hours ago           Deploy image registry.fly.io/...:deployment-...
```

You'll roll back **from v42 → v41**.

## Procedure

### 1. Roll back

```bash
# Replace 41 with whatever the previous-good version number is
flyctl releases rollback v41 -a cartaskers-be-production
```

flyctl does a rolling redeploy with the previous image. Takes ~60 seconds.

### 2. Watch it land

```bash
flyctl status -a cartaskers-be-production
flyctl logs   -a cartaskers-be-production | tail -30
```

You're looking for: all machines in `started` state, no startup errors.

### 3. Verify the symptom is gone

```bash
# Health check
curl -fsS https://api.cartaskers.com.au/health/ready

# Watch Grafana API Overview dashboard for ~5 min — error rate should drop back to baseline.
# Check Sentry — no new events with the rolled-back release tag.
```

### 4. Lock the bad deploy out

Stop anyone from accidentally re-shipping the bad commit:

```bash
# In the backend repo
cd ~/Developers/CarTasker-Backend
git revert <bad-commit-sha>     # creates a new commit reverting the change
git push
```

Or open a PR if you want review on the revert. **Don't `git reset` and force-push** — that loses history.

## Special case: bad database migration

If the deploy included a Prisma migration that succeeded but caused issues, you have a harder problem:

1. **Don't run `prisma migrate reset`** — that wipes data.
2. **Roll back the app** as above. The new (old) code still has to work against the new schema.
3. If the new schema is incompatible with the old code → you may need to **write a counter-migration** (e.g. add the column back, restore the default) in a hotfix PR.
4. Worst case (data corruption / dropped column you need back): **restore from Neon PITR** — see Neon console → Branches → Restore. This is destructive across whatever changed since the bad migration; weigh impact carefully.

## Verification

- Error rate back to baseline in Grafana **for at least 10 min**.
- No new Sentry events with the rolled-back release tag.
- Better Stack monitor green for at least 5 consecutive checks.
- Smoke-test the happy path you care about (e.g. login → post job → accept bid).

## After the dust settles

- Post-mortem in `docs/incidents/YYYY-MM-DD-<short-name>.md` *(template lands in Phase 3)*.
- Capture: what broke, why, how we detected it, how we mitigated, what we changed to prevent it.
- File a ticket for the proper fix-forward.

## Escalation

- **Rollback didn't help** — the bug isn't from the deploy. Move to [db-unreachable.md](db-unreachable.md) or general triage in Grafana.
- **Can't roll back** (e.g. Fly returns error) — `flyctl machine list -a <app>` and manually restart machines, or contact Fly support.
- **Suspected data loss** — STOP, do not roll forward, contact project owner immediately.

## See also

- [Fly releases & rollback docs](https://fly.io/docs/launch/rollback/)
- Architecture doc — release strategy *(Phase 2)*
