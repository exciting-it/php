#!/usr/bin/env bash
#
# check-site.sh <container> [--logs] — read-only check before (and after) moving a running site onto
# ghcr.io/exciting-it/php. Changes nothing.
#
#   before the switch:  which PHP extensions to switch on, which php.ini values to carry over as env,
#                       which code calls the shell functions the image disables, PDFs (Ghostscript)
#   after the switch:   --logs searches the container log for errors the image could cause
#
# Run on the Dokploy host:      bash check-site.sh <container> [--logs]
# or from elsewhere:           ssh root@<docker-host> bash -s -- <container> < tools/check-site.sh
# Container names: docker ps --format '{{.Names}}' | grep -E -- '-(wordpress|joomla|shop)-1$'
#
# Extension lists come from the image if it is present on the host (IMAGE=...), otherwise from the
# copies below; keep those in sync with the Dockerfile.
set -uo pipefail

DEFAULT_EXT="opcache mysqli pdo_mysql gd imagick intl zip exif bcmath soap calendar"
OPTIONAL_EXT="gmp xsl redis apcu bz2 gettext sockets pcntl ftp ldap pgsql pdo_pgsql tidy imap ioncube_loader sourceguardian"
# compiled into php:X-apache, always on
CORE_EXT="core ctype curl date dom fileinfo filter hash iconv json libxml mbstring mysqlnd openssl pcre pdo pdo_sqlite phar posix random readline reflection session simplexml sodium spl sqlite3 standard tokenizer xml xmlreader xmlwriter zlib lexbor uri"

main() {
  local c=${1:-} mode=${2:-}
  if [[ -z $c ]]; then echo "usage: check-site.sh <container> [--logs]" >&2; return 2; fi
  docker inspect "$c" >/dev/null 2>&1 || { echo "container '$c' not found" >&2; return 2; }
  local docroot=${DOCROOT:-/var/www/html}
  local image=${IMAGE:-ghcr.io/exciting-it/php:8.3-apache}

  if [[ $mode == --logs ]]; then check_logs "$c"; return; fi

  if docker image inspect "$image" >/dev/null 2>&1; then
    DEFAULT_EXT=$(docker run --rm --entrypoint cat "$image" /usr/local/etc/php/extensions-default.txt | tr '\n' ' ')
    OPTIONAL_EXT=$(docker run --rm --entrypoint cat "$image" /usr/local/etc/php/extensions-available.txt | tr '\n' ' ')
    echo "(extension lists from $image)"
  fi

  local php kind
  php=$(docker exec "$c" php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;' 2>/dev/null) || { echo "no php in container $c" >&2; return 2; }
  kind=PHP
  docker exec "$c" test -f "$docroot/wp-config.php" && kind=WordPress
  docker exec "$c" test -f "$docroot/configuration.php" && kind=Joomla
  docker exec "$c" test -f "$docroot/includes/config.JTL-Shop.ini.php" && kind=JTL-Shop
  echo "== $c: $kind, PHP $php  ->  image: ghcr.io/exciting-it/php:${php}-apache"

  check_extensions "$c"
  check_ini "$c"
  check_shell "$c" "$docroot"
  [[ $kind == WordPress ]] && check_pdfs "$c" "$docroot"
  echo
  echo "After the switch: check-site.sh $c --logs"
}

has() { [[ " $2 " == *" $1 "* ]]; }

# 1. extensions loaded today vs. the image
check_extensions() {
  local c=$1 mods m on=() missing=()
  mods=$(docker exec "$c" php -m 2>/dev/null | grep -v '^\[' | grep -v '^$' |
    tr 'A-Z' 'a-z' | sed -e 's/^zend opcache$/opcache/' -e 's/^ioncube loader$/ioncube_loader/' -e 's/^the ioncube php loader.*/ioncube_loader/' -e 's/ /_/g' | sort -u)
  for m in $mods; do
    has "$m" "$CORE_EXT $DEFAULT_EXT" && continue
    if has "$m" "$OPTIONAL_EXT"; then on+=("$m"); else missing+=("$m"); fi
  done
  echo
  echo "-- PHP extensions"
  if ((${#on[@]})); then
    echo "   loaded today and off in the image -> add to the container environment:"
    echo "   PHP_EXTENSIONS=${on[*]}"
  else
    echo "   everything loaded today is on by default in the image (PHP_EXTENSIONS stays empty)"
  fi
  ((${#missing[@]})) && echo "   MISSING from the image (sort out before moving): ${missing[*]}"
  echo "   (loaded does not mean needed: what the site never uses can stay off)"
}

# 2. php.ini values that are higher today than the image default -> carry over as env.
#    Read from the ini files themselves: the CLI reports max_execution_time 0 / max_input_time -1.
check_ini() {
  local c=$1 out
  out=$(docker exec -i "$c" php <<'PHPEOF' 2>/dev/null
<?php
$platform = [
  'memory_limit' => ['256M', 'PHP_MEMORY_LIMIT'],
  'upload_max_filesize' => ['100M', 'PHP_UPLOAD_MAX_FILESIZE'],
  'post_max_size' => ['100M', 'PHP_POST_MAX_SIZE'],
  'max_execution_time' => ['300', 'PHP_MAX_EXECUTION_TIME'],
  'max_input_time' => ['300', 'PHP_MAX_INPUT_TIME'],
  'max_input_vars' => ['5000', 'PHP_MAX_INPUT_VARS'],
];
$files = array_filter(array_merge([php_ini_loaded_file()], array_map('trim', explode(',', (string) php_ini_scanned_files()))));
$ini = [];
foreach ($files as $f) {
  $a = @parse_ini_file($f, false, INI_SCANNER_RAW);
  if (is_array($a)) $ini = array_merge($ini, $a);   // later files win, as in PHP
}
$bytes = function ($v) {
  $v = trim((string) $v);
  if ($v === '-1' || $v === '0') return PHP_INT_MAX;  // unlimited
  $n = (float) $v;
  switch (strtolower(substr($v, -1))) { case 'g': $n *= 1024; case 'm': $n *= 1024; case 'k': $n *= 1024; }
  return $n;
};
foreach ($platform as $k => [$def, $env]) {
  if (!isset($ini[$k])) continue;   // not configured: PHP default, always below the platform default
  $cur = $ini[$k];
  if ($bytes($cur) > $bytes($def)) echo "$env=$cur   (today $cur, image default $def)\n";
}
PHPEOF
)
  echo
  echo "-- PHP settings (from the ini files; php_value in a .htaccess is not covered)"
  if [[ -n $out ]]; then
    echo "   higher today than in the image -> add to the container environment:"
    printf '%s\n' "$out" | sed 's/^/   /'
  else
    echo "   image defaults are enough (256M memory, 100M upload, 300 s, 5000 input vars)"
  fi
}

# 3. calls of functions the image disables. "guarded" = the file checks function_exists()/
#    disable_functions first, then the plugin copes. "unguarded" = look at it: since PHP 8 such a
#    call is a fatal error ("Call to undefined function") if the code path runs.
check_shell() {
  local c=$1 docroot=$2 hits
  hits=$(docker exec -i -e DOCROOT="$docroot" "$c" sh -s <<'EOS' 2>/dev/null
fns='exec|passthru|shell_exec|system|proc_open|popen|pcntl_exec'
re='(^|[^>:$.[:alnum:]_'"'"'"])('"$fns"')\('
grep -rnE --include='*.php' "$re" "$DOCROOT" 2>/dev/null \
  | grep -vE '/(tests?|node_modules)/' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(\*|//|#)' \
  | grep -vE "function[[:space:]]+($fns)[[:space:]]*\(" \
  | grep -vE '(exec|system)\((s|es)\)' \
  | while IFS= read -r line; do
      f=${line%%:*}; rest=${line#*:}; n=${rest%%:*}; code=${rest#*:}
      fn=$(printf '%s' "$code" | grep -oE "$re" | head -1 | sed -E 's/^[^a-z_]*//; s/\($//')
      if grep -qE "function_exists[[:space:]]*\([[:space:]]*.\\\\?$fn.|is_callable[[:space:]]*\([[:space:]]*.$fn.|disable_functions|isMethodDisabled" "$f"; then g=guarded; else g=unguarded; fi
      printf '%s\t%s\t%s:%s\n' "$g" "$fn" "${f#"$DOCROOT"/}" "$n"
    done
EOS
)
  echo
  echo "-- calls of disabled shell functions (exec, system, shell_exec, passthru, proc_open, popen)"
  if [[ -z $hits ]]; then echo "   none"; return; fi
  local g fn loc note checked="" known="" unknown=""
  while IFS=$'\t' read -r g fn loc; do
    if [[ $g == guarded ]]; then checked+="$(component "$loc")"$'\n'; continue; fi
    note=$(known_note "$loc")
    if [[ -n $note ]]; then known+="$note"$'\n'; else unknown+="   $fn  $loc"$'\n'; fi
  done <<<"$hits"

  if [[ -n $checked ]]; then
    echo "   guarded (the code checks whether the function exists and copes without it):"
    printf '%s' "$checked" | sort | uniq -c | sort -rn | awk '{printf "     %3d  %s\n", $1, $2}'
  fi
  if [[ -n $known ]]; then
    echo "   unguarded but known harmless (never runs on a website):"
    printf '%s' "$known" | sort | uniq -c | sort -rn | sed -E 's/^ *([0-9]+) /     \1  /'
  fi
  if [[ -n $unknown ]]; then
    echo "   LOOK AT THIS (unguarded, unknown): does this code run on the site? If yes and the site needs it:"
    echo "   PHP_DISABLE_FUNCTIONS= (empty) for this site."
    printf '%s' "$unknown" | sort -u | head -40
  else
    echo "   -> the shell functions can stay disabled"
  fi
}

# plugin/package a file belongs to, for the summary
component() {
  awk -F/ '{ for (i = 1; i < NF; i++) {
      if ($i ~ /^(plugins|themes|mu-plugins|components|modules|templates)$/) { print $i "/" $(i+1); exit }
      if ($i == "vendor") { print "vendor/" $(i+1) "/" $(i+2); exit } }
    print $1 "/" $2 }' <<<"$1"
}

# explanation for unguarded calls that are known not to run on a website ("" = unknown)
known_note() {
  case ${1%:*} in
    */nfwlog/*) echo "NinjaFirewall log file: logged attacks, not executed code" ;;
    *[Pp][Hh][Pp][Mm]ailer*) echo "PHPMailer: only for the sendmail transport (use SMTP)" ;;
    *squizlabs/php_codesniffer* | */Commands/* | */Command/* | */bin/* | */build/* | */build.php | */examples/* | */example/* | \
      */dev/* | */tools/* | *xhprof* | *tests.php | *-test.php | *_test.php | *Test.php)
      echo "developer/build/test tool, never loaded by the website" ;;
    */ID3/getid3*) echo "getID3 (WordPress core): only Windows helpers or files > 2 GB on 32-bit PHP" ;;
    */class-snoopy.php) echo "Snoopy (WordPress core): legacy, unused since WordPress 3.0" ;;
    */Text/Diff/Engine/shell.php) echo "Text_Diff \"shell\" engine: only on explicit request, WordPress uses \"native\"" ;;
    */GeoIp2/GeoIp2.php) echo "Matomo GeoIP update: behind supportsAsync(), which detects disabled functions" ;;
    *aws-sdk-php/*CredentialProvider*) echo "AWS SDK credential_process: only with a ~/.aws/config profile" ;;
    *pear-core-minimal*) echo "PEAR OS detection: CLI only" ;;
    *monolog/*Processor/*) echo "Monolog git/hg processors: only if configured" ;;
    */symfony/process/* | */symfony/console/*) echo "Symfony Process/Console: only when code starts programs (CLI)" ;;
    *thecodingmachine/safe/*) echo "thecodingmachine/safe: wrappers, only active if code calls them" ;;
    *Minify/ClosureCompiler* | *Minify/YUICompressor*) echo "Minify with a Java compressor: only if configured; no java in the container" ;;
    *open-telemetry/*) echo "OpenTelemetry host detector: only with tracing enabled" ;;
    *monolog/*ProcessHandler*) echo "Monolog ProcessHandler: only if logs are piped to a program" ;;
    *google/auth/src/CredentialsLoader*) echo "Google auth library: client certificate via gcloud, not used by plugins" ;;
    *DaemonApplication*) echo "Joomla daemon mode: CLI only" ;;
    *pspellshell*) echo "JCE spellchecker via aspell: binary not in the container" ;;
    *) echo "" ;;
  esac
}

# 4. WordPress makes previews of uploaded PDFs with Imagick + Ghostscript
check_pdfs() {
  local c=$1 docroot=$2 n
  n=$(docker exec "$c" sh -c "find '$docroot/wp-content/uploads' -iname '*.pdf' 2>/dev/null | wc -l")
  echo
  echo "-- PDFs in the media library: $n"
  ((n > 0)) && echo "   previews need Imagick + Ghostscript (both in the image, PDF only)"
  return 0
}

# after the switch: errors the image can cause
check_logs() {
  local c=$1 since=${SINCE:-48h} out
  out=$(docker logs --since "$since" "$c" 2>&1 |
    grep -E 'Call to undefined function|has been disabled|Unable to load dynamic library|not available in this image|PHP (Fatal|Parse) error' |
    sed -E 's/^\[[^]]*\] //; s/ in \/var\/www\/html/ in …/' | sort | uniq -c | sort -rn | head -30)
  echo "== $c: container log, last $since"
  if [[ -z $out ]]; then echo "   no errors that point to the image"; else printf '%s\n' "$out"; fi
}

# wrapped so that "ssh host bash -s < check-site.sh" has read the whole script before docker exec runs
main "$@" </dev/null
