#!/usr/bin/env bash

#ddev-generated
# Launches Rapira for the ddev-rapira add-on, invoked by supervisord as `rapira-daemon`.
#
# `rapira serve` takes a config file and nothing else, so a project's own file is served
# as-is; it has to listen on port 8000, where nginx proxies.
#
# Without one, a classic-mode config for the docroot's index.php is written and served.
# Its pool is pinned to one worker; Rapira's default is the CPU count.

set -eu

config="${RAPIRA_CONFIG_FILE:-rapira.toml}"

if [ ! -f "$config" ]; then
    config=/tmp/rapira-fallback.toml
    cat > "$config" <<TOML
[http]
listen = "127.0.0.1:8000"

[http.pool]
mode = "classic"
entrypoint = "/var/www/html/${DDEV_DOCROOT:-}/index.php"
processes = 1
TOML
fi

exec rapira serve "$config"
