#!/usr/bin/env bash
#
# NVU Dashboard configure-web
# B6.2G-7A
#
# Initial implementation:
#   FQDN mode
#
# Requires:
#   installed Unix-socket Dashboard

set -u
umask 027

CONFIGURE_WEB_VERSION="0.2.0-dev"

DASHBOARD_ROOT="/usr/local/lib/nvu/dashboard"
CURRENT="$DASHBOARD_ROOT/current"
SOCKET="/run/nvu-dashboard/nvu-dashboard.sock"
SERVICE="nvu-dashboard.service"

WEB_PHASE="preflight"
WEB_STARTED=0

APACHE_SITE_CREATED=0
APACHE_SITE_ENABLED=0
HTTPS_CONFIGURED=0
APACHE_PREEXISTED=0
DEFAULT_SITE_DISABLED=0
WEB_CHECKPOINT_CREATED=0

APACHE_SITE="/etc/apache2/sites-available/nvu-dashboard.conf"
APACHE_LINK="/etc/apache2/sites-enabled/nvu-dashboard.conf"
APACHE_SSL_SITE="/etc/apache2/sites-available/nvu-dashboard-le-ssl.conf"
APACHE_SSL_LINK="/etc/apache2/sites-enabled/nvu-dashboard-le-ssl.conf"
APACHE_CANDIDATE="/tmp/nvu-dashboard.conf.candidate"

usage() {
    cat <<EOF
NVU Dashboard configure-web

Usage:
  configure-web.sh.candidate --fqdn HOSTNAME

Example:
  configure-web.sh --fqdn node.example.com
EOF
}

web_fail() {
    local message="$1"
    local code="${2:-1}"

    echo
    echo "============================================================"
    echo "NVU DASHBOARD WEB CONFIGURATION NOT STARTED"
    echo "============================================================"
    echo
    echo "Phase:"
    echo "  $WEB_PHASE"
    echo
    echo "Reason:"
    echo "  $message"
    echo
    echo "Changes made:"
    echo "  none"

    return "$code"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        web_fail \
            "configure-web must be run with sudo/root privileges." \
            1

        return $?
    fi

    echo "PASS: running with required privileges."
}

parse_arguments() {
    FQDN=""

    if [[ "$#" -ne 2 || "$1" != "--fqdn" ]]; then
        usage
        return 2
    fi

    FQDN="$2"

    if [[ ! "$FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
       [[ "$FQDN" != *.* ]]
    then
        web_fail "Invalid FQDN: $FQDN" 2
        return $?
    fi

    echo "PASS: FQDN syntax accepted: $FQDN"
}

require_unix_dashboard() {
    WEB_PHASE="preflight"

    local scheme="http"
    local local_origin

    local_origin="${scheme}://localhost"

    systemctl is-active --quiet "$SERVICE" || {
        web_fail "Dashboard service is not active." 3
        return $?
    }

    systemctl is-enabled --quiet "$SERVICE" || {
        web_fail "Dashboard service is not enabled." 3
        return $?
    }

    [[ -L "$CURRENT" ]] || {
        web_fail "Dashboard current pointer is missing." 3
        return $?
    }

    if [[ ! -S "$SOCKET" ]]; then
        web_fail \
            "Canonical Unix-socket Dashboard is not installed. Existing TCP/reference deployments must not be modified by configure-web." \
            2

        return $?
    fi

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        --unix-socket "$SOCKET" \
        "${local_origin}/api/version" |
        jq -e \
            '.dashboardVersion == "1.3.0"
             and .ticker == "NVU"' \
            >/dev/null || {
                web_fail \
                    "Dashboard Unix-socket API qualification failed." \
                    3

                return $?
            }

    echo "PASS: canonical Unix-socket Dashboard qualified."
}

install_web_dependencies() {
    local package
    local missing=0

    if dpkg-query -W         -f='${db:Status-Abbrev}\n'         apache2 2>/dev/null |
        grep -Fxq 'ii '
    then
        APACHE_PREEXISTED=1
        echo "PASS: preserving preexisting Apache installation."
    else
        APACHE_PREEXISTED=0
        echo "NOTE: Apache will be installed by this NVU web run."
    fi

    for package in         apache2         certbot         python3-certbot-apache
    do
        if dpkg-query -W             -f='${db:Status-Abbrev}\n'             "$package" 2>/dev/null |
            grep -Fxq 'ii '
        then
            echo "PASS: web dependency installed: $package"
        else
            echo "REQUIRED: $package"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        command -v apt-get >/dev/null 2>&1 || {
            web_fail "apt-get is unavailable." 3
            return $?
        }

        export DEBIAN_FRONTEND=noninteractive

        apt-get update || {
            web_fail "Could not update the Ubuntu package index." 1
            return $?
        }

        apt-get install -y --no-install-recommends             apache2             certbot             python3-certbot-apache || {
                web_fail "Could not install Apache and Certbot dependencies." 1
                return $?
            }
    fi

    for package in         apache2         certbot         python3-certbot-apache
    do
        dpkg-query -W             -f='${db:Status-Abbrev}\n'             "$package" 2>/dev/null |
            grep -Fxq 'ii ' || {
                web_fail                     "Required web dependency is not installed: $package"                     1
                return $?
            }

        echo "PASS: verified web dependency: $package"
    done

    for command in         apache2ctl         a2enmod         a2ensite         certbot
    do
        command -v "$command" >/dev/null 2>&1 || {
            web_fail                 "Required web command is unavailable: $command"                 1
            return $?
        }

        echo "PASS: web command available: $command"
    done

    certbot plugins 2>/dev/null |
        grep -Fq 'apache' || {
            web_fail "Certbot Apache plugin is unavailable." 1
            return $?
        }

    echo "PASS: Certbot Apache plugin available."

    systemctl enable apache2 >/dev/null || {
        web_fail "Could not enable Apache." 1
        return $?
    }

    systemctl start apache2 || {
        web_fail "Could not start Apache." 1
        return $?
    }

    systemctl is-active --quiet apache2 || {
        web_fail "Apache is not active after dependency installation." 1
        return $?
    }

    systemctl is-enabled --quiet apache2 || {
        web_fail "Apache is not enabled after dependency installation." 1
        return $?
    }

    apache2ctl -t >/dev/null || {
        web_fail "Apache configuration is invalid after installation." 1
        return $?
    }

    echo "PASS: Apache active, enabled, and syntax-valid."
}

prepare_apache_baseline() {
    WEB_PHASE="apache-baseline"

    local default_link="/etc/apache2/sites-enabled/000-default.conf"
    local enabled_site
    local enabled_name
    local vhost_map=""

    echo
    echo "=== APACHE SHARED-SERVER SAFETY ==="

    apache2ctl -t >/dev/null || {
        web_fail "Existing Apache configuration is invalid." 3
        return $?
    }

    echo "PASS: existing Apache configuration syntax valid."

    # Refuse an explicit ServerName or ServerAlias collision.
    for enabled_site in /etc/apache2/sites-enabled/*.conf; do
        [[ -e "$enabled_site" || -L "$enabled_site" ]] || continue

        enabled_name="$(basename "$enabled_site")"

        case "$enabled_name" in
            nvu-dashboard.conf|nvu-dashboard-le-ssl.conf)
                continue
                ;;
        esac

        if awk -v fqdn="$FQDN" '
            BEGIN {
                fqdn = tolower(fqdn)
            }

            /^[[:space:]]*#/ {
                next
            }

            tolower($1) == "servername" {
                if (tolower($2) == fqdn) {
                    found = 1
                }
            }

            tolower($1) == "serveralias" {
                for (i = 2; i <= NF; i++) {
                    alias = tolower($i)

                    if (alias == fqdn) {
                        found = 1
                    }

                    if (substr(alias, 1, 2) == "*.") {
                        suffix = substr(alias, 2)

                        if (length(fqdn) > length(suffix) &&
                            substr(fqdn, length(fqdn) - length(suffix) + 1) == suffix) {
                            found = 1
                        }
                    }
                }
            }

            END {
                exit(found ? 0 : 1)
            }
        ' "$enabled_site"
        then
            web_fail \
                "Enabled Apache site already claims $FQDN: $enabled_name" \
                2
            return $?
        fi
    done

    echo "PASS: no enabled Apache site explicitly claims $FQDN."

    if [[ -L "$default_link" ]]; then
        if [[ "$APACHE_PREEXISTED" -eq 0 ]]; then
            a2dissite 000-default.conf >/dev/null || {
                web_fail \
                    "Could not disable the newly installed stock Apache site." \
                    1
                return $?
            }

            DEFAULT_SITE_DISABLED=1
            echo "PASS: newly installed stock Apache default site disabled."
        else
            echo "PASS: preexisting Apache default site preserved."

            vhost_map="$(apache2ctl -S 2>&1 || true)"

            if printf '%s\n' "$vhost_map" |
                grep -F "default server $FQDN " >/dev/null
            then
                web_fail \
                    "Preserved default Apache site implicitly claims $FQDN. Assign that site an explicit, different ServerName or disable it before configuring NVU." \
                    2
                return $?
            fi
        fi
    else
        echo "PASS: Apache default site is not enabled."
    fi

    # Do not create or overwrite a global ServerName. A dedicated NVU
    # vhost owns only the requested FQDN.
    echo "PASS: global Apache ServerName left unchanged."

    apache2ctl -t >/dev/null || {
        web_fail \
            "Apache configuration is invalid after shared-server checks." \
            1
        return $?
    }

    if [[ "$DEFAULT_SITE_DISABLED" -eq 1 ]]; then
        systemctl reload apache2 || {
            web_fail \
                "Apache reload failed after disabling the stock site." \
                1
            return $?
        }
    fi

    echo "PASS: Apache shared-server safety checks completed."
}

configure_fqdn() {
    WEB_PHASE="apache"

    local backend_scheme="http"
    local backend_origin
    local http_scheme="http"
    local http_origin

    backend_origin="${backend_scheme}://localhost/"
    http_origin="${http_scheme}://${FQDN}"

    command -v apache2ctl >/dev/null 2>&1 || {
        web_fail "Apache is not installed." 3
        return $?
    }

    command -v a2enmod >/dev/null 2>&1 || {
        web_fail "a2enmod is unavailable." 3
        return $?
    }

    command -v a2ensite >/dev/null 2>&1 || {
        web_fail "a2ensite is unavailable." 3
        return $?
    }

    getent ahosts "$FQDN" >/dev/null 2>&1 || {
        web_fail "FQDN does not resolve: $FQDN" 3
        return $?
    }

    apache2ctl -t >/dev/null 2>&1 || {
        web_fail "Existing Apache configuration is invalid." 3
        return $?
    }

    [[ ! -e "$APACHE_SITE" ]] || {
        web_fail "NVU Dashboard Apache site already exists." 2
        return $?
    }

    [[ ! -e "$APACHE_LINK" ]] || {
        web_fail "NVU Dashboard Apache site is already enabled." 2
        return $?
    }

    [[ ! -e "$APACHE_SSL_SITE" ]] || {
        web_fail "NVU Dashboard HTTPS site already exists." 2
        return $?
    }

    rm -f "$APACHE_CANDIDATE"

    {
        printf '\074VirtualHost *:80\076\n'
        printf '    ServerName %s\n' "$FQDN"
        printf '\n'
        printf '    ProxyRequests Off\n'
        printf '    ProxyPreserveHost On\n'
        printf '\n'
        printf '    ProxyPass        / unix:%s|%s\n' \
            "$SOCKET" \
            "$backend_origin"
        printf '    ProxyPassReverse / unix:%s|%s\n' \
            "$SOCKET" \
            "$backend_origin"
        printf '\n'
        printf '    ErrorLog ${APACHE_LOG_DIR}/nvu-dashboard-error.log\n'
        printf '    CustomLog ${APACHE_LOG_DIR}/nvu-dashboard-access.log combined\n'
        printf '\074/VirtualHost\076\n'
    } > "$APACHE_CANDIDATE" || {
        web_fail "Could not generate Apache candidate." 1
        return $?
    }

    grep -Fq 'ProxyRequests Off' "$APACHE_CANDIDATE" || {
        web_fail "Apache candidate is missing ProxyRequests Off." 1
        return $?
    }

    grep -Fq "unix:${SOCKET}|" "$APACHE_CANDIDATE" || {
        web_fail "Apache candidate is missing Unix-socket proxying." 1
        return $?
    }

    if grep -Eq \
        '127\.0\.0\.1:8080|0\.0\.0\.0:[0-9]+' \
        "$APACHE_CANDIDATE"
    then
        web_fail "Apache candidate contains a Dashboard TCP backend." 1
        return $?
    fi

    if grep -Eq \
        '&lt;|&gt;|<a href=' \
        "$APACHE_CANDIDATE"
    then
        web_fail "Apache candidate contains HTML corruption." 1
        return $?
    fi

    a2enmod proxy proxy_http rewrite ssl headers \
        >/dev/null || {
            web_fail "Could not enable required Apache modules." 1
            return $?
        }

    install \
        -o root \
        -g root \
        -m 0644 \
        "$APACHE_CANDIDATE" \
        "$APACHE_SITE" || {
            web_fail "Could not install Apache site." 1
            return $?
        }

    APACHE_SITE_CREATED=1

    a2ensite nvu-dashboard.conf >/dev/null || {
        web_fail "Could not enable Apache site." 1
        return $?
    }

    APACHE_SITE_ENABLED=1

    apache2ctl -t || {
        web_fail "Apache rejected the NVU Dashboard site." 1
        return $?
    }

    systemctl reload apache2 || {
        web_fail "Apache reload failed." 1
        return $?
    }

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        --resolve "${FQDN}:80:127.0.0.1" \
        "${http_origin}/api/version" |
        jq -e \
            '.dashboardVersion == "1.3.0"
             and .ticker == "NVU"' \
            >/dev/null || {
                web_fail \
                    "Apache HTTP proxy qualification failed." \
                    1

                return $?
            }

    WEB_STARTED=1

    echo "PASS: Apache FQDN site installed."
    echo "PASS: Apache proxies to the canonical Unix socket."
    echo "PASS: Dashboard HTTP API qualified."
}

configure_https() {
    WEB_PHASE="https"

    command -v certbot >/dev/null 2>&1 || {
        web_fail "Certbot is not installed." 3
        return $?
    }

    certbot plugins 2>/dev/null |
        grep -Fq 'apache' || {
            web_fail "Certbot Apache plugin is unavailable." 3
            return $?
        }

    certbot \
        --apache \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --redirect \
        --domain "$FQDN" || {
            web_fail "Certbot HTTPS configuration failed." 1
            return $?
        }

    HTTPS_CONFIGURED=1

    apache2ctl -t || {
        web_fail "Apache configuration is invalid after Certbot." 1
        return $?
    }

    systemctl reload apache2 || {
        web_fail "Apache reload failed after Certbot." 1
        return $?
    }

    echo "PASS: HTTPS configured."
    echo "PASS: HTTP-to-HTTPS redirect requested."
}

qualify_web() {
    WEB_PHASE="qualify"

    local https_scheme="https"
    local http_scheme="http"
    local https_origin
    local http_origin
    local redirect

    https_origin="${https_scheme}://${FQDN}"
    http_origin="${http_scheme}://${FQDN}"

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 15 \
        --resolve "${FQDN}:443:127.0.0.1" \
        "${https_origin}/api/version" |
        jq -e \
            '.dashboardVersion == "1.3.0"
             and .ticker == "NVU"' \
            >/dev/null || {
                web_fail "Public HTTPS version qualification failed." 1
                return $?
            }

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 15 \
        --resolve "${FQDN}:443:127.0.0.1" \
        "${https_origin}/api/status" |
        jq -e \
            '.ok == true
             and .nvun.online == true
             and .nvun.chain == "main"
             and .nvun.initialBlockDownload == false' \
            >/dev/null || {
                web_fail "Public HTTPS status qualification failed." 1
                return $?
            }

    redirect="$(
        curl \
            --silent \
            --show-error \
            --output /dev/null \
            --write-out '%{redirect_url}' \
            --max-time 15 \
            --resolve "${FQDN}:80:127.0.0.1" \
            "${http_origin}/api/version"
    )" || {
        web_fail "HTTP redirect qualification failed." 1
        return $?
    }

    [[ "$redirect" == "${https_origin}/api/version" ]] || {
        web_fail "HTTP redirect did not preserve the API path." 1
        return $?
    }

    if ss -lntp 2>/dev/null |
        grep -Eq \
            '127\.0\.0\.1:8080[[:space:]].*nvu-dashboard|0\.0\.0\.0:8080[[:space:]].*nvu-dashboard'
    then
        web_fail "Dashboard unexpectedly exposes a TCP backend." 1
        return $?
    fi

    echo "PASS: HTTPS Dashboard qualified."
    echo "PASS: NVUN online and synchronized."
    echo "PASS: HTTP redirect preserves API path."
    echo "PASS: Dashboard has no TCP backend."
}

checkpoint_web() {
    WEB_PHASE="checkpoint"

    local checkpoint_root="$DASHBOARD_ROOT/checkpoints"
    local checkpoint="$checkpoint_root/web-${FQDN}"

    [[ ! -e "$checkpoint" ]] || {
        web_fail "Web checkpoint already exists." 2
        return $?
    }

    install \
        -d \
        -o root \
        -g nvu \
        -m 0750 \
        "$checkpoint_root" \
        "$checkpoint" || {
            web_fail "Could not create web checkpoint." 1
            return $?
        }

    cp -a \
        "$APACHE_SITE" \
        "$checkpoint/nvu-dashboard.conf" || {
            web_fail "Could not checkpoint Apache HTTP site." 1
            return $?
        }

    if [[ -f "$APACHE_SSL_SITE" ]]; then
        cp -a \
            "$APACHE_SSL_SITE" \
            "$checkpoint/nvu-dashboard-le-ssl.conf" || {
                web_fail "Could not checkpoint Apache HTTPS site." 1
                return $?
            }
    fi

    {
        echo "NVU Dashboard Web Configuration Checkpoint"
        echo
        echo "Configure-web:"
        echo "  $CONFIGURE_WEB_VERSION"
        echo
        echo "FQDN:"
        echo "  $FQDN"
        echo
        echo "Backend:"
        echo "  unix"
        echo
        echo "Socket:"
        echo "  $SOCKET"
        echo
        echo "Apache:"
        echo "  $(systemctl is-active apache2)"
        echo
        echo "HTTPS:"
        echo "  enabled"
        echo
        echo "Certificate private key:"
        echo "  not copied"
    } > "$checkpoint/state.txt" || {
        web_fail "Could not record web checkpoint state." 1
        return $?
    }

    find "$checkpoint" \
        -type f \
        -print0 |
        sort -z |
        xargs -0 sha256sum \
        > "$checkpoint/SHA256SUMS.web" || {
            web_fail "Could not checksum web checkpoint." 1
            return $?
        }

    chown -R root:nvu "$checkpoint" || {
        web_fail "Could not set web checkpoint ownership." 1
        return $?
    }

    find "$checkpoint" \
        -type d \
        -exec chmod 0750 {} + || {
            web_fail "Could not set web checkpoint directory permissions." 1
            return $?
        }

    find "$checkpoint" \
        -type f \
        -exec chmod 0640 {} + || {
            web_fail "Could not set web checkpoint file permissions." 1
            return $?
        }

    WEB_CHECKPOINT_CREATED=1

    echo "PASS: web checkpoint created."
}

rollback_web() {
    local rollback_failed=0

    echo
    echo "=== WEB CONFIGURATION ROLLBACK ==="

    if [[ "$APACHE_SITE_ENABLED" -eq 1 ]]; then
        rm -f "$APACHE_LINK" || rollback_failed=1
    fi

    if [[ "$HTTPS_CONFIGURED" -eq 1 ]]; then
        rm -f "$APACHE_SSL_LINK" || rollback_failed=1
        rm -f "$APACHE_SSL_SITE" || rollback_failed=1
    fi

    if [[ "$APACHE_SITE_CREATED" -eq 1 ]]; then
        rm -f "$APACHE_SITE" || rollback_failed=1
    fi

    rm -f "$APACHE_CANDIDATE"

    if [[ "$DEFAULT_SITE_DISABLED" -eq 1 ]]; then
        a2ensite 000-default.conf >/dev/null 2>&1 || rollback_failed=1
    fi

    if apache2ctl -t >/dev/null 2>&1; then
        systemctl reload apache2 || rollback_failed=1
    else
        rollback_failed=1
    fi

    if [[ "$rollback_failed" -eq 0 ]]; then
        echo "Rollback status:"
        echo "  PASS"
        return 0
    fi

    echo "Rollback status:"
    echo "  REVIEW REQUIRED"
    return 1
}

run_web_phase() {
    local phase_name="$1"
    local phase_function="$2"
    local rc

    WEB_PHASE="$phase_name"

    echo
    echo "=== PHASE: $phase_name ==="

    set +e
    "$phase_function"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo
        echo "FAILED WEB PHASE:"
        echo "  $phase_name"

        rollback_web || true
        return "$rc"
    fi

    echo "PASS: web phase completed: $phase_name"
    return 0
}

configure_web_main() {
    local rc

    echo "============================================================"
    echo "NVU DASHBOARD CONFIGURE-WEB"
    echo "VERSION: $CONFIGURE_WEB_VERSION"
    echo "B6.2G-7B"
    echo "============================================================"

    require_root || return $?

    parse_arguments "$@" || return $?

    echo
    echo "=== DASHBOARD WEB PREFLIGHT ==="

    set +e
    require_unix_dashboard
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        return "$rc"
    fi

    echo
    echo "============================================================"
    echo "WEB PREFLIGHT PASSED"
    echo "============================================================"

    echo
    echo "=== PHASE: dependencies ==="

    set +e
    install_web_dependencies
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo
        echo "FAILED WEB PHASE:"
        echo "  dependencies"
        echo
        echo "Web configuration changes made:"
        echo "  none"
        return "$rc"
    fi

    echo "PASS: web phase completed: dependencies"

    run_web_phase "apache-baseline" prepare_apache_baseline || return $?
    run_web_phase "apache" configure_fqdn || return $?
    run_web_phase "https" configure_https || return $?
    run_web_phase "qualify" qualify_web || return $?
    run_web_phase "checkpoint" checkpoint_web || return $?

    echo
    echo "============================================================"
    echo "NVU DASHBOARD WEB CONFIGURATION PASSED"
    echo "============================================================"
    echo
    echo "FQDN:"
    echo "  $FQDN"
    echo
    echo "Backend:"
    echo "  unix"
    echo
    echo "HTTPS:"
    echo "  enabled"

    return 0
}

configure_web_main "$@"
