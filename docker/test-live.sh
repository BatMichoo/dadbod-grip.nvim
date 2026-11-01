#!/usr/bin/env bash
# Run the live suite (`just test-live <database>`) inside the runner container
# against the matching database from compose.yaml, starting it if needed.
#
#   docker/test-live.sh mysql-8.4 [sqlserver-2025 ...]
#   docker/test-live.sh all
set -euo pipefail

all=(postgresql-16 mysql-8.4 mariadb-11.8 sqlserver-2025)
compose=(docker compose -f "$(dirname "$0")/compose.yaml")

run_one() {
  local database="$1" service url
  case "$database" in
    postgresql-16)
      service=postgres url="postgresql://postgres:grip@postgres:5432/grip_test" ;;
    mysql-8.4)
      service=mysql url="mysql://root:grip@mysql:3306/grip_test" ;;
    mariadb-11.8)
      service=mariadb url="mariadb://root:grip@mariadb:3306/grip_test" ;;
    sqlserver-2025)
      service=sqlserver
      url="sqlserver://sa:Grip-ci-2025!@sqlserver:1433/grip_test?encrypt=optional&trust_server_certificate=true" ;;
    *)
      echo "Unknown database: $database (expected one of: ${all[*]}, or all)" >&2
      return 2 ;;
  esac
  "${compose[@]}" up -d --wait "$service"
  "${compose[@]}" run --rm --user "$(id -u):$(id -g)" \
    -e GRIP_TEST_LIVE_URL="$url" runner just test-live "$database"
}

[[ $# -gt 0 ]] || { echo "usage: $0 <database>... | all" >&2; exit 2; }
[[ "$1" == all ]] && set -- "${all[@]}"

# Build once up front, not inside every run.
"${compose[@]}" build runner

failed=()
for database in "$@"; do
  echo "==> $database"
  run_one "$database" || failed+=("$database")
done

if ((${#failed[@]})); then
  echo "Live suite failed for: ${failed[*]}" >&2
  exit 1
fi
echo "Live suite passed for: $*"
