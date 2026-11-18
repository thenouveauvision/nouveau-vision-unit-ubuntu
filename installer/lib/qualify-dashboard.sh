#!/usr/bin/env bash

set -u

NVU_QUALIFY_MODULE_VERSION="0.2.0-dev"

ROOT="/usr/local/lib/nvu/dashboard"
CURRENT="$ROOT/current"
VENV="$ROOT/venv"

DASHBOARD_SERVICE="nvu-dashboard.service"
NVUN_SERVICE="nvun.service"

BACKEND_SOCKET="/run/nvu-dashboard/nvu-dashboard.sock"
BACKEND_ORIGIN="http://localhost"

APACHE_SERVICE="apache2"
APACHE_SITE="/etc/apache2/sites-available/nvu-dashboard.conf"
SYSTEMD_UNIT="/etc/systemd/system/nvu-dashboard.service"

QUALIFY_FAILURES=0

pass() {
    printf 'PASS: %s\n' "$1"
}

fail_gate() {
    printf 'FAIL: %s\n' "$1"
    QUALIFY_FAILURES=$((QUALIFY_FAILURES + 1))
}

service_active() {
    systemctl is-active --quiet "$1" \
        2>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$1" \
        2>/dev/null
}

discover_public_hostname() {
    if [[ -r "$APACHE_SITE" ]]; then
        awk '
            /^[[:space:]]*ServerName[[:space:]]+/ {
                print $2
                exit
            }
        ' "$APACHE_SITE"
    fi
}

discover_web_mode() {
    local hostname="$1"

    if [[ -z "$hostname" ]]; then
        printf '%s\n' "localhost"
    elif [[ "$hostname" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "ipv4"
    else
        printf '%s\n' "fqdn"
    fi
}

check_json_endpoint() {
    local route="$1"
    local expression="$2"
    local label="$3"
    local response

    response="$(
        sudo -n curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --unix-socket "$BACKEND_SOCKET" \
            "${BACKEND_ORIGIN}${route}" \
            2>/dev/null || true
    )"

    if [[ -z "$response" ]]; then
        fail_gate "$label"
        return
    fi

    if printf '%s\n' "$response" |
        jq -e "$expression" \
            >/dev/null 2>&1
    then
        pass "$label"
    else
        fail_gate "$label"
    fi
}

check_removed_route() {
    local route="$1"
    local code

    code="$(
        sudo -n curl \
            --silent \
            --output /dev/null \
            --write-out '%{http_code}' \
            --max-time 5 \
            --unix-socket "$BACKEND_SOCKET" \
            "${BACKEND_ORIGIN}${route}" \
            2>/dev/null || true
    )"

    if [[ "$code" == "404" ]]; then
        pass "${route} returns 404"
    else
        fail_gate "${route} returns 404"
    fi
}

qualify_release() {
    local current_target
    local resolved_release

    echo
    echo "=== RELEASE ==="

    if [[ -d "$ROOT" ]]; then
        pass "Dashboard production root exists"
    else
        fail_gate "Dashboard production root exists"
    fi

    if sudo -n test -L "$CURRENT" 2>/dev/null; then
        pass "current symlink exists"
    else
        fail_gate "current symlink exists"
    fi

    current_target="$(
        sudo -n readlink "$CURRENT" 2>/dev/null || true
    )"

    resolved_release="$(
        sudo -n readlink -f "$CURRENT" 2>/dev/null || true
    )"

    if [[ -n "$current_target" ]]; then
        pass "current target = $current_target"
    else
        fail_gate "current target is readable"
    fi

    if [[ -n "$resolved_release" ]] &&
       sudo -n test -d "$resolved_release"
    then
        pass "current resolves to an installed release"
    else
        fail_gate "current resolves to an installed release"
    fi

    for file in \
        server.py \
        nvu_rpc.py \
        requirements.txt \
        static/app.js \
        static/index.html \
        static/nvu-dashboard-icon.png \
        static/nvu-favicon.ico
    do
        if sudo -n test -f "$CURRENT/$file"; then
            pass "release file: $file"
        else
            fail_gate "release file: $file"
        fi
    done

    if sudo -n test -x "$VENV/bin/python" &&
       sudo -n test -x "$VENV/bin/gunicorn"
    then
        pass "production venv exists"
    else
        fail_gate "production venv exists"
    fi
}

qualify_systemd() {
    local main_pid
    local process_user

    echo
    echo "=== SYSTEMD ==="

    if service_active "$DASHBOARD_SERVICE"; then
        pass "Dashboard service active"
    else
        fail_gate "Dashboard service active"
    fi

    if service_enabled "$DASHBOARD_SERVICE"; then
        pass "Dashboard service enabled"
    else
        fail_gate "Dashboard service enabled"
    fi

    if service_active "$NVUN_SERVICE"; then
        pass "NVUN service active"
    else
        fail_gate "NVUN service active"
    fi

    if service_enabled "$NVUN_SERVICE"; then
        pass "NVUN service enabled"
    else
        fail_gate "NVUN service enabled"
    fi

    main_pid="$(
        systemctl show \
            "$DASHBOARD_SERVICE" \
            --property=MainPID \
            --value \
            2>/dev/null || true
    )"

    process_user=""

    if [[ "$main_pid" =~ ^[0-9]+$ &&
          "$main_pid" -gt 0 ]]
    then
        process_user="$(
            ps -o user= -p "$main_pid" \
                2>/dev/null |
            awk '{print $1}'
        )"
    fi

    if [[ "$process_user" == "nvu" ]]; then
        pass "Dashboard master process runs as nvu"
    else
        fail_gate "Dashboard master process runs as nvu"
    fi
}

qualify_listeners() {
    local tcp_listeners
    local socket_state

    echo
    echo "=== LISTENER SECURITY ==="

    if sudo -n test -S "$BACKEND_SOCKET"; then
        pass "Dashboard Unix socket exists"
    else
        fail_gate "Dashboard Unix socket exists"
    fi

    socket_state="$(
        sudo -n stat \
            -c '%U:%G %a %F' \
            "$BACKEND_SOCKET" \
            2>/dev/null || true
    )"

    if [[ "$socket_state" == "nvu:www-data 770 socket" ]]; then
        pass "Dashboard socket = nvu:www-data 0770"
    else
        fail_gate "Dashboard socket = nvu:www-data 0770"
    fi

    if sudo -n -u www-data curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        --unix-socket "$BACKEND_SOCKET" \
        "${BACKEND_ORIGIN}/api/version" \
        >/dev/null 2>&1
    then
        pass "Apache identity can access Dashboard socket"
    else
        fail_gate "Apache identity can access Dashboard socket"
    fi

    tcp_listeners="$(
        sudo -n ss -lntp 2>/dev/null ||
        ss -lnt 2>/dev/null ||
        true
    )"

    if printf '%s\n' "$tcp_listeners" |
        grep -Eq \
            '127\.0\.0\.1:8080[[:space:]]|0\.0\.0\.0:8080[[:space:]]|\[::\]:8080[[:space:]]'
    then
        fail_gate "Dashboard has no TCP backend"
    else
        pass "Dashboard has no TCP backend"
    fi
}

qualify_apis() {
    echo
    echo "=== DASHBOARD APIS ==="

    check_json_endpoint \
        "/api/health" \
        '.ok == true and .nvun == true' \
        "health API"

    check_json_endpoint \
        "/api/version" \
        '.ok == true
         and .dashboardVersion == "1.3.0"
         and .ticker == "NVU"' \
        "version API reports 1.3.0"

    check_json_endpoint \
        "/api/status" \
        '.ok == true
         and .nvun.online == true
         and .nvun.chain == "main"
         and .nvun.initialBlockDownload == false
         and .nvun.p2pPort == 9333
         and (.nvun.hostname | type == "string")' \
        "status API reports synchronized mainnet node"

    check_json_endpoint \
        "/api/network" \
        '.ok == true' \
        "network API"

    check_json_endpoint \
        "/api/peers" \
        '.ok == true' \
        "peers API"

    check_json_endpoint \
        "/api/blocks/latest?limit=3" \
        '.ok == true' \
        "latest blocks API"

    check_json_endpoint \
        "/api/wallet/status" \
        '.ok == true' \
        "wallet status API"

    check_json_endpoint \
        "/api/wallet/transactions?limit=3" \
        '.ok == true' \
        "wallet transactions API"

    check_json_endpoint \
        "/api/wallet/addresses" \
        '.ok == true' \
        "wallet addresses API"

    echo
    echo "=== REMOVED ROUTES ==="

    check_removed_route "/api/mining"
    check_removed_route "/api/mining/workers"
    check_removed_route "/api/mining/blocks"
}

qualify_web() {
    local http_scheme="http"
    local https_scheme="https"
    local hostname
    local web_mode
    local redirect_code
    local redirect_location
    local certificate_found=0

    echo
    echo "=== WEB INTEGRATION ==="

    hostname="$(
        discover_public_hostname
    )"

    web_mode="$(
        discover_web_mode "$hostname"
    )"

    pass "web mode = $web_mode"

    if [[ "$web_mode" == "localhost" ]]; then
        pass "localhost-only mode requires no Apache site"
        return
    fi

    if service_active "$APACHE_SERVICE"; then
        pass "Apache active"
    else
        fail_gate "Apache active"
    fi

    if sudo -n apache2ctl -t \
        >/dev/null 2>&1
    then
        pass "Apache syntax valid"
    else
        fail_gate "Apache syntax valid"
    fi

    if [[ -n "$hostname" ]]; then
        pass "public hostname = $hostname"
    else
        fail_gate "public hostname detected"
        return
    fi

    if curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        "${https_scheme}://${hostname}/api/version" |
        jq -e \
            '.dashboardVersion == "1.3.0"' \
            >/dev/null 2>&1
    then
        pass "public HTTPS Dashboard reports 1.3.0"
    else
        fail_gate "public HTTPS Dashboard reports 1.3.0"
    fi

    if sudo -n test -r \
        "/etc/letsencrypt/live/${hostname}/fullchain.pem" &&
       sudo -n test -r \
        "/etc/letsencrypt/live/${hostname}/privkey.pem"
    then
        certificate_found=1
    fi

    if [[ "$certificate_found" -eq 1 ]]; then
        pass "certificate present"
    else
        fail_gate "certificate present"
    fi

    redirect_code="$(
        curl \
            --silent \
            --output /dev/null \
            --write-out '%{http_code}' \
            --max-time 10 \
            "${http_scheme}://${hostname}/api/version" \
            2>/dev/null || true
    )"

    redirect_location="$(
        curl \
            --silent \
            --head \
            --max-time 10 \
            "${http_scheme}://${hostname}/api/version" \
            2>/dev/null |
        awk '
            BEGIN { IGNORECASE=1 }
            /^Location:/ {
                sub(/\r$/, "", $2)
                print $2
                exit
            }
        '
    )"

    case "$redirect_code" in
        301|302|307|308)
            pass "HTTP redirects to HTTPS"
            ;;
        *)
            fail_gate "HTTP redirects to HTTPS"
            ;;
    esac

    if [[ "$redirect_location" == "${https_scheme}://${hostname}/api/version" ]]; then
        pass "HTTP redirect preserves API path"
    else
        fail_gate "HTTP redirect preserves API path"
    fi
}

qualify_security() {
    local legacy_pattern
    local release_readable=1
    local unit_readable=1

    echo
    echo "=== SECURITY REGRESSION ==="

    legacy_pattern='1\.2\.1|Umbrel|umbrel\.local|asicseer|stratum|blocks_found|/api/mining|/run/nvu-credentials'

    for file in \
        "$CURRENT/server.py" \
        "$CURRENT/nvu_rpc.py" \
        "$CURRENT/static/app.js" \
        "$CURRENT/static/index.html"
    do
        sudo -n test -r "$file" || \
            release_readable=0
    done

    if [[ "$release_readable" -ne 1 ]]; then
        fail_gate "production source is readable for regression scan"
    elif sudo -n grep -RniE \
        --include='*.py' \
        --include='*.js' \
        --include='*.html' \
        "$legacy_pattern" \
        "$CURRENT" \
        >/dev/null 2>&1
    then
        fail_gate "no stale or obsolete source coupling"
    else
        pass "no stale or obsolete source coupling"
    fi

    sudo -n test -r "$SYSTEMD_UNIT" || \
        unit_readable=0

    if [[ "$unit_readable" -ne 1 ]]; then
        fail_gate "systemd unit is readable for credential scan"
    elif sudo -n grep -qiE \
        'RPC_PASSWORD|RPC_USER|rpcpassword|rpc-client\.env' \
        "$SYSTEMD_UNIT" \
        2>/dev/null
    then
        fail_gate "systemd unit contains no RPC credential metadata"
    else
        pass "systemd unit contains no RPC credential metadata"
    fi

    for file in \
        "$CURRENT/server.py" \
        "$CURRENT/nvu_rpc.py" \
        "$CURRENT/static/index.html"
    do
        if sudo -n -u nvu \
            sh -c 'printf x >> "$1"' sh "$file" \
            2>/dev/null
        then
            fail_gate "nvu cannot modify $file"
        else
            pass "nvu cannot modify $file"
        fi
    done
}

qualify_main() {
    QUALIFY_FAILURES=0

    echo "============================================================"
    echo "NVU DASHBOARD QUALIFICATION"
    echo "MODULE: $NVU_QUALIFY_MODULE_VERSION"
    echo "READ ONLY"
    echo "============================================================"

    qualify_release
    qualify_systemd
    qualify_listeners
    qualify_apis
    qualify_web
    qualify_security

    echo
    echo "============================================================"

    if [[ "$QUALIFY_FAILURES" -eq 0 ]]; then
        echo "NVU DASHBOARD QUALIFICATION PASSED"
        echo "Failures: 0"
        echo "============================================================"
        return 0
    fi

    echo "NVU DASHBOARD QUALIFICATION FAILED"
    echo "Failures: $QUALIFY_FAILURES"
    echo "============================================================"
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    qualify_main "$@"
fi
