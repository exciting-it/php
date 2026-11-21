# Moving an existing site onto the image

## 1. Check the running site

`tools/check-site.sh` is read-only. Run it on the Docker host, or pipe it there:

```bash
bash tools/check-site.sh <container>                              # on the host
ssh root@<docker-host> bash -s -- <container> < tools/check-site.sh   # from elsewhere
```

It reports:

- **extensions** the site loads today that are off in the image, ready to paste as `PHP_EXTENSIONS=…`
- **php.ini values** that are higher today than the image defaults, ready to paste as `PHP_MEMORY_LIMIT=…` etc. (read from the ini files;
  `php_value` lines in a .htaccess are not covered)
- **calls of disabled shell functions**, sorted into
  - *guarded*: the code checks `function_exists()`/`disable_functions` first and copes without
  - *unguarded but known harmless*: code that never runs on a website (build tools, Windows branches, sendmail transport, firewall logs, …)
  - *look at this*: everything else. Since PHP 8 an unguarded call of a disabled function is a fatal error if that code path runs.
    If the site really needs it, set `PHP_DISABLE_FUNCTIONS=` (empty) for that site only.
- for WordPress: the number of PDFs in the media library (previews need Ghostscript, which the image has)

## 2. Switch the compose file

Replace the app service's `build:` block (or `image: php:…` / `image: wordpress:…`) with

```yaml
    image: ghcr.io/exciting-it/php:8.3-apache
    environment:
      PHP_EXTENSIONS: ""          # from check-site.sh
      # PHP_MEMORY_LIMIT: 512M    # from check-site.sh
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID, NET_BIND_SERVICE, KILL]
```

Drop php.ini and Apache lines that the image already sets (`display_errors`, `expose_php`, `ServerTokens`, the limits above, `RemoteIP*`,
`SetEnvIf X-Forwarded-Proto`). Keep application-specific rules (e.g. blocking an editor endpoint outside the admin area).

## 3. Try it before going live

Start the new image next to the live container, with the site's volume mounted **read-only**, on the same network (same database),
with the new config files and without a domain. Request the same URLs from both containers and compare status codes and bodies:

```bash
docker run -d --name preflight --network <stack-network> \
  -v <site-volume>:/var/www/html:ro \
  -v $PWD/zz-site.ini:/usr/local/etc/php/conf.d/zz-site.ini:ro \
  --security-opt no-new-privileges:true --cap-drop ALL \
  --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE --cap-add KILL \
  ghcr.io/exciting-it/php:8.3-apache
# curl -H "Host: example.com" -H "X-Forwarded-Proto: https" http://<old-ip>/… vs http://<new-ip>/…
docker rm -f preflight
```

## 4. Deploy and check the log

Redeploy the stack, then:

```bash
bash tools/check-site.sh <container> --logs
```

It searches the container log for `Call to undefined function`, extensions that failed to load and fatal errors.

## Notes for WordPress

- The official `wordpress` image copies WordPress core into the volume and writes `wp-config.php` from environment variables on first start.
  This image doesn't. Make sure core and `wp-config.php` already live in the volume before switching.
- With shell functions disabled, plugins that check first keep working: Matomo computes reports sequentially instead of in parallel processes,
  site-health screens show single values as unavailable, UUID libraries use random node IDs instead of the MAC address.
- PDF previews are generated on upload only; existing PDFs need a plugin such as "Regenerate Thumbnails".
