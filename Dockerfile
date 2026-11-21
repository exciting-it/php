# syntax=docker/dockerfile:1.7
#
# PHP platform image: official php:<version>-apache plus extensions and hardening.
#   - a small default set is loaded on every site (DEFAULT_EXTENSIONS)
#   - everything else is built in but switched off; a site switches extensions on with the
#     environment variable PHP_EXTENSIONS="soap gmp ioncube_loader" (see site-entrypoint)
#   - php.ini limits come from environment variables (PHP_MEMORY_LIMIT etc., defaults below)
# Built and tested in CI (see .github/workflows/build.yml); servers only pull it.

ARG PHP_VERSION=8.3
# CI passes the base pinned by digest (php:8.3-apache@sha256:…) and records it as a label, so the
# nightly check can tell whether the official image changed since this build.
ARG BASE_IMAGE=php:${PHP_VERSION}-apache
ARG BASE_DIGEST=unknown
FROM ${BASE_IMAGE}
ARG PHP_VERSION
ARG BASE_DIGEST
LABEL org.opencontainers.image.base.name="docker.io/library/php:${PHP_VERSION}-apache" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

# All Debian updates go in at build time, not only when Docker rebuilds the official image.
# The nightly CI check rebuilds as soon as apt reports new ones for the published image.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
 && rm -rf /var/lib/apt/lists/*

# Loaded on every site (on top of the ~33 extensions compiled into php:X-apache): what CMS, shops
# and their plugins commonly need and that carries little risk. imagick/exif/bcmath/intl/zip/gd as
# in the official wordpress image; soap for shipping/VAT-check plugins and JTL; calendar because
# plugins call cal_days_in_month() and die without it.
ARG DEFAULT_EXTENSIONS="opcache mysqli pdo_mysql gd imagick intl zip exif bcmath soap calendar"
# Built in, switched off: need a service a site doesn't have (redis, pgsql, ldap), are meant for
# CLI/daemons (pcntl, sockets) or are rarely needed. The build fails if one can't be built.
ARG OPTIONAL_EXTENSIONS="gmp xsl redis apcu bz2 gettext sockets pcntl ftp ldap pgsql pdo_pgsql tidy"
# Built in, switched off, and the build carries on without them if they don't exist for this PHP
# version (ionCube and SourceGuardian lag new PHP releases by months; imap left PHP core in 8.4).
ARG OPTIONAL_BEST_EFFORT="ioncube_loader sourceguardian imap"

# install-php-extensions resolves build deps, PECL and per-version quirks and cleans up after itself.
COPY --from=ghcr.io/mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# opcache is compiled in since PHP 8.5; only install it where it is still a separate extension
RUN exts="${DEFAULT_EXTENSIONS}"; \
    if php -m | grep -qx 'Zend OPcache'; then exts=${exts//opcache/}; fi; \
    install-php-extensions $exts

# Every .ini that appears in conf.d from here on belongs to an optional extension: move it to
# available/ so the extension is present but not loaded.
RUN ls /usr/local/etc/php/conf.d >/tmp/conf.before \
 && install-php-extensions ${OPTIONAL_EXTENSIONS} \
 && for e in ${OPTIONAL_BEST_EFFORT}; do \
      install-php-extensions "$e" || echo "WARN: $e is not available for PHP ${PHP_VERSION}, skipped" >&2; \
    done \
 && mkdir -p /usr/local/etc/php/available \
 && cd /usr/local/etc/php/conf.d \
 && for f in *.ini; do \
      grep -qxF "$f" /tmp/conf.before && continue; \
      n=$(basename "$f" .ini | sed -E 's/^[0-9]+[-_]?//; s/^docker-php-ext-//'); \
      mv "$f" "../available/$n.ini"; \
    done \
 && ls ../available | sed 's/\.ini$//' | sort >/usr/local/etc/php/extensions-available.txt \
 && echo ${DEFAULT_EXTENSIONS} | tr ' ' '\n' >/usr/local/etc/php/extensions-default.txt \
 && rm /tmp/conf.before

# Per-site defaults; Dokploy env overrides them. Changing env recreates the container (unlike
# inline compose configs), so these are the knobs for the customer portal.
ENV PHP_EXTENSIONS="" \
    PHP_MEMORY_LIMIT=256M \
    PHP_UPLOAD_MAX_FILESIZE=100M \
    PHP_POST_MAX_SIZE=100M \
    PHP_MAX_EXECUTION_TIME=300 \
    PHP_MAX_INPUT_TIME=300 \
    PHP_MAX_INPUT_VARS=5000 \
    PHP_TIMEZONE=Europe/Berlin \
    PHP_OPCACHE_MEMORY=128 \
    PHP_SESSION_COOKIE_SECURE=On \
    APACHE_MAX_WORKERS=25 \
    APACHE_START_SERVERS=2 \
    APACHE_MIN_SPARE=1 \
    APACHE_MAX_SPARE=5 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=1000 \
    PHP_DISABLE_FUNCTIONS="exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec"
# PHP_DISABLE_FUNCTIONS: no shell commands from PHP by default. A webshell dropped through a
# vulnerable plugin is mostly useless without them. A site that really needs them sets PHP_DISABLE_FUNCTIONS= (empty).

# Ghostscript: lets Imagick read PDFs (WordPress previews of uploaded PDFs; the official wordpress
# image ships it too). Our ImageMagick policy limits it to PDF, see imagemagick-policy.xml.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript \
 && rm -rf /var/lib/apt/lists/*

COPY rootfs/ /

RUN ls -d /etc/ImageMagick-* >/dev/null \
 && for d in /etc/ImageMagick-*; do cp /usr/local/etc/imagemagick-policy.xml "$d/policy.xml"; done

# status (server-status page) and autoindex (directory listings) are never needed on a site
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && a2enmod rewrite headers expires deflate remoteip setenvif \
 && a2dismod -f status autoindex \
 && a2enconf zz-platform \
 && chmod 755 /usr/local/bin/site-entrypoint

LABEL org.opencontainers.image.source="https://github.com/exciting-it/php" \
      org.opencontainers.image.description="Hardened PHP + Apache for hosting many sites: minimal default extensions, more switchable per site" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["site-entrypoint"]
CMD ["apache2-foreground"]
