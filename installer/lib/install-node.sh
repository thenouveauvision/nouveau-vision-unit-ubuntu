#!/usr/bin/env bash
#
# Nouveau-Vision Ubuntu-Native Installer
# Milestone: B6.2H-2D
# Module: install-node
#
# DRY-RUN ONLY. No installation mutations are implemented.

set -Eeuo pipefail

INSTALL_NODE_VERSION="0.2.0-dev"

MODULE_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 &&
    pwd -P
)"

INSTALLER_ROOT="$(
    cd -- "${MODULE_DIR}/.." >/dev/null 2>&1 &&
    pwd -P
)"

NVUN_VERSION="1.0.0"
PAYLOAD="$INSTALLER_ROOT/payload/nvun/$NVUN_VERSION"
NVUND_PAYLOAD="$PAYLOAD/bin/nvund"
CLI_PAYLOAD="$PAYLOAD/bin/nvu-cli"
PAYLOAD_VERSION="$PAYLOAD/VERSION"
PAYLOAD_SUMS="$PAYLOAD/SHA256SUMS"

SERVICE_TEMPLATE="$INSTALLER_ROOT/templates/nvun.service.in"
CONFIG_TEMPLATE="$INSTALLER_ROOT/templates/nvun.conf.in"

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

PASS_COUNT=0
NOTE_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

note() {
    NOTE_COUNT=$((NOTE_COUNT + 1))
    printf 'NOTE: %s\n' "$1"
}

fail_gate() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL: %s\n' "$1"
}

usage() {
    cat <<'USAGE'
NVU native node installer

Usage:
  install-node.sh --dry-run
  install-node.sh --install

Modes:
  --dry-run   Validate payload, templates, host prerequisites,
              target paths, and prospective installation plan.

  --install   Fresh installation only. Refuses any host where
              an NVUN installation or protected target already exists.
USAGE
}

parse_mode() {
    if [[ "$#" -ne 1 ]]; then
        usage >&2
        return 2
    fi

    case "$1" in
        --dry-run)
            MODE="dry-run"
            ;;
        --install)
            MODE="install"
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

fresh_install_guard() {
    local blocked=0
    local target=""

    echo
    echo "=== FRESH-INSTALL GUARD ==="

    if systemctl list-unit-files nvun.service         --no-legend 2>/dev/null |
        grep -Fq 'nvun.service'
    then
        printf '%s
'             "BLOCKED: nvun.service already exists"
        blocked=1
    fi

    for target in         /usr/local/bin/nvund         /usr/local/bin/nvu-cli         /var/lib/nvu/node         /etc/nvu/nvun.conf         /etc/nvu/credentials/rpc-client.env         /etc/systemd/system/nvun.service
    do
        if sudo -n test -e "$target" 2>/dev/null ||
           sudo -n test -L "$target" 2>/dev/null
        then
            printf 'BLOCKED: protected target exists: %s
' "$target"
            blocked=1
        fi
    done

    if [[ "$blocked" -ne 0 ]]; then
        echo
        echo "NVU NODE INSTALLATION NOT STARTED"
        echo "Reason:"
        echo "  Existing NVUN installation detected."
        echo
        echo "Changes made:"
        echo "  none"
        return 3
    fi

    pass "fresh-install target has no conflicting NVUN installation"
}

check_platform() {
    local architecture
    local os_id

    echo
    echo "=== PLATFORM ==="

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        os_id="${ID:-unknown}"

        printf 'OS: %s\n' "${PRETTY_NAME:-unknown}"

        if [[ "$os_id" == "ubuntu" ]]; then
            pass "Ubuntu detected"
        else
            fail_gate "unsupported operating system: $os_id"
        fi
    else
        fail_gate "/etc/os-release unavailable"
    fi

    architecture="$(
        dpkg --print-architecture 2>/dev/null ||
        uname -m
    )"

    printf 'Architecture: %s\n' "$architecture"

    case "$architecture" in
        amd64|x86_64)
            pass "qualified NVUN payload architecture detected"
            ;;
        *)
            fail_gate "NVUN payload is not qualified for: $architecture"
            ;;
    esac

    if [[ "$(ps -p 1 -o comm= 2>/dev/null | awk '{print $1}')" == "systemd" ]]; then
        pass "systemd is PID 1"
    else
        fail_gate "systemd is not PID 1"
    fi
}

check_commands() {
    local command

    echo
    echo "=== REQUIRED COMMANDS ==="

    for command in \
        bash \
        install \
        sha256sum \
        sed \
        grep \
        awk \
        stat \
        systemctl \
        systemd-analyze \
        getent \
        apt-get \
        dpkg-query \
        ldd \
        jq \
        ss \
        seq \
        useradd \
        groupadd
    do
        if command -v "$command" >/dev/null 2>&1; then
            pass "command available: $command"
        else
            fail_gate "command unavailable: $command"
        fi
    done
}

check_payload() {
    local actual

    echo
    echo "=== NVUN PAYLOAD ==="

    for file in \
        "$NVUND_PAYLOAD" \
        "$CLI_PAYLOAD" \
        "$PAYLOAD_VERSION" \
        "$PAYLOAD_SUMS"
    do
        if [[ -f "$file" ]]; then
            pass "payload file exists: ${file#"$INSTALLER_ROOT/"}"
        else
            fail_gate "payload file missing: $file"
        fi
    done

    if [[ -x "$NVUND_PAYLOAD" ]]; then
        actual="$(sha256sum "$NVUND_PAYLOAD" | awk '{print $1}')"
        printf 'nvund SHA-256: %s\n' "$actual"

        if [[ "$actual" == "$EXPECTED_NVUND_SHA256" ]]; then
            pass "nvund matches qualified Lab binary"
        else
            fail_gate "nvund checksum mismatch"
        fi
    fi

    if [[ -x "$CLI_PAYLOAD" ]]; then
        actual="$(sha256sum "$CLI_PAYLOAD" | awk '{print $1}')"
        printf 'nvu-cli SHA-256: %s\n' "$actual"

        if [[ "$actual" == "$EXPECTED_CLI_SHA256" ]]; then
            pass "nvu-cli matches qualified Lab binary"
        else
            fail_gate "nvu-cli checksum mismatch"
        fi
    fi

    if [[ -r "$PAYLOAD_SUMS" ]]; then
        if (
            cd "$PAYLOAD"
            sha256sum -c SHA256SUMS >/dev/null
        ); then
            pass "payload manifest verifies"
        else
            fail_gate "payload manifest verification failed"
        fi
    fi

    if [[ -r "$PAYLOAD_VERSION" ]] &&
       grep -Fxq 'NVUN_VERSION=1.0.0' "$PAYLOAD_VERSION" &&
       grep -Fxq 'NVUN_BUILD=v1.0.0-d4d3cc031' "$PAYLOAD_VERSION"
    then
        pass "payload version metadata matches qualified build"
    else
        fail_gate "payload version metadata mismatch"
    fi
}

check_runtime_dependencies() {
    local package
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
            note "runtime package required: $package"
            missing_packages=$((missing_packages + 1))
        fi
    done

    printf 'Runtime packages not currently installed: %s\n' \
        "$missing_packages"

    for binary in "$NVUND_PAYLOAD" "$CLI_PAYLOAD"; do
        unresolved_output="$(
            ldd "$binary" 2>/dev/null |
                grep -F 'not found' || true
        )"

        if [[ -n "$unresolved_output" ]]; then
            note "unresolved libraries before installation: ${binary##*/}"
            printf '%s\n' "$unresolved_output"
        else
            pass "all linked libraries currently resolve: ${binary##*/}"
        fi
    done

    if [[ "$missing_packages" -gt 0 ]]; then
        note "fresh install will install the qualified runtime packages"
    fi
}

install_runtime_dependencies() {
    local package
    local unresolved_output=""

    echo
    echo "=== INSTALLING NVUN RUNTIME DEPENDENCIES ==="

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y --no-install-recommends \
        "${RUNTIME_PACKAGES[@]}"

    echo
    echo "=== VERIFYING RUNTIME DEPENDENCIES ==="

    for package in "${RUNTIME_PACKAGES[@]}"; do
        dpkg-query -W \
            -f='${db:Status-Abbrev}\n' \
            "$package" 2>/dev/null |
            grep -Fxq 'ii ' || {
                echo "FAIL: required package not installed: $package"
                return 1
            }

        echo "PASS: $package"
    done

    for binary in "$NVUND_PAYLOAD" "$CLI_PAYLOAD"; do
        unresolved_output="$(
            ldd "$binary" 2>/dev/null |
                grep -F 'not found' || true
        )"

        if [[ -n "$unresolved_output" ]]; then
            echo "FAIL: unresolved libraries remain for ${binary##*/}"
            printf '%s\n' "$unresolved_output"
            return 1
        fi

        echo "PASS: all linked libraries resolve for ${binary##*/}"
    done

    echo "PASS: NVUN runtime dependency set qualified"
}

check_service_template() {
    local temporary_unit

    echo
    echo "=== SYSTEMD TEMPLATE ==="

    if [[ ! -r "$SERVICE_TEMPLATE" ]]; then
        fail_gate "service template missing"
        return
    fi

    pass "service template exists"

    for setting in \
        'User=nvu' \
        'Group=nvu' \
        'ProtectSystem=strict' \
        'ReadOnlyPaths=/etc/nvu' \
        'ReadWritePaths=/var/lib/nvu/node' \
        'ReadWritePaths=/var/log/nvu/nvun' \
        'ExecStart=/usr/local/bin/nvund -datadir=/var/lib/nvu/node -conf=/etc/nvu/nvun.conf' \
        'ExecStop=/usr/local/bin/nvu-cli -datadir=/var/lib/nvu/node -conf=/etc/nvu/nvun.conf stop'
    do
        if grep -Fxq "$setting" "$SERVICE_TEMPLATE"; then
            pass "service setting: $setting"
        else
            fail_gate "service setting missing: $setting"
        fi
    done

    if grep -Fxq "[Unit]" "$SERVICE_TEMPLATE" &&
       grep -Fxq "[Service]" "$SERVICE_TEMPLATE" &&
       grep -Fxq "[Install]" "$SERVICE_TEMPLATE" &&
       [[ -x "$NVUND_PAYLOAD" ]] &&
       [[ -x "$CLI_PAYLOAD" ]]
    then
        pass "service template structure and referenced payloads verified"
    else
        fail_gate "service template structure or referenced payload is invalid"
    fi
}

check_config_template() {
    local placeholder_count

    echo
    echo "=== NVUN CONFIG TEMPLATE ==="

    if [[ ! -r "$CONFIG_TEMPLATE" ]]; then
        fail_gate "configuration template missing"
        return
    fi

    pass "configuration template exists"

    for setting in \
        'server=1' \
        'daemon=0' \
        'listen=1' \
        'port=9333' \
        'rpcbind=127.0.0.1' \
        'rpcallowip=127.0.0.1' \
        'rpcport=9332' \
        'rpcauth=@RPC_AUTH@' \
        'printtoconsole=1' \
        'debuglogfile=0' \
        'upnp=0' \
        'natpmp=0' \
        'listenonion=0'
    do
        if grep -Fxq "$setting" "$CONFIG_TEMPLATE"; then
            pass "configuration setting: $setting"
        else
            fail_gate "configuration setting missing: $setting"
        fi
    done

    placeholder_count="$(
        grep -Eo '@[A-Z_][A-Z_]*@' "$CONFIG_TEMPLATE" |
        sort -u |
        wc -l |
        awk '{print $1}'
    )"

    if [[ "$placeholder_count" == "1" ]] &&
       grep -Fq '@RPC_AUTH@' "$CONFIG_TEMPLATE"
    then
        pass "RPC_AUTH is the only template placeholder"
    else
        fail_gate "unexpected template placeholders detected"
    fi

    if grep -Eiq \
        'rpc(user|password)[[:space:]]*=|rpcauth=[^@]' \
        "$CONFIG_TEMPLATE"
    then
        fail_gate "configuration template may contain a credential"
    else
        pass "configuration template contains no credential"
    fi
}

check_identity() {
    local record
    local home
    local shell

    echo
    echo "=== SERVICE IDENTITY ==="

    if getent passwd nvu >/dev/null 2>&1; then
        record="$(getent passwd nvu)"
        home="$(printf '%s\n' "$record" | cut -d: -f6)"
        shell="$(printf '%s\n' "$record" | cut -d: -f7)"

        printf 'Existing nvu account: %s\n' "$record"

        if [[ "$home" == "/var/lib/nvu" ]]; then
            pass "existing nvu home matches installation contract"
        else
            fail_gate "existing nvu home differs from /var/lib/nvu"
        fi

        if [[ "$shell" == "/usr/sbin/nologin" ]]; then
            pass "existing nvu shell matches installation contract"
        else
            fail_gate "existing nvu shell differs from /usr/sbin/nologin"
        fi

        note "fresh install would reuse the matching nvu account"
    else
        pass "nvu account is available for fresh creation"
    fi

    if getent group nvu >/dev/null 2>&1; then
        pass "existing nvu group detected"
        note "fresh install would reuse the matching nvu group"
    else
        pass "nvu group is available for fresh creation"
    fi
}

describe_target() {
    local target="$1"
    local expected_type="$2"

    if sudo -n test -e "$target" 2>/dev/null ||
       sudo -n test -L "$target" 2>/dev/null
    then
        case "$expected_type" in
            file)
                if sudo -n test -f "$target"; then
                    note "existing file target: $target"
                else
                    fail_gate "unexpected target type: $target"
                fi
                ;;
            directory)
                if sudo -n test -d "$target"; then
                    note "existing directory target: $target"
                else
                    fail_gate "unexpected target type: $target"
                fi
                ;;
        esac
    else
        pass "target available: $target"
    fi
}

check_targets() {
    echo
    echo "=== INSTALLATION TARGETS ==="

    describe_target "/usr/local/bin/nvund" file
    describe_target "/usr/local/bin/nvu-cli" file
    describe_target "/var/lib/nvu" directory
    describe_target "/var/lib/nvu/node" directory
    describe_target "/var/log/nvu" directory
    describe_target "/var/log/nvu/nvun" directory
    describe_target "/etc/nvu" directory
    describe_target "/etc/nvu/credentials" directory
    describe_target "/etc/nvu/nvun.conf" file
    describe_target "/etc/nvu/credentials/rpc-client.env" file
    describe_target "/etc/systemd/system/nvun.service" file
}

check_existing_service() {
    local active
    local enabled

    echo
    echo "=== EXISTING NVUN SERVICE ==="

    if systemctl list-unit-files nvun.service --no-legend 2>/dev/null |
       grep -Fq 'nvun.service'
    then
        pass "existing nvun.service recognized"

        active="$(systemctl is-active nvun.service 2>/dev/null || true)"
        enabled="$(systemctl is-enabled nvun.service 2>/dev/null || true)"

        printf 'Service active:  %s\n' "${active:-unknown}"
        printf 'Service enabled: %s\n' "${enabled:-unknown}"

        note "dry-run is evaluating the installed Lab deployment"
        note "future mutation mode must refuse an existing installation"
    else
        pass "nvun.service absent on prospective fresh-install target"
    fi
}

print_plan() {
    echo
    echo "=== PROSPECTIVE INSTALLATION PLAN ==="

    cat <<'PLAN'
1. Verify the embedded NVUN payload.
2. Create the nvu system group and user when absent.
3. Create the proven Lab directory contract.
4. Install nvund and nvu-cli under /usr/local/bin.
5. Generate fresh local RPC authorization.
6. Render /etc/nvu/nvun.conf from nvun.conf.in.
7. Create the Dashboard RPC client credential record.
8. Install the hardened nvun.service unit.
9. Reload systemd.
10. Enable and start nvun.service.
11. Qualify the node, listeners, RPC, synchronization, and wallet.

DRY-RUN ONLY:
None of these operations are performed by this command.
PLAN
}

check_lab_safety() {
    local pid
    local balance

    echo
    echo "=== LAB SAFETY OBSERVATION ==="

    if systemctl is-active --quiet nvun.service &&
       sudo -n test -x /usr/local/bin/nvu-cli
    then
        pid="$(
            systemctl show nvun.service \
                --property=MainPID \
                --value
        )"

        balance="$(
            sudo -n -u nvu /usr/local/bin/nvu-cli \
                -datadir=/var/lib/nvu/node \
                -conf=/etc/nvu/nvun.conf \
                getbalance 2>/dev/null || true
        )"

        printf 'Production PID:     %s\n' "${pid:-unknown}"
        printf 'Production balance: %s\n' "${balance:-unavailable}"

        note "dry-run did not stop or restart production NVUN"
    else
        note "no active existing NVUN service observed"
    fi
}

require_install_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo
        echo "NVU NODE INSTALLATION NOT STARTED"
        echo "Reason:"
        echo "  --install requires sudo/root privileges."
        echo
        echo "Changes made:"
        echo "  none"
        return 2
    fi
}

generate_rpc_credentials() {
    local output

    output="$(
        python3 - <<'PY'
import hashlib
import hmac
import secrets

username = "nvu-dashboard"
password = secrets.token_urlsafe(32)
salt = secrets.token_hex(16)
digest = hmac.new(
    salt.encode("utf-8"),
    password.encode("utf-8"),
    hashlib.sha256,
).hexdigest()

print(username)
print(password)
print(f"{username}:{salt}${digest}")
PY
    )"

    mapfile -t RPC_FIELDS <<< "$output"

    if [[ "${#RPC_FIELDS[@]}" -ne 3 ]]; then
        echo "FAIL: RPC credential generation returned an invalid result"
        return 1
    fi

    RPC_USER="${RPC_FIELDS[0]}"
    RPC_PASSWORD="${RPC_FIELDS[1]}"
    RPC_AUTH="${RPC_FIELDS[2]}"

    if [[ -z "$RPC_USER" ||
          -z "$RPC_PASSWORD" ||
          -z "$RPC_AUTH" ]]
    then
        echo "FAIL: RPC credential generation returned an empty field"
        return 1
    fi

    if [[ "$RPC_AUTH" != "${RPC_USER}:"*'$'* ]]; then
        echo "FAIL: generated rpcauth field has an invalid structure"
        return 1
    fi
}

wait_for_rpc() {
    local attempt

    for attempt in $(seq 1 120); do
        if sudo -u nvu /usr/local/bin/nvu-cli \
            -datadir=/var/lib/nvu/node \
            -conf=/etc/nvu/nvun.conf \
            getblockchaininfo >/dev/null 2>&1
        then
            return 0
        fi

        if ! systemctl is-active --quiet nvun.service; then
            echo "FAIL: nvun.service exited during startup"
            journalctl -u nvun.service -n 80 --no-pager || true
            return 1
        fi

        sleep 1
    done

    echo "FAIL: NVUN RPC did not become available within 120 seconds"
    return 1
}

rollback_fresh_install() {
    local original_rc="$1"

    trap - ERR INT TERM

    echo
    echo "=== GUARDED ROLLBACK ==="

    if [[ "${STARTED_SERVICE:-0}" -eq 1 ]]; then
        systemctl stop nvun.service >/dev/null 2>&1 || true
    fi

    if [[ "${ENABLED_SERVICE:-0}" -eq 1 ]]; then
        systemctl disable nvun.service >/dev/null 2>&1 || true
    fi

    if [[ "${CREATED_UNIT:-0}" -eq 1 ]]; then
        rm -f /etc/systemd/system/nvun.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    [[ "${CREATED_CONFIG:-0}" -eq 1 ]] &&
        rm -f /etc/nvu/nvun.conf

    [[ "${CREATED_CREDENTIALS:-0}" -eq 1 ]] &&
        rm -f /etc/nvu/credentials/rpc-client.env

    [[ "${CREATED_NVUND:-0}" -eq 1 ]] &&
        rm -f /usr/local/bin/nvund

    [[ "${CREATED_CLI:-0}" -eq 1 ]] &&
        rm -f /usr/local/bin/nvu-cli

    if [[ "${CREATED_DATADIR:-0}" -eq 1 ]] &&
       [[ -d /var/lib/nvu/node ]]
    then
        rm -rf --one-file-system /var/lib/nvu/node
    fi

    if [[ "${CREATED_LOGDIR:-0}" -eq 1 ]] &&
       [[ -d /var/log/nvu/nvun ]]
    then
        rm -rf --one-file-system /var/log/nvu/nvun
    fi

    [[ "${CREATED_CREDENTIAL_DIR:-0}" -eq 1 ]] &&
        rmdir /etc/nvu/credentials 2>/dev/null || true

    [[ "${CREATED_ETC:-0}" -eq 1 ]] &&
        rmdir /etc/nvu 2>/dev/null || true

    [[ "${CREATED_LOG_ROOT:-0}" -eq 1 ]] &&
        rmdir /var/log/nvu 2>/dev/null || true

    [[ "${CREATED_HOME:-0}" -eq 1 ]] &&
        rmdir /var/lib/nvu 2>/dev/null || true

    if [[ "${CREATED_USER:-0}" -eq 1 ]]; then
        userdel nvu >/dev/null 2>&1 || true
    fi

    if [[ "${CREATED_GROUP:-0}" -eq 1 ]]; then
        groupdel nvu >/dev/null 2>&1 || true
    fi

    echo "Rollback completed."
    echo "Original failure code: $original_rc"
    return "$original_rc"
}

install_fresh_node() {
    local staging
    local rendered_config
    local rendered_credentials
    local rendered_unit
    local blockchain_json
    local wallet_json
    local installed_nvund_sha
    local installed_cli_sha

    CREATED_GROUP=0
    CREATED_USER=0
    CREATED_HOME=0
    CREATED_DATADIR=0
    CREATED_LOG_ROOT=0
    CREATED_LOGDIR=0
    CREATED_ETC=0
    CREATED_CREDENTIAL_DIR=0
    CREATED_NVUND=0
    CREATED_CLI=0
    CREATED_CONFIG=0
    CREATED_CREDENTIALS=0
    CREATED_UNIT=0
    ENABLED_SERVICE=0
    STARTED_SERVICE=0

    echo
    echo "=== FINAL PRE-MUTATION VALIDATION ==="

    FAIL_COUNT=0
    check_payload
    check_service_template
    check_config_template

    if [[ "$FAIL_COUNT" -ne 0 ]]; then
        echo
        echo "NVU NODE INSTALLATION NOT STARTED"
        echo "Reason:"
        echo "  Payload or template validation failed."
        echo
        echo "Changes made:"
        echo "  none"
        return 1
    fi

    install_runtime_dependencies || return $?

    staging="$(mktemp -d /tmp/nvu-node-install.XXXXXX)"
    chmod 0700 "$staging"

    rendered_config="$staging/nvun.conf"
    rendered_credentials="$staging/rpc-client.env"
    rendered_unit="$staging/nvun.service"

    cleanup_staging() {
        rm -rf --one-file-system "$staging"
    }

    trap cleanup_staging RETURN

    echo
    echo "=== GENERATING INSTALLATION-SPECIFIC RPC AUTHORIZATION ==="

    generate_rpc_credentials

    sed \
        "s|@RPC_AUTH@|$RPC_AUTH|" \
        "$CONFIG_TEMPLATE" \
        > "$rendered_config"

    cat > "$rendered_credentials" <<EOF_CREDENTIALS
RPC_HOST=127.0.0.1
RPC_PORT=9332
RPC_USER=$RPC_USER
RPC_PASSWORD=$RPC_PASSWORD
RPC_DATADIR=/var/lib/nvu/node
RPC_CONFIG=/etc/nvu/nvun.conf
EOF_CREDENTIALS

    cp "$SERVICE_TEMPLATE" "$rendered_unit"

    chmod 0640 "$rendered_config"
    chmod 0640 "$rendered_credentials"
    chmod 0644 "$rendered_unit"

    if grep -Fq '@RPC_AUTH@' "$rendered_config"; then
        echo "FAIL: unresolved RPC_AUTH placeholder remains"
        return 1
    fi

    if grep -Eq '@[A-Z_][A-Z_]*@' \
        "$rendered_config" \
        "$rendered_credentials" \
        "$rendered_unit"
    then
        echo "FAIL: unresolved installer placeholder remains"
        return 1
    fi

    if ! grep -Fxq "rpcauth=$RPC_AUTH" "$rendered_config"; then
        echo "FAIL: rendered rpcauth does not match generated authorization"
        return 1
    fi

    echo "PASS: fresh RPC authorization generated"
    echo "PASS: configuration candidates rendered"

    echo
    echo "=== CREATING SERVICE IDENTITY ==="

    if ! getent group nvu >/dev/null 2>&1; then
        groupadd --system nvu
        CREATED_GROUP=1
    fi

    if ! getent passwd nvu >/dev/null 2>&1; then
        useradd \
            --system \
            --gid nvu \
            --home-dir /var/lib/nvu \
            --shell /usr/sbin/nologin \
            --comment "Nouveau-Vision Unit service account" \
            nvu
        CREATED_USER=1
    fi

    getent passwd nvu |
        awk -F: '
            $6 != "/var/lib/nvu" {exit 1}
            $7 != "/usr/sbin/nologin" {exit 1}
        ' || {
            echo "FAIL: nvu service-account contract is invalid"
            return 1
        }

    echo "PASS: nvu service identity established"

    echo
    echo "=== CREATING DIRECTORY CONTRACT ==="

    if [[ ! -d /var/lib/nvu ]]; then
        install -d -o nvu -g nvu -m 0750 /var/lib/nvu
        CREATED_HOME=1
    fi

    if [[ ! -d /var/lib/nvu/node ]]; then
        install -d -o nvu -g nvu -m 0750 /var/lib/nvu/node
        CREATED_DATADIR=1
    fi

    if [[ ! -d /var/log/nvu ]]; then
        install -d -o nvu -g nvu -m 0750 /var/log/nvu
        CREATED_LOG_ROOT=1
    fi

    if [[ ! -d /var/log/nvu/nvun ]]; then
        install -d -o nvu -g nvu -m 0750 /var/log/nvu/nvun
        CREATED_LOGDIR=1
    fi

    if [[ ! -d /etc/nvu ]]; then
        install -d -o root -g nvu -m 0750 /etc/nvu
        CREATED_ETC=1
    fi

    if [[ ! -d /etc/nvu/credentials ]]; then
        install -d -o root -g nvu -m 0750 /etc/nvu/credentials
        CREATED_CREDENTIAL_DIR=1
    fi

    echo "PASS: known-good directory contract created"

    echo
    echo "=== INSTALLING QUALIFIED NVUN PAYLOAD ==="

    install \
        -o root \
        -g root \
        -m 0755 \
        "$NVUND_PAYLOAD" \
        /usr/local/bin/nvund
    CREATED_NVUND=1

    install \
        -o root \
        -g root \
        -m 0755 \
        "$CLI_PAYLOAD" \
        /usr/local/bin/nvu-cli
    CREATED_CLI=1

    installed_nvund_sha="$(
        sha256sum /usr/local/bin/nvund |
        awk '{print $1}'
    )"

    installed_cli_sha="$(
        sha256sum /usr/local/bin/nvu-cli |
        awk '{print $1}'
    )"

    [[ "$installed_nvund_sha" == "$EXPECTED_NVUND_SHA256" ]] || {
        echo "FAIL: installed nvund checksum mismatch"
        return 1
    }

    [[ "$installed_cli_sha" == "$EXPECTED_CLI_SHA256" ]] || {
        echo "FAIL: installed nvu-cli checksum mismatch"
        return 1
    }

    echo "PASS: qualified NVUN binaries installed and verified"

    echo
    echo "=== INSTALLING CONFIGURATION AND SERVICE ==="

    install \
        -o root \
        -g nvu \
        -m 0640 \
        "$rendered_config" \
        /etc/nvu/nvun.conf
    CREATED_CONFIG=1

    install \
        -o root \
        -g nvu \
        -m 0640 \
        "$rendered_credentials" \
        /etc/nvu/credentials/rpc-client.env
    CREATED_CREDENTIALS=1

    install \
        -o root \
        -g root \
        -m 0644 \
        "$rendered_unit" \
        /etc/systemd/system/nvun.service
    CREATED_UNIT=1

    systemd-analyze verify /etc/systemd/system/nvun.service \
        >/dev/null

    echo "PASS: configuration and hardened service installed"

    echo
    echo "=== STARTING NVUN ==="

    systemctl daemon-reload

    systemctl enable nvun.service
    ENABLED_SERVICE=1

    systemctl start nvun.service
    STARTED_SERVICE=1

    wait_for_rpc

    echo "PASS: nvun.service started and RPC became available"

    echo
    echo "=== IMMEDIATE INSTALLATION QUALIFICATION ==="

    systemctl is-active --quiet nvun.service
    systemctl is-enabled --quiet nvun.service

    blockchain_json="$(
        sudo -u nvu /usr/local/bin/nvu-cli \
            -datadir=/var/lib/nvu/node \
            -conf=/etc/nvu/nvun.conf \
            getblockchaininfo
    )"

    wallet_json="$(
        sudo -u nvu /usr/local/bin/nvu-cli \
            -datadir=/var/lib/nvu/node \
            -conf=/etc/nvu/nvun.conf \
            getwalletinfo
    )"

    printf '%s\n' "$blockchain_json" |
        jq -e '
            .chain == "main"
            and (.blocks | type == "number")
            and (.headers | type == "number")
        ' >/dev/null

    printf '%s\n' "$wallet_json" |
        jq -e '
            .walletname == ""
            and .private_keys_enabled == true
        ' >/dev/null

    ss -lnt |
        grep -Eq '127\.0\.0\.1:9332[[:space:]]'

    ss -lnt |
        grep -Eq '(^|[[:space:]])(\*|0\.0\.0\.0|\[::\]):9333[[:space:]]'

    stat -c '%U:%G %a' /etc/nvu/nvun.conf |
        grep -Fxq 'root:nvu 640'

    stat -c '%U:%G %a' /etc/nvu/credentials/rpc-client.env |
        grep -Fxq 'root:nvu 640'

    echo "PASS: service active and enabled"
    echo "PASS: main-chain RPC operational"
    echo "PASS: wallet subsystem operational"
    echo "PASS: RPC listener is local-only on 9332"
    echo "PASS: P2P listener is active on 9333"
    echo "PASS: configuration permissions verified"

    trap - ERR INT TERM
    trap - RETURN
    cleanup_staging

    echo
    echo "============================================================"
    echo "NVU NATIVE NODE INSTALLATION PASSED"
    echo "============================================================"
    echo
    echo "NVUN version:"
    echo "  $NVUN_VERSION"
    echo
    echo "Service:"
    echo "  active"
    echo "  enabled"
    echo
    echo "RPC:"
    echo "  127.0.0.1:9332"
    echo
    echo "P2P:"
    echo "  9333"
    echo
    echo "Wallet:"
    echo "  unnamed default wallet"
    echo "  private keys enabled"
    echo
    echo "Synchronization:"
    echo "  started; final synchronization is qualified separately"
    echo "============================================================"
}

execute_fresh_install() {
    local rc

    require_install_root || return $?
    fresh_install_guard || return $?

    trap '
        rc=$?
        rollback_fresh_install "$rc"
        exit "$rc"
    ' ERR INT TERM

    set +e
    install_fresh_node
    rc=$?
    set -e

    trap - ERR INT TERM

    if [[ "$rc" -ne 0 ]]; then
        rollback_fresh_install "$rc"
        return "$rc"
    fi

    return 0
}

print_summary() {
    echo
    echo "============================================================"
    echo "NVU NATIVE NODE INSTALLER DRY-RUN"
    echo "============================================================"
    echo
    echo "Installer module:"
    echo "  $INSTALL_NODE_VERSION"
    echo
    echo "NVUN payload:"
    echo "  $NVUN_VERSION"
    echo
    echo "Counts:"
    echo "  PASS: $PASS_COUNT"
    echo "  NOTE: $NOTE_COUNT"
    echo "  FAIL: $FAIL_COUNT"
    echo
    echo "Result:"

    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "  DRY-RUN PASSED"
    else
        echo "  DRY-RUN FAILED"
    fi

    echo
    echo "Changes made:"
    echo "  none"
    echo "============================================================"
}

main() {
    MODE=""
    parse_mode "$@" || return $?

    echo "============================================================"
    echo "NVU NATIVE NODE INSTALLER"
    echo "B6.2H-2E"
    printf 'MODE: %s\n' "$MODE"
    echo "============================================================"

    if [[ "$MODE" == "install" ]]; then
        execute_fresh_install
        return $?
    fi

    check_platform
    check_commands
    check_payload
    check_runtime_dependencies
    check_service_template
    check_config_template
    check_identity
    check_targets
    check_existing_service
    print_plan
    check_lab_safety
    print_summary

    [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
