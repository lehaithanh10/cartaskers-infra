#!/usr/bin/env bash
# scripts/bootstrap.sh — one-time CarTaskers infrastructure setup.
#
# Idempotent. Re-runnable. Reads any value you don't supply.
# Never echoes secrets to the terminal or writes them to disk.
#
# Usage:
#   ./scripts/bootstrap.sh                       # run all steps interactively
#   ./scripts/bootstrap.sh --dry-run             # preview, no state changes
#   ./scripts/bootstrap.sh --step fly-tokens     # re-run one step
#   ./scripts/bootstrap.sh --help                # show this help
#
# Steps:
#   preflight    — verify CLIs, auth, repo names
#   fly-apps     — create the two Fly apps (idempotent)
#   fly-secrets  — set DATABASE_URL, JWT_SECRET, BCRYPT_ROUNDS, CORS_ORIGINS on both Fly apps
#   fly-tokens   — create per-app deploy tokens, write to GitHub env-scoped secrets
#   gh-vars      — set GitHub environment variables (FLY_APP_NAME, FLY_CONFIG, API_URL, SENTRY_ENV)
#
# Pre-populated values are accepted from env vars — useful for CI / non-interactive runs:
#   DATABASE_URL_STAGING=postgresql://... ./scripts/bootstrap.sh --step fly-secrets

set -euo pipefail

# --- Constants (edit if you fork) -----------------------------------------

BE_REPO="lehaithanh10/CarTasker-Backend"
FE_REPO="lehaithanh10/CarTasker-Frontend"

FLY_APP_BE_STAGING="cartaskers-be-staging"
FLY_APP_BE_PRODUCTION="cartaskers-be-production"
FLY_REGION="syd"

FLY_TOKEN_EXPIRY="2160h"   # 90 days — quarterly rotation

# Default URLs (override after custom domain DNS is set up)
API_URL_STAGING="https://${FLY_APP_BE_STAGING}.fly.dev"
API_URL_PRODUCTION="https://${FLY_APP_BE_PRODUCTION}.fly.dev"

# --- Helpers --------------------------------------------------------------

# shellcheck source=lib/prompt.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/prompt.sh"

DRY_RUN="false"
STEP="all"

# run <cmd...>  — execute or just print in dry-run mode
run() {
  if [ "$DRY_RUN" = "true" ]; then
    dim "    [dry-run] $*"
  else
    "$@"
  fi
}

# run_pipe <cmd...>  — like run, but the FIRST arg is the stdin content
#                       (used for piping secrets into flyctl/gh without exposing on argv)
run_pipe_stdin() {
  local stdin="$1"; shift
  if [ "$DRY_RUN" = "true" ]; then
    dim "    [dry-run] (stdin redacted) | $*"
  else
    printf '%s' "$stdin" | "$@"
  fi
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# --- Argument parsing -----------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN="true"; shift ;;
    --step)         STEP="${2:-}"; shift 2 ;;
    --step=*)       STEP="${1#--step=}"; shift ;;
    --help|-h)      usage ;;
    *) die "Unknown arg: $1   (try --help)" ;;
  esac
done

[ "$DRY_RUN" = "true" ] && warn "DRY-RUN mode — no changes will be made."

# --- Step: preflight ------------------------------------------------------

step_preflight() {
  section "Preflight"
  require_cmd gh      "brew install gh"
  require_cmd flyctl  "brew install flyctl"
  require_cmd openssl "(should be on every macOS)"

  # gh auth
  if ! gh auth status >/dev/null 2>&1; then
    die "gh is not authenticated. Run: gh auth login"
  fi
  ok "gh authenticated as $(gh api user --jq .login)"

  # flyctl auth
  if ! flyctl auth whoami >/dev/null 2>&1; then
    die "flyctl is not authenticated. Run: flyctl auth login"
  fi
  ok "flyctl authenticated as $(flyctl auth whoami)"

  # repo access
  for repo in "$BE_REPO" "$FE_REPO"; do
    if gh repo view "$repo" >/dev/null 2>&1; then
      ok "$repo accessible"
    else
      die "Cannot access $repo (check permissions or repo name)"
    fi
  done
}

# --- Step: fly-apps -------------------------------------------------------

step_fly_apps() {
  section "Fly apps"
  for app in "$FLY_APP_BE_STAGING" "$FLY_APP_BE_PRODUCTION"; do
    # flyctl status is the authoritative existence check — more reliable than
    # parsing apps list JSON (which has been observed to miss apps in some orgs).
    if flyctl status -a "$app" >/dev/null 2>&1; then
      ok "$app already exists — skipping"
      continue
    fi

    info "Creating Fly app: $app (region $FLY_REGION)"

    if [ "$DRY_RUN" = "true" ]; then
      dim "    [dry-run] flyctl apps create $app --org personal"
      continue
    fi

    if flyctl apps create "$app" --org personal; then
      ok "$app created"
    else
      # Creation failed — could be "Name has already been taken" from a previous
      # partial run, or a race with another session.  Re-check with status: if the
      # app now exists, we can safely continue.
      if flyctl status -a "$app" >/dev/null 2>&1; then
        warn "$app already exists (name taken from a previous run) — continuing"
      else
        die "Failed to create $app and it does not appear to exist.
  Run 'flyctl apps list' to investigate, then re-run this script."
      fi
    fi
  done
}

# --- Validation helpers ---------------------------------------------------

# Validate that $1 looks like a Postgres URL.
# Exits (via die) if it doesn't — prevents importing a garbage DATABASE_URL
# and discovering the mistake only when Prisma fails at deploy time.
validate_db_url_shape() {
  local url="$1"
  local label="$2"

  if [ -z "$url" ]; then
    die "$label is empty — cannot continue"
  fi

  case "$url" in
    postgresql://*|postgres://*)
      : ;;  # valid prefix — continue
    *)
      die "$label does not start with postgresql:// or postgres://
  Got: ${url:0:40}...
  Expected format: postgresql://user:pass@ep-xxx.region.aws.neon.tech/dbname?pgbouncer=true&connection_limit=5"
      ;;
  esac

  # Must contain @ (host separator) and / (db name separator)
  case "$url" in
    *@*/*) : ;;
    *) die "$label looks malformed (missing host or database name): ${url:0:60}" ;;
  esac

  ok "$label shape looks valid"
}

# --- Step: fly-secrets ----------------------------------------------------

# Set runtime secrets for one Fly app.
# $1 = app name, $2 = APP_ENV value (staging|production)
set_fly_secrets_for() {
  local app="$1"
  local app_env="$2"
  local db_var="DATABASE_URL_$(printf '%s' "$app_env" | tr 'a-z' 'A-Z')"
  local cors_var="CORS_ORIGINS_$(printf '%s' "$app_env" | tr 'a-z' 'A-Z')"

  info "Configuring secrets for $app ($app_env)"

  # Read from env if pre-supplied, else prompt.
  prompt_secret "$db_var" "  Neon DATABASE_URL for $app_env (pooled)"
  prompt_value  "$cors_var" "  CORS_ORIGINS for $app_env (comma-separated)" \
    "$(if [ "$app_env" = "staging" ]; then echo "https://cartaskers-fe-staging.pages.dev"; else echo "https://cartaskers.com.au"; fi)"

  local db_url cors jwt
  eval "db_url=\$$db_var"
  eval "cors=\$$cors_var"

  # Validate the URL before importing — catches typos & paste errors immediately
  # instead of letting them surface as a cryptic Prisma error at deploy time.
  validate_db_url_shape "$db_url" "DATABASE_URL ($app_env)"

  # Generate a fresh JWT secret — never reuse across envs.
  jwt="$(openssl rand -base64 64 | tr -d '\n')"

  # Pipe via stdin so no secret ever appears on argv / in `ps aux` / shell history.
  local stdin
  stdin=$(cat <<EOF
DATABASE_URL=$db_url
JWT_SECRET=$jwt
BCRYPT_ROUNDS=12
CORS_ORIGINS=$cors
NODE_ENV=production
APP_ENV=$app_env
AUTH_ACCESS_TOKEN_TTL=15m
AUTH_REFRESH_TOKEN_TTL=7d
AUTO_RELEASE_HOURS=48
EOF
)
  run_pipe_stdin "$stdin" flyctl secrets import -a "$app"
  ok "Secrets set on $app"
}

step_fly_secrets() {
  section "Fly secrets"
  set_fly_secrets_for "$FLY_APP_BE_STAGING"    "staging"
  set_fly_secrets_for "$FLY_APP_BE_PRODUCTION" "production"
}

# --- Step: fly-tokens -----------------------------------------------------

# Create a per-app deploy token and write to the matching GitHub environment secret.
# $1 = fly app, $2 = github env (staging|production), $3 = github repo
create_and_store_fly_token() {
  local app="$1"
  local env="$2"
  local repo="$3"

  info "Creating Fly deploy token for $app (env: $env)"
  if [ "$DRY_RUN" = "true" ]; then
    dim "    [dry-run] flyctl tokens create deploy -a $app --name github-actions-$env --expiry $FLY_TOKEN_EXPIRY"
    dim "    [dry-run] <token> | gh secret set FLY_API_TOKEN --repo $repo --env $env"
    return 0
  fi

  local token
  token="$(flyctl tokens create deploy -a "$app" --name "github-actions-$env" --expiry "$FLY_TOKEN_EXPIRY")"
  # gh secret set reads from stdin when --body/-b is omitted — token never appears on argv.
  printf '%s' "$token" | gh secret set FLY_API_TOKEN --repo "$repo" --env "$env"
  ok "Stored FLY_API_TOKEN in $repo / $env"
}

step_fly_tokens() {
  section "Fly deploy tokens → GitHub environment secrets"
  create_and_store_fly_token "$FLY_APP_BE_STAGING"    "staging"    "$BE_REPO"
  create_and_store_fly_token "$FLY_APP_BE_PRODUCTION" "production" "$BE_REPO"
}

# --- Step: gh-vars --------------------------------------------------------

set_var() {
  local key="$1" value="$2" env="$3" repo="$4"
  if [ "$DRY_RUN" = "true" ]; then
    dim "    [dry-run] gh variable set $key --env $env --repo $repo --body '$value'"
    return 0
  fi
  gh variable set "$key" --env "$env" --repo "$repo" --body "$value"
}

step_gh_vars() {
  section "GitHub environment variables"

  # Backend repo
  set_var FLY_APP_NAME "$FLY_APP_BE_STAGING"    "staging"    "$BE_REPO"
  set_var FLY_APP_NAME "$FLY_APP_BE_PRODUCTION" "production" "$BE_REPO"
  set_var FLY_CONFIG   "fly.toml"               "staging"    "$BE_REPO"
  set_var FLY_CONFIG   "fly.prod.toml"          "production" "$BE_REPO"
  set_var API_URL      "$API_URL_STAGING"       "staging"    "$BE_REPO"
  set_var API_URL      "$API_URL_PRODUCTION"    "production" "$BE_REPO"
  set_var SENTRY_ENV   "staging"                "staging"    "$BE_REPO"
  set_var SENTRY_ENV   "production"             "production" "$BE_REPO"

  # Frontend repo — most env-specific config lives in Cloudflare Pages dashboard,
  # so only SENTRY_ENV here for now.
  set_var SENTRY_ENV "staging"    "staging"    "$FE_REPO"
  set_var SENTRY_ENV "production" "production" "$FE_REPO"

  ok "GitHub variables set"
}

# --- Step dispatcher ------------------------------------------------------

case "$STEP" in
  all)
    step_preflight
    step_fly_apps
    step_fly_secrets
    step_fly_tokens
    step_gh_vars
    ;;
  preflight)    step_preflight ;;
  fly-apps)     step_preflight; step_fly_apps ;;
  fly-secrets)  step_preflight; step_fly_secrets ;;
  fly-tokens)   step_preflight; step_fly_tokens ;;
  gh-vars)      step_preflight; step_gh_vars ;;
  *) die "Unknown step: $STEP   (try --help)" ;;
esac

section "Done"
ok "Bootstrap complete."
if [ "$DRY_RUN" = "true" ]; then
  warn "Reminder: this was a dry run. Re-run without --dry-run to apply changes."
fi
