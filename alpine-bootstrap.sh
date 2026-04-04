#!/bin/sh
set -eu

# Alpine Minimal AI-Host Bootstrap
# Supports Podman or Docker as primary container engine
# Idempotent with persistent engine role tracking
#
# Usage:
#   ./alpine-bootstrap.sh                           # Use defaults (Podman, edge/testing enabled)
#   ./alpine-bootstrap.sh --engine docker           # Force Docker
#   ./alpine-bootstrap.sh --disable-testing-repos   # Disable edge/testing
#   ./alpine-bootstrap.sh --skip-ssh-keys           # Skip GitHub key bootstrap
#   ./alpine-bootstrap.sh --run-setup-apkrepos      # Opt-in: run setup-apkrepos helper
#   ./alpine-bootstrap.sh --force-engine-switch     # Allow switching from saved engine choice
#   ./alpine-bootstrap.sh --no-bash                 # Skip Bash tooling install
#   ./alpine-bootstrap.sh --no-fish                 # Skip Fish install/config
#   ./alpine-bootstrap.sh --no-color                # Disable colored output
#   ./alpine-bootstrap.sh --help                    # Show CLI help
#
# Environment Variables:
#   NO_COLOR=1                                     # Disable colors (standard)

# ============================================================================
# Configuration & Constants
# ============================================================================

STATE_DIR="/etc/alpine-bootstrap"
STATE_FILE="${STATE_DIR}/state.env"
GITHUB_USER="jdries3"
LOG_PREFIX="[alpine-bootstrap]"

# Package sets (whitespace/newline separated for easy editing)
BASE_PACKAGES="
atuin
btop
curl
dbus
dust
eza
fuse-overlayfs
fzf
jq
lazydocker
ncurses-terminfo
nushell
openssh
ripgrep
starship
trippy@testing
wget
yq-go
zellij
"

PODMAN_PACKAGES="
podman
podman-compose
podman-tui
iptables
ip6tables
slirp4netns
"

DOCKER_PACKAGES="
docker
docker-cli
docker-compose
containerd
iptables
ip6tables
"

BASH_OPTIONAL_PACKAGES="
bash
bash-completion
"

FISH_OPTIONAL_PACKAGES="
fish
"

TESTING_REPOS_ENABLED=1

# ANSI Color Codes (will be empty if colors disabled)
C_RESET=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""
C_BOLD=""

# Determine if colors should be used
# Check: NO_COLOR env var, --no-color flag, or if stdout is not a tty
USE_COLORS=1
if [ -n "${NO_COLOR:-}" ]; then
    USE_COLORS=0
elif ! [ -t 1 ]; then
    # stdout is not a tty (e.g., piped), disable colors
    USE_COLORS=0
fi

# Parse CLI arguments
ENGINE_OVERRIDE=""
DISABLE_TESTING_REPOS=0
SKIP_SSH_KEYS=0
RUN_SETUP_APKREPOS=0
FORCE_ENGINE_SWITCH=0
INSTALL_BASH=1
INSTALL_FISH=1
BASH_SET_BY_CLI=0
FISH_SET_BY_CLI=0

# Global: set by determine_engine; avoids command-substitution stdout capture
SELECTED_ENGINE=""

while [ $# -gt 0 ]; do
    case "$1" in
                -h|--help)
                        cat << EOF
Usage: $(basename "$0") [options]

Options:
    --engine <podman|docker>   Use a specific container engine
    --force-engine-switch      Allow switching from saved engine selection
    --disable-testing-repos    Disable edge/testing repository entries
    --run-setup-apkrepos       Run setup-apkrepos helper (interactive when available)
    --skip-setup-apkrepos      Backward-compatible no-op (skipping is default)
    --skip-ssh-keys            Skip GitHub SSH key bootstrap
    --no-bash                  Skip Bash + bash-completion installation
    --install-bash             Force-enable Bash tooling (default)
    --no-fish                  Skip Fish installation and Fish config/completions
    --install-fish             Force-enable Fish tooling (default)
    --no-color                 Disable colored output
    -h, --help                 Show this help text and exit

Defaults:
    Engine: podman (unless saved state exists)
    Testing repos: enabled
    SSH bootstrap: enabled
    Bash tooling: enabled
    Fish tooling: enabled
EOF
                        exit 0
                        ;;
        --engine)
            ENGINE_OVERRIDE="$2"
            shift 2
            ;;
        --disable-testing-repos)
            DISABLE_TESTING_REPOS=1
            shift
            ;;
        --skip-ssh-keys)
            SKIP_SSH_KEYS=1
            shift
            ;;
        --run-setup-apkrepos)
            RUN_SETUP_APKREPOS=1
            shift
            ;;
        --skip-setup-apkrepos)
            # Backward-compatible no-op: skipping is now the default.
            RUN_SETUP_APKREPOS=0
            shift
            ;;
        --force-engine-switch)
            FORCE_ENGINE_SWITCH=1
            shift
            ;;
        --no-color)
            USE_COLORS=0
            shift
            ;;
        --install-bash)
            INSTALL_BASH=1
            BASH_SET_BY_CLI=1
            shift
            ;;
        --no-bash)
            INSTALL_BASH=0
            BASH_SET_BY_CLI=1
            shift
            ;;
        --install-fish)
            INSTALL_FISH=1
            FISH_SET_BY_CLI=1
            shift
            ;;
        --no-fish)
            INSTALL_FISH=0
            FISH_SET_BY_CLI=1
            shift
            ;;
        *)
            echo "${LOG_PREFIX} Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Initialize color codes if colors are enabled.
# Use printf '\033' to generate a real ESC byte — busybox ash single-quoted
# strings are literal, so '\033[1m' would be 7 chars of text, not an escape.
if [ "${USE_COLORS}" = 1 ]; then
    _esc=$(printf '\033')
    C_RESET="${_esc}[0m"
    C_RED="${_esc}[0;31m"
    C_GREEN="${_esc}[0;32m"
    C_YELLOW="${_esc}[1;33m"
    C_BLUE="${_esc}[0;34m"
    C_CYAN="${_esc}[0;36m"
    C_BOLD="${_esc}[1m"
    unset _esc
fi

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    printf "%s%s%s %s\n" "${C_CYAN}" "${LOG_PREFIX}" "${C_RESET}" "$*" >&2
}

log_success() {
    printf "%s%s SUCCESS:%s %s\n" "${C_GREEN}" "${LOG_PREFIX}" "${C_RESET}" "$*" >&2
}

log_warn() {
    printf "%s%s WARNING:%s %s\n" "${C_YELLOW}" "${LOG_PREFIX}" "${C_RESET}" "$*" >&2
}

log_error() {
    printf "%s%s ERROR:%s %s\n" "${C_RED}" "${LOG_PREFIX}" "${C_RESET}" "$*" >&2
}

log_prompt() {
    printf "%s%s PROMPT:%s %s\n" "${C_BOLD}${C_BLUE}" "${LOG_PREFIX}" "${C_RESET}" "$*" >&2
}

log_section() {
    printf "%s%s%s\n" "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}" >&2
}

die() {
    log_error "$*"
    exit 1
}

ensure_line_in_file() {
    local file_path="$1"
    local line_text="$2"

    if [ ! -f "${file_path}" ]; then
        : > "${file_path}"
    fi

    if ! grep -Fqx "${line_text}" "${file_path}" 2>/dev/null; then
        printf "%s\n" "${line_text}" >> "${file_path}"
    fi
}

backup_once() {
    local file_path="$1"
    local backup_path="${file_path}.orig"

    if [ -f "${file_path}" ] && [ ! -f "${backup_path}" ]; then
        cp "${file_path}" "${backup_path}"
    fi
}

ensure_toml_key() {
    local file_path="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local temp_file

    temp_file="$(mktemp)"

    if [ ! -f "${file_path}" ]; then
        mkdir -p "$(dirname "${file_path}")"
        {
            printf "%s\n" "${section}"
            printf "%s = %s\n" "${key}" "${value}"
        } > "${file_path}"
        rm -f "${temp_file}"
        return 0
    fi

    backup_once "${file_path}"

    awk -v section="${section}" -v key="${key}" -v value="${value}" '
BEGIN {
    in_section = 0
    section_seen = 0
    key_set = 0
}
{
    if ($0 ~ /^\[[^]]+\][[:space:]]*$/) {
        if (in_section && !key_set) {
            print key " = " value
            key_set = 1
        }
        in_section = ($0 == section)
        if (in_section) {
            section_seen = 1
            key_set = 0
        }
        print
        next
    }

    if (in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        print key " = " value
        key_set = 1
        next
    }

    print
}
END {
    if (in_section && !key_set) {
        print key " = " value
    }
    if (!section_seen) {
        if (NR > 0) {
            print ""
        }
        print section
        print key " = " value
    }
}
' "${file_path}" > "${temp_file}"

    mv "${temp_file}" "${file_path}"
}

ensure_docker_storage_driver() {
    local file_path="/etc/docker/daemon.json"
    local temp_file

    mkdir -p /etc/docker

    if [ ! -f "${file_path}" ] || [ ! -s "${file_path}" ]; then
        cat > "${file_path}" << 'EOF'
{
  "storage-driver": "fuse-overlayfs"
}
EOF
        return 0
    fi

    backup_once "${file_path}"

    if grep -Eq '"storage-driver"[[:space:]]*:' "${file_path}"; then
        sed -E '0,/"storage-driver"[[:space:]]*:[[:space:]]*"[^"]*"/s//"storage-driver": "fuse-overlayfs"/' "${file_path}" > "${file_path}.tmp"
        mv "${file_path}.tmp" "${file_path}"
        return 0
    fi

    temp_file="$(mktemp)"
    awk '
{ lines[NR] = $0 }
END {
    close_idx = 0
    for (i = NR; i >= 1; i--) {
        if (lines[i] ~ /^[[:space:]]*}$/) {
            close_idx = i
            break
        }
    }

    if (close_idx == 0) {
        print "{"
        print "  \"storage-driver\": \"fuse-overlayfs\""
        print "}"
        exit
    }

    prev = close_idx - 1
    while (prev >= 1 && lines[prev] ~ /^[[:space:]]*$/) {
        prev--
    }

    for (i = 1; i <= NR; i++) {
        if (i == prev && prev >= 1 && lines[prev] !~ /{[[:space:]]*$/ && lines[prev] !~ /,[[:space:]]*$/) {
            print lines[i] ","
            continue
        }

        if (i == close_idx) {
            if (prev >= 1 && lines[prev] ~ /{[[:space:]]*$/) {
                print "  \"storage-driver\": \"fuse-overlayfs\""
            } else if (prev < 1) {
                print "{"
                print "  \"storage-driver\": \"fuse-overlayfs\""
            } else {
                print "  \"storage-driver\": \"fuse-overlayfs\""
            }
            print lines[i]
            continue
        }

        print lines[i]
    }
}
' "${file_path}" > "${temp_file}"

    mv "${temp_file}" "${file_path}"
}

# Enable and start an OpenRC service
enable_service() {
    local service_name="$1"
    local display_name="${2:-$service_name}"

    # Check if service exists
    if ! rc-service --list 2>/dev/null | grep -q "${service_name}"; then
        log_warn "Service '${service_name}' not found, skipping"
        return 1
    fi

    # Add to default runlevel if not already enabled
    if ! rc-update show default 2>/dev/null | grep -q -w "${service_name}"; then
        rc-update add "${service_name}" default
        log_info "Enabled ${display_name} service"
    fi

    # Start the service
    if rc-service "${service_name}" start 2>/dev/null; then
        return 0
    else
        log_warn "Failed to start ${display_name} service"
        return 1
    fi
}

normalize_package_name() {
    local pkg="$1"
    # Strip repo selector suffix (e.g., trippy@testing -> trippy)
    printf "%s\n" "${pkg%@*}"
}

is_package_installed() {
    local pkg_raw="$1"
    local pkg
    pkg="$(normalize_package_name "${pkg_raw}")"
    apk info -e "${pkg}" >/dev/null 2>&1
}

install_package_set() {
    local set_name="$1"
    local set_values="$2"
    local add_testing="$3"
    local pkg
    local install_list=""
    local has_packages=0

    log_info "Installing ${set_name}..."

    # Build a single apk invocation so output is less noisy and install is faster.
    for pkg in ${set_values}; do
        case "${pkg}" in
            *@testing)
                if [ "${add_testing}" != "1" ]; then
                    log_warn "Skipping ${pkg} because testing repositories are disabled"
                    continue
                fi
                ;;
        esac

        if is_package_installed "${pkg}"; then
            continue
        fi

        install_list="${install_list} ${pkg}"
        has_packages=1
    done

    if [ "${has_packages}" != "1" ]; then
        log_info "All ${set_name} are already installed; skipping"
        return 0
    fi

    log_info "Packages queued for ${set_name}:"
    for pkg in ${install_list}; do
        log_info "  - ${pkg}"
    done

    # Deliberate word-splitting of package list.
    # shellcheck disable=SC2086
    apk add --no-cache -q -q ${install_list}
    log_success "Installed ${set_name}"
}

build_unique_tool_list() {
    local combined="$1"
    # Normalize package names and dedupe while preserving first-seen order.
    printf "%s\n" "${combined}" \
        | sed '/^[[:space:]]*$/d' \
        | sed 's/@.*$//' \
        | awk '!seen[$0]++'
}

# Try to install a completion package if it exists
try_install_completion() {
    local tool_raw="$1"
    local shell="$2"
    local tool
    tool="$(normalize_package_name "${tool_raw}")"

    # Handle special cases (e.g., docker-cli instead of docker)
    local pkg_name="${tool}-${shell}-completion"
    case "${tool}" in
        docker)
            pkg_name="docker-cli-${shell}-completion"
            ;;
    esac

    # Search for the completion package
    if apk search "${pkg_name}" 2>/dev/null | grep -q "^${pkg_name}"; then
        if is_package_installed "${pkg_name}"; then
            return 0
        fi

        if apk add --no-cache -q -q "${pkg_name}" 2>/dev/null; then
            log_info "Installed ${pkg_name}"
            return 0
        fi
    fi
    return 1
}

# Determine the container engine for this host.
# Sets the SELECTED_ENGINE global variable; does NOT use echo/stdout so it is
# safe to call without command substitution.
# Requires: ENGINE_OVERRIDE, FORCE_ENGINE_SWITCH (from CLI) and BOOTSTRAP_ENGINE
# (from state file, sourced by main before this is called).
determine_engine() {
    local saved_engine="${BOOTSTRAP_ENGINE:-}"

    # If engine was explicitly set via CLI, use it
    if [ -n "${ENGINE_OVERRIDE}" ]; then
        if [ -n "${saved_engine}" ] && [ "${saved_engine}" != "${ENGINE_OVERRIDE}" ]; then
            if [ "${FORCE_ENGINE_SWITCH}" = 1 ]; then
                log_warn "Switching engine from ${saved_engine} to ${ENGINE_OVERRIDE} (forced)"
            else
                die "Engine mismatch: saved=${saved_engine}, requested=${ENGINE_OVERRIDE}. Use --force-engine-switch to override."
            fi
        fi
        SELECTED_ENGINE="${ENGINE_OVERRIDE}"
        return 0
    fi

    # If we have a saved choice and no override, use it
    if [ -n "${saved_engine}" ]; then
        log_info "Using saved engine: ${saved_engine}"
        SELECTED_ENGINE="${saved_engine}"
        return 0
    fi

    # Default to Podman
    log_info "No saved engine found; defaulting to Podman"
    SELECTED_ENGINE="podman"
}

# ============================================================================
# Repository Configuration
# ============================================================================

configure_repositories() {
    local add_testing=$1
    TESTING_REPOS_ENABLED="${add_testing}"
    local alpine_version
    local repo_file="/etc/apk/repositories"

    ensure_repo_enabled() {
        local repo_name=$1
        local repo_url="https://dl-cdn.alpinelinux.org/alpine/v${alpine_version}/${repo_name}"
        local repo_pattern="^[[:space:]]*#[[:space:]]*https?://[^[:space:]]*/v${alpine_version}/${repo_name}([[:space:]]|$)"
        local tmp_file
        local line

        if grep -Eq "^[[:space:]]*https?://[^[:space:]]*/v${alpine_version}/${repo_name}([[:space:]]|$)" "${repo_file}"; then
            return 0
        fi

        if grep -Eq "${repo_pattern}" "${repo_file}"; then
            tmp_file=$(mktemp)
            while IFS= read -r line || [ -n "${line}" ]; do
                if printf '%s\n' "${line}" | grep -Eq "${repo_pattern}"; then
                    printf '%s\n' "${repo_url}" >> "${tmp_file}"
                else
                    printf '%s\n' "${line}" >> "${tmp_file}"
                fi
            done < "${repo_file}"
            mv "${tmp_file}" "${repo_file}"
            log_info "Uncommented ${repo_name} repository"
            return 0
        fi

        printf '%s\n' "${repo_url}" >> "${repo_file}"
        log_info "Added ${repo_name} repository"
    }

    log_info "Configuring package repositories..."

    # Use Alpine's repo setup tool when available to enable community repos.
    # Keep stdin connected to a TTY when available so user prompts still work.
    if [ "${RUN_SETUP_APKREPOS}" = 1 ]; then
        if command -v setup-apkrepos >/dev/null 2>&1; then
            log_info "Running setup-apkrepos -cf (may prompt for input)"
            if [ -t 0 ] && [ -r /dev/tty ]; then
                setup-apkrepos -cf </dev/tty || log_warn "setup-apkrepos -cf failed; keeping existing repository file"
            else
                setup-apkrepos -cf </dev/null || log_warn "setup-apkrepos -cf failed in non-interactive mode; keeping existing repository file"
            fi
        else
            log_info "setup-apkrepos not found; managing /etc/apk/repositories directly"
        fi
    else
        log_info "Skipping setup-apkrepos helper by default (use --run-setup-apkrepos to opt in)"
    fi

    alpine_version=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | cut -d. -f1,2)
    if [ -z "${alpine_version}" ]; then
        alpine_version="v3.23"
    fi

    # Ensure stable main/community are present and uncommented.
    ensure_repo_enabled "main"
    ensure_repo_enabled "community"

    # Enforce HTTPS for configured repositories.
    sed -i 's#^http://#https://#' "${repo_file}"

    # Handle testing repos
    if [ "${add_testing}" = 1 ]; then
        if ! grep -q "@testing" "${repo_file}"; then
            echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> "${repo_file}"
            log_info "Added @testing repository"
        fi
    else
        # Remove testing repos if present
        sed -i '/@testing/d' "${repo_file}"
        log_info "Removed edge/testing repository entries"
    fi

    log_success "Repository configuration complete"
}

# ============================================================================
# System Preparation
# ============================================================================

prepare_system() {
    log_info "Preparing system..."
    local running_kernel
    local modules_dir

    # Required for container runtimes in many LXC environments.
    if grep -q '^rc_cgroup_mode=' /etc/rc.conf 2>/dev/null; then
        sed -i 's/^rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' /etc/rc.conf
    else
        printf '%s\n' 'rc_cgroup_mode="unified"' >> /etc/rc.conf
    fi

    # Ensure /lib/modules exists (some package hooks expect it)
    if [ ! -d /lib/modules ]; then
        log_info "Creating /lib/modules directory"
        mkdir -p /lib/modules
    fi

    # Some APK post-install hooks try to access /lib/modules/$(uname -r).
    # Creating this directory avoids noisy modprobe errors on container/VM hosts.
    running_kernel="$(uname -r 2>/dev/null || true)"
    if [ -n "${running_kernel}" ] && [ ! -d "/lib/modules/${running_kernel}" ]; then
        log_info "Creating /lib/modules/${running_kernel} compatibility directory"
        mkdir -p "/lib/modules/${running_kernel}"
    fi

    # Some package maintainer scripts call modprobe, which expects metadata files
    # under /lib/modules/$(uname -r). In minimal LXC environments these files can
    # be absent, producing noisy warnings even though installation succeeds.
    if [ -n "${running_kernel}" ]; then
        modules_dir="/lib/modules/${running_kernel}"
        mkdir -p "${modules_dir}"
        [ -f "${modules_dir}/modules.dep" ] || : > "${modules_dir}/modules.dep"
        [ -f "${modules_dir}/modules.alias" ] || : > "${modules_dir}/modules.alias"
        [ -f "${modules_dir}/modules.symbols" ] || : > "${modules_dir}/modules.symbols"
    fi

    # Update package index
    log_info "Updating package index..."
    apk update

    # Upgrade existing packages
    log_info "Upgrading installed packages..."
    apk upgrade -q

    log_success "System preparation complete"
}

# ============================================================================
# Package Installation
# ============================================================================

install_base_tools() {
    local base_values="${BASE_PACKAGES}"

    if [ "${INSTALL_FISH}" = 1 ]; then
        base_values="${base_values} ${FISH_OPTIONAL_PACKAGES}"
    else
        log_info "Skipping Fish install (--no-fish)"
    fi

    install_package_set "base packages" "${base_values}" "${TESTING_REPOS_ENABLED}"
}

install_optional_bash() {
    if [ "${INSTALL_BASH}" = 1 ]; then
        install_package_set "optional bash packages" "${BASH_OPTIONAL_PACKAGES}" "${TESTING_REPOS_ENABLED}"
    else
        log_info "Skipping Bash install (--no-bash)"
    fi
}

configure_podman_compat() {
    log_info "Configuring Podman Docker-compatible socket access..."

    # Prefer Podman's native API socket path for Docker-compatible clients.
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/podman-docker-host.sh << 'EOF'
export DOCKER_HOST=unix:///run/podman/podman.sock
EOF
    chmod 644 /etc/profile.d/podman-docker-host.sh

    if [ -S /run/podman/podman.sock ]; then
        if [ ! -e /var/run/docker.sock ]; then
            ln -s /run/podman/podman.sock /var/run/docker.sock
            log_info "Linked /var/run/docker.sock -> /run/podman/podman.sock"
        fi
    else
        log_warn "Podman socket not found at /run/podman/podman.sock; docker-compatible clients may require DOCKER_HOST"
    fi

    log_success "Podman compatibility socket configuration complete"
}

install_podman() {
    install_package_set "podman packages" "${PODMAN_PACKAGES}" "${TESTING_REPOS_ENABLED}"

    # Use fuse-overlayfs-backed overlay storage for Podman in ZFS-backed LXC.
    ensure_toml_key /etc/containers/storage.conf '[storage]' 'driver' '"overlay"'
    ensure_toml_key /etc/containers/storage.conf '[storage.options.overlay]' 'mount_program' '"/usr/bin/fuse-overlayfs"'

    # Enable required services
    enable_service "cgroups" "cgroups"
    enable_service "podman" "Podman"

    configure_podman_compat

    log_success "Podman installation complete"
}

install_docker() {
    install_package_set "docker packages" "${DOCKER_PACKAGES}" "${TESTING_REPOS_ENABLED}"

        # Use fuse-overlayfs storage driver for Docker in ZFS-backed LXC.
        ensure_docker_storage_driver

    # Enable required services
    enable_service "cgroups" "cgroups"
    enable_service "docker" "Docker"

    # Ensure docker.sock is properly created and accessible
    if [ -S /var/run/docker.sock ]; then
        chmod 660 /var/run/docker.sock
        log_info "Docker socket permissions set"
    fi

    log_success "Docker installation complete"
}

install_completions() {
    local consolidated_packages="$1"
    local tools

    log_info "Installing shell completions from Alpine packages..."

    tools="$(build_unique_tool_list "${consolidated_packages}")"

    # Install fish completions only when fish tooling is enabled.
    if [ "${INSTALL_FISH}" = 1 ]; then
        for tool in ${tools}; do
            try_install_completion "${tool}" "fish" || true
        done
    fi

    # Install bash completions only if --install-bash was specified
    if [ "${INSTALL_BASH}" = 1 ]; then
        # Ensure bash-completion infrastructure is ready
        if [ ! -f /etc/profile.d/bash_completion.sh ]; then
            cat > /etc/profile.d/bash_completion.sh << 'EOF'
# ash sources /etc/profile.d/*.sh on login; only load bash completion in bash.
if [ -n "${BASH_VERSION:-}" ] && [ -r /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi
EOF
            chmod 644 /etc/profile.d/bash_completion.sh
        fi

        for tool in ${tools}; do
            try_install_completion "${tool}" "bash" || true
        done
    fi

    log_success "Shell completions configured"
}

# ============================================================================
# SSH Configuration
# ============================================================================

configure_ssh() {
    if [ "${SKIP_SSH_KEYS}" = 1 ]; then
        log_warn "Skipping SSH configuration (--skip-ssh-keys)"
        return 0
    fi

    log_info "Configuring SSH for root access..."

    # Enable SSH service
    enable_service "sshd" "SSH"

    # Create .ssh directory with proper permissions
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Fetch GitHub public keys
    log_info "Fetching GitHub SSH keys for user: ${GITHUB_USER}"
    local keys_url="https://github.com/${GITHUB_USER}.keys"
    local temp_keys="/tmp/github-keys-$$.pub"

    if ! curl -fsSL "${keys_url}" -o "${temp_keys}" 2>/dev/null; then
        log_error "Failed to fetch SSH keys from GitHub"
        rm -f "${temp_keys}"
        return 1
    fi

    if [ ! -s "${temp_keys}" ]; then
        log_error "GitHub SSH keys are empty"
        rm -f "${temp_keys}"
        return 1
    fi

    # Merge keys into authorized_keys without duplicates
    if [ -f /root/.ssh/authorized_keys ]; then
        # Append only new keys
        while IFS= read -r key; do
            if [ -n "${key}" ] && ! grep -F "${key}" /root/.ssh/authorized_keys >/dev/null 2>&1; then
                echo "${key}" >> /root/.ssh/authorized_keys
            fi
        done < "${temp_keys}"
    else
        cp "${temp_keys}" /root/.ssh/authorized_keys
    fi

    chmod 600 /root/.ssh/authorized_keys
    rm -f "${temp_keys}"

    # Configure sshd to allow root key auth only
    if [ ! -f /etc/ssh/sshd_config.orig ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
        log_info "Backed up original sshd_config"
    fi

    # Set sshd_config preferences (idempotently via sed)
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

    # Restart SSH to apply changes
    rc-service sshd restart 2>/dev/null || log_warn "Failed to restart SSH service"

    log_success "SSH configuration complete (root key-only auth enabled)"
}

# ============================================================================
# Shell Configuration
# ============================================================================

configure_shell() {
    if [ "${INSTALL_FISH}" != 1 ]; then
        log_info "Skipping Fish shell configuration (--no-fish)"
        return 0
    fi

    log_info "Configuring shell environment..."

    # Only create Fish config if it doesn't exist
    if [ ! -d /root/.config/fish ]; then
        mkdir -p /root/.config/fish
    fi

    if [ ! -f /root/.config/fish/config.fish ]; then
        log_info "Creating Fish shell configuration"
        cat > /root/.config/fish/config.fish << 'EOF'
set -U fish_greeting ""
command -sq atuin; and atuin init fish | source
command -sq starship; and starship init fish | source
command -sq fzf; and fzf --fish | source
EOF
        chmod 644 /root/.config/fish/config.fish
    else
        log_info "Fish configuration already exists, skipping"
    fi

    # Migrate any older unconditional init lines to guarded, idempotent variants.
    sed -i '/^atuin init fish | source$/d' /root/.config/fish/config.fish
    sed -i '/^starship init fish | source$/d' /root/.config/fish/config.fish
    sed -i '/^fzf --fish | source$/d' /root/.config/fish/config.fish

    ensure_line_in_file /root/.config/fish/config.fish 'command -sq atuin; and atuin init fish | source'
    ensure_line_in_file /root/.config/fish/config.fish 'command -sq starship; and starship init fish | source'
    ensure_line_in_file /root/.config/fish/config.fish 'command -sq fzf; and fzf --fish | source'

    ensure_line_in_file /root/.config/fish/config.fish 'source /etc/profile.d/alpine-aliases.fish'

    log_success "Shell configuration complete"
}

configure_bash_shell() {
    if [ "${INSTALL_BASH}" != 1 ]; then
        log_info "Skipping Bash shell configuration (--no-bash)"
        return 0
    fi

    if [ ! -f /root/.bashrc ]; then
        : > /root/.bashrc
        chmod 644 /root/.bashrc
    fi

    ensure_line_in_file /root/.bashrc 'command -v atuin >/dev/null 2>&1 && eval "$(atuin init bash)"'
    ensure_line_in_file /root/.bashrc 'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"'
    ensure_line_in_file /root/.bashrc 'command -v fzf >/dev/null 2>&1 && eval "$(fzf --bash)"'
    ensure_line_in_file /root/.bashrc '. /etc/profile.d/alpine-aliases.sh'
}

configure_shared_aliases() {
    log_info "Configuring shared aliases for ash/bash/fish..."

    cat > /etc/profile.d/alpine-aliases.sh << 'EOF'
# Shared aliases for ash/bash login environments.
# eza is preferred when available, with safe fallback to busybox/coreutils ls.
if command -v eza >/dev/null 2>&1; then
    alias ls='eza'
    alias ll='eza -lah --icons=auto'
    alias lt='eza --tree -L 2 --icons=auto'
else
    alias ls='ls --color=auto'
    alias ll='ls -lah'
    alias lt='ls -lah'
fi

alias grep='grep --color=auto'
alias cls='clear'
alias c='clear'
alias ..='cd ..'
alias ...='cd ../..'
alias lzd='lazydocker'
alias bt='btop'
alias rg='rg --smart-case'
alias du='dust'
alias p='podman'
alias pc='podman compose'
alias psa='podman ps -a'
alias pi='podman images'
EOF
    chmod 644 /etc/profile.d/alpine-aliases.sh

    cat > /etc/profile.d/alpine-aliases.fish << 'EOF'
# Shared aliases for fish environments.
if command -sq eza
    alias ls 'eza'
    alias ll 'eza -lah --icons=auto'
    alias lt 'eza --tree -L 2 --icons=auto'
else
    alias ls 'ls --color=auto'
    alias ll 'ls -lah'
    alias lt 'ls -lah'
end

alias grep 'grep --color=auto'
alias cls 'clear'
alias c 'clear'
alias .. 'cd ..'
alias ... 'cd ../..'
alias lzd 'lazydocker'
alias bt 'btop'
alias rg 'rg --smart-case'
alias du 'dust'
alias p 'podman'
alias pc 'podman compose'
alias psa 'podman ps -a'
alias pi 'podman images'
EOF
    chmod 644 /etc/profile.d/alpine-aliases.fish

    log_success "Shared aliases configured"
}

# ============================================================================
# State Persistence
# ============================================================================

save_state() {
    local engine=$1

    mkdir -p "${STATE_DIR}"
    cat > "${STATE_FILE}" << EOF
# Alpine Bootstrap State
# This file tracks idempotent bootstrap configuration
BOOTSTRAP_ENGINE="${engine}"
BOOTSTRAP_INSTALL_BASH="${INSTALL_BASH}"
BOOTSTRAP_INSTALL_FISH="${INSTALL_FISH}"
BOOTSTRAP_LAST_RUN="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
BOOTSTRAP_VERSION="1.0"
EOF
    chmod 644 "${STATE_FILE}"
    log_success "State persisted to ${STATE_FILE}"
}

# ============================================================================
# Main Orchestration
# ============================================================================

main() {
    # Load persisted state from a previous run.
    # Sourcing here (not inside a subshell) makes BOOTSTRAP_ENGINE available globally
    # for determine_engine, and restores INSTALL_BASH if not set by CLI.
    if [ -f "${STATE_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
        if [ "${BASH_SET_BY_CLI}" = 0 ]; then
            INSTALL_BASH="${BOOTSTRAP_INSTALL_BASH:-1}"
        fi
        if [ "${FISH_SET_BY_CLI}" = 0 ]; then
            INSTALL_FISH="${BOOTSTRAP_INSTALL_FISH:-1}"
        fi
    fi

    log_section "========================================"
    log_section "Alpine Bootstrap Started"
    log_section "========================================"
    log_info ""

    # Determine engine (sets SELECTED_ENGINE global; no subshell/stdout capture)
    determine_engine
    local engine="${SELECTED_ENGINE}"

    log_info ""
    log_section "Configuration"
    log_info "Container engine: ${C_BOLD}${engine}${C_RESET}"
    log_info "GitHub user: ${GITHUB_USER}"
    if [ "${DISABLE_TESTING_REPOS}" = 0 ]; then
        log_info "Testing repos: ${C_GREEN}ENABLED${C_RESET}"
    else
        log_info "Testing repos: ${C_RED}DISABLED${C_RESET}"
    fi
    if [ "${SKIP_SSH_KEYS}" = 0 ]; then
        log_info "SSH bootstrap: ${C_GREEN}ENABLED${C_RESET}"
    else
        log_info "SSH bootstrap: ${C_YELLOW}SKIPPED${C_RESET}"
    fi
    if [ "${RUN_SETUP_APKREPOS}" = 1 ]; then
        log_info "setup-apkrepos helper: ${C_GREEN}ENABLED${C_RESET}"
    else
        log_info "setup-apkrepos helper: ${C_YELLOW}SKIPPED${C_RESET} (default; use --run-setup-apkrepos)"
    fi
    if [ "${INSTALL_BASH}" = 1 ]; then
        log_info "Bash tooling: ${C_GREEN}ENABLED${C_RESET}"
    else
        log_info "Bash tooling: ${C_YELLOW}DISABLED${C_RESET} (--no-bash)"
    fi
    if [ "${INSTALL_FISH}" = 1 ]; then
        log_info "Fish tooling: ${C_GREEN}ENABLED${C_RESET}"
    else
        log_info "Fish tooling: ${C_YELLOW}DISABLED${C_RESET} (--no-fish)"
    fi
    log_section "========================================"
    log_info ""

    # Configure repositories
    local add_testing=1
    if [ "${DISABLE_TESTING_REPOS}" = 1 ]; then
        add_testing=0
    fi
    configure_repositories "${add_testing}"

    # System preparation (update, upgrade)
    prepare_system

    # Install base tools
    install_base_tools

    # Install optional Bash tooling
    install_optional_bash

    # Build consolidated package list for completion management.
    local selected_engine_packages
    local consolidated_packages
    case "${engine}" in
        podman)
            selected_engine_packages="${PODMAN_PACKAGES}"
            ;;
        docker)
            selected_engine_packages="${DOCKER_PACKAGES}"
            ;;
        *)
            selected_engine_packages=""
            ;;
    esac
    consolidated_packages="${BASE_PACKAGES} ${selected_engine_packages}"
    if [ "${INSTALL_FISH}" = 1 ]; then
        consolidated_packages="${consolidated_packages} ${FISH_OPTIONAL_PACKAGES}"
    fi

    # Install selected engine
    case "${engine}" in
        podman)
            install_podman
            ;;
        docker)
            install_docker
            ;;
        *)
            die "Unknown engine: ${engine}"
            ;;
    esac

    # Install/enable completions for installed toolchain
    install_completions "${consolidated_packages}"

    # SSH configuration
    configure_ssh || log_warn "SSH configuration failed; continuing"

    # Shared aliases (ash/bash/fish)
    configure_shared_aliases

    # Shell configuration
    configure_shell
    configure_bash_shell

    # Save state
    save_state "${engine}"

    log_info ""
    log_section "========================================"
    log_success "Bootstrap Complete!"
    log_section "========================================"
    log_info "Container engine: ${C_BOLD}${engine}${C_RESET}"
    log_info "SSH access: Key-based only (GitHub: ${GITHUB_USER})"
    if [ "${add_testing}" = 1 ]; then
        log_info "Testing repos: ${C_GREEN}ENABLED${C_RESET} (trippy available)"
    else
        log_info "Testing repos: ${C_RED}DISABLED${C_RESET}"
    fi
    log_info "State file: ${STATE_FILE}"
    log_info "Proxmox reminder: ensure CT config includes features: fuse=1,keyctl=1,nesting=1"
    log_info "Check: /etc/pve/lxc/<CTID>.conf"
    log_info ""
}

main "$@"
