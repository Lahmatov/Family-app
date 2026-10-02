#!/usr/bin/env bash
# Runs all database migrations and pgTAP tests against a throwaway Postgres
# cluster. Works on Linux CI and in sandboxes without Docker.
#
# On a Mac with the Supabase CLI prefer:  supabase start && supabase test db
#
# Env:
#   PG_BIN   directory with initdb/pg_ctl/postgres (auto-detected)
#   KEEP_DB  if set, leave the cluster running after tests (prints psql cmd)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
PORT="${PGPORT_TEST:-54329}"
RUN_AS=()

if [ "$(id -u)" = "0" ]; then
  # Postgres refuses to run as root.
  chown -R postgres:postgres "$WORK"
  RUN_AS=(sudo -u postgres)
fi

cleanup() {
  if [ -z "${KEEP_DB:-}" ]; then
    "${RUN_AS[@]}" "$PG_BIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

"${RUN_AS[@]}" "$PG_BIN/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
"${RUN_AS[@]}" "$PG_BIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/pg.log" -w start >/dev/null

PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -X)

"${PSQL[@]}" -d postgres -c "create database app" >/dev/null
"${PSQL[@]}" -d app -f "$ROOT/scripts/db/supabase_shim.sql" >/dev/null
"${PSQL[@]}" -d app -c "create extension if not exists pgtap with schema extensions" >/dev/null

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate: $(basename "$f")"
  "${PSQL[@]}" -d app -f "$f" >/dev/null
done

if [ -f "$ROOT/supabase/seed.sql" ]; then
  "${PSQL[@]}" -d app -f "$ROOT/supabase/seed.sql" >/dev/null
fi

# pgTAP functions live in the extensions schema (as on Supabase).
export PGOPTIONS="-c search_path=public,extensions"
pg_prove -h "$WORK" -p "$PORT" -U postgres -d app --ext .sql -r "$ROOT/supabase/tests" "$@"

if [ -n "${KEEP_DB:-}" ]; then
  echo "DB kept: psql -h $WORK -p $PORT -U postgres app"
fi
