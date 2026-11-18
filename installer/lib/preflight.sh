#!/usr/bin/env bash
#
# NVU Dashboard Native Installation Preflight
# B6.2G-4 candidate
#
# STRICTLY READ ONLY
#
# Results:
#   READY
#   INSTALLED
#   UPGRADE_CANDIDATE
#   REVIEW
#   BLOCKED

set -u

PREFLIGHT_VERSION="0.2.0-dev"

DASHBOARD_ROOT="/usr/local/lib/nvu/dashboard"
RELEASES_DIR="$DASHBOARD_ROOT/releases"
CURRENT_LINK="$DASHBOARD_ROOT/current"
VENV_DIR="$DASHBOARD_ROOT/venv"

DASHBOARD_UNIT="nvu-dashboard.service"
DASHBOARD_UNIT_FILE="/etc/systemd/system/$DASHBOARD_UNIT"
NVUN_UNIT="nvun.service"

RPC_CREDENTIAL_FILE="/etc/nvu/credentials/rpc-client.env"
RPC_HOST="127.0.0.1"
RPC_PORT="9332"

TARGET_RUNTIME_DIR="/run/nvu-dashboard"
TARGET_SOCKET="$TARGET_RUNTIME_DIR/nvu-dashboard.sock"

APACHE_SERVICE="apache2"
APACHE_SITE_AVAILABLE="/etc/apache2/sites-available/nvu-dashboard.conf"
APACHE_SITE_ENABLED="/etc/apache2/sites-enabled/nvu-dashboard.conf"

REFERENCE_BACKEND_HOST="127.0.0.1"
REFERENCE_BACKEND_PORT="8080"

PASS_COUNT=0
NOTE_COUNT=0
REVIEW_COUNT=0
BLOCK_COUNT=0

DASHBOARD_STATE="NOT_INSTALLED"
CURRENT_BACKEND="none"
TARGET_BACKEND="unix"
SOCKET_NAMESPACE="UNKNOWN"
FINAL_RESULT="READY"

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

unit_exists() {
    systemctl list-unit-files "$1" \
        --no-legend \
        2>/dev/null |
        grep -Fq "$1"
}

unit_active() {
    systemctl is-active --quiet "$1" \
        2>/dev/null
}

unit_enabled() {
    systemctl is-enabled --quiet "$1" \
        2>/dev/null
}

priv_test() {
    sudo -n test "$@" 2>/dev/null
}

read_privileged_file() {
    local file="$1"

    if [[ -r "$file" ]]; then
        cat "$file"
    else
        sudo -n cat "$file" 2>/dev/null
    fi
}

get_tcp_listeners() {
    sudo -n ss -lntp 2>/dev/null ||
        ss -lnt 2>/dev/null ||
        true
}

get_unix_listeners() {
    sudo -n ss -lxnp 2>/dev/null ||
        ss -lxn 2>/dev/null ||
        true
}

extract_dashboard_execstart() {
    systemctl show \
        "$DASHBOARD_UNIT" \
        --property=ExecStart \
        --value \
        2>/dev/null || true
}

discover_current_resolved() {
    if priv_test -L "$CURRENT_LINK"; then
        sudo -n readlink -f "$CURRENT_LINK" 2>/dev/null || true
    fi
}

discover_reference_dashboard_version() {
    local response

    response="$(
        sudo -n curl \
            --silent \
            --max-time 3 \
            --unix-socket "$TARGET_SOCKET" \
            "http://localhost/api/version" \
            2>/dev/null || true
    )"

    if [[ -n "$response" ]]; then
        printf '%s
' "$response" |
            jq -r \
                '.dashboardVersion // empty' \
                2>/dev/null || true
    fi
}

discover_apache_server_name() {
    local content=""

    content="$(
        read_privileged_file "$APACHE_SITE_AVAILABLE" \
            2>/dev/null || true
    )"

    if [[ -n "$content" ]]; then
        printf '%s\n' "$content" |
            awk '
                /^[[:space:]]*ServerName[[:space:]]+/ {
                    print $2
                    exit
                }
            '
    fi
}

check_platform() {
    local os_id=""
    local os_name=""
    local os_version=""
    local architecture=""
    local init_name=""

    echo
    echo "=== PLATFORM ==="

    if [[ -r /etc/os-release ]]; then
        source /etc/os-release

        os_id="${ID:-unknown}"
        os_name="${PRETTY_NAME:-${NAME:-unknown}}"
        os_version="${VERSION_ID:-unknown}"

        echo "OS: $os_name"
        echo "OS ID: $os_id"
        echo "Version: $os_version"

        if [[ "$os_id" == "ubuntu" ]]; then
            pass "Ubuntu detected"
        else
            block "unsupported operating system: $os_id"
        fi
    else
        block "/etc/os-release unavailable"
    fi

    architecture="$(
        dpkg --print-architecture 2>/dev/null ||
        uname -m
    )"

    echo "Architecture: $architecture"

    case "$architecture" in
        amd64|arm64|x86_64|aarch64)
            pass "supported architecture detected"
            ;;
        *)
            review "architecture requires package-support review: $architecture"
            ;;
    esac

    init_name="$(
        ps -p 1 -o comm= 2>/dev/null |
        awk '{print $1}'
    )"

    if [[ "$init_name" == "systemd" ]]; then
        pass "systemd is PID 1"
    else
        block "systemd is not PID 1"
    fi

    if systemctl --version >/dev/null 2>&1; then
        pass "systemctl operational"
    else
        block "systemctl unavailable"
    fi

    if [[ -d /run ]]; then
        pass "/run available"
    else
        block "/run unavailable"
    fi
}

check_commands() {
    local cmd

    echo
    echo "=== REQUIRED COMMANDS ==="

    for cmd in \
        bash \
        python3 \
        curl \
        jq \
        sha256sum \
        tar \
        systemctl \
        ss \
        awk \
        grep \
        find \
        stat
    do
        if command_exists "$cmd"; then
            pass "command available: $cmd"
        else
            block "required command missing: $cmd"
        fi
    done

    echo
    echo "=== OPTIONAL WEB COMMANDS ==="

    for cmd in \
        apache2ctl \
        a2enmod \
        a2ensite \
        certbot
    do
        if command_exists "$cmd"; then
            pass "web command available: $cmd"
        else
            note "web command not installed: $cmd"
        fi
    done
}

check_runtime_identity() {
    local nvu_home=""
    local nvu_shell=""

    echo
    echo "=== RUNTIME IDENTITY ==="

    if getent passwd nvu >/dev/null 2>&1; then
        pass "nvu user exists"

        nvu_home="$(
            getent passwd nvu |
            cut -d: -f6
        )"

        nvu_shell="$(
            getent passwd nvu |
            cut -d: -f7
        )"

        echo "nvu home: $nvu_home"
        echo "nvu shell: $nvu_shell"
    else
        block "nvu user does not exist"
    fi

    if getent group nvu >/dev/null 2>&1; then
        pass "nvu group exists"
    else
        block "nvu group does not exist"
    fi

    if getent passwd www-data >/dev/null 2>&1; then
        pass "Apache runtime user www-data exists"
    else
        note "Apache runtime user www-data absent"
    fi

    if getent group www-data >/dev/null 2>&1; then
        pass "Apache runtime group www-data exists"
    else
        note "Apache runtime group www-data absent"
    fi
}

check_nvun() {
    local credential_owner=""
    local credential_mode=""
    local tcp_listeners=""

    echo
    echo "=== NVUN PREREQUISITE ==="

    if unit_exists "$NVUN_UNIT"; then
        pass "nvun.service exists"
    else
        block "nvun.service does not exist"
    fi

    if unit_active "$NVUN_UNIT"; then
        pass "NVUN active"
    else
        block "NVUN inactive"
    fi

    if unit_enabled "$NVUN_UNIT"; then
        pass "NVUN enabled"
    else
        review "NVUN not enabled"
    fi

    if priv_test -f "$RPC_CREDENTIAL_FILE"; then
        pass "RPC credential file exists"

        credential_owner="$(
            sudo -n stat \
                -c '%U:%G' \
                "$RPC_CREDENTIAL_FILE" \
                2>/dev/null || true
        )"

        credential_mode="$(
            sudo -n stat \
                -c '%a' \
                "$RPC_CREDENTIAL_FILE" \
                2>/dev/null || true
        )"

        echo "RPC credential owner: ${credential_owner:-unknown}"
        echo "RPC credential mode: ${credential_mode:-unknown}"
    else
        block "RPC credential file missing"
    fi

    if sudo -n -u nvu \
        head -c 1 "$RPC_CREDENTIAL_FILE" \
        >/dev/null 2>&1
    then
        pass "nvu can read RPC credential record"
    else
        block "nvu cannot read RPC credential record"
    fi

    tcp_listeners="$(
        get_tcp_listeners
    )"

    if printf '%s\n' "$tcp_listeners" |
        grep -Eq \
            "${RPC_HOST}:${RPC_PORT}[[:space:]]"
    then
        pass "NVUN RPC listener detected at ${RPC_HOST}:${RPC_PORT}"
    else
        review "NVUN RPC listener not confirmed at ${RPC_HOST}:${RPC_PORT}"
    fi

    if sudo -n test -x "$VENV_DIR/bin/python" &&
       { [[ -d "$CURRENT_LINK" ]] || [[ -L "$CURRENT_LINK" ]]; }
    then
        if sudo -n -u nvu env \
            HOME=/var/lib/nvu \
            PYTHONPATH="$CURRENT_LINK" \
            PYTHONDONTWRITEBYTECODE=1 \
            "$VENV_DIR/bin/python" -c \
            'import server; info=server.rpc.blockchain_info(); assert info["chain"] == "main"; assert info["initialblockdownload"] is False' \
            >/dev/null 2>&1
        then
            pass "native RPC authentication and synchronization"
        else
            review "native RPC authentication not confirmed"
        fi
    else
        note "Dashboard runtime unavailable for optional RPC probe"
    fi
}

classify_dashboard_installation() {
    local recognized=0
    local partial=0
    local current_resolved=""
    local dashboard_version=""
    local exec_start=""

    echo
    echo "=== DASHBOARD INSTALLATION DISCOVERY ==="

    if ! priv_test -e "$DASHBOARD_ROOT" &&
       ! priv_test -e "$DASHBOARD_UNIT_FILE" &&
       ! priv_test -L "$CURRENT_LINK"
    then
        DASHBOARD_STATE="NOT_INSTALLED"
        pass "Dashboard not currently installed"
        return
    fi

    if priv_test -d "$DASHBOARD_ROOT"; then
        pass "Dashboard production root exists"
    else
        partial=1
        review "Dashboard production root absent"
    fi

    if priv_test -d "$RELEASES_DIR"; then
        pass "Dashboard releases directory exists"
    else
        partial=1
        review "Dashboard releases directory absent"
    fi

    if priv_test -L "$CURRENT_LINK"; then
        current_resolved="$(
            discover_current_resolved
        )"

        if [[ -n "$current_resolved" ]] &&
           priv_test -d "$current_resolved"
        then
            pass "current resolves to $current_resolved"
            recognized=1
        else
            partial=1
            review "current is broken or unresolved"
        fi
    else
        partial=1
        review "current symlink absent"
    fi

    if sudo -n test -x "$VENV_DIR/bin/python" &&
       sudo -n test -x "$VENV_DIR/bin/gunicorn"
    then
        pass "production Python environment exists"
    else
        partial=1
        review "production Python environment incomplete"
    fi

    if sudo -n test -f "$DASHBOARD_UNIT_FILE"; then
        pass "Dashboard systemd unit exists"
        recognized=1
    elif unit_exists "$DASHBOARD_UNIT"; then
        pass "Dashboard unit known to systemd"
        recognized=1
    else
        partial=1
        review "Dashboard systemd unit absent"
    fi

    dashboard_version="$(
        discover_reference_dashboard_version
    )"

    if [[ -n "$dashboard_version" ]]; then
        pass "running Dashboard version = $dashboard_version"
        recognized=1
    else
        note "running Dashboard version not detected"
    fi

    exec_start="$(
        extract_dashboard_execstart
    )"

    if [[ "$exec_start" == *"127.0.0.1:8080"* ]]; then
        CURRENT_BACKEND="legacy-loopback-tcp"
        pass "recognized loopback TCP reference backend"
    elif [[ "$exec_start" == *"unix:"* &&
            "$exec_start" == *"nvu-dashboard.sock"* ]]
    then
        CURRENT_BACKEND="unix"
        pass "recognized Unix-socket Dashboard backend"
    elif [[ -n "$exec_start" ]]; then
        CURRENT_BACKEND="unknown"
        review "Dashboard service uses unknown backend transport"
    fi

    if [[ "$partial" -eq 1 && "$recognized" -eq 0 ]]; then
        DASHBOARD_STATE="PARTIAL_UNKNOWN"
        review "unrecognized partial Dashboard state"
    elif [[ "$partial" -eq 1 ]]; then
        DASHBOARD_STATE="PARTIAL_RECOGNIZED"
        review "recognized but incomplete Dashboard installation"
    elif [[ "$CURRENT_BACKEND" == "legacy-loopback-tcp" ]]; then
        DASHBOARD_STATE="UPGRADE_CANDIDATE"
        pass "existing Dashboard is a Unix-socket migration candidate"
    elif [[ "$CURRENT_BACKEND" == "unix" ]]; then
        DASHBOARD_STATE="INSTALLED"
        pass "recognized Unix-socket Dashboard installation"
    else
        DASHBOARD_STATE="INSTALLED_UNKNOWN_BACKEND"
        review "Dashboard installed with unclassified backend"
    fi
}

check_socket_namespace() {
    local object_type=""
    local object_owner=""
    local object_mode=""
    local unix_listeners=""
    local service_contract=""

    echo
    echo "=== UNIX-SOCKET NAMESPACE ==="

    echo "Target runtime directory: $TARGET_RUNTIME_DIR"
    echo "Target socket: $TARGET_SOCKET"

    if ! priv_test -e "$TARGET_RUNTIME_DIR"; then
        SOCKET_NAMESPACE="AVAILABLE"
        pass "runtime-directory namespace available"
    else
        object_type="$(
            sudo -n stat -c '%F' "$TARGET_RUNTIME_DIR" \
                2>/dev/null || true
        )"

        object_owner="$(
            sudo -n stat -c '%U:%G' "$TARGET_RUNTIME_DIR" \
                2>/dev/null || true
        )"

        object_mode="$(
            sudo -n stat -c '%a' "$TARGET_RUNTIME_DIR" \
                2>/dev/null || true
        )"

        echo "Existing runtime type: ${object_type:-unknown}"
        echo "Existing runtime owner: ${object_owner:-unknown}"
        echo "Existing runtime mode: ${object_mode:-unknown}"

        if [[ "$object_type" != "directory" ]]; then
            SOCKET_NAMESPACE="CONFLICT"
            block "$TARGET_RUNTIME_DIR exists but is not a directory"
        elif [[ "$object_owner" == "nvu:www-data" &&
                  "$object_mode" == "750" ]]
        then
            pass "graduated Dashboard runtime directory recognized"
        elif [[ "$object_owner" == "nvu:nvu" ||
                "$object_owner" == "root:nvu" ]]
        then
            SOCKET_NAMESPACE="REVIEW"
            review "legacy-looking runtime directory requires review"
        else
            SOCKET_NAMESPACE="REVIEW"
            review "runtime directory ownership not recognized"
        fi
    fi

    if ! priv_test -e "$TARGET_SOCKET"; then
        if [[ "$SOCKET_NAMESPACE" == "UNKNOWN" ]]; then
            SOCKET_NAMESPACE="AVAILABLE"
        fi

        pass "socket pathname available"
        return
    fi

    object_type="$(
        sudo -n stat -c '%F' "$TARGET_SOCKET" \
            2>/dev/null || true
    )"

    object_owner="$(
        sudo -n stat -c '%U:%G' "$TARGET_SOCKET" \
            2>/dev/null || true
    )"

    echo "Existing socket type: ${object_type:-unknown}"
    echo "Existing socket owner: ${object_owner:-unknown}"

    if [[ "$object_type" != "socket" ]]; then
        SOCKET_NAMESPACE="CONFLICT"
        block "$TARGET_SOCKET exists but is not a Unix socket"
        return
    fi

    unix_listeners="$(
        get_unix_listeners
    )"

    service_contract="$(
        extract_dashboard_execstart
    )"

    if [[ "$service_contract" == *"$TARGET_SOCKET"* ]]; then
        SOCKET_NAMESPACE="NVU_OWNED"
        pass "existing socket referenced by nvu-dashboard.service"
    elif printf '%s\n' "$unix_listeners" |
        grep -Fq "$TARGET_SOCKET"
    then
        SOCKET_NAMESPACE="CONFLICT"
        block "socket active but ownership is not recognized"
    else
        SOCKET_NAMESPACE="REVIEW"
        review "socket exists without recognized active owner"
    fi
}

check_systemd_capability() {
    local version=""

    echo
    echo "=== SYSTEMD RUNTIME-DIRECTORY CAPABILITY ==="

    version="$(
        systemctl --version |
        awk 'NR == 1 {print $2}'
    )"

    echo "systemd version: ${version:-unknown}"

    if command_exists systemd-analyze; then
        pass "systemd-analyze available"
    else
        block "systemd-analyze unavailable"
    fi

    if man systemd.exec 2>/dev/null |
        col -b 2>/dev/null |
        grep -Fq 'RuntimeDirectory='
    then
        pass "RuntimeDirectory directive documented"
    else
        note "RuntimeDirectory documentation probe unavailable"
    fi

    note "runtime-directory permission model will be qualified in B6.2G-5"
    note "Apache socket-access model will be qualified in B6.2G-5"
}

check_apache() {
    local modules=""
    local server_name=""

    echo
    echo "=== APACHE DISCOVERY ==="

    if ! command_exists apache2ctl; then
        note "Apache not installed"
        note "FQDN/IPv4 modes require Apache dependencies"
        return
    fi

    pass "Apache installed"

    if unit_active "$APACHE_SERVICE"; then
        pass "Apache active"
    else
        review "Apache installed but inactive"
    fi

    if unit_enabled "$APACHE_SERVICE"; then
        pass "Apache enabled"
    else
        review "Apache not enabled"
    fi

    if sudo -n apache2ctl -t \
        >/dev/null 2>&1
    then
        pass "Apache syntax valid"
    else
        review "Apache syntax could not be validated"
    fi

    modules="$(
        sudo -n apache2ctl -M \
            2>/dev/null || true
    )"

    if printf '%s\n' "$modules" |
        grep -Fq 'proxy_module'
    then
        pass "Apache proxy module loaded"
    else
        note "Apache proxy module not loaded"
    fi

    if printf '%s\n' "$modules" |
        grep -Fq 'proxy_http_module'
    then
        pass "Apache proxy_http module loaded"
    else
        note "Apache proxy_http module not loaded"
    fi

    if priv_test -f "$APACHE_SITE_AVAILABLE"; then
        pass "NVU Dashboard Apache site exists"

        server_name="$(
            discover_apache_server_name
        )"

        if [[ -n "$server_name" ]]; then
            pass "Dashboard ServerName = $server_name"
        else
            review "Dashboard ServerName not detected"
        fi
    else
        note "NVU Dashboard Apache site not installed"
    fi

    if priv_test -L "$APACHE_SITE_ENABLED"; then
        pass "NVU Dashboard Apache site enabled"
    else
        note "NVU Dashboard Apache site not enabled"
    fi

    note "Unix-socket ProxyPass is qualified in B6.2G-5"
}

check_certbot() {
    echo
    echo "=== CERTBOT DISCOVERY ==="

    if command_exists certbot; then
        pass "Certbot installed"

        certbot --version \
            2>/dev/null || true

        if sudo -n certbot plugins \
            2>/dev/null |
            grep -Fq 'apache'
        then
            pass "Certbot Apache plugin available"
        else
            note "Certbot Apache plugin not confirmed"
        fi
    else
        note "Certbot not installed"
        note "HTTPS mode will require Certbot dependency"
    fi
}

check_filesystem_targets() {
    local available_kb=""

    echo
    echo "=== FILESYSTEM TARGETS ==="

    available_kb="$(
        df -Pk /usr/local |
        awk 'NR == 2 {print $4}'
    )"

    echo "Available /usr/local space: ${available_kb:-unknown} KiB"

    if [[ "$available_kb" =~ ^[0-9]+$ &&
          "$available_kb" -ge 262144 ]]
    then
        pass "at least 256 MiB available under /usr/local"
    elif [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        review "less than 256 MiB available under /usr/local"
    else
        review "available disk space could not be determined"
    fi

    for target in \
        "$DASHBOARD_ROOT" \
        "$RELEASES_DIR" \
        "$CURRENT_LINK" \
        "$VENV_DIR" \
        "$DASHBOARD_UNIT_FILE" \
        "$APACHE_SITE_AVAILABLE"
    do
        if [[ -e "$target" || -L "$target" ]]; then
            note "target exists: $target"
        else
            pass "target available: $target"
        fi
    done
}

determine_result() {
    if [[ "$BLOCK_COUNT" -gt 0 ]]; then
        FINAL_RESULT="BLOCKED"
        return
    fi

    if [[ "$REVIEW_COUNT" -gt 0 ]]; then
        FINAL_RESULT="REVIEW"
        return
    fi

    case "$DASHBOARD_STATE" in
        NOT_INSTALLED)
            FINAL_RESULT="READY"
            ;;
        UPGRADE_CANDIDATE)
            FINAL_RESULT="UPGRADE_CANDIDATE"
            ;;
        INSTALLED)
            FINAL_RESULT="INSTALLED"
            ;;
        *)
            FINAL_RESULT="REVIEW"
            ;;
    esac
}

print_summary() {
    echo
    echo "============================================================"
    echo "NVU DASHBOARD INSTALLATION PREFLIGHT SUMMARY"
    echo "============================================================"

    echo
    echo "Preflight version:"
    echo "  $PREFLIGHT_VERSION"

    echo
    echo "Dashboard state:"
    echo "  $DASHBOARD_STATE"

    echo
    echo "Current backend:"
    echo "  $CURRENT_BACKEND"

    echo
    echo "Installer target backend:"
    echo "  $TARGET_BACKEND"

    echo
    echo "Runtime directory:"
    echo "  $TARGET_RUNTIME_DIR"

    echo
    echo "Unix socket:"
    echo "  $TARGET_SOCKET"

    echo
    echo "Socket namespace:"
    echo "  $SOCKET_NAMESPACE"

    echo
    echo "TCP backend port required:"
    echo "  none"

    echo
    echo "Web modes:"
    echo "  fqdn       available when Apache/DNS prerequisites pass"
    echo "  ipv4       available when Apache prerequisites pass"
    echo "  localhost  final design pending B6.2G-5"

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
    echo "============================================================"
    echo "NVU DASHBOARD NATIVE INSTALLATION PREFLIGHT"
    echo "B6.2G-4"
    echo "READ ONLY"
    echo "============================================================"

    check_platform
    check_commands
    check_runtime_identity
    check_nvun
    classify_dashboard_installation
    check_socket_namespace
    check_systemd_capability
    check_apache
    check_certbot
    check_filesystem_targets

    determine_result
    print_summary

    case "$FINAL_RESULT" in
        READY|INSTALLED|UPGRADE_CANDIDATE)
            return 0
            ;;
        REVIEW)
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
