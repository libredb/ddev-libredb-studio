#!/usr/bin/env bash
#ddev-generated
# Creates the LibreDB Studio login secrets of this project once, and keeps
# them from then on.
#
# They live in .ddev/.env.libredb-studio.local, which DDEV v1.25.4+ passes
# both to the libredb-studio container and to the interpolation of
# .ddev/docker-compose.*.yaml. Each developer gets their own values: a
# teammate who clones a project with a committed .ddev directory gets theirs
# on the first `ddev start`, through the pre-start hook in
# config.libredb-studio.yaml.
#
# DDEV adds /.env.*.local to .ddev/.gitignore only while it manages that file,
# so the script checks with Git itself and refuses to keep the secrets where
# a commit would pick them up.
#
# A failing pre-start hook only warns under DDEV's default fail_on_hook_fail,
# so the check also writes or removes LIBREDB_STUDIO_GIT_GUARD in the secrets
# file, and docker-compose.libredb-studio.yaml requires it: the pre-start hook
# runs before DDEV writes the compose file, so a failed check stops the start.
#
# Runs on the host, from post_install_actions and from that hook. A value
# that is already set is never replaced, so a restart keeps the login.
set -eu -o pipefail

ddev_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_name=.env.libredb-studio.local
env_file="${ddev_dir}/${env_name}"

# Checked before anything is written, and again on every start, so a project
# that becomes a Git repository later, or takes over .ddev/.gitignore, is
# caught as well. Outside a Git work tree there is nothing to commit to.
guard_key=LIBREDB_STUDIO_GIT_GUARD
if command -v git >/dev/null 2>&1 && git -C "${ddev_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git -C "${ddev_dir}" check-ignore -q "${env_name}"; then
    # Without the guard line the compose file cannot be rendered, so the start
    # stops even though DDEV only warns about this hook. The secrets stay.
    if [ -f "${env_file}" ] && grep -q "^${guard_key}=" "${env_file}"; then
      grep -v "^${guard_key}=" "${env_file}" >"${env_file}.tmp" || true
      cat "${env_file}.tmp" >"${env_file}"
      rm -f "${env_file}.tmp"
    fi
    {
      echo "ddev-libredb-studio: Git does not ignore .ddev/${env_name}, which holds the LibreDB Studio login secrets, so a commit could publish them."
      echo "  If .ddev/.gitignore is your own (it has no #ddev-generated line), add this line to it: /.env.*.local"
      echo "  If DDEV manages .ddev/.gitignore, run 'ddev config' once, which adds that line."
      echo "  If the file is already committed, also run: git rm --cached .ddev/${env_name}"
    } >&2
    exit 1
  fi
fi

# Letters and digits only, so the value needs no quoting in an env file and
# no escaping in a URL or a shell. 512 random bytes leave about 120 of them.
random_alnum() {
  local length="$1" value
  value="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-${length}")"
  if [ "${#value}" -ne "${length}" ]; then
    echo "ddev-libredb-studio: could not generate a ${length}-character secret from /dev/urandom" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

has_key() {
  [ -f "${env_file}" ] && grep -q "^$1=." "${env_file}"
}

umask 077
touch "${env_file}"
# Readable by the owner only, also when the file existed before with a wider mode.
chmod 600 "${env_file}"
# A hand-edited file may end without a newline; appending to it would join two lines.
if [ -s "${env_file}" ] && [ -n "$(tail -c 1 "${env_file}")" ]; then
  echo >>"${env_file}"
fi

created=""
if ! has_key LIBREDB_STUDIO_JWT_SECRET; then
  # LibreDB Studio needs at least 32 characters; 48 alphanumerics are about 285 bits.
  # Assigned first: a failure inside a command substitution used as an
  # argument would not stop the script.
  value="$(random_alnum 48)"
  printf 'LIBREDB_STUDIO_JWT_SECRET=%s\n' "${value}" >>"${env_file}"
  created="${created} LIBREDB_STUDIO_JWT_SECRET"
fi
if ! has_key LIBREDB_STUDIO_ADMIN_PASSWORD; then
  value="$(random_alnum 24)"
  printf 'LIBREDB_STUDIO_ADMIN_PASSWORD=%s\n' "${value}" >>"${env_file}"
  created="${created} LIBREDB_STUDIO_ADMIN_PASSWORD"
fi

# Reached only when Git ignores the file, or when there is no Git work tree.
if ! grep -q "^${guard_key}=ok$" "${env_file}"; then
  printf '%s=ok\n' "${guard_key}" >>"${env_file}"
fi

if [ -n "${created}" ]; then
  echo "ddev-libredb-studio: wrote${created} to .ddev/${env_name}; 'ddev libredb-studio' prints the login"
fi
