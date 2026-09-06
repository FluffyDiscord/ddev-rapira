#!/usr/bin/env bats

# Bats is a testing framework for Bash: https://bats-core.readthedocs.io/en/stable/
# Local run (install bats-core, bats-assert, bats-file, bats-support first):
#   bats ./tests/test.bats
#   bats ./tests/test.bats --filter-tags static        # no Docker needed
#   bats ./tests/test.bats --print-output-on-failure --show-output-of-passing-tests --verbose-run

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=FluffyDiscord/ddev-rapira

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p ~/tmp
  export TESTDIR=$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
}

teardown() {
  set -eu -o pipefail
  cd "${TESTDIR}" 2>/dev/null || true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# Sets up a minimal project whose front controller is the given testdata file, installs
# the add-on and restarts. Used by every integration test that expects a serving site.
installIntoBareProject() {
  local frontController=$1

  mkdir -p public
  cp "${DIR}/tests/testdata/${frontController}" public/index.php
  cp "${DIR}/tests/testdata/asset.txt" public/asset.txt

  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=public --php-version=8.5
  assert_success
  run ddev start -y
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
}

# bats test_tags=static
@test "TC-001: the shipped config files parse" {
  set -eu -o pipefail

  run bash -c "python3 -c \"import yaml; yaml.safe_load(open('${DIR}/install.yaml')); yaml.safe_load(open('${DIR}/config.rapira.yaml'))\""
  assert_success
  run bash -c "python3 -c \"import tomllib; tomllib.load(open('${DIR}/example.rapira.toml','rb'))\""
  assert_success
}

# bats test_tags=static
@test "TC-002: every installed file is ddev-owned except the nginx override" {
  set -eu -o pipefail

  for file in config.rapira.yaml web-build/Dockerfile.rapira web-build/rapira-daemon.sh commands/web/rapira-restart; do
    run grep -q '#ddev-generated' "${DIR}/${file}"
    assert_success
  done

  # The override must carry no ownership marker, or ddev regenerates it back to php-fpm.
  # Asserted on the matches, not on grep's status, so a missing file cannot pass this.
  run bash -c "grep -c '#ddev-generated' '${DIR}/nginx_full/nginx-site.conf' || true"
  assert_output "0"
}

# bats test_tags=static
@test "TC-003: the nginx override proxies to Rapira and nothing else" {
  set -eu -o pipefail

  run grep -q 'ddev-rapira-managed' "${DIR}/nginx_full/nginx-site.conf"
  assert_success
  run grep -q 'upstream rapira_backend' "${DIR}/nginx_full/nginx-site.conf"
  assert_success
  run grep -q 'proxy_pass http://rapira_backend\$request_uri;' "${DIR}/nginx_full/nginx-site.conf"
  assert_success
  run grep -q 'fastcgi_pass' "${DIR}/nginx_full/nginx-site.conf"
  assert_failure
}

# bats test_tags=static
@test "TC-004: the daemon command carries no quote characters" {
  set -eu -o pipefail

  # ddev interpolates this value into a double-quoted supervisord command that is then
  # shell-lexed, so any quote written here is silently stripped. Read the parsed value,
  # not the file text, so a quote inside the value cannot slip past a grep.
  run bash -c "python3 -c \"import yaml; print(yaml.safe_load(open('${DIR}/config.rapira.yaml'))['web_extra_daemons'][0]['command'])\""
  assert_success
  assert_output "rapira-daemon"
}

# bats test_tags=static
@test "TC-005: the Dockerfile keeps its load-bearing steps" {
  set -eu -o pipefail

  run grep -q 'set -eux -o pipefail' "${DIR}/web-build/Dockerfile.rapira"
  assert_success
  run grep -q 'sha256sum --ignore-missing -c' "${DIR}/web-build/Dockerfile.rapira"
  assert_success
  run grep -q 'embed/php.ini' "${DIR}/web-build/Dockerfile.rapira"
  assert_success
  run grep -q 'embed/conf.d' "${DIR}/web-build/Dockerfile.rapira"
  assert_success
  for script in enable_xdebug disable_xdebug enable_xhprof disable_xhprof; do
    run grep -q "/usr/local/bin/${script}" "${DIR}/web-build/Dockerfile.rapira"
    assert_success
  done
}

# bats test_tags=static
@test "TC-006: the shipped shell scripts pass shellcheck" {
  set -eu -o pipefail

  if ! command -v shellcheck >/dev/null; then
    skip "shellcheck is not installed"
  fi
  run shellcheck "${DIR}/commands/web/rapira-restart" "${DIR}/web-build/rapira-daemon.sh"
  assert_success
}

# bats test_tags=static
@test "TC-007: the repository names no other application server" {
  set -eu -o pipefail

  # This file holds the pattern and is excluded from its own search, so these words
  # appear exactly once in the repository: here.
  local forbidden='roadrunner|\.rr\.|RR_|spiral'

  # Assert on the matches rather than on grep's status, so a search that fails to run
  # cannot look like a clean repository.
  run bash -c "grep -rniE '${forbidden}' '${DIR}' --exclude-dir=.git --exclude=test.bats || true"
  assert_output ""

  if ! gh auth status >/dev/null 2>&1; then
    skip "gh is not authenticated; cannot check the repository description and topics"
  fi
  # Piped, never re-expanded through a shell string: the description holds an apostrophe.
  run bash -c "gh repo view '${GITHUB_REPO}' --json description,repositoryTopics | grep -icE '${forbidden}' || true"
  assert_output "0"
}

# bats test_tags=serve
@test "IT-001: Rapira serves the app, with the original request path, and nginx serves static files" {
  set -eu -o pipefail

  installIntoBareProject index.php

  # No rapira.toml exists, so this also proves the classic-mode fallback.
  run curl -sf "https://${PROJNAME}.ddev.site/some/path?q=1"
  assert_success
  assert_output --partial "sapi=rapira"
  assert_output --partial "uri=/some/path?q=1"

  run curl -sf "https://${PROJNAME}.ddev.site/asset.txt"
  assert_success
  assert_output --partial "static-ok"

  run ddev exec supervisorctl status
  assert_output --regexp 'webextradaemons:rapira[[:space:]]+RUNNING'

  run ddev exec grep -q 'proxy_pass http://rapira_backend' /etc/nginx/sites-enabled/nginx-site.conf
  assert_success
}

# bats test_tags=runtime
@test "IT-002: Rapira runs ddev's PHP configuration, extensions and environment" {
  set -eu -o pipefail

  installIntoBareProject runtime.php

  run curl -sf "https://${PROJNAME}.ddev.site/"
  assert_success
  assert_output --partial "sapi=rapira"
  local served="${output}"

  # The ini values must be php-fpm's, not the embed package's stock production ini.
  # The reference is fpm's php.ini read at test time, so a ddev default change is not a
  # failure. Not `ddev php -r ini_get(...)`: that is the CLI ini, which differs by design.
  for directive in memory_limit max_execution_time upload_max_filesize post_max_size variables_order sendmail_path; do
    run ddev exec "php -r 'echo parse_ini_file(\"/etc/php/8.5/fpm/php.ini\")[\"${directive}\"];'"
    assert_success
    [[ "${served}" == *"ini:${directive}=${output}"* ]] || fail "Rapira reports a different ${directive} than php-fpm's ini (${output})"
  done

  run bash -c "echo '${served}'"
  for extension in pdo_pgsql pgsql intl bcmath gd zip redis igbinary sodium "Zend OPcache"; do
    assert_output --partial "ext:${extension}=yes"
  done

  # ddev ships both profilers disabled; the embed SAPI must agree.
  assert_output --partial "ext:xdebug=no"
  assert_output --partial "ext:xhprof=no"

  assert_output --partial "env:IS_DDEV_PROJECT=true"
  assert_output --partial "server:HTTP_X_FORWARDED_PROTO=https"
}

# bats test_tags=profilers
@test "IT-003: the profiler toggles reach Rapira, one at a time" {
  set -eu -o pipefail

  installIntoBareProject runtime.php

  # Counted, not `grep -L`, whose exit status is 1 even when it lists the files it found.
  local profilerScripts="/usr/local/bin/enable_xdebug /usr/local/bin/disable_xdebug /usr/local/bin/enable_xhprof /usr/local/bin/disable_xhprof"

  run ddev exec "cat ${profilerScripts} | grep -c 'killall -USR2 php-fpm' || true"
  assert_output "0"

  run ddev exec "cat ${profilerScripts} | grep -c \"supervisorctl start 'webextradaemons:\\*'\" || true"
  assert_output "4"

  run ddev xdebug on
  assert_success
  run curl -sf "https://${PROJNAME}.ddev.site/"
  assert_success
  assert_output --partial "ext:xdebug=yes"

  # enable_xhprof disables xdebug, so the two are asserted in sequence, never together.
  run ddev xhprof on
  assert_success
  run curl -sf "https://${PROJNAME}.ddev.site/"
  assert_success
  assert_output --partial "ext:xhprof=yes"
  assert_output --partial "ext:xdebug=no"

  # The trailing slash matters: /xhprof is a 301 to /xhprof/, and curl -f does not fail on 3xx.
  run curl -sfI "https://${PROJNAME}.ddev.site/xhprof/"
  assert_success
  assert_output --partial "200"
}

# bats test_tags=removal
@test "IT-004: removal restores php-fpm routing and leaves the project's own files alone" {
  set -eu -o pipefail

  installIntoBareProject index.php
  cp "${DIR}/example.rapira.toml" rapira.toml

  run ddev add-on remove rapira
  assert_success
  assert_file_not_exist .ddev/config.rapira.yaml
  assert_file_not_exist .ddev/nginx_full/nginx-site.conf
  assert_file_exist rapira.toml

  run ddev restart -y
  assert_success
  run ddev exec grep -q php-fpm.sock /etc/nginx/sites-enabled/nginx-site.conf
  assert_success
}

# bats test_tags=gates
@test "IT-005: install is refused on an unsupported PHP version, project type, or foreign nginx override" {
  set -eu -o pipefail

  mkdir -p public
  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=public --php-version=8.3
  assert_success
  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "8.5"

  run ddev config --project-name="${PROJNAME}" --project-type=drupal11 --docroot=public --php-version=8.5
  assert_success
  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "drupal11"

  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=public --php-version=8.5
  assert_success
  mkdir -p .ddev/nginx_full
  echo "# my own config" > .ddev/nginx_full/nginx-site.conf
  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "nginx-site.conf"
}

# bats test_tags=config
@test "IT-006: the docroot and config-file knobs are honored" {
  set -eu -o pipefail

  mkdir -p web
  cp "${DIR}/tests/testdata/index.php" web/index.php

  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=web --php-version=8.5
  assert_success
  run ddev dotenv set .ddev/.env.web --rapira-config-file=rapira.dev.toml
  assert_success

  # A listen address the add-on must override, and an entrypoint under the web/ docroot.
  cat > rapira.dev.toml <<'TOML'
[http]
listen = "127.0.0.1:9999"

[pool]
mode = "classic"
entrypoint = "web/index.php"
TOML

  run ddev start -y
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run grep -q 'root /var/www/html/web;' .ddev/nginx_full/nginx-site.conf
  assert_success
  run ddev restart -y
  assert_success

  # A 200 here proves --listen beat the config file's 9999.
  run curl -sf "https://${PROJNAME}.ddev.site/"
  assert_success
  assert_output --partial "sapi=rapira"
}

# bats test_tags=reinstall
@test "IT-007: re-installing replaces the nginx override and keeps a backup" {
  set -eu -o pipefail

  installIntoBareProject index.php
  echo "# hand edit" >> .ddev/nginx_full/nginx-site.conf

  run ddev add-on get "${DIR}"
  assert_success
  run grep -q '# hand edit' .ddev/nginx_full/nginx-site.conf
  assert_failure
  run bash -c "grep -lq '# hand edit' .ddev/nginx-site.conf.ddev-rapira-backup-*"
  assert_success

  run ddev restart -y
  assert_success
  run curl -sf "https://${PROJNAME}.ddev.site/"
  assert_success
  assert_output --partial "sapi=rapira"
}

# bats test_tags=daemons
@test "IT-008: a project's own web_extra_daemon survives the install" {
  set -eu -o pipefail

  mkdir -p public
  cp "${DIR}/tests/testdata/index.php" public/index.php
  run ddev config --project-name="${PROJNAME}" --project-type=php --docroot=public --php-version=8.5
  assert_success

  mkdir -p .ddev
  cat > .ddev/config.sleeper.yaml <<'YAML'
web_extra_daemons:
  - name: "sleeper"
    command: "sleep infinity"
    directory: /var/www/html
YAML

  run ddev start -y
  assert_success
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run ddev exec supervisorctl status
  assert_output --regexp 'webextradaemons:rapira[[:space:]]+RUNNING'
  assert_output --regexp 'webextradaemons:sleeper[[:space:]]+RUNNING'
}
