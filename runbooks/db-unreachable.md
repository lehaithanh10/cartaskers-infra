# Runbook: Database unreachable

**Trigger:** alert from Better Stack on `/health/ready` failing; or `/health/ready` returning 503; or 5xx spike with logs containing `PrismaClientInitializationError` / `Can't reach database server`.

**Severity:** P1 (paging).

**Time to acknowledge:** 15 minutes. **Likely time to mitigate:** 5–30 minutes.

---

## Symptom

- API returns 5xx on most requests.
- Logs contain Prisma errors like `Can't reach database server at ep-...neon.tech:5432`.
- `curl https://api.cartaskers.com.au/health/ready` returns 503.
- Better Stack monitor for the API is red.

## First 3 checks (parallel — open three terminals)

```bash
# 1. Is Fly's app even running?
flyctl status -a cartaskers-be-production

# 2. Can the app talk to Neon at all? (this prints the most recent app errors)
flyctl logs -a cartaskers-be-production | tail -100

# 3. Is Neon itself up? Check https://neonstatus.com  AND  open the Neon console
#    (https://console.neon.tech) → your project → Operations → look for outages.
```

## Likely causes (in order of probability)

| Cause | Signal | Fix |
|---|---|---|
| Neon project paused (free tier auto-pause after inactivity) | Status page green, Neon console shows compute paused | Just hit any endpoint — Neon auto-wakes in ~5s. Repeat health check. |
| Neon regional outage | https://neonstatus.com red for `ap-southeast-2` | Wait it out. There is no useful action. Update status page. |
| Stale DATABASE_URL after Neon rotated credentials | Logs: `password authentication failed` | Go to Neon console → branch → Connection Details → copy new pooled URL → `flyctl secrets set DATABASE_URL=... -a cartaskers-be-production` (triggers redeploy) |
| Connection pool exhausted (too many idle connections) | Logs: `prepared statement "..." already exists` or `too many connections` | Confirm `DATABASE_URL` includes `?pgbouncer=true&connection_limit=5`. If missing, add it and redeploy. |
| Bad recent migration | Last `prisma migrate deploy` in `flyctl releases -a ...` failed | See [rollback-deploy.md](rollback-deploy.md). |
| Fly machine networking issue | Status page green, Neon console green, only one Fly machine affected | `flyctl machine restart <id> -a cartaskers-be-production` |

## Mitigation steps

### If Neon is paused (free tier)
No action needed besides hitting an endpoint to wake it. Confirm:
```bash
curl -fsS https://api.cartaskers.com.au/health/ready
```

### If Neon is in an outage
1. Post to status page (whatever tool you use) — "Investigating database connectivity issues. Following upstream provider."
2. Subscribe to https://neonstatus.com updates.
3. Wait. There is genuinely nothing to do.

### If credentials are wrong
```bash
# Grab fresh pooled URL from Neon console, then:
echo "DATABASE_URL=<new pooled url>" | flyctl secrets import -a cartaskers-be-production
# Fly will redeploy automatically. Watch:
flyctl logs -a cartaskers-be-production
```

### If pool is exhausted
```bash
# Verify the URL has pgbouncer params
flyctl ssh console -a cartaskers-be-production -C 'env | grep -i database_url' | grep -i pgbouncer
# If missing, repair:
echo "DATABASE_URL=<url>?pgbouncer=true&connection_limit=5" | flyctl secrets import -a cartaskers-be-production
```

### If recent migration is the cause
See [rollback-deploy.md](rollback-deploy.md). Roll back the app first, then deal with the migration in a fix-forward PR.

## Verification

After any fix:
```bash
# Health endpoint comes back green
curl -fsS https://api.cartaskers.com.au/health/ready

# Error rate drops in Grafana → API Overview dashboard
# Better Stack monitor goes back to up
```

## Escalation

- **30 minutes in, still down** → escalate to project owner (Hai). Page via SMS.
- **Neon outage >2 hours** → consider failing over to a read-only mode (return 503 for writes, 200 with cached data for reads) if you've implemented it; otherwise, communicate transparently on status page.
- **Suspect data corruption** → DO NOT run more migrations; contact Neon support immediately (paid plans have 1-hour response).

## See also

- [Neon status](https://neonstatus.com)
- [Fly status](https://status.flyio.net)
- Architecture doc — connection pooling decisions *(Phase 2)*
