#!/usr/bin/env bash
#
# NVU Dashboard Installer
# B6.2G-6A
#
# INSTALL SKELETON ONLY
#
# This version performs no installation mutations.

set -u

INSTALLER_VERSION="0.2.0-dev"

MODULE_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 &&
    pwd -P
)"
INSTALLER_ROOT="$(
    cd -- "${MODULE_DIR}/.." >/dev/null 2>&1 &&
    pwd -P
)"
PREFLIGHT_MODULE="$INSTALLER_ROOT/lib/preflight.sh"

INSTALL_PHASE="preflight"
INSTALL_STARTED=0

RELEASE_CREATED=0
VENV_CREATED=0
CURRENT_CREATED=0
SYSTEMD_CREATED=0
SERVICE_STARTED=0
SERVICE_ENABLED=0
CHECKPOINT_CREATED=0

usage() {
    cat <<EOF
NVU Dashboard Installer

Usage:
  install.sh.candidate

Version:
  $INSTALLER_VERSION
EOF
}

installer_fail() {
    local message="$1"

    echo
    echo "============================================================"
    echo "NVU DASHBOARD INSTALLATION NOT STARTED"
    echo "============================================================"
    echo
    echo "Phase:"
    echo "  $INSTALL_PHASE"
    echo
    echo "Reason:"
    echo "  $message"
    echo
    echo "Changes made:"
    echo "  none"

    return 0
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        installer_fail \
            "Installer must be run with sudo/root privileges."
        return 1
    fi

    echo "PASS: installer running with required privileges."
}

run_preflight() {
    local output
    local rc

    [[ -x "$PREFLIGHT_MODULE" ]] || {
        installer_fail \
            "Preflight module is unavailable."
        return 1
    }

    set +e

    output="$(
        "$PREFLIGHT_MODULE" 2>&1
    )"

    rc=$?

    set -e

    printf '%s\n' "$output"

    PREFLIGHT_RESULT="$(
        printf '%s\n' "$output" |
        awk '
            /^Result:/ {
                getline
                gsub(/^[[:space:]]+/, "", $0)
                print
                exit
            }
        '
    )"

    if [[ -z "$PREFLIGHT_RESULT" ]]; then
        installer_fail \
            "Preflight did not return a classification."
        return 1
    fi

    echo
    echo "Preflight classification:"
    echo "  $PREFLIGHT_RESULT"

    case "$PREFLIGHT_RESULT" in
        READY)
            return 0
            ;;

        INSTALLED)
            installer_fail \
                "NVU Dashboard is already installed. No changes made."
            return 2
            ;;

        UPGRADE_CANDIDATE)
            installer_fail \
                "Existing Dashboard requires the future upgrade/migration workflow. No changes made."
            return 2
            ;;

        REVIEW)
            installer_fail \
                "Operator review is required before installation."
            return 2
            ;;

        BLOCKED)
            installer_fail \
                "Installation prerequisites are blocked."
            return 3
            ;;

        *)
            installer_fail \
                "Unknown preflight classification: $PREFLIGHT_RESULT"
            return 1
            ;;
    esac
}

install_dashboard_dependencies() {
    INSTALL_PHASE="dependencies"

    echo
    echo "=== PHASE: dependencies ==="

    command -v apt-get >/dev/null 2>&1 || {
        installer_fail "apt-get is unavailable."
        return 1
    }

    if dpkg-query -W         -f='${db:Status-Abbrev}\n'         python3.14-venv 2>/dev/null |
        grep -Fxq 'ii '
    then
        echo "PASS: python3.14-venv already installed."
    else
        echo "Installing required Dashboard dependency: python3.14-venv"

        export DEBIAN_FRONTEND=noninteractive

        apt-get update || {
            installer_fail "Could not update package index."
            return 1
        }

        apt-get install -y --no-install-recommends             python3.14-venv || {
                installer_fail "Could not install python3.14-venv."
                return 1
            }
    fi

    dpkg-query -W         -f='${db:Status-Abbrev}\n'         python3.14-venv 2>/dev/null |
        grep -Fxq 'ii ' || {
            installer_fail "python3.14-venv is not installed after dependency phase."
            return 1
        }

    local test_venv

    test_venv="$(mktemp -d /tmp/nvu-dashboard-venv-test.XXXXXX)"

    if ! python3 -m venv "$test_venv"; then
        rm -rf -- "$test_venv"
        installer_fail "python3 venv capability test failed."
        return 1
    fi

    if [[ ! -x "$test_venv/bin/python" ||
          ! -x "$test_venv/bin/pip" ]]
    then
        rm -rf -- "$test_venv"
        installer_fail "temporary Python venv is incomplete."
        return 1
    fi

    rm -rf -- "$test_venv"

    echo "PASS: python3 venv capability verified."
}

install_release() {
    INSTALL_PHASE="release"

    local version="1.3.0"
    local root="/usr/local/lib/nvu/dashboard"
    local releases="$root/releases"
    local destination="$releases/$version"
    local staging="$root/.release-${version}.install"
    local source="${NVU_DASHBOARD_RELEASE_SOURCE:-$INSTALLER_ROOT/payload/dashboard/$version}"
    local inventory
    local expected_inventory

    [[ -d "$source" ]] || {
        installer_fail "Dashboard release payload is missing: $source"
        return 1
    }

    [[ ! -e "$destination" ]] || {
        installer_fail "Release $version already exists; refusing overwrite."
        return 2
    }

    [[ ! -e "$staging" ]] || {
        installer_fail "Release staging path already exists: $staging"
        return 2
    }

    expected_inventory="$(
        cat <<'EOF'
nvu_rpc.py
requirements.txt
server.py
static/app.js
static/index.html
static/nvu-dashboard-icon.png
static/nvu-favicon.ico
EOF
    )"

    inventory="$(
        find "$source"             -type f             ! -path '*/__pycache__/*'             ! -name '*.pyc'             -printf '%P\n' |
        sort
    )"

    [[ "$inventory" == "$expected_inventory" ]] || {
        installer_fail "Release payload inventory is invalid."
        return 1
    }

    if grep -RniE         --include='*.py'         --include='*.js'         --include='*.html'         '1\.2\.1|Umbrel|umbrel\.local|asicseer|stratum|blocks_found|/api/mining|/run/nvu-credentials'         "$source"         >/dev/null 2>&1
    then
        installer_fail "Release payload contains prohibited legacy coupling."
        return 1
    fi

    PYTHONDONTWRITEBYTECODE=1     python3 -m py_compile         "$source/server.py"         "$source/nvu_rpc.py" || {
            installer_fail "Release Python syntax validation failed."
            return 1
        }

    install         -d         -o root         -g nvu         -m 0750         "$root"         "$releases"         "$staging" || {
            installer_fail "Could not create release staging directories."
            return 1
        }

    while IFS= read -r relative_path; do
        local source_file="$source/$relative_path"
        local staged_file="$staging/$relative_path"
        local staged_parent

        staged_parent="$(dirname "$staged_file")"

        install             -d             -o root             -g nvu             -m 0750             "$staged_parent" || {
                rm -rf -- "$staging"
                installer_fail "Could not create staged release directory."
                return 1
            }

        install             -o root             -g nvu             -m 0640             "$source_file"             "$staged_file" || {
                rm -rf -- "$staging"
                installer_fail "Could not stage release file: $relative_path"
                return 1
            }
    done <<< "$inventory"

    while IFS= read -r relative_path; do
        cmp -s             "$source/$relative_path"             "$staging/$relative_path" || {
                rm -rf -- "$staging"
                installer_fail "Staged release verification failed: $relative_path"
                return 1
            }
    done <<< "$inventory"

    mv -T "$staging" "$destination" || {
        rm -rf -- "$staging"
        installer_fail "Could not promote staged release."
        return 1
    }

    RELEASE_CREATED=1

    [[ -d "$destination" ]] || {
        installer_fail "Installed release verification failed."
        return 1
    }

    echo "PASS: Dashboard release $version installed."
}

build_venv() {
    INSTALL_PHASE="venv"

    local root="/usr/local/lib/nvu/dashboard"
    local release="$root/releases/1.3.0"
    local requirements="$release/requirements.txt"
    local venv="$root/venv"
    local freeze="$root/pip-freeze.install.txt"

    [[ -f "$requirements" ]] || {
        installer_fail "Installed release requirements.txt is missing."
        return 1
    }

    [[ ! -e "$venv" ]] || {
        installer_fail "Production venv already exists; refusing overwrite."
        return 2
    }

    python3 -m venv "$venv" || {
        rm -rf -- "$venv"
        installer_fail "Could not create production venv."
        return 1
    }

    VENV_CREATED=1

    "$venv/bin/python" -m pip install         --requirement "$requirements" || {
            installer_fail "Could not install pinned Dashboard requirements."
            return 1
        }

    "$venv/bin/python" - <<'PYTHON'
from importlib.metadata import version

assert version("Flask") == "3.1.2"
assert version("gunicorn") == "23.0.0"
assert version("requests") == "2.32.5"
PYTHON

    if [[ "$?" -ne 0 ]]; then
        installer_fail "Production venv package qualification failed."
        return 1
    fi

    "$venv/bin/python" -m pip freeze |
        sort         > "$freeze" || {
            installer_fail "Could not record installed Python dependencies."
            return 1
        }

    chown -R root:nvu "$venv" || {
        installer_fail "Could not set production venv ownership."
        return 1
    }

    chmod -R g+rX,o-rwx "$venv" || {
        installer_fail "Could not set production venv permissions."
        return 1
    }

    chown root:nvu "$freeze" || {
        installer_fail "Could not set dependency-record ownership."
        return 1
    }

    chmod 0640 "$freeze" || {
        installer_fail "Could not set dependency-record permissions."
        return 1
    }

    [[ -x "$venv/bin/python" &&
       -x "$venv/bin/gunicorn" ]] || {
        installer_fail "Production venv executables are unavailable."
        return 1
    }

    echo "PASS: production venv created."
    echo "PASS: pinned Dashboard dependencies installed."
}

create_current() {
    INSTALL_PHASE="current"

    local root="/usr/local/lib/nvu/dashboard"
    local release="$root/releases/1.3.0"
    local current="$root/current"
    local temporary="$root/.current.install"

    [[ -d "$release" ]] || {
        installer_fail "Installed release 1.3.0 is missing."
        return 1
    }

    [[ ! -e "$current" && ! -L "$current" ]] || {
        installer_fail "current already exists; refusing fresh-install overwrite."
        return 2
    }

    rm -f "$temporary"

    ln -s "releases/1.3.0" "$temporary" || {
        installer_fail "Could not create temporary current symlink."
        return 1
    }

    mv -T "$temporary" "$current" || {
        rm -f "$temporary"
        installer_fail "Could not promote current symlink."
        return 1
    }

    [[ "$(readlink "$current")" == "releases/1.3.0" ]] || {
        installer_fail "current symlink verification failed."
        return 1
    }

    echo "PASS: current -> releases/1.3.0"
}

install_systemd() {
    INSTALL_PHASE="systemd"

    local template="$INSTALLER_ROOT/templates/nvu-dashboard-unix.service.candidate"
    local unit="/etc/systemd/system/nvu-dashboard.service"
    local verify="/tmp/nvu-dashboard-install-verify.service"

    [[ -f "$template" ]] || {
        installer_fail "Qualified Unix-socket systemd template is missing."
        return 1
    }

    [[ ! -e "$unit" ]] || {
        installer_fail "nvu-dashboard.service already exists; refusing overwrite."
        return 2
    }

    rm -f "$verify"

    install -o root -g root -m 0644 "$template" "$verify" || {
        installer_fail "Could not prepare systemd verification unit."
        return 1
    }

    systemd-analyze verify "$verify" >/dev/null 2>&1
    local verify_rc=$?

    rm -f "$verify"

    [[ "$verify_rc" -eq 0 ]] || {
        installer_fail "Unix-socket systemd template failed validation."
        return 1
    }

    install -o root -g root -m 0644 "$template" "$unit" || {
        installer_fail "Could not install nvu-dashboard.service."
        return 1
    }

    systemctl daemon-reload || {
        installer_fail "systemd daemon-reload failed."
        return 1
    }

    echo "PASS: Unix-socket systemd service installed."
}

start_dashboard() {
    INSTALL_PHASE="start"

    local socket="/run/nvu-dashboard/nvu-dashboard.sock"

    systemctl start nvu-dashboard.service || {
        installer_fail "Dashboard service failed to start."
        return 1
    }

    for unused in $(seq 1 30); do
        if systemctl is-active --quiet nvu-dashboard.service &&
           [[ -S "$socket" ]]
        then
            echo "PASS: Dashboard service active."
            echo "PASS: Unix socket created."
            return 0
        fi

        sleep 1
    done

    installer_fail "Dashboard service did not create its Unix socket."
    return 1
}

qualify_local() {
    INSTALL_PHASE="qualify"

    local socket="/run/nvu-dashboard/nvu-dashboard.sock"
    local origin="http://localhost"
    local response

    [[ -S "$socket" ]] || {
        installer_fail "Dashboard Unix socket is missing."
        return 1
    }

    response="$(
        curl             --silent             --show-error             --fail             --max-time 10             --unix-socket "$socket"             "$origin/api/version"
    )" || {
        installer_fail "Dashboard version API failed through Unix socket."
        return 1
    }

    printf '%s\n' "$response" |
        jq -e             '.dashboardVersion == "1.3.0" and .ticker == "NVU"'             >/dev/null || {
                installer_fail "Dashboard version qualification failed."
                return 1
            }

    response="$(
        curl             --silent             --show-error             --fail             --max-time 10             --unix-socket "$socket"             "$origin/api/status"
    )" || {
        installer_fail "Dashboard status API failed through Unix socket."
        return 1
    }

    printf '%s\n' "$response" |
        jq -e             '.ok == true
             and .nvun.online == true
             and .nvun.chain == "main"
             and .nvun.initialBlockDownload == false'             >/dev/null || {
                installer_fail "Dashboard runtime qualification failed."
                return 1
            }

    if ss -lntp 2>/dev/null |
        grep -Eq             '127\.0\.0\.1:8080[[:space:]].*nvu-dashboard|0\.0\.0\.0:8080[[:space:]].*nvu-dashboard'
    then
        installer_fail "Dashboard unexpectedly exposes a TCP backend."
        return 1
    fi

    echo "PASS: Dashboard version qualified through Unix socket."
    echo "PASS: NVUN online and synchronized."
    echo "PASS: no Dashboard TCP backend detected."
}

enable_dashboard() {
    INSTALL_PHASE="enable"

    systemctl is-active --quiet nvu-dashboard.service || {
        installer_fail "Dashboard is not active; refusing enablement."
        return 1
    }

    [[ -S /run/nvu-dashboard/nvu-dashboard.sock ]] || {
        installer_fail "Dashboard Unix socket is missing; refusing enablement."
        return 1
    }

    systemctl enable nvu-dashboard.service || {
        installer_fail "Could not enable Dashboard service."
        return 1
    }

    systemctl is-enabled --quiet nvu-dashboard.service || {
        installer_fail "Dashboard service enablement verification failed."
        return 1
    }

    echo "PASS: Dashboard service enabled."
}

create_checkpoint() {
    INSTALL_PHASE="checkpoint"

    local root="/usr/local/lib/nvu/dashboard"
    local release="$root/releases/1.3.0"
    local current="$root/current"
    local unit="/etc/systemd/system/nvu-dashboard.service"
    local checkpoint_root="$root/checkpoints"
    local checkpoint="$checkpoint_root/install-1.3.0"
    local socket="/run/nvu-dashboard/nvu-dashboard.sock"

    [[ -d "$release" ]] || {
        installer_fail "Cannot checkpoint: installed release is missing."
        return 1
    }

    [[ -L "$current" ]] || {
        installer_fail "Cannot checkpoint: current symlink is missing."
        return 1
    }

    [[ "$(readlink "$current")" == "releases/1.3.0" ]] || {
        installer_fail "Cannot checkpoint: current target is unexpected."
        return 1
    }

    [[ -f "$unit" ]] || {
        installer_fail "Cannot checkpoint: systemd unit is missing."
        return 1
    }

    [[ -S "$socket" ]] || {
        installer_fail "Cannot checkpoint: Unix socket is missing."
        return 1
    }

    [[ ! -e "$checkpoint" ]] || {
        installer_fail "Installation checkpoint already exists."
        return 1
    }

    install         -d         -o root         -g nvu         -m 0750         "$checkpoint_root"         "$checkpoint" || {
            installer_fail "Could not create installation checkpoint."
            return 1
        }

    find "$release"         -type f         -print0 |
        sort -z |
        xargs -0 sha256sum         > "$checkpoint/SHA256SUMS.release" || {
            installer_fail "Could not record release checksums."
            return 1
        }

    "$root/venv/bin/python" -m pip freeze |
        sort         > "$checkpoint/pip-freeze.txt" || {
            installer_fail "Could not record Python dependency state."
            return 1
        }

    cp -a         "$unit"         "$checkpoint/nvu-dashboard.service" || {
            installer_fail "Could not checkpoint systemd unit."
            return 1
        }

    {
        echo "NVU Dashboard Installation Checkpoint"
        echo
        echo "Installer:"
        echo "  $INSTALLER_VERSION"
        echo
        echo "Dashboard:"
        echo "  1.3.0"
        echo
        echo "Current:"
        echo "  $(readlink "$current")"
        echo
        echo "Backend:"
        echo "  unix"
        echo
        echo "Socket:"
        echo "  $socket"
        echo
        echo "Service:"
        echo "  $(systemctl is-active nvu-dashboard.service)"
        echo "  $(systemctl is-enabled nvu-dashboard.service)"
        echo
        echo "NVUN:"
        echo "  $(systemctl is-active nvun.service)"
    } > "$checkpoint/state.txt" || {
        installer_fail "Could not record checkpoint state."
        return 1
    }

    sha256sum         "$checkpoint/SHA256SUMS.release"         "$checkpoint/pip-freeze.txt"         "$checkpoint/nvu-dashboard.service"         "$checkpoint/state.txt"         > "$checkpoint/SHA256SUMS.checkpoint" || {
            installer_fail "Could not checksum installation checkpoint."
            return 1
        }

    chown -R root:nvu "$checkpoint" || {
        installer_fail "Could not set checkpoint ownership."
        return 1
    }

    find "$checkpoint"         -type d         -exec chmod 0750 {} + || {
            installer_fail "Could not set checkpoint directory permissions."
            return 1
        }

    find "$checkpoint"         -type f         -exec chmod 0640 {} + || {
            installer_fail "Could not set checkpoint file permissions."
            return 1
        }

    CHECKPOINT_CREATED=1

    echo "PASS: installation checkpoint created."
}

rollback_installation() {
    local rollback_failed=0
    local root="/usr/local/lib/nvu/dashboard"
    local release="$root/releases/1.3.0"
    local venv="$root/venv"
    local current="$root/current"
    local unit="/etc/systemd/system/nvu-dashboard.service"

    echo
    echo "=== INSTALLATION ROLLBACK ==="

    if [[ "$SERVICE_ENABLED" -eq 1 ]]; then
        systemctl disable nvu-dashboard.service             >/dev/null 2>&1 || rollback_failed=1
    fi

    if [[ "$SERVICE_STARTED" -eq 1 ]]; then
        systemctl stop nvu-dashboard.service             >/dev/null 2>&1 || rollback_failed=1
    fi

    if [[ "$SYSTEMD_CREATED" -eq 1 ]]; then
        rm -f "$unit" || rollback_failed=1
        systemctl daemon-reload || rollback_failed=1
    fi

    if [[ "$CURRENT_CREATED" -eq 1 ]]; then
        if [[ -L "$current" &&
              "$(readlink "$current")" == "releases/1.3.0" ]]
        then
            rm -f "$current" || rollback_failed=1
        else
            echo "WARNING: current was not removed because it no longer matches."
            rollback_failed=1
        fi
    fi

    if [[ "$VENV_CREATED" -eq 1 ]]; then
        rm -rf -- "$venv" || rollback_failed=1
    fi

    if [[ "$RELEASE_CREATED" -eq 1 ]]; then
        rm -rf -- "$release" || rollback_failed=1
    fi

    if [[ "$CHECKPOINT_CREATED" -eq 1 ]]; then
        echo "NOTE: checkpoint cleanup remains B6.2G-6F."
    fi

    # Remove artifacts created outside the release/venv/current paths.
    rm -f "$root/pip-freeze.install.txt" || rollback_failed=1

    # Remove fresh-install parent directories only when empty.
    rmdir "$releases" 2>/dev/null || true
    rmdir "$root" 2>/dev/null || true

    if [[ "$rollback_failed" -eq 0 ]]; then
        echo "Rollback status:"
        echo "  PASS"
        return 0
    fi

    echo "Rollback status:"
    echo "  REVIEW REQUIRED"
    return 1
}

run_install_phase() {
    local phase_name="$1"
    local phase_function="$2"
    local rc

    INSTALL_PHASE="$phase_name"

    echo
    echo "=== PHASE: $phase_name ==="

    set +e
    "$phase_function"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        echo
        echo "FAILED PHASE:"
        echo "  $phase_name"

        rollback_installation || true
        return "$rc"
    fi

    echo "PASS: phase completed: $phase_name"
    return 0
}

install_main() {
    local rc

    echo "============================================================"
    echo "NVU DASHBOARD INSTALLER"
    echo "VERSION: $INSTALLER_VERSION"
    echo "B6.2G-6E"
    echo "============================================================"

    echo
    echo "=== ROOT CHECK ==="

    require_root || return $?

    echo
    echo "=== INSTALLATION PREFLIGHT ==="

    INSTALL_PHASE="preflight"

    set +e
    run_preflight
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        return "$rc"
    fi

    echo
    echo "============================================================"
    echo "PREFLIGHT RESULT: READY"
    echo "============================================================"

    INSTALL_STARTED=1

    run_install_phase "dependencies" install_dashboard_dependencies || return $?

    run_install_phase "release" install_release || return $?
    RELEASE_CREATED=1

    run_install_phase "venv" build_venv || return $?
    VENV_CREATED=1

    run_install_phase "current" create_current || return $?
    CURRENT_CREATED=1

    run_install_phase "systemd" install_systemd || return $?
    SYSTEMD_CREATED=1

    run_install_phase "start" start_dashboard || return $?
    SERVICE_STARTED=1

    run_install_phase "qualify" qualify_local || return $?

    run_install_phase "enable" enable_dashboard || return $?
    SERVICE_ENABLED=1

    run_install_phase "checkpoint" create_checkpoint || return $?
    CHECKPOINT_CREATED=1

    echo
    echo "============================================================"
    echo "NVU DASHBOARD INSTALLATION PASSED"
    echo "============================================================"
    echo
    echo "Release:"
    echo "  1.3.0"
    echo
    echo "Backend:"
    echo "  unix"
    echo
    echo "Socket:"
    echo "  /run/nvu-dashboard/nvu-dashboard.sock"
    echo
    echo "Public web:"
    echo "  not configured"
    echo
    echo "NEXT:"
    echo "  sudo nvu-dashboard configure-web"

    return 0
}

install_main "$@"
