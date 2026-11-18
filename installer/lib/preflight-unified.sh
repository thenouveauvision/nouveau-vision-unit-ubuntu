#!/usr/bin/env bash
#
# Nouveau-Vision Unit Unified Preflight
# Milestone: B6.2I-2
#
# READ ONLY
#
# Initial scope:
#   - host/platform
#   - installer integrity
#   - NVUN runtime dependencies
#   - service identity
#   - NVUN installation discovery
#   - RPC credential contract
#   - node/wallet health
#   - NVUN listener security
#
# Unified discovery covers NVUN, Dashboard, and public web state.

set -u

PREFLIGHT_VERSION="0.2.0-dev"
PREFLIGHT_SCOPE="FULL_STACK"

REQUESTED_FQDN=""

MODULE_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 &&
    pwd -P
)"

INSTALLER_ROOT="$(
    cd -- "${MODULE_DIR}/.." >/dev/null 2>&1 &&
    pwd -P
)"

VERSION_FILE="$INSTALLER_ROOT/VERSION"

NODE_INSTALLER="$INSTALLER_ROOT/lib/install-node.sh"
DASHBOARD_INSTALLER="$INSTALLER_ROOT/lib/install-dashboard.sh"
WEB_CONFIGURATOR="$INSTALLER_ROOT/lib/configure-web.sh"
DASHBOARD_PREFLIGHT="$INSTALLER_ROOT/lib/preflight.sh"
DASHBOARD_QUALIFY="$INSTALLER_ROOT/lib/qualify-dashboard.sh"

NVUN_VERSION="1.0.0"
PAYLOAD_ROOT="$INSTALLER_ROOT/payload/nvun/$NVUN_VERSION"
PAYLOAD_NVUND="$PAYLOAD_ROOT/bin/nvund"
PAYLOAD_CLI="$PAYLOAD_ROOT/bin/nvu-cli"
PAYLOAD_VERSION="$PAYLOAD_ROOT/VERSION"
PAYLOAD_SUMS="$PAYLOAD_ROOT/SHA256SUMS"

EXPECTED_NVUND_SHA256="c5154b355cb4969138fe816f48db6dc73614e3f6e6e7c2d2efd22cc2d0120bf8"
EXPECTED_CLI_SHA256="13c79a6b13df15c770773137fcc8c538c9de8c624ffeb0e50e1248cdb572d0c5"

RUNTIME_PACKAGES=(
    libevent-2.1-7t64
    libevent-pthreads-2.1-7t64
    libminiupnpc21
    libnatpmp1t64
    libzmq5
    libboost-filesystem1.90.0
    libgmpxx4ldbl
    libdb5.3++t64
)

KNOWN_PAYLOAD_LIBRARIES=(
    libevent_pthreads-2.1.so.7
    libminiupnpc.so.21
    libnatpmp.so.1
    libzmq.so.5
    libevent-2.1.so.7
    libboost_filesystem.so.1.90.0
    libgmpxx.so.4
    libdb_cxx-5.3.so
)

NVUND="/usr/local/bin/nvund"
NVU_CLI="/usr/local/bin/nvu-cli"
NVUN_CONFIG="/etc/nvu/nvun.conf"
RPC_CREDENTIALS="/etc/nvu/credentials/rpc-client.env"
NVUN_DATADIR="/var/lib/nvu/node"
NVUN_UNIT_FILE="/etc/systemd/system/nvun.service"
NVUN_UNIT="nvun.service"

DASHBOARD_VERSION="1.3.0"
DASHBOARD_ROOT="/usr/local/lib/nvu/dashboard"
DASHBOARD_RELEASES="$DASHBOARD_ROOT/releases"
DASHBOARD_RELEASE="$DASHBOARD_RELEASES/$DASHBOARD_VERSION"
DASHBOARD_CURRENT="$DASHBOARD_ROOT/current"
DASHBOARD_VENV="$DASHBOARD_ROOT/venv"
DASHBOARD_GUNICORN="$DASHBOARD_VENV/bin/gunicorn"

DASHBOARD_UNIT="nvu-dashboard.service"
DASHBOARD_UNIT_FILE="/etc/systemd/system/nvu-dashboard.service"

DASHBOARD_RUNTIME="/run/nvu-dashboard"
DASHBOARD_SOCKET="$DASHBOARD_RUNTIME/nvu-dashboard.sock"

APACHE_UNIT="apache2.service"
APACHE_HTTP_SITE="/etc/apache2/sites-available/nvu-dashboard.conf"
APACHE_HTTP_LINK="/etc/apache2/sites-enabled/nvu-dashboard.conf"
APACHE_HTTPS_SITE="/etc/apache2/sites-available/nvu-dashboard-le-ssl.conf"
APACHE_HTTPS_LINK="/etc/apache2/sites-enabled/nvu-dashboard-le-ssl.conf"
APACHE_DEFAULT_LINK="/etc/apache2/sites-enabled/000-default.conf"
APACHE_SERVERNAME_CONF="/etc/apache2/conf-available/nvu-servername.conf"
APACHE_SERVERNAME_LINK="/etc/apache2/conf-enabled/nvu-servername.conf"

CERTBOT_LIVE_ROOT="/etc/letsencrypt/live"

PASS_COUNT=0
NOTE_COUNT=0
REVIEW_COUNT=0
BLOCK_COUNT=0

NODE_STATE="UNKNOWN"
WALLET_STATE="UNKNOWN"
RPC_STATE="UNKNOWN"
LISTENER_STATE="UNKNOWN"
DASHBOARD_STATE="UNKNOWN"
DASHBOARD_RUNTIME_STATE="UNKNOWN"
WEB_STATE="UNKNOWN"
DNS_STATE="NOT_EVALUATED"
CERTIFICATE_STATE="NOT_EVALUATED"
REDIRECT_STATE="NOT_EVALUATED"
FINAL_RESULT="UNKNOWN"

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

note() {
    NOTE_COUNT=$((NOTE_COUNT + 1))
    printf 'NOTE: %s\n' "$1"
}

review() {
    REVIEW_COUNT=$((REVIEW_COUNT + 1))
    printf 'REVIEW: %s\n' "$1"
}

block() {
    BLOCK_COUNT=$((BLOCK_COUNT + 1))
    printf 'BLOCKED: %s\n' "$1"
}

priv_test() {
    local operator="$1"
    local path="$2"

    if [[ "$(id -u)" -eq 0 ]]; then
        test "$operator" "$path"
    else
        sudo -n test "$operator" "$path" 2>/dev/null
    fi
}

read_privileged_file() {
    local path="$1"

    if [[ -r "$path" ]]; then
        cat "$path"
    else
        sudo -n cat "$path" 2>/dev/null
    fi
}

run_as_nvu() {
    if [[ "$(id -u)" -eq 0 ]]; then
        sudo -u nvu "$@"
    else
        sudo -n -u nvu "$@"
    fi
}

usage() {
    cat <<'USAGE'
Nouveau-Vision Unit Unified Preflight

Usage:
  preflight-unified.sh
  preflight-unified.sh --fqdn <hostname>

Options:
  --fqdn <hostname>
      Evaluate DNS, Apache, certificate, redirect, and HTTPS readiness
      for the specified public hostname.

This command is read-only.
USAGE
}

parse_arguments() {
    REQUESTED_FQDN=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --fqdn)
                if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
                    echo "FAIL: --fqdn requires a hostname." >&2
                    return 2
                fi

                REQUESTED_FQDN="$2"
                shift 2
                ;;

            -h|--help)
                usage
                return 10
                ;;

            *)
                printf 'FAIL: unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    if [[ -n "$REQUESTED_FQDN" ]]; then
        if [[ ! "$REQUESTED_FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
           [[ "$REQUESTED_FQDN" != *.* ]]
        then
            printf 'FAIL: invalid FQDN: %s\n' \
                "$REQUESTED_FQDN" >&2
            return 2
        fi
    fi
}

check_platform() {
    local architecture=""
    local init_process=""
    local available_kb=""

    echo
    echo "=== PLATFORM ==="

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release

        printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"
        printf 'OS ID: %s\n' "${ID:-unknown}"
        printf 'Version: %s\n' "${VERSION_ID:-unknown}"

        if [[ "${ID:-}" == "ubuntu" &&
              "${VERSION_ID:-}" == "26.04" ]]
        then
            pass "supported Ubuntu release detected"
        else
            block "supported platform is Ubuntu 26.04"
        fi
    else
        block "/etc/os-release is unavailable"
    fi

    architecture="$(
        dpkg --print-architecture 2>/dev/null ||
        uname -m
    )"

    printf 'Architecture: %s\n' "$architecture"

    case "$architecture" in
        amd64|x86_64)
            pass "supported architecture detected"
            ;;
        *)
            block "qualified NVUN payload does not support: $architecture"
            ;;
    esac

    init_process="$(
        ps -p 1 -o comm= 2>/dev/null |
        awk '{print $1}'
    )"

    if [[ "$init_process" == "systemd" ]]; then
        pass "systemd is PID 1"
    else
        block "systemd is not PID 1"
    fi

    if [[ -d /run ]]; then
        pass "/run runtime filesystem is available"
    else
        block "/run runtime filesystem is unavailable"
    fi

    available_kb="$(
        df -Pk /usr/local 2>/dev/null |
        awk 'NR == 2 {print $4}'
    )"

    printf 'Available /usr/local space: %s KiB\n' \
        "${available_kb:-unknown}"

    if [[ "$available_kb" =~ ^[0-9]+$ &&
          "$available_kb" -ge 1048576 ]]
    then
        pass "at least 1 GiB available under /usr/local"
    elif [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        review "less than 1 GiB available under /usr/local"
    else
        review "available /usr/local space could not be determined"
    fi
}

check_commands() {
    local command

    echo
    echo "=== REQUIRED COMMANDS ==="

    for command in \
        bash \
        python3 \
        apt-get \
        dpkg-query \
        install \
        sha256sum \
        ldd \
        curl \
        jq \
        tar \
        systemctl \
        systemd-analyze \
        ss \
        getent \
        awk \
        grep \
        find \
        stat \
        sed \
        ps \
        df \
        useradd \
        groupadd
    do
        if command -v "$command" >/dev/null 2>&1; then
            pass "command available: $command"
        else
            block "required command unavailable: $command"
        fi
    done
}

check_installer_integrity() {
    local module
    local actual_nvund=""
    local actual_cli=""

    echo
    echo "=== INSTALLER INTEGRITY ==="

    if [[ -r "$VERSION_FILE" ]]; then
        pass "VERSION file exists"
    else
        block "VERSION file unavailable: $VERSION_FILE"
    fi

    for module in \
        "$NODE_INSTALLER" \
        "$DASHBOARD_INSTALLER" \
        "$WEB_CONFIGURATOR" \
        "$DASHBOARD_PREFLIGHT" \
        "$DASHBOARD_QUALIFY"
    do
        if [[ -x "$module" ]]; then
            pass "installer module executable: ${module#"$INSTALLER_ROOT/"}"
        else
            block "installer module unavailable: $module"
        fi
    done

    for module in \
        "$NODE_INSTALLER" \
        "$DASHBOARD_INSTALLER" \
        "$WEB_CONFIGURATOR" \
        "$DASHBOARD_PREFLIGHT" \
        "$DASHBOARD_QUALIFY"
    do
        if [[ -r "$module" ]] && bash -n "$module"; then
            pass "installer syntax valid: ${module#"$INSTALLER_ROOT/"}"
        elif [[ -r "$module" ]]; then
            block "installer syntax invalid: $module"
        fi
    done

    for module in \
        "$PAYLOAD_NVUND" \
        "$PAYLOAD_CLI" \
        "$PAYLOAD_VERSION" \
        "$PAYLOAD_SUMS"
    do
        if [[ -f "$module" ]]; then
            pass "NVUN payload file exists: ${module#"$INSTALLER_ROOT/"}"
        else
            block "NVUN payload file missing: $module"
        fi
    done

    if [[ -x "$PAYLOAD_NVUND" ]]; then
        actual_nvund="$(
            sha256sum "$PAYLOAD_NVUND" |
            awk '{print $1}'
        )"

        if [[ "$actual_nvund" == "$EXPECTED_NVUND_SHA256" ]]; then
            pass "nvund payload matches qualified binary"
        else
            block "nvund payload checksum mismatch"
        fi
    fi

    if [[ -x "$PAYLOAD_CLI" ]]; then
        actual_cli="$(
            sha256sum "$PAYLOAD_CLI" |
            awk '{print $1}'
        )"

        if [[ "$actual_cli" == "$EXPECTED_CLI_SHA256" ]]; then
            pass "nvu-cli payload matches qualified binary"
        else
            block "nvu-cli payload checksum mismatch"
        fi
    fi

    if [[ -r "$PAYLOAD_SUMS" ]]; then
        if (
            cd "$PAYLOAD_ROOT" &&
            sha256sum -c SHA256SUMS >/dev/null
        ); then
            pass "NVUN payload manifest verifies"
        else
            block "NVUN payload manifest verification failed"
        fi
    fi
}

library_is_known() {
    local candidate="$1"
    local known

    for known in "${KNOWN_PAYLOAD_LIBRARIES[@]}"; do
        if [[ "$candidate" == "$known" ]]; then
            return 0
        fi
    done

    return 1
}

check_runtime_dependencies() {
    local package
    local binary
    local library
    local missing_packages=0
    local unresolved_output=""

    echo
    echo "=== NVUN RUNTIME DEPENDENCIES ==="

    for package in "${RUNTIME_PACKAGES[@]}"; do
        if dpkg-query -W \
            -f='${db:Status-Abbrev}\n' \
            "$package" 2>/dev/null |
            grep -Fxq 'ii '
        then
            pass "runtime package installed: $package"
        else
            note "runtime package not installed: $package"
            missing_packages=$((missing_packages + 1))
        fi
    done

    printf 'Missing qualified runtime packages: %s\n' \
        "$missing_packages"

    for binary in "$PAYLOAD_NVUND" "$PAYLOAD_CLI"; do
        [[ -x "$binary" ]] || continue

        unresolved_output="$(
            ldd "$binary" 2>/dev/null |
            awk '/not found/ {print $1}'
        )"

        if [[ -z "$unresolved_output" ]]; then
            pass "all payload libraries resolve: ${binary##*/}"
            continue
        fi

        while IFS= read -r library; do
            [[ -n "$library" ]] || continue

            if library_is_known "$library"; then
                note "qualified runtime library unresolved: $library"
            else
                block "unexpected payload library unresolved: $library"
            fi
        done <<< "$unresolved_output"
    done

    if [[ "$missing_packages" -gt 0 ]]; then
        note "NVUN installer can install the qualified runtime packages"
    fi
}

check_service_identity() {
    local record=""
    local home=""
    local shell=""

    echo
    echo "=== SERVICE IDENTITY ==="

    if getent passwd nvu >/dev/null 2>&1; then
        record="$(getent passwd nvu)"
        home="$(printf '%s\n' "$record" | cut -d: -f6)"
        shell="$(printf '%s\n' "$record" | cut -d: -f7)"

        printf 'nvu home: %s\n' "$home"
        printf 'nvu shell: %s\n' "$shell"

        if [[ "$home" == "/var/lib/nvu" ]]; then
            pass "nvu home matches supported contract"
        else
            block "nvu home conflicts with /var/lib/nvu"
        fi

        if [[ "$shell" == "/usr/sbin/nologin" ]]; then
            pass "nvu shell matches supported contract"
        else
            block "nvu shell conflicts with /usr/sbin/nologin"
        fi
    else
        pass "nvu user absent and available for fresh installation"
    fi

    if getent group nvu >/dev/null 2>&1; then
        pass "nvu group exists"
    else
        pass "nvu group absent and available for fresh installation"
    fi
}

validate_credential_contract() {
    local fields=""

    fields="$(
        read_privileged_file "$RPC_CREDENTIALS" |
        awk -F= '
            /^[A-Za-z_][A-Za-z0-9_]*=/ {
                print $1
            }
        ' |
        sort
    )" || return 1

    [[ "$fields" == "$(printf '%s\n' \
        RPC_CONFIG \
        RPC_DATADIR \
        RPC_HOST \
        RPC_PASSWORD \
        RPC_PORT \
        RPC_USER |
        sort
    )" ]]
}

check_nvUN_listeners() {
    local listeners=""

    echo
    echo "=== NVUN LISTENERS ==="

    listeners="$(
        sudo -n ss -lntp 2>/dev/null ||
        ss -lnt 2>/dev/null ||
        true
    )"

    if [[ "$NODE_STATE" == "NOT_INSTALLED" ]]; then
        if printf '%s\n' "$listeners" |
            grep -Eq ':(9332|9333|9334)[[:space:]]'
        then
            block "NVUN target port already occupied on clean target"
            printf '%s\n' "$listeners" |
                grep -E ':(9332|9333|9334)[[:space:]]' || true
            LISTENER_STATE="CONFLICT"
        else
            pass "NVUN ports 9332/9333/9334 are available"
            LISTENER_STATE="AVAILABLE"
        fi

        return
    fi

    if printf '%s\n' "$listeners" |
        grep -Eq '127\.0\.0\.1:9332[[:space:]]'
    then
        pass "NVUN RPC listens on 127.0.0.1:9332"
    else
        review "NVUN RPC listener not detected on 127.0.0.1:9332"
    fi

    if printf '%s\n' "$listeners" |
        grep -Eq '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):9333[[:space:]]'
    then
        pass "NVUN P2P listener detected on port 9333"
    else
        review "NVUN P2P listener not detected on port 9333"
    fi

    if printf '%s\n' "$listeners" |
        grep -Eq '127\.0\.0\.1:9334[[:space:]]'
    then
        note "NVUN auxiliary listener detected on 127.0.0.1:9334"
    else
        note "no NVUN auxiliary listener detected on port 9334"
    fi

    LISTENER_STATE="INSPECTED"
}

check_nvun_installation() {
    local artifact
    local artifact_count=0
    local blockchain_json=""
    local wallet_json=""
    local owner_mode=""
    local installed_nvund_sha=""
    local installed_cli_sha=""

    echo
    echo "=== NVUN INSTALLATION DISCOVERY ==="

    for artifact in \
        "$NVUND" \
        "$NVU_CLI" \
        "$NVUN_CONFIG" \
        "$RPC_CREDENTIALS" \
        "$NVUN_DATADIR" \
        "$NVUN_UNIT_FILE"
    do
        if priv_test -e "$artifact" ||
           priv_test -L "$artifact"
        then
            artifact_count=$((artifact_count + 1))
            printf 'FOUND: %s\n' "$artifact"
        else
            printf 'ABSENT: %s\n' "$artifact"
        fi
    done

    if [[ "$artifact_count" -eq 0 ]]; then
        NODE_STATE="NOT_INSTALLED"
        WALLET_STATE="NOT_INSTALLED"
        RPC_STATE="NOT_INSTALLED"
        pass "NVUN is not currently installed"
        return
    fi

    if [[ "$artifact_count" -ne 6 ]]; then
        NODE_STATE="PARTIAL"
        review "partial NVUN installation detected"
        return
    fi

    NODE_STATE="INSTALLED"

    installed_nvund_sha="$(
        sudo -n sha256sum "$NVUND" 2>/dev/null |
        awk '{print $1}'
    )"

    installed_cli_sha="$(
        sudo -n sha256sum "$NVU_CLI" 2>/dev/null |
        awk '{print $1}'
    )"

    if [[ "$installed_nvund_sha" == "$EXPECTED_NVUND_SHA256" ]]; then
        pass "installed nvund matches qualified binary"
    else
        review "installed nvund differs from qualified payload"
    fi

    if [[ "$installed_cli_sha" == "$EXPECTED_CLI_SHA256" ]]; then
        pass "installed nvu-cli matches qualified binary"
    else
        review "installed nvu-cli differs from qualified payload"
    fi

    if systemctl is-active --quiet "$NVUN_UNIT"; then
        pass "NVUN service active"
    else
        review "NVUN service is not active"
    fi

    if systemctl is-enabled --quiet "$NVUN_UNIT"; then
        pass "NVUN service enabled"
    else
        review "NVUN service is not enabled"
    fi

    owner_mode="$(
        sudo -n stat \
            -c '%U:%G %a' \
            "$NVUN_CONFIG" 2>/dev/null || true
    )"

    if [[ "$owner_mode" == "root:nvu 640" ]]; then
        pass "NVUN configuration permissions = root:nvu 640"
    else
        review "NVUN configuration permissions differ: ${owner_mode:-unknown}"
    fi

    owner_mode="$(
        sudo -n stat \
            -c '%U:%G %a' \
            "$RPC_CREDENTIALS" 2>/dev/null || true
    )"

    if [[ "$owner_mode" == "root:nvu 640" ]]; then
        pass "RPC credential permissions = root:nvu 640"
    else
        review "RPC credential permissions differ: ${owner_mode:-unknown}"
    fi

    if validate_credential_contract; then
        pass "Dashboard RPC credential contract contains six required fields"
        RPC_STATE="AVAILABLE"
    else
        review "Dashboard RPC credential contract is incompatible"
        RPC_STATE="INCOMPATIBLE"
    fi

    blockchain_json="$(
        run_as_nvu "$NVU_CLI" \
            -datadir="$NVUN_DATADIR" \
            -conf="$NVUN_CONFIG" \
            getblockchaininfo 2>/dev/null || true
    )"

    if [[ -n "$blockchain_json" ]] &&
       printf '%s\n' "$blockchain_json" |
       jq -e \
          '.chain == "main"
           and (.blocks | type == "number")
           and (.headers | type == "number")' \
          >/dev/null 2>&1
    then
        pass "NVUN main-chain RPC operational"

        if printf '%s\n' "$blockchain_json" |
           jq -e \
              '.blocks == .headers
               and .verificationprogress == 1
               and .initialblockdownload == false' \
              >/dev/null 2>&1
        then
            pass "NVUN synchronized"
        else
            note "NVUN installed but synchronization is incomplete"
        fi
    else
        review "NVUN blockchain RPC unavailable or invalid"
    fi

    wallet_json="$(
        run_as_nvu "$NVU_CLI" \
            -datadir="$NVUN_DATADIR" \
            -conf="$NVUN_CONFIG" \
            getwalletinfo 2>/dev/null || true
    )"

    if [[ -n "$wallet_json" ]] &&
       printf '%s\n' "$wallet_json" |
       jq -e \
          '.walletname == ""
           and .private_keys_enabled == true' \
          >/dev/null 2>&1
    then
        pass "unnamed default wallet available"
        pass "wallet private keys enabled"
        WALLET_STATE="AVAILABLE"
    else
        review "supported wallet contract not confirmed"
        WALLET_STATE="REVIEW"
    fi
}

check_dashboard_installation() {
    local artifact
    local artifact_count=0
    local current_target=""
    local current_resolved=""
    local runtime_meta=""
    local socket_meta=""
    local version_json=""
    local status_json=""
    local exec_start=""

    echo
    echo "=== DASHBOARD INSTALLATION DISCOVERY ==="

    for artifact in \
        "$DASHBOARD_ROOT" \
        "$DASHBOARD_RELEASES" \
        "$DASHBOARD_RELEASE" \
        "$DASHBOARD_CURRENT" \
        "$DASHBOARD_VENV" \
        "$DASHBOARD_UNIT_FILE"
    do
        if priv_test -e "$artifact" ||
           priv_test -L "$artifact"
        then
            artifact_count=$((artifact_count + 1))
            printf 'FOUND: %s\n' "$artifact"
        else
            printf 'ABSENT: %s\n' "$artifact"
        fi
    done

    if [[ "$artifact_count" -eq 0 ]]; then
        DASHBOARD_STATE="NOT_INSTALLED"
        DASHBOARD_RUNTIME_STATE="AVAILABLE"
        pass "Dashboard is not currently installed"

        if priv_test -e "$DASHBOARD_RUNTIME" ||
           priv_test -e "$DASHBOARD_SOCKET"
        then
            review "Dashboard runtime namespace exists without installation"
            DASHBOARD_RUNTIME_STATE="REVIEW"
        else
            pass "Dashboard runtime namespace available"
        fi

        return
    fi

    if [[ "$artifact_count" -ne 6 ]]; then
        DASHBOARD_STATE="PARTIAL"
        DASHBOARD_RUNTIME_STATE="REVIEW"
        review "partial Dashboard installation detected"
        return
    fi

    DASHBOARD_STATE="INSTALLED"

    current_target="$(
        sudo -n readlink "$DASHBOARD_CURRENT" 2>/dev/null || true
    )"

    current_resolved="$(
        sudo -n readlink -f "$DASHBOARD_CURRENT" 2>/dev/null || true
    )"

    if [[ "$current_target" == "releases/$DASHBOARD_VERSION" ]]; then
        pass "Dashboard current pointer targets releases/$DASHBOARD_VERSION"
    else
        review "Dashboard current pointer differs: ${current_target:-unknown}"
    fi

    if [[ "$current_resolved" == "$DASHBOARD_RELEASE" ]] &&
       priv_test -d "$current_resolved"
    then
        pass "Dashboard current resolves to installed release $DASHBOARD_VERSION"
    else
        review "Dashboard current does not resolve to qualified release"
    fi

    for artifact in \
        "$DASHBOARD_RELEASE/server.py" \
        "$DASHBOARD_RELEASE/nvu_rpc.py" \
        "$DASHBOARD_RELEASE/requirements.txt" \
        "$DASHBOARD_RELEASE/static/app.js" \
        "$DASHBOARD_RELEASE/static/index.html"
    do
        if priv_test -f "$artifact"; then
            pass "Dashboard release file: ${artifact#"$DASHBOARD_RELEASE/"}"
        else
            review "Dashboard release file missing: $artifact"
        fi
    done

    if priv_test -x "$DASHBOARD_GUNICORN"; then
        pass "Dashboard production Gunicorn exists"
    else
        review "Dashboard production Gunicorn unavailable"
    fi

    if systemctl is-active --quiet "$DASHBOARD_UNIT"; then
        pass "Dashboard service active"
    else
        review "Dashboard service is not active"
    fi

    if systemctl is-enabled --quiet "$DASHBOARD_UNIT"; then
        pass "Dashboard service enabled"
    else
        review "Dashboard service is not enabled"
    fi

    if [[ "$(
        systemctl show "$DASHBOARD_UNIT" \
            --property=User \
            --value 2>/dev/null
    )" == "nvu" ]]
    then
        pass "Dashboard service user = nvu"
    else
        review "Dashboard service user differs from nvu"
    fi

    if [[ "$(
        systemctl show "$DASHBOARD_UNIT" \
            --property=Group \
            --value 2>/dev/null
    )" == "www-data" ]]
    then
        pass "Dashboard service group = www-data"
    else
        review "Dashboard service group differs from www-data"
    fi

    exec_start="$(
        systemctl show "$DASHBOARD_UNIT" \
            --property=ExecStart \
            --value 2>/dev/null || true
    )"

    if [[ "$exec_start" == *"unix:$DASHBOARD_SOCKET"* ]]; then
        pass "Dashboard service uses canonical Unix socket"
    else
        review "Dashboard service does not use canonical Unix socket"
    fi

    runtime_meta="$(
        sudo -n stat \
            -c '%U:%G %a %F' \
            "$DASHBOARD_RUNTIME" 2>/dev/null || true
    )"

    if [[ "$runtime_meta" == "nvu:www-data 750 directory" ]]; then
        pass "Dashboard runtime directory = nvu:www-data 750"
    else
        review "Dashboard runtime directory contract differs: ${runtime_meta:-unknown}"
    fi

    socket_meta="$(
        sudo -n stat \
            -c '%U:%G %a %F' \
            "$DASHBOARD_SOCKET" 2>/dev/null || true
    )"

    if [[ "$socket_meta" == "nvu:www-data 770 socket" ]]; then
        pass "Dashboard socket = nvu:www-data 770"
        DASHBOARD_RUNTIME_STATE="NVU_OWNED"
    else
        review "Dashboard socket contract differs: ${socket_meta:-unknown}"
        DASHBOARD_RUNTIME_STATE="REVIEW"
    fi

    version_json="$(
        sudo -n curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --unix-socket "$DASHBOARD_SOCKET" \
            http://localhost/api/version \
            2>/dev/null || true
    )"

    if [[ -n "$version_json" ]] &&
       printf '%s\n' "$version_json" |
       jq -e \
          '.dashboardVersion == "1.3.0"
           and .ok == true
           and .ticker == "NVU"' \
          >/dev/null 2>&1
    then
        pass "Dashboard version API reports 1.3.0"
    else
        review "Dashboard version API qualification failed"
    fi

    status_json="$(
        sudo -n curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --unix-socket "$DASHBOARD_SOCKET" \
            http://localhost/api/status \
            2>/dev/null || true
    )"

    if [[ -n "$status_json" ]] &&
       printf '%s\n' "$status_json" |
       jq -e \
          '.ok == true
           and .nvun.online == true
           and .nvun.chain == "main"
           and .nvun.initialBlockDownload == false' \
          >/dev/null 2>&1
    then
        pass "Dashboard reports synchronized mainnet NVUN"
    else
        review "Dashboard-to-NVUN status qualification failed"
    fi

    if sudo -n ss -lntp 2>/dev/null |
       grep -Eq \
          ':8080[[:space:]].*(gunicorn|python|nvu-dashboard)'
    then
        review "Dashboard unexpectedly exposes TCP backend port 8080"
    else
        pass "Dashboard has no TCP backend"
    fi
}

check_web_installation() {
    local package
    local installed_packages=0
    local web_artifacts=0
    local fqdn=""
    local dns_ipv4=""
    local http_site=""
    local https_site=""
    local redirect=""
    local version_json=""
    local status_json=""
    local apache_syntax=""
    local certificate_dir=""

    echo
    echo "=== WEB / HTTPS DISCOVERY ==="

    if [[ -n "$REQUESTED_FQDN" ]]; then
        fqdn="$REQUESTED_FQDN"
        pass "requested FQDN syntax accepted: $fqdn"
    else
        fqdn="$(
            hostname -f 2>/dev/null ||
            hostname
        )"

        note "no --fqdn supplied; using system FQDN for installed-web discovery"
    fi

    printf 'Evaluated FQDN: %s\n' "$fqdn"

    for package in \
        apache2 \
        certbot \
        python3-certbot-apache
    do
        if dpkg-query -W \
            -f='${db:Status-Abbrev}\n' \
            "$package" 2>/dev/null |
            grep -Fxq 'ii '
        then
            pass "web package installed: $package"
            installed_packages=$((installed_packages + 1))
        else
            note "web package not installed: $package"
        fi
    done

    for artifact in \
        "$APACHE_HTTP_SITE" \
        "$APACHE_HTTP_LINK" \
        "$APACHE_HTTPS_SITE" \
        "$APACHE_HTTPS_LINK"
    do
        if priv_test -e "$artifact" ||
           priv_test -L "$artifact"
        then
            web_artifacts=$((web_artifacts + 1))
            printf 'FOUND: %s\n' "$artifact"
        else
            printf 'ABSENT: %s\n' "$artifact"
        fi
    done

    if [[ "$installed_packages" -eq 0 &&
          "$web_artifacts" -eq 0 ]]
    then
        WEB_STATE="NOT_CONFIGURED"
        CERTIFICATE_STATE="NOT_PRESENT"
        REDIRECT_STATE="NOT_CONFIGURED"

        pass "public web stack is not currently configured"

        if [[ -n "$REQUESTED_FQDN" ]]; then
            dns_ipv4="$(
                getent ahostsv4 "$fqdn" 2>/dev/null |
                awk '{print $1}' |
                sort -u
            )"

            if [[ -n "$dns_ipv4" ]]; then
                pass "requested FQDN resolves through IPv4"
                printf 'DNS IPv4:\n%s\n' "$dns_ipv4" |
                    sed '2,$s/^/  /'
                DNS_STATE="RESOLVES"
            else
                block "requested FQDN does not resolve through IPv4: $fqdn"
                DNS_STATE="BLOCKED"
            fi
        else
            DNS_STATE="NOT_EVALUATED"
            note "FQDN and DNS readiness were not evaluated"
        fi

        return
    fi

    if ! dpkg-query -W         -f='${db:Status-Abbrev}\n'         apache2 2>/dev/null |
        grep -Fxq 'ii '
    then
        WEB_STATE="PARTIAL"
        review "Apache package is not installed"
        return
    fi

    if command -v certbot >/dev/null 2>&1; then
        pass "Certbot command available"
    else
        WEB_STATE="PARTIAL"
        review "Certbot command is unavailable"
        return
    fi

    if [[ "$web_artifacts" -ne 4 ]]; then
        WEB_STATE="PARTIAL"
        review "partial NVU Apache virtual-host configuration detected"
        return
    fi

    if systemctl is-active --quiet "$APACHE_UNIT"; then
        pass "Apache service active"
    else
        review "Apache service is not active"
    fi

    if systemctl is-enabled --quiet "$APACHE_UNIT"; then
        pass "Apache service enabled"
    else
        review "Apache service is not enabled"
    fi

    apache_syntax="$(
        sudo -n apache2ctl -t 2>&1 || true
    )"

    if printf '%s\n' "$apache_syntax" |
       grep -Fq 'Syntax OK'
    then
        pass "Apache configuration syntax valid"
    else
        review "Apache configuration syntax validation failed"
        printf '%s\n' "$apache_syntax"
    fi

    http_site="$(
        read_privileged_file "$APACHE_HTTP_SITE" 2>/dev/null || true
    )"

    https_site="$(
        read_privileged_file "$APACHE_HTTPS_SITE" 2>/dev/null || true
    )"

    if printf '%s\n' "$http_site" |
       grep -Fq "ServerName $fqdn"
    then
        pass "Apache HTTP site ServerName matches $fqdn"
    else
        review "Apache HTTP site ServerName does not match $fqdn"
    fi

    if printf '%s\n' "$https_site" |
       grep -Fq "ServerName $fqdn"
    then
        pass "Apache HTTPS site ServerName matches $fqdn"
    else
        review "Apache HTTPS site ServerName does not match $fqdn"
    fi

    if printf '%s\n' "$http_site" |
       grep -Fq "unix:$DASHBOARD_SOCKET|" &&
       printf '%s\n' "$https_site" |
       grep -Fq "unix:$DASHBOARD_SOCKET|"
    then
        pass "Apache HTTP and HTTPS sites proxy to canonical Unix socket"
    else
        review "Apache Unix-socket proxy contract is incomplete"
    fi

    if printf '%s\n%s\n' "$http_site" "$https_site" |
       grep -Eq \
          '127\.0\.0\.1:8080|0\.0\.0\.0:8080|localhost:8080'
    then
        review "Apache configuration references prohibited Dashboard TCP backend"
    else
        pass "Apache contains no Dashboard TCP backend"
    fi

    if priv_test -L "$APACHE_DEFAULT_LINK"; then
        review "Apache default site remains enabled"
    else
        pass "Apache default site disabled"
    fi

    if priv_test -f "$APACHE_SERVERNAME_CONF"; then
        if read_privileged_file "$APACHE_SERVERNAME_CONF" |
           grep -Fxq "ServerName $fqdn"
        then
            pass "Apache global ServerName matches $fqdn"
        else
            review "Apache global ServerName differs from $fqdn"
        fi

        if priv_test -L "$APACHE_SERVERNAME_LINK"; then
            pass "Apache global ServerName configuration enabled"
        else
            review "Apache global ServerName configuration is not enabled"
        fi
    else
        note "NVU Apache global ServerName configuration not present"
    fi

    if command -v certbot >/dev/null 2>&1 &&
       certbot plugins 2>/dev/null |
       grep -Fq 'apache'
    then
        pass "Certbot Apache plugin available"
    else
        review "Certbot Apache plugin unavailable"
    fi

    certificate_dir="$CERTBOT_LIVE_ROOT/$fqdn"

    if priv_test -f "$certificate_dir/fullchain.pem" &&
       priv_test -f "$certificate_dir/privkey.pem"
    then
        pass "certificate files present for $fqdn"
        CERTIFICATE_STATE="PRESENT"
    else
        review "certificate files unavailable for $fqdn"
        CERTIFICATE_STATE="MISSING"
    fi

    dns_ipv4="$(
        getent ahostsv4 "$fqdn" 2>/dev/null |
        awk '{print $1}' |
        sort -u
    )"

    if [[ -n "$dns_ipv4" ]]; then
        pass "FQDN resolves through IPv4"
        DNS_STATE="RESOLVES"
    else
        review "FQDN does not resolve through IPv4: $fqdn"
        DNS_STATE="REVIEW"
    fi

    redirect="$(
        curl \
            --silent \
            --show-error \
            --output /dev/null \
            --write-out '%{http_code} %{redirect_url}' \
            --max-time 15 \
            --resolve "${fqdn}:80:127.0.0.1" \
            "http://${fqdn}/api/version" \
            2>/dev/null || true
    )"

    if [[ "$redirect" == "301 https://${fqdn}/api/version" ||
          "$redirect" == "308 https://${fqdn}/api/version" ]]
    then
        pass "HTTP redirects to HTTPS and preserves API path"
        REDIRECT_STATE="QUALIFIED"
    else
        review "HTTP-to-HTTPS redirect qualification failed: ${redirect:-unavailable}"
        REDIRECT_STATE="REVIEW"
    fi

    version_json="$(
        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 15 \
            --resolve "${fqdn}:443:127.0.0.1" \
            "https://${fqdn}/api/version" \
            2>/dev/null || true
    )"

    if [[ -n "$version_json" ]] &&
       printf '%s\n' "$version_json" |
       jq -e \
          '.dashboardVersion == "1.3.0"
           and .ok == true
           and .ticker == "NVU"' \
          >/dev/null 2>&1
    then
        pass "HTTPS Dashboard version API qualified"
    else
        review "HTTPS Dashboard version qualification failed"
    fi

    status_json="$(
        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 15 \
            --resolve "${fqdn}:443:127.0.0.1" \
            "https://${fqdn}/api/status" \
            2>/dev/null || true
    )"

    if [[ -n "$status_json" ]] &&
       printf '%s\n' "$status_json" |
       jq -e \
          '.ok == true
           and .nvun.online == true
           and .nvun.chain == "main"
           and .nvun.initialBlockDownload == false' \
          >/dev/null 2>&1
    then
        pass "HTTPS Dashboard reports synchronized mainnet NVUN"
    else
        review "HTTPS Dashboard status qualification failed"
    fi

    if sudo -n ss -lntp 2>/dev/null |
       grep -Eq ':(80|443)[[:space:]].*apache2'
    then
        pass "Apache listeners detected on public web ports"
    else
        review "Apache listeners not detected on ports 80/443"
    fi

    WEB_STATE="HTTPS_CONFIGURED"
}

determine_result() {
    if [[ "$BLOCK_COUNT" -gt 0 ]]; then
        FINAL_RESULT="BLOCKED"
        return
    fi

    if [[ "$REVIEW_COUNT" -gt 0 ]]; then
        FINAL_RESULT="PARTIAL"
        return
    fi

    if [[ "$NODE_STATE" == "NOT_INSTALLED" &&
          "$DASHBOARD_STATE" == "NOT_INSTALLED" ]]
    then
        FINAL_RESULT="READY"
        return
    fi

    if [[ "$NODE_STATE" == "INSTALLED" &&
          "$DASHBOARD_STATE" == "INSTALLED" &&
          "$WEB_STATE" == "HTTPS_CONFIGURED" ]]
    then
        FINAL_RESULT="INSTALLED"
        return
    fi

    FINAL_RESULT="PARTIAL"
}

print_summary() {
    echo
    echo "============================================================"
    echo "NOUVEAU-VISION UNIT UNIFIED PREFLIGHT SUMMARY"
    echo "============================================================"

    echo
    echo "Preflight version:"
    echo "  $PREFLIGHT_VERSION"

    echo
    echo "Scope:"
    echo "  $PREFLIGHT_SCOPE"

    echo
    echo "Host:"
    printf '  %s\n' "$(hostname -f 2>/dev/null || hostname)"

    echo
    echo "NVUN:"
    echo "  $NODE_STATE"

    echo
    echo "RPC credential contract:"
    echo "  $RPC_STATE"

    echo
    echo "Wallet:"
    echo "  $WALLET_STATE"

    echo
    echo "NVUN listeners:"
    echo "  $LISTENER_STATE"

    echo
    echo "Dashboard:"
    echo "  $DASHBOARD_STATE"

    echo
    echo "Dashboard runtime:"
    echo "  $DASHBOARD_RUNTIME_STATE"

    echo
    echo "Web:"
    echo "  $WEB_STATE"

    echo
    echo "DNS:"
    echo "  $DNS_STATE"

    echo
    echo "Certificate:"
    echo "  $CERTIFICATE_STATE"

    echo
    echo "HTTP redirect:"
    echo "  $REDIRECT_STATE"

    echo
    echo "Counts:"
    echo "  PASS:    $PASS_COUNT"
    echo "  NOTE:    $NOTE_COUNT"
    echo "  REVIEW:  $REVIEW_COUNT"
    echo "  BLOCKED: $BLOCK_COUNT"

    echo
    echo "Result:"
    echo "  $FINAL_RESULT"

    echo
    echo "No changes were made."
    echo "============================================================"
}

main() {
    local parse_rc=0

    parse_arguments "$@"
    parse_rc=$?

    if [[ "$parse_rc" -eq 10 ]]; then
        return 0
    fi

    if [[ "$parse_rc" -ne 0 ]]; then
        return "$parse_rc"
    fi

    echo "============================================================"
    echo "NOUVEAU-VISION UNIT UNIFIED PREFLIGHT"
    echo "B6.2I-2"
    echo "READ ONLY"
    echo "============================================================"

    check_platform
    check_commands
    check_installer_integrity
    check_runtime_dependencies
    check_service_identity
    check_nvun_installation
    check_nvUN_listeners
    check_dashboard_installation
    check_web_installation

    determine_result
    print_summary

    case "$FINAL_RESULT" in
        READY|INSTALLED)
            return 0
            ;;
        PARTIAL)
            return 2
            ;;
        BLOCKED)
            return 3
            ;;
        *)
            return 4
            ;;
    esac
}

main "$@"
