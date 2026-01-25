#!/bin/sh
set -e

# Start Dart agent in background (logs to stdout)
if [ -x /usr/local/bin/pgdump-agent ]; then
  /usr/local/bin/pgdump-agent &
fi

# If no args were provided, default to postgres
if [ "$#" -eq 0 ]; then
  set -- postgres
fi

# Chain to official Postgres entrypoint
exec /usr/local/bin/docker-entrypoint.sh "$@"
