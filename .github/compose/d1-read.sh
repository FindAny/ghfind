#!/usr/bin/env bash
# Read-only query against a production D1 database. Prints tab-separated rows.
# Needs `wrangler login` (or CLOUDFLARE_API_TOKEN) with D1 read access, and jq.
#
#   .github/compose/d1-read.sh core "SELECT name FROM d1_migrations ORDER BY id"
#   .github/compose/d1-read.sh feed "SELECT COUNT(*) FROM feed_items"
#
# core = ghfind (shared by dev and production), feed = ghfind-feed. Schema changes go
# through migrations and ops/feed-production-schema-release.json in ghfind-server,
# never through this script, so it accepts one SELECT / WITH / EXPLAIN / read-only
# PRAGMA statement and rejects anything that writes.
set -euo pipefail
case "${1:-}" in core) db=ghfind ;; feed) db=ghfind-feed ;; *) echo "usage: $0 core|feed \"SELECT …\"" >&2; exit 64 ;; esac
sql=${2:-}
[ -n "$sql" ] && [ $# = 2 ] || { echo "usage: $0 core|feed \"SELECT …\"" >&2; exit 64; }

upper=$(printf '%s' "$sql" | tr '[:lower:]' '[:upper:]')
body=${upper%;}          # one trailing semicolon is fine; any other means a second statement
if [[ "$body" == *";"* ]] \
  || ! [[ "$upper" =~ ^[[:space:]]*(SELECT|WITH|EXPLAIN|PRAGMA)[[:space:]] ]] \
  || [[ "$upper" =~ (^|[^A-Z_])(INSERT|UPDATE|DELETE|REPLACE|UPSERT|DROP|ALTER|CREATE|ATTACH|DETACH|VACUUM|REINDEX)([^A-Z_]|$) ]] \
  || { [[ "$upper" =~ ^[[:space:]]*PRAGMA ]] && [[ "$upper" == *"="* ]]; }; then
  echo "d1-read: only one read-only SELECT / WITH / EXPLAIN / PRAGMA statement is allowed" >&2
  exit 64
fi

out=$(CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-8f19bebe359e4ec1a24c68c5f49c1584} \
  npx -y wrangler@4 d1 execute "$db" --remote --json --command "$sql" 2>/dev/null) || {
  echo "d1-read: wrangler failed; run it without 2>/dev/null to see why (often: wrangler login)" >&2; exit 1; }
if [ "$(jq -r '.[0].meta.changed_db' <<<"$out")" = true ]; then
  echo "d1-read: WARNING: the database reports a change; tell the owners" >&2; exit 1
fi
jq -r '.[0].results | if length == 0 then "(no rows)" else (.[0] | keys_unsorted | @tsv), (.[] | [.[] | tostring] | @tsv) end' <<<"$out"
