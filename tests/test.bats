#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=libredb/ddev-libredb-studio

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  # A second project, for the tests that run two projects side by side
  export OTHER_PROJNAME="${PROJNAME}-other"
  export OTHERDIR=""
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  ddev delete -Oy "${OTHER_PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  echo > .cookie-jar.txt
  export STUDIO_URL="https://${PROJNAME}.ddev.site:9401"
  export SECRETS_FILE=.ddev/.env.libredb-studio.local
}

# Creates and starts the project, with extra `ddev config` flags if given.
start_project() {
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site "$@"
  assert_success
  run ddev start -y
  assert_success
}

# Creates and starts a second project with a db and a mongo service. Every
# DDEV project shares the ddev_default network, where the short names db and
# mongo then resolve to this project's containers.
start_other_project() {
  OTHERDIR="$(mktemp -d "${HOME}/tmp/${OTHER_PROJNAME}.XXXXXX")"
  pushd "${OTHERDIR}" >/dev/null
  run ddev config --project-name="${OTHER_PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev add-on get ddev/ddev-mongo
  assert_success
  run ddev start -y
  assert_success
  popd >/dev/null
}

secret() {
  grep "^$1=" "${SECRETS_FILE}" | cut -d= -f2-
}

login() {
  run curl -sf -o /dev/null -w '%{http_code}' --cookie-jar .cookie-jar.txt \
    -H 'Content-Type: application/json' \
    --data "{\"email\":\"admin@ddev.site\",\"password\":\"$(secret LIBREDB_STUDIO_ADMIN_PASSWORD)\"}" \
    "${STUDIO_URL}/api/auth/login"
  assert_success
  assert_output "200"
}

managed_connections() {
  run curl -sf --cookie .cookie-jar.txt "${STUDIO_URL}/api/connections/managed"
  assert_success
}

# query <connection id> <statement>
query() {
  local body
  body="$(jq -cn --arg id "seed:$1" --arg sql "$2" '{connectionId: $id, sql: $sql}')"
  run curl -sf --cookie .cookie-jar.txt -H 'Content-Type: application/json' --data "${body}" "${STUDIO_URL}/api/db/query"
  assert_success
}

# Checks one seeded connection: listed, managed, admin-only, without secrets,
# and addressed by this project's own container name.
assert_seeded() {
  managed_connections
  local entry
  entry="$(echo "${output}" | jq -c --arg id "seed:$1" '.connections[] | select(.id == $id)')"
  assert [ -n "${entry}" ]
  run jq -r '[.type, .managed, (.roles | join(","))] | join(" ")' <<<"${entry}"
  assert_output "$2 true admin"
  refute [ "$(jq 'has("password") or has("connectionString")' <<<"${entry}")" = "true" ]
  run jq -r '.host' <<<"${entry}"
  assert_output "ddev-${PROJNAME}-$3"
}

health_checks() {
  # The login secrets exist, only the owner can read them, and the JWT
  # secret meets Studio's 32-character minimum
  assert_file_exist "${SECRETS_FILE}"
  run find "${SECRETS_FILE}" -perm 600
  assert_output "${SECRETS_FILE}"
  assert [ "$(secret LIBREDB_STUDIO_JWT_SECRET | wc -c)" -gt 32 ]

  # DDEV's rendered compose file, which holds the resolved secrets, is
  # readable by the owner only after a start
  run find .ddev/.ddev-docker-compose-full.yaml -perm 600
  assert_output .ddev/.ddev-docker-compose-full.yaml

  # Studio answers through the router
  run curl -sf "${STUDIO_URL}/api/db/health"
  assert_success

  # A wrong password is refused, the generated one is accepted
  run curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    --data '{"email":"admin@ddev.site","password":"db"}' "${STUDIO_URL}/api/auth/login"
  assert_output "401"
  login

  # `ddev libredb-studio` prints the login and opens the HTTPS port
  DDEV_DEBUG=true run ddev libredb-studio
  assert_success
  assert_output --partial "LibreDB Studio login: admin@ddev.site / $(secret LIBREDB_STUDIO_ADMIN_PASSWORD)"
  assert_output --partial "FULLURL ${STUDIO_URL}"
}

# Checks the project database: listed, and a query through Studio reads a
# row written through DDEV.
db_checks() {
  local family="$1"
  if [ "${family}" = "postgres" ]; then
    run ddev psql -c "CREATE TABLE libredb_probe (name text); INSERT INTO libredb_probe VALUES ('from-ddev');"
  else
    run ddev mysql -e "CREATE TABLE libredb_probe (name VARCHAR(20)); INSERT INTO libredb_probe VALUES ('from-ddev');"
  fi
  assert_success
  assert_seeded ddev-db "${family}" db
  query ddev-db "SELECT name FROM libredb_probe"
  assert_output --partial '"rows":[{"name":"from-ddev"}]'
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  if [ -n "${OTHERDIR}" ]; then
    ddev delete -Oy "${OTHER_PROJNAME}" >/dev/null 2>&1
    rm -rf "${OTHERDIR}"
  fi
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  start_project
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  db_checks mysql

  # Only the project database is seeded by default
  managed_connections
  run jq -r '[.connections[].id] | join(" ")' <<<"${output}"
  assert_output "seed:ddev-db"

  # A restart keeps the login
  local password
  password="$(secret LIBREDB_STUDIO_ADMIN_PASSWORD)"
  run ddev restart -y
  assert_success
  assert_equal "$(secret LIBREDB_STUDIO_ADMIN_PASSWORD)" "${password}"
  login
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  start_project
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  db_checks mysql
}

@test "install from directory with postgres" {
  set -eu -o pipefail
  start_project --database=postgres:16
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  db_checks postgres
}

# MySQL 8.4 logs in with caching_sha2_password, which over a connection
# without TLS takes a different path in the driver than MariaDB does.
@test "install from directory with mysql 8.4" {
  set -eu -o pipefail
  start_project --database=mysql:8.4
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  db_checks mysql
}

@test "a missing secrets file is created again on start" {
  set -eu -o pipefail
  start_project
  run ddev add-on get "${DIR}"
  assert_success
  # A teammate's clone of a project whose .ddev directory is committed
  rm -f "${SECRETS_FILE}"
  run ddev restart -y
  assert_success
  health_checks
}

@test "secrets are never written where Git would commit them" {
  set -eu -o pipefail
  start_project
  run git init -q
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  # The project takes over .ddev/.gitignore, without DDEV's .env.*.local line
  grep -v -e '#ddev-generated' -e '\.env\.\*\.local' .ddev/.gitignore > .ddev/.gitignore.new
  mv .ddev/.gitignore.new .ddev/.gitignore
  rm -f "${SECRETS_FILE}"
  run ddev restart -y
  assert_failure
  assert_output --partial "Git does not ignore .ddev/.env.libredb-studio.local"
  assert_file_not_exist "${SECRETS_FILE}"

  # The fix the message names
  echo '/.env.*.local' >> .ddev/.gitignore
  run ddev restart -y
  assert_success
  health_checks
}

@test "a project without a db container gets no db connection" {
  set -eu -o pipefail
  start_project --omit-containers=db
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-wait-seconds=5
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
  managed_connections
  run jq -r '.connections | length' <<<"${output}"
  assert_output "0"
  run ddev logs -s libredb-studio
  assert_output --partial "this project has no 'db' service"
}

@test "another running project's services are never used" {
  set -eu -o pipefail
  start_other_project
  start_project --omit-containers=db
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-wait-seconds=5
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # The other project's db answers to the name db, but is not this project's
  health_checks
  managed_connections
  run jq -r '.connections | length' <<<"${output}"
  assert_output "0"
  run ddev logs -s libredb-studio
  assert_output --partial "this project has no 'db' service (ddev-${PROJNAME}-db)"

  # The same for an opt-in: the other project's mongo does not stand in
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-seed-mongo=true
  assert_success
  run ddev restart -y
  assert_failure
  run ddev logs -s libredb-studio
  assert_output --partial "LIBREDB_STUDIO_SEED_MONGO=true, but no 'mongo' service (ddev-${PROJNAME}-mongo) answers"
}

@test "redis is seeded when switched on" {
  set -eu -o pipefail
  start_project
  run ddev add-on get ddev/ddev-redis
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-seed-redis=true
  assert_success
  run ddev restart -y
  assert_success
  login
  assert_seeded ddev-redis redis redis
  run ddev exec -s redis redis-cli SET libredb_probe from-ddev
  assert_success
  query ddev-redis "GET libredb_probe"
  assert_output --partial '"rows":[{"result":"from-ddev"}]'
}

@test "mongo is seeded when switched on" {
  set -eu -o pipefail
  start_project
  run ddev add-on get ddev/ddev-mongo
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-seed-mongo=true
  assert_success
  run ddev restart -y
  assert_success
  login
  assert_seeded ddev-mongo mongodb mongo
  run ddev exec -s mongo mongosh -u db -p db --authenticationDatabase admin db --quiet --eval 'db.libredb_probe.insertOne({name: "from-ddev"})'
  assert_success
  query ddev-mongo '{"collection":"libredb_probe","operation":"find","filter":{},"options":{"projection":{"_id":0}}}'
  assert_output --partial '"rows":[{"name":"from-ddev"}]'
}

# bats test_tags=sqlsrv
@test "sqlsrv is seeded when switched on" {
  set -eu -o pipefail
  if [ "$(uname -m)" != "x86_64" ]; then
    skip "ddev/ddev-sqlsrv runs a linux/amd64 image only"
  fi
  start_project
  run ddev add-on get ddev/ddev-sqlsrv
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-seed-sqlsrv=true
  assert_success
  run ddev restart -y
  assert_success
  login
  assert_seeded ddev-sqlsrv mssql sqlsrv
  query ddev-sqlsrv "SELECT 'from-ddev' AS name"
  assert_output --partial '"rows":[{"name":"from-ddev"}]'
}

@test "a switched-on service that is missing stops the start with an error" {
  set -eu -o pipefail
  start_project
  run ddev add-on get "${DIR}"
  assert_success
  run ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-seed-mongo=true --libredb-studio-wait-seconds=5
  assert_success
  run ddev restart -y
  assert_failure
  run ddev logs -s libredb-studio
  assert_output --partial "LIBREDB_STUDIO_SEED_MONGO=true, but no 'mongo' service (ddev-${PROJNAME}-mongo) answers"
}
