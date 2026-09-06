# DDEV Rapira Add-on — Design (Implementation)

**Source pinned to:** 2026-09-06 · Rapira `v0.8.1` (released 2026-09-05) · DDEV `v1.25.2` (web image `ddev/ddev-webserver:v1.25.2`, Debian trixie + sury PHP)

Every "verified" claim below was measured on 2026-09-06 — in a container built `FROM` this DDEV web image, through real nginx in front of a real Rapira, or read out of DDEV `v1.25.2`'s own source at the cited line. Nothing here is recalled. Every measurement was taken on **amd64**; see the arm64 assumption.

---

## 1. Goal

`ddev add-on get FluffyDiscord/ddev-rapira` + `ddev restart` serves the project through [Rapira](https://github.com/rapira-rs/rapira) instead of php-fpm, with DDEV's nginx still in front (TLS, static files, `/phpstatus`, `/xhprof`).

| # | Acceptance criterion | Verified by |
|---|---|---|
| AC-1 | After install + restart, `https://<project>.ddev.site` is answered by Rapira, not php-fpm | IT-001: the response carries `php_sapi_name() === 'rapira'` |
| AC-2 | Works on a project with no Rapira config file at all | IT-001 installs into a project holding only `public/index.php` |
| AC-3 | Rapira runs DDEV's PHP configuration, not sury's stock one: `memory_limit`, `max_execution_time`, `upload_max_filesize`, `post_max_size`, `sendmail_path`, `variables_order` and the extension set all match php-fpm's | IT-002 |
| AC-4 | `web_environment` values and `IS_DDEV_PROJECT` are visible in `$_ENV`, as they are under php-fpm | IT-002 |
| AC-5 | On a fresh install xdebug and xhprof are **off**, as DDEV ships them; `ddev xdebug on` and `ddev xhprof on` each take effect on the next request | IT-003. They are mutually exclusive — `enable_xhprof` runs `phpdismod blackfire xdebug` — so they are asserted one at a time |
| AC-6 | The original request path reaches the app, not nginx's rewritten `/index.php` | IT-001 asserts `REQUEST_URI` equals the requested path + query |
| AC-7 | `ddev add-on remove rapira` restores php-fpm routing and leaves the project's own files untouched | IT-004 |
| AC-8 | Re-running `ddev add-on get` on an installed project updates every add-on file, including the nginx override, and backs up the replaced one | IT-007 |
| AC-9 | Static files and the `/xhprof` UI keep being served, by nginx and php-fpm respectively | IT-001, IT-003 |

## 2. Architecture

```
ddev-router ──► nginx (webserver_type: nginx-fpm)
                 ├─ static files from the docroot
                 ├─ /phpstatus, /xhprof ──fastcgi──► php-fpm (idle otherwise)
                 └─ location ~ \.php$ ──proxy_pass──► upstream 127.0.0.1:8000
                                                       rapira (web_extra_daemon)
                                                         └─ libphp + php.ini + conf.d = php-fpm's
```

Rapira embeds `libphp.so`; it is not a standalone binary. The add-on installs the release binary, points it at the DDEV image's own PHP through sury's embed SAPI package, and symlinks the embed SAPI's `php.ini` and `conf.d` onto php-fpm's (D-8) — so the app server runs the same PHP build, the same extensions, the same ini values and the same user `.ddev/php/*.ini` overrides that `ddev php` and php-fpm use.

## 3. Decisions

| # | Decision | Rejected alternative | Rationale |
|---|---|---|---|
| D-1 | `webserver_type: nginx-fpm`; Rapira runs as a `web_extra_daemon` behind nginx | `webserver_type: generic` (Rapira serves HTTP directly) | `generic` drops DDEV's nginx, and with it TLS, static-file serving, the `/phpstatus` container healthcheck and the `/xhprof` UI — all of which `fastcgi_pass` to php-fpm (`/etc/nginx/monitoring.conf`, `/etc/nginx/common.d/xhprof.conf`, read out of the v1.25.2 image). php-fpm stays up and idle so those keep working |
| D-2 | Binary from the GitHub release tarball, **binary only** (`--strip-components=2 <release>/bin/rapira`) | `COPY --from=ghcr.io/rapira-rs/rapira:0.8.1-php<v>`; the `.deb` package | `COPY --from` cannot interpolate a build arg — BuildKit refuses with *"variable expansion is not supported for --from"* (verified). Its documented workaround is a `FROM` in a `web-build/prepend.Dockerfile.*` using a global-scope ARG, which additionally forces re-declaring DDEV's own `BASE_IMAGE` global arg (a `FROM` above it makes DDEV's `ARG BASE_IMAGE` stage-scoped and its `FROM $BASE_IMAGE` then fails with *"base name should not be blank"*, verified) — a second file coupled to DDEV's generated header, to save three lines. The `.deb` and the full tarball both install a `libphp.so` (26,016,144 bytes, decimal) that D-3 immediately replaces |
| D-3 | libphp = sury `libphp${DDEV_PHP_VERSION}-embed`, symlinked over the path the binary's RUNPATH resolves | Rapira's bundled libphp, with `PHPRC` / `PHP_INI_SCAN_DIR` / `extension_dir` pointed at sury's directories | Rapira's own libphp carries no `pdo_pgsql`, `pgsql`, `bcmath`, `intl`, `igbinary` or `redis` ([rapira#103](https://github.com/rapira-rs/rapira/issues/103)) — useless for a real app. With sury's, every extension of the DDEV image loads (verified). The env-var variant mixes an 8.5.10 libphp with 8.5.5-built extension `.so`s: same API number, but unverified, with segfaults as the failure mode |
| D-4 | The only change to DDEV's site config is inside `location ~ \.php$`: the `fastcgi_*` body becomes `proxy_pass http://rapira_backend$request_uri;` plus proxy headers | A named `location @app` reached from a rewritten `try_files` | `proxy_pass` forwards the **rewritten** URI, so `try_files … /index.php?$query_string` would hand the app `/index.php` and lose the real path. `$request_uri` is the unmodified original request line including its query, and a `proxy_pass` carrying a URI does not append `$args` — the `REQUEST_URI` semantics FastCGI gives today. Verified end to end through real nginx: `/cs/produkty?page=2` arrives as `REQUEST_URI=/cs/produkty?page=2`. Every other `try_files … /index.php` fallback — DDEV's own, and any in a user's `.ddev/nginx/*.conf` include — therefore keeps working unchanged |
| D-5 | The listen address is pinned on the daemon command line (`--listen 127.0.0.1:8000`) | Trusting the project's `rapira.toml` `[http] listen` | nginx hard-codes the upstream, but the add-on does not own the config file (D-7). A CLI flag overrides the file (verified: a toml with `listen = "127.0.0.1:9999"` served on 8000, and 9999 refused connections), which removes the mismatch failure class instead of documenting it |
| D-6 | No project config file → the daemon falls back to `--mode classic /var/www/html/${DDEV_DOCROOT}/index.php` | Failing with guidance | Rapira's classic mode re-runs the entrypoint per request and populates the CGI superglobals, so it serves a plain front controller for any framework with no app changes (verified: `REQUEST_URI`, `QUERY_STRING`, `$_GET`, `$_POST`, `$_COOKIE`, `php://input` and `HTTP_*` all correct — but read §5.3's `$_SERVER` table for what a proxy cannot supply). Without the fallback, `ddev add-on get` + `ddev restart` leaves a crash-looping daemon (`Error: no entrypoint: pass a SCRIPT argument or set pool.entrypoint in the config file`, verified) |
| D-7 | The add-on never writes, copies or edits `rapira.toml`, and never touches app source | Copying a `#ddev-generated` `rapira.toml` into the project root; `composer require`-ing a framework bundle | A generated file in the project root is overwritten on re-install and deleted on removal, putting user edits at risk. DDEV bind-mounts the project, so the user's own file is live and entirely theirs. `example.rapira.toml` ships in the repo as a reference and is not installed |
| D-8 | The embed SAPI's `php.ini` and `conf.d` are **symlinked onto php-fpm's** | Writing individual overrides into the embed `conf.d` | The embed package creates its own `php.ini` from sury's `php.ini-production`, which is a different runtime from the one DDEV configures. Measured, embed vs DDEV's fpm: `memory_limit` 128M vs 1024M · `max_execution_time` 30 vs 600 · `upload_max_filesize` 2M vs 100M · `post_max_size` 8M vs 100M · `display_errors` Off vs On · `max_input_vars` 1000 vs 5000 · `sendmail_path` unset vs mailpit (mail silently vanishes) · `opcache.memory_consumption` default vs 500 · `variables_order` GPCS vs EGPCS. And `/start.sh:46-47` copies `.ddev/php/*.ini` into `cli/conf.d` and `fpm/conf.d` only, so **every user ini override would be invisible to Rapira**. Patching the keys one at a time is a symptom fix; the cause is that embed reads a different ini tree. Symlinking both onto fpm's fixes all of it at once — verified after the change: `memory_limit=1024M`, `upload=100M`, `max_execution_time=600`, `sendmail_path` = mailpit, `variables_order=EGPCS` (so no separate EGPCS override is needed), `$_ENV['IS_DDEV_PROJECT']=true`, all extensions of AC-3 loaded. It also fixes a second defect for free: DDEV runs `phpdismod blackfire xdebug xhprof` (`config.go:1313`) *before* user Dockerfiles, so installing the embed package afterwards makes php-common link **xdebug and xhprof into the new embed `conf.d`** — both loaded on every Rapira request, with `xdebug.start_with_request=yes` and xhprof's `auto_prepend_file`, and `/start.sh` only ever disables xdebug. Sharing fpm's `conf.d` makes the SAPIs agree: verified `xdebug=no, xhprof=no` on a fresh build, `xdebug=yes` after `ddev xdebug on`, `xhprof=yes` (and xdebug back off) after `ddev xhprof on` |
| D-9 | `enable_xdebug`, `disable_xdebug`, `enable_xhprof`, `disable_xhprof` are patched to bounce the daemon | Documenting `ddev rapira-restart` as a manual follow-up | Those four scripts bounce `webextradaemons:*` only when `DDEV_WEBSERVER_TYPE = generic`, else they `killall -USR2 php-fpm` (read out of the v1.25.2 image). libphp reads its ini once at startup, so under D-1 a resident Rapira worker would never see the toggle. Replacing that one line in exactly those four files is the cause-level fix. The replacement is `supervisorctl stop` followed by `supervisorctl start` rather than `restart` (D-17), and is redirected to `/dev/null` because `/start.sh:85` calls `disable_xdebug` before supervisord exists, where an unredirected `supervisorctl` prints `unix:///var/run/supervisor.sock no such file` on every container start (verified). The `sed` matches `killall -USR2 php-fpm 2>/dev/null` in full so no stray redirect is left behind. The wildcard bounces *every* extra daemon, matching what DDEV's own `generic` branch does; `ddev rapira-restart` is the narrow form |
| D-10 | `nginx_full/nginx-site.conf` carries **no** DDEV generated-file marker, and a host-side `removal_action` deletes it | Redefining `location ~ \.php$` from a supported `.ddev/nginx/*.conf` include | That include is pulled in *inside* the same `server {}` block, so a second `location ~ \.php$` is a duplicate-location error, and it is included after DDEV's, so it could not win regex ordering either. A markerless `nginx_full/nginx-site.conf` is DDEV's own documented ownership mechanism (`README.nginx_full.txt` instructs exactly this). DDEV owns any such file in which its generated-file marker appears **as a substring anywhere, comments included**, and regenerates it back to php-fpm on every start; for the same reason it refuses to auto-remove a markerless one, so the `removal_action` (guarded by the `ddev-rapira-managed` sentinel) does it. Side effect worth knowing: `GenerateWebserverConfig` (`ddevapp.go:2360-2369`) iterates a Go map of six webserver config targets and `return nil`s on the first one lacking the signature, so once our file is installed the other five (`apache/apache-site.conf`, `seconddocroot.conf.example`, the `nginx_full` README…) may or may not be re-rendered on a given start, depending on map order. Harmless today; it means a future DDEV update to those files may not land |
| D-11 | Hard-fail install on any PHP other than 8.4 / 8.5 | Warning and continuing | Rapira publishes `php8.4` and `php8.5` builds only — every release asset since v0.6.0. Any other `DDEV_PHP_VERSION` has no binary to install, so the build would fail later and less clearly |
| D-12 | Hard-fail install on any project type other than `php` and `symfony` | Shipping one nginx file for every type | DDEV v1.25.2 ships a distinct `nginx-site-<type>.conf` for 23 project types. `nginx-site-symfony.conf` differs from `nginx-site-php.conf` in its two leading comment lines only (verified by diff), but `laravel`, `drupal*`, `magento*`, `typo3`, `shopware6`, `wordpress` and the rest carry real extra rules. Installing this add-on's copy on one of those would silently replace that project's routing. A gate fails loudly instead. The gate is one-shot: changing the project type *after* install keeps the php/symfony routing, because DDEV then declines to regenerate the markerless file. That is a §9 row rather than a post-start hook — a rare, self-inflicted and recoverable state does not earn a check on every `ddev start` |
| D-13 | One custom command, `ddev rapira-restart` | A `ddev rapira` CLI passthrough | Rapira's only functional subcommand is `serve` (`rapira --help`: `serve`, `help`) — there is no `reset`, `workers` or `stop` for a passthrough to reach, and `ddev rapira serve` would start a second server fighting for port 8000. Reloading resident workers after a code edit is the one operation that needs a command. `supervisorctl restart` also *starts* a stopped program, so the same command recovers the D-16 case |
| D-14 | The daemon's logic lives in a shell script installed into the image; `config.rapira.yaml`'s `command:` is a single bare word with **no quote characters** | Inlining `bash -c '…'` in the YAML | DDEV interpolates the value into `command=bash -c "%s; exit_code=$?; …"` (`config.go:1015`) and supervisord then `shlex.split`s the line, so every quote in the value is stripped: `[ -f "$config" ]` becomes `[ -f $config ]`, which mis-parses a path containing a space and falls through to classic mode with exit status 0 — a silent wrong-config failure. An odd number of quotes makes shlex raise and takes the whole web container down |
| D-15 | Installing the embed package upgrades the container's PHP to sury's current patch | Pinning the installed patch level | `apt-cache madison libphp8.5-embed` lists exactly one version, and the package hard-depends on `php8.5-common (= same version)`, so the upgrade (17 packages, 8.5.5 → 8.5.10 as of today) is unavoidable, not a choice. It is also undated: a rebuild next month gets a newer patch. §5.4 step 9 prints the installed version so the build log records it, and the README states the effect |
| D-17 | Everything that bounces the daemon runs `supervisorctl stop` then `supervisorctl start`, never `supervisorctl restart` | `restart` | `restart` respawns before Rapira has released the listening socket, so the new process dies with `bind 127.0.0.1:8000 / Address already in use (os error 98)`, supervisord drops to `BACKOFF`, and the site 502s for about a second. Measured on a live project with a warm keepalive connection: `ddev rapira-restart` built on `restart` failed 2 of 3 runs and left one 502; built on `stop` + `start` it succeeded 4 of 4 with the site answering 200 each time. The same substitution therefore goes into the D-9 scripts, where the failure would otherwise be silent behind their `/dev/null` |
| D-16 | A container restarted outside `ddev` leaves Rapira stopped, and the add-on does not try to prevent it | A `web-entrypoint.d` self-heal script | DDEV's supervisord stanza sets `autostart=false` (`config.go:1017`) and starts the daemons host-side afterwards, so `docker restart ddev-<p>-web` brings up nginx and php-fpm but not Rapira; `/healthcheck.sh` probes `/phpstatus` and the `php-fpm nginx apache2` processes only, so the container reports healthy while every PHP request 502s. Overriding DDEV's own start sequencing from an add-on would fight the platform for a case `ddev start` already handles; §9 documents the symptom and the one-command recovery |

**Irreversibility list:** the public repository name `FluffyDiscord/ddev-rapira` and the add-on name `rapira` (what `ddev add-on remove` takes) — both baked into every user's `.ddev/addon-metadata/`. Decided with the owner, 2026-09-06.

**Naming constraint (owner requirement, 2026-09-06):** no file in this repository may name the other PHP application server the owner maintains an add-on for, its config filename, its env-var prefix, or its vendor namespace. TC-007 holds the exact pattern and is the single place in the repository where those literals appear; it excludes only itself. The constraint covers `docs/`, `tests/` and `.github/` — `export-ignore` only affects `git archive`, so those paths stay visible on GitHub — and it binds commit messages, the repository description and its topics (TC-007 checks the last two through `gh repo view`).

## 4. Repository layout

```
ddev-rapira/
├── install.yaml                      manifest (not installed)
├── config.rapira.yaml                → .ddev/                   #ddev-generated
├── nginx_full/nginx-site.conf        → .ddev/nginx_full/        MARKERLESS (D-10)
├── web-build/Dockerfile.rapira       → .ddev/web-build/         #ddev-generated
├── web-build/rapira-daemon.sh        → .ddev/web-build/         #ddev-generated (build-context file, D-14)
├── commands/web/rapira-restart       → .ddev/commands/web/      #ddev-generated
├── example.rapira.toml               reference, not installed
├── README.md · LICENSE · .gitattributes · .gitignore
├── docs/design.md                    this file (export-ignored)
├── tests/{test.bats,testdata/*}      (export-ignored)
└── .github/workflows/tests.yml       (export-ignored)
```

Nothing is written outside `.ddev/`. Any non-`Dockerfile*` file in `.ddev/web-build/` is copied into the web image's build context (`config.go:1368`, `isNotDockerfileContextFile` at `:1722`), which is how `rapira-daemon.sh` reaches the `COPY`.

## 5. File specifications

**Execution context, once, for every action in `install.yaml`:** DDEV runs add-on bash actions **on the host** (`addons.go:177` → `processBashHostAction`), never in the web container — so every path is `${DDEV_APPROOT}/.ddev/…`. DDEV prepends `set -eu -o pipefail` (`addons.go:190`), so a bare `grep -q` that finds nothing aborts the action; every test must sit inside an `if`. Action bodies are Go templates (`addons.go:191`), so a literal `{{` would break parsing. Order is `pre_install_actions` → `project_files` copy → `post_install_actions` (`addons.go:1314`, `:1330`, `:1393`); `removal_actions` run before the project files are removed (`addons.go:961-971`). `DDEV_APPROOT`, `DDEV_DOCROOT`, `DDEV_PHP_VERSION` and `DDEV_PROJECT_TYPE` are exported to those actions (`ddevapp.go:2875,2895,2901,2903`).

### 5.1 `install.yaml`

`name: rapira`. `project_files`: the five `.ddev/` paths above. `ddev_version_constraint: '>= v1.24.10'` — origin: an arbitrary declared floor; only v1.25.2 (locally) and CI's `stable` + `HEAD` are tested, and older releases are untested rather than known-broken.

`pre_install_actions`:

1. **PHP gate** (D-11) — exit 2 unless `DDEV_PHP_VERSION` is `8.4` or `8.5`, naming `ddev config --php-version=8.5`.
2. **Project-type gate** (D-12) — exit 2 unless `DDEV_PROJECT_TYPE` is `php` or `symfony`, naming the type it found and why.
3. **nginx override guard** (D-10, AC-8) — on `${DDEV_APPROOT}/.ddev/nginx_full/nginx-site.conf`:
   - contains the `ddev-rapira-managed` sentinel → copy it to `${DDEV_APPROOT}/.ddev/nginx-site.conf.ddev-rapira-backup-<epoch>` — the `.ddev` root, **not** `nginx_full/`, because DDEV copies that whole directory into the container's `sites-enabled/` — print that path, then `rm -f` the original so the `project_files` copy installs the current version. Without the `rm` an upgrade is impossible: DDEV refuses to overwrite a file lacking its own marker (*"NOT overwriting %s. The #ddev-generated signature was not found in the file"*). The backup exists because the `rm` would otherwise silently discard hand edits.
   - exists, no sentinel, and no DDEV generated-file marker → exit 2: the user owns this file, and installing would either clobber their work or silently skip the one file that carries the whole proxy wiring, leaving php-fpm serving 200s.
   - otherwise (DDEV's own generated file, or absent) → leave it; the copy overwrites it.

`post_install_actions`:

4. `sed` the shipped override's `root /var/www/html/public;` to `root /var/www/html/${DDEV_DOCROOT};` — the add-on patches only a file it owns. An empty `DDEV_DOCROOT` (a project served from its root) yields `root /var/www/html/;`, which is the form Rapira's fallback entrypoint `/var/www/html//index.php` also resolves to.
5. Assert the installed override carries the sentinel **and** `proxy_pass http://rapira_backend`; exit 2 naming the file otherwise, so a skipped copy fails the install instead of leaving php-fpm serving.
6. Print, in this order: **`ddev restart` is required** (DDEV prints no such hint itself, and until it runs the project still serves through php-fpm); `git add -f .ddev/nginx_full/nginx-site.conf` — DDEV passes that path to `CreateGitIgnore` (`config.go:1635`), but `CreateGitIgnore` only emits an entry while the target still carries DDEV's marker (`utils.go:242-247`), so the path is ignored until the next `ddev start` regenerates `.gitignore` without it and plain `git add` starts working (verified both states). `-f` is correct in the window that matters and harmless afterwards; the trusted-proxy requirement (§5.3), whose header list omits `x-forwarded-port`; and, when the file the daemon would load is absent, that classic mode is the fallback (D-6). That last check must resolve `RAPIRA_CONFIG_FILE` from `.ddev/.env.web` first — DDEV injects only `.ddev/.env.<add-on name>` into the action's environment (`addons.go:274`), so a hard-coded `rapira.toml` check would claim there is no config file for a project that has one under another name.

`removal_actions`: delete `${DDEV_APPROOT}/.ddev/nginx_full/nginx-site.conf` when it carries the sentinel, and print `git rm --cached .ddev/nginx_full/nginx-site.conf` — a force-added file stays tracked, so without that the next branch switch restores an override pointing at a port nothing listens on.

### 5.2 `config.rapira.yaml`

```yaml
#ddev-generated
webserver_type: nginx-fpm
web_extra_daemons:
  - name: "rapira"
    command: "rapira-daemon"
    directory: /var/www/html
```

`command` is one bare word with no quote characters, for the reason in D-14. `directory: /var/www/html` is what makes a relative `rapira.toml` resolve.

`web-build/rapira-daemon.sh`, installed to `/usr/local/bin/rapira-daemon`:

```bash
#!/usr/bin/env bash
#ddev-generated
set -eu

config="${RAPIRA_CONFIG_FILE:-rapira.toml}"

if [ -f "$config" ]; then
    exec rapira serve --listen 127.0.0.1:8000 --config "$config"
fi

exec rapira serve --listen 127.0.0.1:8000 --mode classic "/var/www/html/${DDEV_DOCROOT:-}/index.php"
```

`RAPIRA_CONFIG_FILE` is set with `ddev dotenv set .ddev/.env.web`, which DDEV injects into the web container's environment; supervisord's stanza declares no `environment=`, so the child inherits it (both it and `DDEV_DOCROOT` verified present in the web container's `/proc/1/environ`). `${DDEV_DOCROOT:-}` is guarded because `set -u` would otherwise abort on an unset value.

### 5.3 `nginx_full/nginx-site.conf`

Take DDEV v1.25.2's `pkg/ddevapp/webserver_config_assets/nginx-site-symfony.conf` verbatim and make exactly four edits, leaving every other line — including the position of `include /etc/nginx/monitoring.conf;` near the top of the `server` block — untouched:

1. Replace **template lines 1–7** (the two descriptive comment lines and the four-line `#ddev-generated` block) with the sentinel line, an ownership line, and the one warning a reader cannot derive from the file — that DDEV searches it for its own marker as a substring, so the token must never appear here, comments included (D-10):
   ```nginx
   # ddev-rapira-managed
   # Owned by the ddev-rapira add-on. Replaced on `ddev add-on get`, deleted on `ddev add-on remove`.
   # Never write DDEV's generated-file marker in this file: DDEV searches for it as a
   # substring and would take the file over, restoring php-fpm routing on the next start.
   ```
   Everything else a reader might want — what the proxy block does to `$_SERVER`, where additive rules belong — lives in the README, not here.
2. Insert the `map` and the `upstream` above `server {`.
3. Render `{{ .Docroot }}` as `/var/www/html/public` (post_install rewrites it, §5.1 step 4).
4. Replace the body of `location ~ \.php$` — everything after `try_files $uri =404;` — with the proxy block.

```nginx
map $http_x_forwarded_proto $rapira_forwarded_proto {
    ""      $scheme;
    default $http_x_forwarded_proto;
}

upstream rapira_backend {
    server 127.0.0.1:8000;
    keepalive 16;
}
```
```nginx
    location ~ \.php$ {
        try_files $uri =404;
        proxy_pass http://rapira_backend$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $rapira_forwarded_proto;
        proxy_set_header X-Forwarded-Host $host;
        proxy_read_timeout 10m;
    }
```

The `map` and `upstream` need http context; `nginx.conf:137` includes `sites-enabled/*.conf` inside `http {}`, so the top of this file qualifies (verified — `nginx -t` passes and the site serves). A variable in `proxy_pass` does not prevent using an upstream group: nginx searches the declared groups for the name first, so `keepalive` applies and no resolver is needed. DDEV's own `$fcgi_https` map at `nginx.conf:128` (`default off; https on;`) proves the router forwards `X-Forwarded-Proto` rather than TLS, but it yields `on`/`off` rather than a scheme, so it cannot be reused here. `proxy_read_timeout 10m` carries over DDEV's `fastcgi_read_timeout 10m`. `/xhprof`'s nested `location ~ \.php$` (inside `location ^~ /xhprof`) out-scopes this block, so the xhprof UI keeps its php-fpm socket.

**What the app loses with `fastcgi_params`, measured through real nginx + Rapira:**

| `$_SERVER` key | Under php-fpm | Under Rapira | Compensation |
|---|---|---|---|
| `SERVER_NAME` | the request's host | **`localhost`**, regardless of the `Host` header | Read `HTTP_HOST`, or a trusted `X-Forwarded-Host` |
| `SERVER_PORT` | 80 (nginx's own port, even for an HTTPS request through the router) | **8000** (Rapira's listen port) | None, deliberately. `X-Forwarded-Port` is **not** sent: nginx's `$server_port` is its own listening port, so it would say `80` for a request the router terminated as HTTPS, and a framework that trusts it generates `https://host:80/` URLs — verified on a real Sylius page before the header was removed. With the header absent, Symfony derives 443 from the forwarded scheme |
| `HTTPS` | `on` / `off` | **empty** — Rapira terminates no TLS | Trusted `X-Forwarded-Proto` |
| `REMOTE_ADDR` | the client | **`127.0.0.1`** — nginx is the peer | Trusted `X-Real-IP` / `X-Forwarded-For` |
| `REQUEST_SCHEME` | `https` | `http` | Trusted `X-Forwarded-Proto` |
| `SERVER_ADDR`, `DOCUMENT_URI`, `REMOTE_USER`, `REDIRECT_STATUS` | set by `fastcgi_params` | **absent** | None — a proxy cannot supply them |
| `SERVER_SOFTWARE` | `nginx/<version>` | `Rapira` | None |
| `CONTENT_TYPE` | `''` when absent | **absent** when absent | `isset()` differs; use `?? ''` |
| `fastcgi_split_path_info` | splits `PATH_INFO` | — | Rapira runs one entrypoint per request; nothing to split |
| `fastcgi_pass_header "X-Accel-*"` | forwarded to the client | nginx **acts** on `X-Accel-Redirect` / `X-Accel-Buffering` instead | Kept deliberately: honouring `X-Accel-Buffering: no` is what a resident-worker app relies on in production. DDEV set the pass-through for its own test suite |

**Trusted proxies (required, app-side).** Everything in the "Compensation" column needs the app to trust the proxy, e.g. Symfony `framework.trusted_proxies: '127.0.0.1'` with `trusted_headers: ['x-forwarded-for','x-forwarded-proto','x-forwarded-host']`. Without it `Request::isSecure()` is false, generated URLs are `http://…:8000`, and every client IP is `127.0.0.1`. `x-forwarded-port` is absent from that list on purpose (see the `SERVER_PORT` row). README §Trusted proxies states this; the add-on cannot set it (D-7).

### 5.4 `web-build/Dockerfile.rapira`

`#ddev-generated`, `ARG RAPIRA_VERSION=v0.8.1`. `DDEV_PHP_VERSION` is already in scope from DDEV's generated header (`config.go:1204ff`) — do **not** re-declare it, or it shadows to empty. One `COPY` and one `RUN` opening with `set -eux -o pipefail` (that header also sets `SHELL ["/bin/bash","-c"]`, so `pipefail` is available; the steps below use no pipeline today, and the flag keeps it that way if one is added):

1. `COPY rapira-daemon.sh /usr/local/bin/rapira-daemon` and `chmod +x`.
2. Map `dpkg --print-architecture` to Rapira's asset name (`amd64`→`x86_64`, `arm64`→`aarch64`); anything else exits 1 naming the limitation.
3. Download `<release>.tar.gz` and `rapira-${RAPIRA_VERSION}-SHA256SUMS.txt`, `sha256sum --ignore-missing -c` the tarball, then `tar -xz -C /usr/local/bin --strip-components=2 "${release}/bin/rapira"` — the binary (4,847,680 bytes, decimal) only, not the `libphp.so` that step 6 replaces. The checksum earns its place because §6 invites users to bump `RAPIRA_VERSION`.
4. `apt-get update -qq` — **required**: `/var/lib/apt/lists/` is empty in the DDEV web image (verified), so the install below fails with *Unable to locate package* without it.
5. `apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "libphp${DDEV_PHP_VERSION}-embed"`, then `rm -rf /var/lib/apt/lists/*`. The `Dpkg` options are **required, not cosmetic**: the install upgrades `php<v>-fpm` (D-15), whose conffile prompt on DDEV's modified `php-fpm.conf` fails the build non-interactively (verified). `--force-confold` keeps DDEV's file.
6. `mkdir -p /usr/local/lib/rapira && ln -sf "/usr/lib/libphp${DDEV_PHP_VERSION}.so" /usr/local/lib/rapira/libphp.so`. The `mkdir` is required — step 3 extracted only the binary, and `ln` does not create parents. The tarball binary's RUNPATH is `$ORIGIN/../lib/rapira` (`readelf -d`, verified), so from `/usr/local/bin` it resolves exactly there.
7. Replace the embed SAPI's config with php-fpm's (D-8): `rm -f` the embed `php.ini` and `ln -s` fpm's onto it; `rm -rf` the embed `conf.d` and `ln -s` fpm's onto it. Must run **after** step 5, which creates them. Note that DDEV's `/start.sh:38` runs `perl -pi` over `$(find /etc/php -name php.ini)` to set the timezone, which turns the `php.ini` symlink into a regular copy of fpm's at every container start (verified). That is harmless — the copy is taken from fpm's file, so the values match, and the timezone is the only thing `/start.sh` writes to it — and `conf.d` stays a symlink, which is what carries `.ddev/php/*.ini` and the profiler toggles.
8. `sed -i` replacing the whole `killall -USR2 php-fpm 2>/dev/null` with `supervisorctl stop 'webextradaemons:*' >/dev/null 2>&1; supervisorctl start 'webextradaemons:*' >/dev/null 2>&1` over exactly `/usr/local/bin/enable_xdebug`, `/usr/local/bin/disable_xdebug`, `/usr/local/bin/enable_xhprof`, `/usr/local/bin/disable_xhprof` (D-9, D-17). The `&` in `2>&1` must be escaped in the replacement, or `sed` splices the matched text in. Never a glob: `/usr/local/bin/*xdebug*` also matches the 6,379,424-byte `xdebugctl` binary, which `sed -i` would corrupt silently.
9. `rapira --version` and `dpkg-query -W -f='${Version}\n' "libphp${DDEV_PHP_VERSION}-embed"`. `rapira --version` must run **last**: the binary links `libphp.so` through its RUNPATH, so it also proves step 6's symlink resolves, not merely that step 3 downloaded something. The `dpkg-query` puts D-15's PHP patch level in the build log.

### 5.5 `commands/web/rapira-restart`

`#ddev-generated`, DDEV's `## Description:` / `## Usage:` headers, then `supervisorctl stop webextradaemons:rapira` followed by `exec supervisorctl start webextradaemons:rapira` (D-17). `start` on a stopped program is what also makes this the recovery for D-16.

### 5.6 `example.rapira.toml`

Not installed. Carries `[pool] mode = "classic"`, `entrypoint = "public/index.php"`, and a comment that `[http] listen` is overridden by the daemon (D-5).

### 5.7 `README.md`

Written fresh, never adapted from another add-on's README (§3 naming constraint). Badges, an AI-authorship note, a resources list and a credits line may surround it; the substance is this section list, in this order:

1. **Install** — `ddev add-on get FluffyDiscord/ddev-rapira`, then `ddev restart`, then `git add -f .ddev/nginx_full/nginx-site.conf`.
2. **Requirements** — DDEV `>= v1.24.10`; PHP 8.4 or 8.5; project type `php` or `symfony`; amd64 (arm64 untested).
3. **One paragraph on libphp** — Rapira embeds it, so the add-on points it at the image's own PHP; the project keeps its PHP version, extensions and ini, and DDEV's own features keep working. Link to Rapira's installation docs. No architecture diagram and no inventory of what the add-on changes internally: a reader installing a DDEV add-on expects DDEV to keep working, and the mechanism is this document's job (owner, 2026-09-06).
4. **Trusted proxies** — the §5.3 snippet verbatim, plus the §5.3 `$_SERVER` table itself, so a reader sees `REQUEST_SCHEME`, the absent `SERVER_ADDR` / `DOCUMENT_URI` / `REMOTE_USER` / `REDIRECT_STATUS` and the `CONTENT_TYPE` `?? ''` note, not only the two headline cases.
5. **Configuration** — the §6 knob table; `rapira.toml` is the project's own file and classic mode is the fallback when it is absent.
6. **`ddev rapira-restart`** — when a code edit needs it, and that it also recovers a stopped daemon (D-16).
7. **Removal** — `ddev add-on remove rapira`, then `git rm --cached .ddev/nginx_full/nginx-site.conf`.
8. **Known limitations** — D-12's project-type gate, D-16, arm64.

No comparison to, or mention of, any other PHP application server.

## 6. Configuration knobs

| Knob | Default | How to change |
|---|---|---|
| Docroot (the override's nginx `root`) | `${DDEV_DOCROOT}`, set at install | Edit `root` in `.ddev/nginx_full/nginx-site.conf`, `ddev restart`. Any edit to that file is replaced on the next `ddev add-on get` (a timestamped backup is left beside it); put additive rules in `.ddev/nginx/*.conf`, which the override still `include`s at its last line |
| Which Rapira config file the daemon loads | `rapira.toml`, else classic mode on the docroot's `index.php` | `ddev dotenv set .ddev/.env.web --rapira-config-file=rapira.dev.toml && ddev restart` |
| Rapira version | `v0.8.1` | `ARG RAPIRA_VERSION` in `.ddev/web-build/Dockerfile.rapira`, `ddev restart` |

## Assumptions

| Assumption | If wrong, then… |
|---|---|
| sury's `libphp<v>-embed` stays same-minor with the DDEV image's `php<v>-*` extension packages (today the install upgrades both to the same patch — D-15) | Extensions fail to load; `rapira --version` still passes, so it surfaces at the first request. Pin the extension packages, or fall back to Rapira's bundled libphp |
| A Rapira release keeps publishing `linux-x86_64` / `linux-aarch64` tarballs named `rapira-<tag>-php<v>-linux-<arch>.tar.gz` plus `rapira-<tag>-SHA256SUMS.txt` (all present for v0.6.0, v0.7.0 and v0.8.1 — checked) | The `curl -f` or the checksum fails the image build loudly; correct the asset name |
| **arm64 works.** The aarch64 tarball is published and the Dockerfile maps to it, but nothing here was run on arm64 — in particular that sury publishes `libphp<v>-embed` for arm64 trixie, and that the RUNPATH symlink resolves there | The image build fails at the embed install or at `rapira --version`; the first arm64 user is the tester. README states this |
| `--listen` keeps overriding `[http] listen` (verified on v0.8.1) | nginx proxies to a port nothing listens on → 502; re-pin the port in the toml |
| `[pool] mode` defaults to `dispatcher`, so a config file that omits `mode` will not serve a plain front controller | IT-006 fails; the shipped `example.rapira.toml` sets `mode` explicitly, and the README says to |
| DDEV keeps including `sites-enabled/*.conf` inside `http {}` | nginx refuses to start on the `map` / `upstream`; move them to a separate `nginx_full/*.conf` file |
| DDEV keeps gating the xdebug/xhprof daemon restart on `webserver_type = generic` | The `sed` becomes a silent no-op; IT-003 catches it by asserting the old string is absent from all four scripts |
| `web_extra_daemons` from `config.rapira.yaml` merges with, rather than replaces, a list already in `config.yaml` | A project with its own extra daemon loses it on install; IT-008 asserts both daemons run |

## Open Questions

| Question | Why it matters | Blocks |
|---|---|---|
| OQ-1 — Widen D-12 beyond `php` / `symfony` by shipping per-type nginx overrides, or by patching the project's generated file in place? | `laravel`, `drupal*`, `wordpress` are large DDEV audiences that the gate currently turns away | Nothing; the gate fails loudly today |
| OQ-2 — Add an arm64 dimension to CI (`runs-on: ubuntu-24.04-arm`), or leave arm64 declared-untested? | The Assumptions row is the only thing standing between arm64 users and a failed build | Nothing |

## 7. Anti-Patterns (DO NOT)

| Don't | Do instead | Why |
|---|---|---|
| Put a quote character in a `web_extra_daemons` `command:` | Invoke one bare word; put the logic in a script (D-14) | DDEV wraps the value in double quotes and supervisord `shlex.split`s the result, stripping every quote you wrote — silently, unless the count is odd, which takes the container down |
| Patch individual ini keys into the embed `conf.d` | Symlink the embed `php.ini` and `conf.d` onto php-fpm's (D-8) | The cause is that embed reads sury's ini tree, not DDEV's. Key-by-key patching leaves `memory_limit`, `sendmail_path`, the user's `.ddev/php/*.ini`, and DDEV's `phpdismod` of the profilers all wrong |
| Write DDEV's generated-file marker token into `nginx_full/nginx-site.conf`, comments included | Keep it markerless, sentinel `ddev-rapira-managed` | DDEV matches that token as a substring anywhere in the file and regenerates the file back to php-fpm on the next start |
| Let `project_files` overwrite a previous markerless override | Back it up and `rm` it in `pre_install_actions` (§5.1 step 3) | DDEV refuses to overwrite a file lacking its marker, so every later version of the add-on would ship an nginx file that never lands |
| Use container paths (`/var/www/html/.ddev/…`) in any install or removal action | `${DDEV_APPROOT}/.ddev/…` | **All** add-on bash actions run on the host (`addons.go:177`), not only removal ones |
| Write a bare `grep -q` in an action | Wrap it in `if` | DDEV prepends `set -eu -o pipefail`, so a non-match aborts the whole action |
| Route PHP through a named `location` reached by a rewritten `try_files` | `proxy_pass http://rapira_backend$request_uri;` in `location ~ \.php$` | `proxy_pass` forwards the rewritten URI; the app would see `/index.php` and lose the real path (D-4) |
| `sed` the xdebug/xhprof scripts through a glob, or leave the replacement's output unredirected | Name all four paths; append `>/dev/null 2>&1` | `/usr/local/bin/*xdebug*` matches the `xdebugctl` binary, which `sed -i` corrupts silently; and `/start.sh` calls `disable_xdebug` before supervisord exists, so an unredirected `supervisorctl` prints an error on every container start |
| Assert the D-9 substitution by grepping for `webextradaemons` | Assert `killall -USR2 php-fpm` is **absent** from all four scripts | Each script already contains `supervisorctl restart 'webextradaemons:*'` in its `generic` branch, so a presence check passes before the patch too |
| Assert a profiler is loaded without asserting it was absent first | Check absence before the toggle and presence after (IT-003) | Both profilers can be loaded by default through the embed `conf.d`; a presence-only check passes for the wrong reason |
| Disable php-fpm because Rapira serves the app | Let it idle | `/phpstatus` (DDEV's container healthcheck) and the `/xhprof` UI `fastcgi_pass` to its socket |
| Read the listen port from the project's `rapira.toml` | Pin `--listen 127.0.0.1:8000` on the daemon (D-5) | nginx's upstream is fixed; a file the add-on does not own must not be able to break it |
| Bounce the daemon with `supervisorctl restart` | `supervisorctl stop` then `supervisorctl start` (D-17) | `restart` respawns before the listening socket is released, so the new process dies on `Address already in use` and the site 502s until `autorestart` catches up |
| Assume `.ddev/nginx_full/nginx-site.conf` gets committed by a plain `git add` | Tell the user `git add -f` | DDEV lists that path in the `.ddev/.gitignore` it generates while the file still carries DDEV's own marker, which is exactly the state right after install and before the next `ddev start` |
| Write the pre-install backup into `nginx_full/` | Write it to the `.ddev` root | DDEV copies everything under `nginx_full/` into the container's `sites-enabled/` |
| Interpolate a build arg into `COPY --from=` | Download in a `RUN` (D-2) | BuildKit refuses: *"variable expansion is not supported for --from"* |
| Re-declare `ARG DDEV_PHP_VERSION` in the Dockerfile fragment | Use the one DDEV's header already declares | A re-declaration with no default shadows it to empty |
| `apt-get install` the embed package without `apt-get update` and `--force-confold` | Do both (§5.4 steps 4–5) | The image ships empty apt lists, and the `php<v>-fpm` upgrade prompts on DDEV's modified `php-fpm.conf` |
| Ship a `ddev rapira` passthrough | Only `ddev rapira-restart` (D-13) | `serve` is the only functional subcommand; a passthrough can only start a second server on the same port |

## 8. Test Case Specifications

Bats, tagged so CI can shard them. `${DIR}` is the add-on repo; `ddev add-on get "${DIR}"` installs it.

### Static (`static` tag)

| ID | Check |
|---|---|
| TC-001 | `install.yaml`, `config.rapira.yaml` and `example.rapira.toml` parse (YAML / TOML) |
| TC-002 | Every installed file carries DDEV's generated-file marker **except** `nginx_full/nginx-site.conf`, which must not contain the token anywhere |
| TC-003 | `nginx_full/nginx-site.conf` contains the `ddev-rapira-managed` sentinel, the `upstream rapira_backend` block and `proxy_pass http://rapira_backend$request_uri;`, and no `fastcgi_pass` |
| TC-004 | `config.rapira.yaml`'s `command:` is exactly `rapira-daemon` — asserted on the parsed YAML value, not by grepping the file, so a value carrying a quote fails rather than slipping through a shell pipeline (D-14) |
| TC-005 | `Dockerfile.rapira` names all four xdebug/xhprof script paths literally, symlinks the embed `php.ini` and `conf.d`, verifies the tarball checksum, and its `RUN` opens with `set -eux -o pipefail` |
| TC-006 | `shellcheck` passes on `commands/web/rapira-restart` and `web-build/rapira-daemon.sh` |
| TC-007 | No file names the products the §3 naming constraint forbids, and neither does the GitHub repository description or its topics (`gh repo view --json description,repositoryTopics`, skipped when `gh` is unauthenticated). This test holds the literal pattern and greps the whole repository for it, excluding `.git` and its own file — so the repository's only occurrence of those words is the assertion itself. The `gh` output is piped straight into `grep`, never re-expanded through a shell string: the description contains an apostrophe, and interpolating it into a quoted `bash -c` breaks the quoting |

### Integration (bats)

| ID | Tag | Flow | Verification |
|---|---|---|---|
| IT-001 | `serve` | `ddev config --project-type=php --php-version=8.5 --docroot=public`; `public/index.php` echoes `sapi=<php_sapi_name()>` and `uri=<$_SERVER['REQUEST_URI']>`; `public/asset.txt` = `static-ok`; `ddev add-on get "${DIR}"`; `ddev restart` | `curl https://…/some/path?q=1` → body contains `sapi=rapira` (AC-1) and `uri=/some/path?q=1` (AC-6); `curl https://…/asset.txt` → `static-ok` (AC-9); `ddev exec supervisorctl status` → `webextradaemons:rapira RUNNING`; `ddev exec grep 'proxy_pass http://rapira_backend' /etc/nginx/sites-enabled/nginx-site.conf`. No `rapira.toml` exists, so this also proves D-6 (AC-2) |
| IT-002 | `runtime` | as IT-001, entrypoint printing all six AC-3 ini values, `extension_loaded()` for `pdo_pgsql, pgsql, intl, bcmath, gd, zip, redis, igbinary, sodium, Zend OPcache, xdebug, xhprof`, `$_ENV['IS_DDEV_PROJECT']`, and `$_SERVER['HTTP_X_FORWARDED_PROTO']` | each of the six ini values equals what `parse_ini_file()` reads out of `/etc/php/<v>/fpm/php.ini` at test time — **not** what `ddev php -r 'echo ini_get(…)'` reports, which is the *CLI* ini and legitimately differs (`memory_limit` is `-1` there, `1024M` in fpm's, measured). Reading the reference at test time rather than hard-coding it means the test fails on a divergence between the SAPIs, not on a DDEV default change (AC-3); the ten always-on extensions `yes` and **`xdebug` / `xhprof` `no`** (AC-5's precondition); `IS_DDEV_PROJECT=true` (AC-4); forwarded proto is `https` for an `https://` request |
| IT-003 | `profilers` | as IT-001, then `ddev xdebug on` + request, then `ddev xhprof on` + request | the four scripts concatenated contain `killall -USR2 php-fpm` **zero** times and `supervisorctl start 'webextradaemons:*'` **four** times — a count, never `grep -L`'s exit status, which is 1 even when it lists files (measured on the DDEV image's grep) and would fail the job; `xdebug` absent before and loaded after the first toggle; `xhprof` absent before and loaded after the second, with `xdebug` back off (AC-5); `https://…/xhprof/` → 200, with the trailing slash — `/xhprof` is a 301 to it (AC-9) |
| IT-004 | `removal` | install; write a project `rapira.toml`; `ddev add-on remove rapira`; assert; **then** `ddev restart`; assert | before the restart: `.ddev/config.rapira.yaml` and `.ddev/nginx_full/nginx-site.conf` gone, `rapira.toml` untouched. After: `ddev exec grep php-fpm.sock /etc/nginx/sites-enabled/nginx-site.conf` succeeds (AC-7) |
| IT-005 | `gates` | (a) `--php-version=8.3` then `ddev add-on get`; (b) `--project-type=drupal11` then `ddev add-on get`; (c) a hand-written markerless `nginx_full/nginx-site.conf` with no sentinel, then `ddev add-on get` | each fails; output names 8.4/8.5, the project type, and the conflicting file respectively (D-11, D-12, §5.1 step 3) |
| IT-006 | `config` | `--docroot=web`; `ddev dotenv set .ddev/.env.web --rapira-config-file=rapira.dev.toml`; a `rapira.dev.toml` with `listen = "127.0.0.1:9999"`, `mode = "classic"`, `entrypoint = "web/index.php"`; install; restart | the override's `root` is `/var/www/html/web`; the site answers on 443, proving `--listen` beat the toml's 9999 (D-5) |
| IT-007 | `reinstall` | install; append a marker comment to the installed override; `ddev add-on get "${DIR}"` a second time; `ddev restart` | the override no longer carries the marker comment but a `nginx-site.conf.ddev-rapira-backup-*` file does; the site still answers `sapi=rapira` (AC-8) |
| IT-008 | `daemons` | a project whose `config.yaml` already declares a `web_extra_daemons` entry; install; restart | `supervisorctl status` lists both that daemon and `rapira` as RUNNING (Assumptions, last row) |

CI matrix: `[stable, HEAD] × [static, serve, runtime, profilers, removal, gates, config, reinstall, daemons]` via `ddev/github-action-add-on-test@v2`.

## 9. Error Handling Matrix

| Error | Detection | Response | Recovery |
|---|---|---|---|
| PHP version other than 8.4 / 8.5 | `pre_install_actions` | `exit 2`, message names both | `ddev config --php-version=8.5` |
| Project type other than `php` / `symfony` | `pre_install_actions` | `exit 2`, names the type | change the type, or track OQ-1 |
| Project type changed **after** install | nothing — DDEV declines to regenerate the markerless override, so the php/symfony routing silently persists (D-12) | — | `ddev add-on remove rapira` |
| A user-owned `nginx_full/nginx-site.conf` | `pre_install_actions` | `exit 2`, names the file | back it up and remove it, then re-install |
| The override was not installed (copy skipped) | `post_install_actions` assertion | `exit 2` | as above |
| Architecture other than amd64 / arm64 | `case` in the Dockerfile | build fails with the reason | none — Rapira publishes no such build |
| Release asset renamed, removed, or corrupted | `curl -fsSL` under `pipefail`; `sha256sum -c` | build fails at the download or the checksum | correct `ARG RAPIRA_VERSION` |
| Binary or libphp symlink broken | `rapira --version` (step 9) | build fails | pin an older `RAPIRA_VERSION` |
| `php<v>-fpm` conffile prompt during the embed install | dpkg | build fails without `--force-confold` | the Dockerfile passes it (§5.4 step 5) |
| Daemon crash-loop (bad `rapira.toml`) | `ddev logs`, `supervisorctl status` | nginx returns 502 | fix the toml, `ddev rapira-restart` |
| Container restarted outside `ddev` | every PHP request 502s while the container reports **healthy** (D-16) | — | `ddev start`, or `ddev rapira-restart` (which starts a stopped program) |
| 200s served by php-fpm instead of Rapira | `php_sapi_name()` is `fpm-fcgi` | — | `ddev restart` was not run, or the override is missing / carries DDEV's marker; re-run `ddev add-on get` and `git add -f` it |
| Override restored by git after removal | 502s with the add-on uninstalled | — | `git rm --cached .ddev/nginx_full/nginx-site.conf` (printed by `removal_actions`) |
| Code edit not reflected | stale response in dispatcher/worker mode | — | `ddev rapira-restart`, or `mode = "classic"` for the edit loop |
| App generates `http://…:8000` URLs, or sees `127.0.0.1` as the client | wrong scheme/port in links, wrong IP in logs | — | configure trusted proxies (§5.3) |

## 10. References

| Topic | Location |
|---|---|
| Rapira source, config keys, releases | https://github.com/rapira-rs/rapira |
| Rapira documentation (classic / worker / dispatcher modes) | https://rapira.rs/docs/intro/ |
| Missing extensions in the shipped libphp | https://github.com/rapira-rs/rapira/issues/103 |
| Symfony integration (dispatcher mode) | https://github.com/FluffyDiscord/rapira-symfony-bundle |
| DDEV add-on authoring, `#ddev-generated`, `removal_actions` | https://docs.ddev.com/en/stable/users/extend/creating-add-ons/ |
| DDEV `webserver_type`, `web_extra_daemons`, custom nginx | https://docs.ddev.com/en/stable/users/extend/customization-extendibility/ |
| DDEV custom commands | https://docs.ddev.com/en/stable/users/extend/custom-commands/ |
| nginx `proxy_pass` with variables, `upstream`, `keepalive` | https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass |
| sury PHP packages (Debian trixie) | https://packages.sury.org/php |
