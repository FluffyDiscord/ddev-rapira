#!/usr/bin/env bash

#ddev-generated
# Launches Rapira for the ddev-rapira add-on, invoked by supervisord as `rapira-daemon`.
#
# --listen is passed on the command line, where it overrides whatever the config file
# says, because nginx proxies to a fixed port that a project-owned file must not break.
#
# --processes is pinned only on the fallback, which has no config file to size the pool.
# A project's own rapira.toml owns its process count.

set -eu

config="${RAPIRA_CONFIG_FILE:-rapira.toml}"

if [ -f "$config" ]; then
    exec rapira serve --listen 127.0.0.1:8000 --config "$config"
fi

exec rapira serve --listen 127.0.0.1:8000 --mode classic --processes 1 "/var/www/html/${DDEV_DOCROOT:-}/index.php"
