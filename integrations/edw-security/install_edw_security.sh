#!/usr/bin/env bash
# =============================================================================
# install_edw_security.sh — One-command installer for EDW Security → Veza OAA
# =============================================================================
# Usage (interactive):
#   bash install_edw_security.sh
#
# Usage (non-interactive / CI):
#   EDW_DB_HOST=db.example.com \
#   EDW_DB_PORT=1526 \
#   EDW_DB_SERVICE=MYPROD \
#   EDW_DB_USER=svcveza \
#   EDW_DB_PASSWORD=secret \
#   EDW_WEB_APP_ID=100005 \
#   VEZA_URL=https://mytenant.veza.com \
#   VEZA_API_KEY=myapikey \
#   bash install_edw_security.sh --non-interactive
#
# Optional flags:
#   --non-interactive    skip all prompts (requires env vars above)
#   --overwrite-env      overwrite an existing .env without asking
#   --install-dir PATH   custom install root (default: /opt/edw-security-veza)
#   --repo-url URL       override GitHub repo URL for script download
#   --branch NAME        override Git branch (default: main)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configurable defaults
# ---------------------------------------------------------------------------
INSTALL_DIR_DEFAULT="/opt/edw-security-veza"
REPO_URL_DEFAULT="https://github.com/YOUR_ORG/YOUR_REPO"
BRANCH_DEFAULT="main"
INTEGRATION_SUBDIR="integrations/edw-security"
SLUG="edw-security"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }

info()  { _blue    "[INFO]  $*"; }
ok()    { _green   "[OK]    $*"; }
warn()  { _yellow  "[WARN]  $*"; }
die()   { _red     "[ERROR] $*"; exit 1; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
NON_INTERACTIVE=false
OVERWRITE_ENV=false
INSTALL_DIR="${INSTALL_DIR_DEFAULT}"
REPO_URL="${REPO_URL_DEFAULT}"
BRANCH="${BRANCH_DEFAULT}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --overwrite-env)   OVERWRITE_ENV=true ;;
        --install-dir)     INSTALL_DIR="$2"; shift ;;
        --repo-url)        REPO_URL="$2"; shift ;;
        --branch)          BRANCH="$2"; shift ;;
        *) warn "Unknown flag: $1" ;;
    esac
    shift
done

SCRIPTS_DIR="${INSTALL_DIR}/scripts"
LOGS_DIR="${INSTALL_DIR}/logs"
VENV_DIR="${SCRIPTS_DIR}/venv"

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
OS_ID=""
PKG_MGR=""

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-}"
fi

if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
else
    die "Unsupported package manager. Install dnf/yum or apt-get first."
fi
info "Detected OS: ${OS_ID:-unknown}  package manager: ${PKG_MGR}"

# ---------------------------------------------------------------------------
# Package installer — one package at a time to avoid conflict failures
# ---------------------------------------------------------------------------
_install_pkg() {
    local pkg="$1"
    info "Installing ${pkg}..."
    case "${PKG_MGR}" in
        dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null 2>&1 || die "Failed to install ${pkg}" ;;
        apt-get) apt-get install -y "${pkg}"       >/dev/null 2>&1 || die "Failed to install ${pkg}" ;;
    esac
    ok "Installed ${pkg}"
}

# ---------------------------------------------------------------------------
# System prerequisite checks
# ---------------------------------------------------------------------------
_check_system_deps() {
    info "Checking system dependencies..."

    # git
    command -v git &>/dev/null || _install_pkg git

    # python3
    command -v python3 &>/dev/null || _install_pkg python3

    # pip
    python3 -m pip --version &>/dev/null || _install_pkg python3-pip

    # curl — Amazon Linux ships curl-minimal which conflicts with full curl
    if ! command -v curl &>/dev/null; then
        if [[ "${OS_ID}" == "amzn" ]]; then
            warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
        else
            _install_pkg curl
        fi
    fi

    # venv — python3-venv is built-in on Amazon Linux 2023 / RHEL 9+
    if ! python3 -m venv --help &>/dev/null 2>&1; then
        case "${PKG_MGR}" in
            dnf|yum) _install_pkg python3-virtualenv ;;
            apt-get) _install_pkg python3-venv ;;
        esac
    fi

    ok "All system dependencies satisfied"
}

# ---------------------------------------------------------------------------
# Python version check (require 3.9+)
# ---------------------------------------------------------------------------
_check_python_version() {
    local py_major py_minor
    py_major=$(python3 -c "import sys; print(sys.version_info.major)")
    py_minor=$(python3 -c "import sys; print(sys.version_info.minor)")

    if [[ "${py_major}" -lt 3 ]] || { [[ "${py_major}" -eq 3 ]] && [[ "${py_minor}" -lt 9 ]]; }; then
        die "Python 3.9+ is required (found ${py_major}.${py_minor}). Please upgrade Python first."
    fi
    ok "Python ${py_major}.${py_minor} detected"
}

# ---------------------------------------------------------------------------
# Read a value from the terminal (works even when stdin is a pipe)
# ---------------------------------------------------------------------------
_prompt() {
    local varname="$1"
    local prompt_text="$2"
    local default_val="${3:-}"
    local value=""

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        # Use the already-exported env var; error if missing and no default
        value="${!varname:-${default_val}}"
        if [[ -z "${value}" ]]; then
            die "--non-interactive mode: required variable ${varname} is not set"
        fi
        printf '%s\n' "${value}"
        return
    fi

    local display_default=""
    if [[ -n "${default_val}" ]]; then
        display_default=" [${default_val}]"
    fi

    IFS= read -r -p "${prompt_text}${display_default}: " value </dev/tty || true
    if [[ -z "${value}" && -n "${default_val}" ]]; then
        value="${default_val}"
    fi
    printf '%s\n' "${value}"
}

_prompt_secret() {
    local varname="$1"
    local prompt_text="$2"
    local value=""

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        value="${!varname:-}"
        if [[ -z "${value}" ]]; then
            die "--non-interactive mode: required secret ${varname} is not set"
        fi
        printf '%s\n' "${value}"
        return
    fi

    IFS= read -r -s -p "${prompt_text}: " value </dev/tty || true
    echo >/dev/tty
    printf '%s\n' "${value}"
}

# ---------------------------------------------------------------------------
# Gather configuration from the operator
# ---------------------------------------------------------------------------
_gather_config() {
    echo
    _blue "================================================================="
    _blue "  EDW Security — Veza OAA Integration — Configuration"
    _blue "================================================================="
    echo
    info "All values are written to ${SCRIPTS_DIR}/.env (chmod 600)."
    info "Nothing is transmitted anywhere during this installer."
    echo

    # Oracle DB
    _blue "── Oracle Database connection ──────────────────────────────────"
    EDW_DB_HOST=$(_prompt     "EDW_DB_HOST"    "Oracle DB hostname")
    EDW_DB_PORT=$(_prompt     "EDW_DB_PORT"    "Oracle DB listener port" "1526")
    EDW_DB_SERVICE=$(_prompt  "EDW_DB_SERVICE" "Oracle DB SID or service name")
    EDW_DB_USER=$(_prompt     "EDW_DB_USER"    "Oracle DB username (service account)")
    EDW_DB_PASSWORD=$(_prompt_secret "EDW_DB_PASSWORD" "Oracle DB password")
    EDW_WEB_APP_ID=$(_prompt  "EDW_WEB_APP_ID" "WEB_APP_ID filter value" "100005")

    # Veza
    echo
    _blue "── Veza connection ─────────────────────────────────────────────"
    VEZA_URL=$(_prompt "VEZA_URL" "Veza tenant URL (e.g. https://mytenant.veza.com)")
    VEZA_URL="${VEZA_URL%/}"  # strip trailing slash
    VEZA_API_KEY=$(_prompt_secret "VEZA_API_KEY" "Veza API key")

    # OAA naming (optional overrides)
    echo
    _blue "── OAA provider settings (press Enter to accept defaults) ───────"
    PROVIDER_NAME=$(_prompt   "PROVIDER_NAME"   "OAA provider name in Veza"    "EDW Security")
    DATASOURCE_NAME=$(_prompt "DATASOURCE_NAME" "OAA datasource name in Veza"  "EDW Security")

    # Validate mandatory fields
    for var in EDW_DB_HOST EDW_DB_SERVICE EDW_DB_USER EDW_DB_PASSWORD EDW_WEB_APP_ID VEZA_URL VEZA_API_KEY; do
        if [[ -z "${!var:-}" ]]; then
            die "Required value '${var}' was not provided."
        fi
    done
}

# ---------------------------------------------------------------------------
# Clone repository and copy integration files
# ---------------------------------------------------------------------------
_fetch_scripts() {
    if [[ "${REPO_URL}" == *"YOUR_ORG"* ]]; then
        warn "REPO_URL is still the placeholder value (${REPO_URL})."
        warn "Skipping git clone — copying local files if available."
        if [[ -f "$(dirname "$0")/edw_security.py" ]]; then
            mkdir -p "${SCRIPTS_DIR}"
            cp -f "$(dirname "$0")/edw_security.py"  "${SCRIPTS_DIR}/"
            cp -f "$(dirname "$0")/requirements.txt"  "${SCRIPTS_DIR}/"
            ok "Copied integration files from local directory"
        else
            die "No REPO_URL configured and no local edw_security.py found. " \
                "Re-run with --repo-url to specify the GitHub repository."
        fi
        return
    fi

    info "Cloning integration files from ${REPO_URL} (branch: ${BRANCH})..."
    local tmp_dir
    tmp_dir=$(mktemp -d)

    GIT_TERMINAL_PROMPT=0 git clone \
        --branch "${BRANCH}" \
        --depth 1 \
        --single-branch \
        "${REPO_URL}" "${tmp_dir}" \
    || die "git clone failed from ${REPO_URL}"

    mkdir -p "${SCRIPTS_DIR}"
    cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/edw_security.py"  "${SCRIPTS_DIR}/"
    cp -f "${tmp_dir}/${INTEGRATION_SUBDIR}/requirements.txt" "${SCRIPTS_DIR}/"
    rm -rf "${tmp_dir}"
    ok "Integration files installed to ${SCRIPTS_DIR}"
}

# ---------------------------------------------------------------------------
# Create directory layout
# ---------------------------------------------------------------------------
_create_directories() {
    info "Creating directory structure under ${INSTALL_DIR}..."
    mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"
    ok "Directories created"
}

# ---------------------------------------------------------------------------
# Create Python virtual environment and install dependencies
# ---------------------------------------------------------------------------
_setup_venv() {
    info "Creating Python virtual environment in ${VENV_DIR}..."
    python3 -m venv "${VENV_DIR}" || die "Failed to create virtual environment"

    info "Installing Python dependencies from requirements.txt..."
    "${VENV_DIR}/bin/pip" install --upgrade pip --quiet
    "${VENV_DIR}/bin/pip" install -r "${SCRIPTS_DIR}/requirements.txt" --quiet \
        || die "pip install failed — check requirements.txt"
    ok "Virtual environment ready at ${VENV_DIR}"
}

# ---------------------------------------------------------------------------
# Write .env file
# ---------------------------------------------------------------------------
_write_env() {
    local env_path="${SCRIPTS_DIR}/.env"

    if [[ -f "${env_path}" && "${OVERWRITE_ENV}" == "false" && "${NON_INTERACTIVE}" == "false" ]]; then
        local answer
        answer=$(_prompt "" "An .env file already exists. Overwrite? [y/N]" "N")
        if [[ "${answer,,}" != "y" ]]; then
            warn "Keeping existing .env — configuration NOT updated."
            return
        fi
    fi

    info "Writing .env to ${env_path}..."
    cat > "${env_path}" <<EOF
# EDW Security → Veza OAA Integration — generated by install_edw_security.sh
# $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# IMPORTANT: keep this file private (chmod 600)

# Oracle Database
EDW_DB_HOST=${EDW_DB_HOST}
EDW_DB_PORT=${EDW_DB_PORT}
EDW_DB_SERVICE=${EDW_DB_SERVICE}
EDW_DB_USER=${EDW_DB_USER}
EDW_DB_PASSWORD=${EDW_DB_PASSWORD}
EDW_WEB_APP_ID=${EDW_WEB_APP_ID}

# Veza
VEZA_URL=${VEZA_URL}
VEZA_API_KEY=${VEZA_API_KEY}

# OAA provider naming
PROVIDER_NAME=${PROVIDER_NAME}
DATASOURCE_NAME=${DATASOURCE_NAME}
EOF

    chmod 600 "${env_path}"
    ok ".env written and secured (chmod 600)"
}

# ---------------------------------------------------------------------------
# Print final summary
# ---------------------------------------------------------------------------
_print_summary() {
    echo
    _green "================================================================="
    _green "  EDW Security → Veza OAA Integration — Installation Complete"
    _green "================================================================="
    echo
    info  "Install directory : ${INSTALL_DIR}"
    info  "Scripts directory : ${SCRIPTS_DIR}"
    info  "Logs directory    : ${LOGS_DIR}"
    info  "Virtual env       : ${VENV_DIR}"
    info  "Credentials file  : ${SCRIPTS_DIR}/.env"
    echo
    _blue "── Next steps ──────────────────────────────────────────────────"
    echo
    echo  "  1.  Verify the .env file contains the correct values:"
    echo  "        cat ${SCRIPTS_DIR}/.env"
    echo
    echo  "  2.  Run a dry-run to validate the payload:"
    echo  "        cd ${SCRIPTS_DIR}"
    echo  "        ${VENV_DIR}/bin/python3 edw_security.py --dry-run --save-json --log-level DEBUG"
    echo
    echo  "  3.  When satisfied, push to Veza:"
    echo  "        cd ${SCRIPTS_DIR}"
    echo  "        ${VENV_DIR}/bin/python3 edw_security.py --env-file .env"
    echo
    echo  "  4.  Schedule with cron (example — daily at 06:00):"
    echo  "        0 6 * * * ${VENV_DIR}/bin/python3 ${SCRIPTS_DIR}/edw_security.py --env-file ${SCRIPTS_DIR}/.env >> ${LOGS_DIR}/cron.log 2>&1"
    echo
    _green "================================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo
    _blue "================================================================="
    _blue "  EDW Security → Veza OAA Integration Installer"
    _blue "  $(date)"
    _blue "================================================================="

    _check_system_deps
    _check_python_version
    _gather_config
    _create_directories
    _fetch_scripts
    _setup_venv
    _write_env
    _print_summary
}

main "$@"
