#!/usr/bin/env bash
# test.sh <image> — smoke test for a freshly built platform image. Exit 0 = safe to push.
set -uo pipefail

IMG=${1:?usage: test.sh <image>}
fails=0
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# php inside the image, through the real entrypoint (so PHP_EXTENSIONS handling is tested too)
run() { docker run --rm "$@"; }

# name of the extension as extension_loaded() knows it
loaded_name() {
  case $1 in
    opcache) echo 'Zend OPcache' ;;
    ioncube_loader) echo 'ionCube Loader' ;;
    sourceguardian) echo 'SourceGuardian' ;;
    *) echo "$1" ;;
  esac
}
is_loaded() { # is_loaded <ext> [docker run args...]
  local ext=$1; shift
  run "$@" "$IMG" php -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$(loaded_name "$ext")" 2>/dev/null
}

echo "== $IMG: $(run "$IMG" php -r 'echo PHP_VERSION;')"

defaults=$(run --entrypoint cat "$IMG" /usr/local/etc/php/extensions-default.txt)
available=$(run --entrypoint cat "$IMG" /usr/local/etc/php/extensions-available.txt)
echo "   default:   $(echo $defaults)"
echo "   available: $(echo $available)"

echo "-- PHP starts without warnings"
out=$(run "$IMG" php -v 2>&1)
if grep -qiE 'warning|unable to load|error' <<<"$out"; then bad "php -v: $out"; else ok "php -v"; fi

echo "-- default extensions are loaded"
for e in $defaults; do is_loaded "$e" && ok "$e" || bad "$e not loaded"; done

echo "-- optional extensions are off by default"
for e in $available; do is_loaded "$e" && bad "$e is loaded without being asked for" || ok "$e off"; done

echo "-- each optional extension loads on its own, without warnings"
for e in $available; do
  out=$(run -e PHP_EXTENSIONS="$e" "$IMG" php -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$(loaded_name "$e")" 2>&1)
  rc=$?
  if ((rc != 0)); then bad "$e did not load: $out"
  elif grep -qiE 'warning|unable to load|error' <<<"$out"; then bad "$e loads with warnings: $out"
  else ok "$e"; fi
done

echo "-- all optional extensions together"
all=$(echo $available)
out=$(run -e PHP_EXTENSIONS="$all" "$IMG" php -v 2>&1)
if grep -qiE 'warning|unable to load|error' <<<"$out"; then bad "all together: $out"; else ok "all $(wc -w <<<"$all" | tr -d ' ') together"; fi

echo "-- unknown extension names are ignored, not fatal"
out=$(run -e PHP_EXTENSIONS="does_not_exist" "$IMG" php -r 'echo "alive";' 2>&1)
[[ $out == *alive* ]] && ok "typo tolerated" || bad "typo broke php: $out"

echo "-- php.ini values come from the environment"
v=$(run -e PHP_MEMORY_LIMIT=512M "$IMG" php -r 'echo ini_get("memory_limit");')
[[ $v == 512M ]] && ok "memory_limit=512M" || bad "memory_limit is '$v', expected 512M"
v=$(run "$IMG" php -r 'echo ini_get("display_errors"), "|", ini_get("date.timezone");')
[[ $v == "|Europe/Berlin" || $v == "0|Europe/Berlin" || $v == "Off|Europe/Berlin" ]] && ok "display_errors off, timezone Berlin" || bad "display_errors|timezone = $v"

echo "-- Apache serves PHP"
cid=$(docker run -d -p 127.0.0.1::80 "$IMG")
trap 'docker rm -f "$cid" >/dev/null 2>&1' EXIT
port=$(docker port "$cid" 80/tcp | head -1 | sed 's/.*://')
docker exec "$cid" sh -c 'echo "<?php echo \"ok \", PHP_VERSION;" >/var/www/html/index.php
  mkdir -p /var/www/html/wp-content/uploads && echo "<?php echo \"shell\";" >/var/www/html/wp-content/uploads/x.php
  mkdir -p /var/www/html/.git && echo secret >/var/www/html/.git/config'
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -sS "http://127.0.0.1:$port/")
[[ $body == "ok "* ]] && ok "index.php -> $body" || bad "index.php -> $body"
headers=$(curl -sSI "http://127.0.0.1:$port/")
grep -qi '^x-powered-by' <<<"$headers" && bad "X-Powered-By header present" || ok "no X-Powered-By"
grep -qiE '^server: apache/[0-9]' <<<"$headers" && bad "Server header shows the Apache version" || ok "Server header without version"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/wp-content/uploads/x.php")
[[ $code == 403 ]] && ok "PHP in uploads blocked (403)" || bad "PHP in uploads -> $code, expected 403"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/.git/config")
[[ $code == 404 ]] && ok ".git hidden (404)" || bad ".git/config -> $code, expected 404"

echo "-- hardening"
expect_code() { # expect_code <path> <code>
  local c; c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port$1")
  [[ $c == "$2" ]] && ok "$1 -> $c" || bad "$1 -> $c, expected $2"
}
docker exec "$cid" sh -c 'cd /var/www/html && for f in dump.sql wp-config.php.bak debug.log composer.lock readme.html style.css; do echo x >$f; done
  mkdir -p listing && echo x >listing/file.txt && printf "Options +Indexes\n" >listing/.htaccess'
for f in dump.sql wp-config.php.bak debug.log composer.lock readme.html; do expect_code "/$f" 403; done
expect_code /style.css 200
expect_code /server-status 404
c=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/listing/")
[[ $c == 403 || $c == 404 || $c == 500 ]] && ok "no directory listing even with Options +Indexes (-> $c)" || bad "/listing/ -> $c (directory listing?)"
headers=$(curl -sSI "http://127.0.0.1:$port/")
for h in 'x-content-type-options: nosniff' 'x-frame-options: SAMEORIGIN' 'referrer-policy: strict-origin-when-cross-origin'; do
  grep -qi "^$h" <<<"$headers" && ok "header $h" || bad "header missing: $h"
done
v=$(run "$IMG" php -r 'echo function_exists("exec") ? "on" : "off", "|", function_exists("shell_exec") ? "on" : "off";')
[[ $v == "off|off" ]] && ok "exec/shell_exec disabled by default" || bad "exec|shell_exec = $v"
v=$(run -e PHP_DISABLE_FUNCTIONS= "$IMG" php -r 'echo function_exists("exec") ? "on" : "off";')
[[ $v == on ]] && ok "PHP_DISABLE_FUNCTIONS= re-enables exec" || bad "exec with empty PHP_DISABLE_FUNCTIONS = $v"
v=$(run "$IMG" php -r 'echo ini_get("allow_url_include") ? "on" : "off", "|", ini_get("session.cookie_secure") ? "on" : "off";')
[[ $v == "off|on" ]] && ok "allow_url_include off, session.cookie_secure on" || bad "allow_url_include|cookie_secure = $v"

echo "-- Imagick + Ghostscript: PDF previews yes, PostScript no"
v=$(run --entrypoint sh "$IMG" -c 'gs -q -dSAFER -sDEVICE=pdfwrite -o /tmp/t.pdf -c "<</PageSize [200 100]>> setpagedevice showpage" >/dev/null 2>&1
  php -r "try { \$i = new Imagick(); \$i->setResolution(36, 36); \$i->readImage(\"/tmp/t.pdf[0]\"); \$i->setImageFormat(\"jpeg\"); echo strlen(\$i->getImageBlob()) > 0 ? \"pdf-ok\" : \"pdf-empty\"; } catch (Throwable \$e) { echo \"pdf-fail: \", \$e->getMessage(); }
    try { \$i = new Imagick(); \$i->readImageBlob(\"%!PS-Adobe-3.0\n/x 1 def\nshowpage\n\"); echo \" ps-READ\"; } catch (Throwable \$e) { echo \" ps-blocked\"; }
    try { \$i = new Imagick(); \$i->readImage(\"text:/etc/passwd\"); echo \" text-READ\"; } catch (Throwable \$e) { echo \" text-blocked\"; }"' 2>&1)
[[ $v == "pdf-ok ps-blocked text-blocked" ]] && ok "PDF -> JPEG works, PostScript and text: blocked" || bad "imagick/gs: $v"

echo "-- APACHE_MAX_WORKERS limits concurrent PHP processes"
apache_procs() { docker exec "$1" sh -c 'n=0; for f in /proc/[0-9]*/comm; do [ "$(cat "$f" 2>/dev/null)" = apache2 ] && n=$((n+1)); done; echo $n'; }
wid=$(docker run -d -p 127.0.0.1::80 -e APACHE_MAX_WORKERS=3 "$IMG")
wport=$(docker port "$wid" 80/tcp | head -1 | sed 's/.*://')
docker exec "$wid" sh -c 'echo "<?php sleep(3); echo \"done\";" >/var/www/html/slow.php'
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$wport/slow.php" -m 1 >/dev/null 2>&1; [[ $? == 28 ]] && break; sleep 1; done
for _ in $(seq 1 10); do curl -s -o /dev/null -m 15 "http://127.0.0.1:$wport/slow.php" & done
sleep 1.5
n=$(apache_procs "$wid")
wait
# master + at most 3 workers
((n >= 2 && n <= 4)) && ok "10 parallel requests, $n apache processes (limit 3 + master)" || bad "APACHE_MAX_WORKERS=3 but $n apache processes"
docker logs "$wid" 2>&1 | grep -q 'not defined' && bad "Apache reports undefined config variables" || ok "no undefined Apache variables"
docker rm -f "$wid" >/dev/null
v=$(docker run --rm -e APACHE_MAX_WORKERS=abc "$IMG" sh -c 'echo $APACHE_MAX_WORKERS' 2>/dev/null)
[[ $v == 25 ]] && ok "invalid APACHE_MAX_WORKERS falls back to 25" || bad "APACHE_MAX_WORKERS=abc -> '$v'"

echo "-- runs with dropped capabilities (compose hardening from the README)"
hid=$(docker run -d -p 127.0.0.1::80 --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add NET_BIND_SERVICE --cap-add KILL --security-opt no-new-privileges:true -e PHP_EXTENSIONS="redis" "$IMG")
trap 'docker rm -f "$cid" "$hid" >/dev/null 2>&1' EXIT
hport=$(docker port "$hid" 80/tcp | head -1 | sed 's/.*://')
docker exec "$hid" sh -c 'echo "<?php echo extension_loaded(\"redis\") ? \"ok\" : \"no-redis\";" >/var/www/html/index.php'
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$hport/" >/dev/null 2>&1 && break; sleep 1; done
body=$(curl -sS "http://127.0.0.1:$hport/")
[[ $body == ok ]] && ok "hardened container serves PHP, PHP_EXTENSIONS works" || { bad "hardened container -> '$body'"; docker logs "$hid" 2>&1 | tail -5; }

echo
if ((fails)); then echo "$fails test(s) FAILED for $IMG"; exit 1; fi
echo "all tests passed for $IMG"
