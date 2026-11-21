# PHP + Apache platform image

A hardened, multi-version PHP + Apache image for hosting many PHP sites (WordPress, Joomla, shops, custom PHP)
from one tested image instead of one ad-hoc build per site. Built on the official `php:<version>-apache`,
rebuilt and tested in GitHub Actions, published to GHCR. Servers only pull it.

```
ghcr.io/exciting-it/php:8.2-apache
ghcr.io/exciting-it/php:8.3-apache
ghcr.io/exciting-it/php:8.4-apache
ghcr.io/exciting-it/php:8.5-apache
```

We use it on [Dokploy](https://dokploy.com) behind Cloudflare and Traefik, but nothing in the image depends on that.

## Extensions

**Always on, compiled into the official image (33):** curl, mbstring, openssl, dom/xml, json, sodium, fileinfo, PDO, zlib, iconv, …

**Also on by default:** what CMS, shops and their plugins commonly need, with little risk:
`opcache mysqli pdo_mysql gd imagick intl zip exif bcmath soap calendar`
(the official WordPress image's set, plus `soap` for shipping/VAT-check plugins and JTL-Shop, and `calendar` because some plugins call
`cal_days_in_month()` and die without it)

**Built in, off by default, switched on per site:**

| Why off | Extensions |
|---|---|
| need a service a site usually doesn't have | `redis` `pgsql` `pdo_pgsql` `ldap` `imap` |
| only for encoded third-party code | `ioncube_loader` `sourceguardian` |
| meant for CLI tools and daemons | `pcntl` `sockets` |
| special cases | `gmp` `xsl` `tidy` `bz2` `gettext` `ftp` `apcu` |

Switch them on with an environment variable of the container, then recreate it (no build):

```
PHP_EXTENSIONS=soap gmp ioncube_loader
```

Removing a name switches the extension off again on the next start. A typo does not take the site down; the container log shows a warning.
The image lists its extensions in `/usr/local/etc/php/extensions-default.txt` and `extensions-available.txt` (useful for a control panel).
`ioncube_loader`, `sourceguardian` and `imap` are best effort: if they don't exist yet for a new PHP version, the image is built without them.

## Per-site PHP settings

| Variable | Default |
|---|---|
| `PHP_MEMORY_LIMIT` | `256M` |
| `PHP_UPLOAD_MAX_FILESIZE` | `100M` |
| `PHP_POST_MAX_SIZE` | `100M` |
| `PHP_MAX_EXECUTION_TIME` | `300` |
| `PHP_MAX_INPUT_TIME` | `300` |
| `PHP_MAX_INPUT_VARS` | `5000` |
| `PHP_TIMEZONE` | `Europe/Berlin` |
| `PHP_OPCACHE_MEMORY` | `128` (MB) |
| `PHP_SESSION_COOKIE_SECURE` | `On` |
| `PHP_DISABLE_FUNCTIONS` | `exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec`; a site that really needs shell commands sets it empty |

Environment variables on purpose: Docker Compose recreates a container when its environment changes, but not when only the content of an
inline `configs:` entry changes. Anything else goes into your own `zz-*.ini` (`/usr/local/etc/php/conf.d/`) or `zz-*.conf`
(`/etc/apache2/conf-enabled/`), which load after the platform files.

## Resources (per site or hosting plan)

| Variable | Default | Meaning |
|---|---|---|
| `APACHE_MAX_WORKERS` | `25` | PHP requests served at the same time (one Apache prefork process each); more wait in the queue |
| `APACHE_START_SERVERS` / `APACHE_MIN_SPARE` / `APACHE_MAX_SPARE` | `2` / `1` / `5` | idle processes kept ready (clamped to `APACHE_MAX_WORKERS`) |
| `APACHE_MAX_CONNECTIONS_PER_CHILD` | `1000` | recycle a process after that many connections (contains slow memory leaks) |

The container's RAM and CPU are set in the compose file, ideally from variables so a control panel only changes the environment:

```yaml
    deploy:
      resources:
        limits:
          memory: ${PLAN_MEMORY}   # hard limit, e.g. 1G
          cpus: "${PLAN_CPUS}"     # e.g. 1.0 = at most one core
```

Rule of thumb: `APACHE_MAX_WORKERS` × typical PHP process (50–100 MB for WordPress) + `PHP_OPCACHE_MEMORY` ≤ container memory.
`PHP_MEMORY_LIMIT` is the ceiling for a single request, not the average. Example plans:

| Plan | Memory | CPUs | `APACHE_MAX_WORKERS` | `PHP_MEMORY_LIMIT` | `PHP_OPCACHE_MEMORY` | `PHP_MAX_EXECUTION_TIME` |
|---|---|---|---|---|---|---|
| small | 512M | 0.5 | 5 | 128M | 64 | 60 |
| medium | 1G | 1.0 | 10 | 256M | 128 | 120 |
| large | 2G | 2.0 | 16 | 512M | 256 | 300 |

## Security

**Reveal nothing**
- no `X-Powered-By: PHP/8.x`, `Server: Apache` without version, no signature on error pages
- errors never shown to visitors (`display_errors`, `display_startup_errors`, `html_errors` off), logged to the container log; stack traces without arguments
- no `server-status`, no directory listings (modules `status` and `autoindex` removed, so `Options +Indexes` in a .htaccess can't bring them back)
- hidden files and folders (`.git/`, `.env`, `.user.ini`) return 404; `.well-known/` stays reachable
- backups, dumps, logs and dependency manifests in the webroot return 403: `*.sql`, `*.bak`, `*.old`, `*.orig`, `*.swp`, `*.log`, `*~`, `composer.json/lock`, WordPress' `readme.html`

**Slow down injected code**
- shell functions (`exec`, `system`, `shell_exec`, `passthru`, `proc_open`, `popen`) disabled: a dropped webshell can't start programs
- `allow_url_include = Off`
- PHP files in `wp-content/uploads` and `wp-content/cache` can't be requested from outside (`include()` still works)

**Images and PDFs (Imagick + Ghostscript)**
- Ghostscript is included so WordPress can render previews of uploaded PDFs (the official WordPress image ships it too)
- own ImageMagick policy (`/usr/local/etc/imagemagick-policy.xml`): PDF read-only; **PostScript, EPS and XPS disabled** (that's how exploits reach
  Ghostscript, and no website needs them); URL, file and script coders (`url:`, `text:`, `msl:` …) disabled; limits for memory, size and time.
  The official WordPress image allows PostScript.

**Browser and sessions**
- `X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`, only if the application
  doesn't send its own; a site that must be framed elsewhere drops it with `Header unset X-Frame-Options` in its .htaccess
- session cookie `HttpOnly` and `Secure`, strict mode, no session IDs in URLs

**Recommended in the compose file** (tested: Apache and all extensions work with it):

```yaml
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID, NET_BIND_SERVICE, KILL]
```

**Deliberately not done**

| What | Why not |
|---|---|
| `session.cookie_samesite = Lax` | a customer returning from PayPal/Klarna by POST would lose the session, i.e. lost orders |
| `allow_url_fopen = Off` | many plugins fetch feeds and APIs this way |
| `open_basedir` | the container is already the boundary; costs performance, breaks plugins |
| read-only code | WordPress/Joomla update themselves, the webroot must be writable |
| Apache without root | the master process needs root for port 80 and to switch to `www-data`; PHP itself runs as `www-data` |
| HSTS, CSP | HSTS belongs where TLS ends (CDN/proxy); a CSP differs per site |

## Other defaults

- `php.ini-production` as base
- Apache modules `rewrite headers expires deflate remoteip setenvif`
- visitor IP and HTTPS detection behind reverse proxies on private networks (`X-Forwarded-For`, `X-Forwarded-Proto`)

## Builds, tests, security scan

GitHub Actions ([.github/workflows/build.yml](.github/workflows/build.yml)), one job per PHP version:

- **Every night: check first, build only if needed.** A rebuild happens when the official `php:<version>-apache` image changed (new PHP release
  or refreshed Debian base; compared by digest, recorded in the image label `org.opencontainers.image.base.digest`) or when Debian has
  updates for packages in the published image (`apt list --upgradable`). Otherwise nothing is built and nothing is pushed, so servers don't
  restart sites for nothing.
- **Every Saturday:** full rebuild regardless, as a safety net (e.g. new PECL extension releases).
- **On push to `main` and by hand** (Actions → build → Run workflow).
- `test/test.sh` checks every image before it is pushed: default extensions on, optional ones off, each optional one loads alone and all
  together without warnings, environment settings apply, Apache serves PHP, every point under Security holds, and the container runs with
  the reduced capabilities above. **Only images that pass are pushed.**
- **Trivy** scans the image that is live after each run (`--ignore-unfixed`, HIGH and CRITICAL): results in the repository's
  Security → Code scanning tab and in the run summary.
- Tags: `8.3-apache` (moving, what sites use), `8.3.37-apache` (moving within a patch release), `8.3.37-apache-20261121` (fixed, for rollback).

Build and test locally:

```bash
docker build --pull --build-arg PHP_VERSION=8.3 -t php-test:8.3 .
bash test/test.sh php-test:8.3
```

## Moving an existing site onto the image

[`tools/check-site.sh`](tools/check-site.sh) inspects a running site container (read-only) and tells you which extensions to switch on,
which php.ini values to carry over, whether the code calls disabled shell functions and whether those calls are guarded.
See [docs/migrating-a-site.md](docs/migrating-a-site.md).

## Urgent fix (CVE)

Run the workflow by hand (Actions → build → Run workflow). Servers that watch the tags pick up the new image (ours check at night, an urgent fix is rolled out by starting the watcher by hand); otherwise redeploy.

## Rollback of a site

Pin the site to a fixed tag, e.g. `ghcr.io/exciting-it/php:8.3.37-apache-20261114`, and redeploy. Switch back to `8.3-apache` later,
or the site stops getting updates.

## License

[MIT](LICENSE)
