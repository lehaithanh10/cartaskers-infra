# cartaskers-infra

Central nervous system for CarTaskers operations: bootstrap scripts, reusable CI/CD workflows, runbooks, and decision records.

**App repos:**
- [CarTasker-Backend](https://github.com/lehaithanh10/CarTasker-Backend) — NestJS + Prisma + Postgres
- [CarTasker-Frontend](https://github.com/lehaithanh10/CarTasker-Frontend) — Next.js 15

---

## New engineer? Start here (30 minutes)

### 1. Accounts you'll need (5 min)

| Service | Why | Sign-up |
|---|---|---|
| GitHub (with access to the 3 repos) | Source + CI | ask the owner |
| Fly.io | Backend host | https://fly.io/app/sign-up |
| Cloudflare | Frontend host + edge security | https://dash.cloudflare.com/sign-up |
| Neon | Postgres | https://console.neon.tech/signup |
| Sentry | Error tracking | https://sentry.io/signup/ |
| Grafana Cloud | Logs + metrics + traces | https://grafana.com/auth/sign-up/create-user |
| Better Stack | Uptime + alerts | https://betterstack.com/users/sign-up |

Ask the project owner to add you to each org/team.

### 2. CLI tools (5 min)

```bash
brew install gh flyctl
brew install cloudflare/cloudflare/wrangler   # OR: npm i -g wrangler
gh auth login
flyctl auth login
```

### 3. Clone the three repos (2 min)

```bash
cd ~/Developers
gh repo clone lehaithanh10/CarTasker-Backend
gh repo clone lehaithanh10/CarTasker-Frontend
gh repo clone lehaithanh10/cartaskers-infra
```

### 4. Run bootstrap (10 min)

Reads any values you don't have set yet, configures Fly apps + GitHub secrets, never prints secrets to your screen.

```bash
cd cartaskers-infra
./scripts/bootstrap.sh                # interactive, all steps
./scripts/bootstrap.sh --dry-run      # see what it would do
./scripts/bootstrap.sh --step fly-tokens   # re-run just one step
```

See [scripts/bootstrap.sh](scripts/bootstrap.sh) for the full step list.

### 5. Verify (5 min)

```bash
flyctl status -a cartaskers-be-staging
gh secret list --env staging --repo lehaithanh10/CarTasker-Backend
```

If those both show data, you're set up. Welcome aboard.

---

## Repo layout

```
cartaskers-infra/
├── README.md                       # this file
├── scripts/
│   ├── bootstrap.sh                # one-time onboarding + per-step re-runs
│   └── lib/
│       └── prompt.sh               # shell helpers (no-echo prompts, colors)
├── .github/workflows/              # reusable workflows (called from app repos)
│   ├── ci-node.yml                 # lint + build + test + audit + gitleaks
│   └── fly-deploy.yml              # deploy to a named Fly app
└── runbooks/                       # one MD per alert; every alert MUST link here
    ├── rotate-fly-token.md
    ├── db-unreachable.md
    └── rollback-deploy.md
```

## Conventions

- **Every alert links to a runbook.** No alert without a runbook. No exceptions.
- **Reusable workflows are versioned** — pin app repos to `@v1.2.3`, not `@main`. Cut a new tag for every breaking change.
- **Secrets never get committed or pasted in chat.** Use `bootstrap.sh` or `gh secret set` / `flyctl secrets set` directly.
- **Bash, not zsh-isms** (`#!/usr/bin/env bash`, no `[[ … ]]` style if `[ … ]` works). Scripts should run on stock macOS bash 3.2.

## Contributing

1. Branch off `main`, open a PR.
2. CI must pass (lint check + shellcheck on scripts).
3. One approval required.
4. Squash-merge.

## See also

- [docs/architecture.md](docs/architecture.md) — full deployment architecture *(Phase 2)*
- [docs/decisions/](docs/decisions/) — ADRs — why each tool/pattern was chosen *(Phase 3)*
