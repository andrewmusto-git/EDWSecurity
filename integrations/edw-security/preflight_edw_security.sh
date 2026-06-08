#!/usr/bin/env bash
# =============================================================================
# preflight_edw_security.sh — Pre-deployment validation for EDW Security OAA
# =============================================================================
# Derived from edw_security.py — validates every prerequisite before running.
#
# Usage:
#   bash preflight_edw_security.sh            # interactive menu
#   bash preflight_edw_security.sh --all      # non-interactive, all checks
#
# Exit codes:
#   0  — all checks passed (or only warnings)
#   1  — one or more checks failed
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="${SCRIPT_DIR}/venv/bin/python3"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

# ---------------------------------------------------------------------------
# Colour + logging helpers
# ---------------------------------------------------------------------------
_ts() { date +"%Y-%m-%dT%H:%M:%S"; }

_log() { printf '%s %s\n' "$(_ts)" "$*" | tee -a "${LOG_FILE}"; }

pass()  { TESTS_PASSED=$((TESTS_PASSED + 1));  _log "$(printf '\033[0;32m✓ PASS\033[0m  %s' "$*")"; }
fail()  { TESTS_FAILED=$((TESTS_FAILED + 1));  _log "$(printf '\033[0;31m✗ FAIL\033[0m  %s' "$*")"; }
warn()  { TESTS_WARNING=$((TESTS_WARNING + 1)); _log "$(printf '\033[0;33m⚠ WARN\033[0m  %s' "$*")"; }
info()  { _log "$(printf '\033[0;34mℹ INFO\033[0m  %s' "$*)"; }
banner(){ _log "$(printf '\033[1;37m%s\033[0m' "$*")"; }

# ---------------------------------------------------------------------------
# Check 1 — System requirements
# ---------------------------------------------------------------------------
check_system() {
    banner "── [1/7] System Requirements ────────────────────────────────"

    # Python 3.9+
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        PY_MAJOR=$(python3 -c "import sys; print(sys.version_info.major)")
        PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
        if [[ "${PY_MAJOR}" -ge 3 && "${PY_MINOR}" -ge 9 ]]; then
            pass "Python ${PY_VER} (≥3.9 required)"
        else
            fail "Python ${PY_VER} — 3.9+ required"
        fi
    else
        fail "python3 not found"
    fi

    # pip3
    if command -v pip3 &>/dev/null || python3 -m pip --version &>/dev/null 2>&1; then
        pass "pip3 available"
    else
        fail "pip3 not found — install python3-pip"
    fi

    # curl
    if command -v curl &>/dev/null; then
        pass "curl available"
    else
        warn "curl not found — not strictly required but useful for network tests"
    fi

    # jq (optional)
    if command -v jq &>/dev/null; then
        pass "jq available (optional)"
    else
        warn "jq not found (optional) — JSON inspection will be manual"
    fi
}

# ---------------------------------------------------------------------------
# Check 2 — Python dependencies
# ---------------------------------------------------------------------------
check_python_deps() {
    banner "── [2/7] Python Dependencies ────────────────────────────────"

    local python_bin="python3"
    if [[ -x "${VENV_PYTHON}" ]]; then
        python_bin="${VENV_PYTHON}"
        info "Using venv python: ${python_bin}"
    else
        warn "Virtual environment not found at ${VENV_PYTHON} — using system python3"
    fi

    # Packages derived from requirements.txt
    local pkgs=("oaaclient" "oracledb" "dotenv" "requests" "urllib3")
    for pkg in "${pkgs[@]}"; do
        local import_name="${pkg}"
        # dotenv is imported as 'dotenv' but installed as 'python-dotenv'
        if "${python_bin}" -c "import ${import_name}" &>/dev/null 2>&1; then
            local ver
            ver=$("${python_bin}" -c "
import importlib.metadata, sys
try:
    print(importlib.metadata.version('${pkg}'))
except Exception:
    print('unknown')
" 2>/dev/null)
            pass "${pkg} ${ver}"
        else
            fail "${pkg} not importable — run: pip install -r ${SCRIPT_DIR}/requirements.txt"
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 3 — Configuration file and environment variables
# ---------------------------------------------------------------------------
check_config() {
    banner "── [3/7] Configuration ──────────────────────────────────────"

    if [[ -f "${ENV_FILE}" ]]; then
        pass ".env file exists: ${ENV_FILE}"
        local perms
        perms=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%p" "${ENV_FILE}" 2>/dev/null | tail -c 4)
        if [[ "${perms}" == "600" ]]; then
            pass ".env permissions: 600"
        else
            warn ".env permissions: ${perms} (should be 600 — run: chmod 600 ${ENV_FILE})"
        fi
        # shellcheck source=/dev/null
        set -o allexport
        source "${ENV_FILE}" 2>/dev/null || true
        set +o allexport
    else
        fail ".env not found at ${ENV_FILE} — copy .env.example and fill in values"
        return
    fi

    # Required variables — derived from load_config() in edw_security.py
    local required_vars=(
        "EDW_DB_HOST"
        "EDW_DB_SERVICE"
        "EDW_DB_USER"
        "EDW_DB_PASSWORD"
        "EDW_WEB_APP_ID"
        "VEZA_URL"
        "VEZA_API_KEY"
    )
    local optional_vars=(
        "EDW_DB_PORT"
        "PROVIDER_NAME"
        "DATASOURCE_NAME"
    )
    # Patterns that indicate a placeholder value was never replaced
    local placeholder_pattern="your_|your-|example\.com|placeholder"

    for var in "${required_vars[@]}"; do
        local val="${!var:-}"
        if [[ -z "${val}" ]]; then
            fail "${var} is not set"
        elif echo "${val}" | grep -qiE "${placeholder_pattern}"; then
            fail "${var} appears to be a placeholder value — update it in .env"
        else
            # Mask sensitive values
            if echo "${var}" | grep -qiE "PASSWORD|KEY|TOKEN|SECRET"; then
                pass "${var} = ****${val: -4}"
            else
                pass "${var} = ${val}"
            fi
        fi
    done

    for var in "${optional_vars[@]}"; do
        local val="${!var:-}"
        if [[ -n "${val}" ]]; then
            info "${var} = ${val} (optional override active)"
        fi
    done
}

# ---------------------------------------------------------------------------
# Check 4 — Network connectivity
# ---------------------------------------------------------------------------
check_network() {
    banner "── [4/7] Network Connectivity ───────────────────────────────"

    # Load .env so we have the values
    if [[ -f "${ENV_FILE}" ]]; then
        set -o allexport
        # shellcheck source=/dev/null
        source "${ENV_FILE}" 2>/dev/null || true
        set +o allexport
    fi

    local db_host="${EDW_DB_HOST:-}"
    local db_port="${EDW_DB_PORT:-1526}"
    local veza_url="${VEZA_URL:-}"

    # Oracle DB TCP reachability
    if [[ -n "${db_host}" ]]; then
        local start_ts end_ts latency
        start_ts=$(date +%s%N 2>/dev/null || echo 0)
        if timeout 5 bash -c "echo >/dev/tcp/${db_host}/${db_port}" &>/dev/null 2>&1; then
            end_ts=$(date +%s%N 2>/dev/null || echo 0)
            latency=$(( (end_ts - start_ts) / 1000000 ))
            pass "Oracle DB TCP ${db_host}:${db_port} reachable (${latency}ms)"
        else
            fail "Oracle DB TCP ${db_host}:${db_port} unreachable — check host, port, firewall"
        fi
    else
        warn "EDW_DB_HOST not set — skipping Oracle connectivity check"
    fi

    # Veza HTTPS reachability
    if [[ -n "${veza_url}" ]]; then
        local veza_host
        veza_host=$(echo "${veza_url}" | sed -E 's|https?://||;s|/.*||')
        local start_ts end_ts latency
        start_ts=$(date +%s%N 2>/dev/null || echo 0)
        if timeout 5 bash -c "echo >/dev/tcp/${veza_host}/443" &>/dev/null 2>&1; then
            end_ts=$(date +%s%N 2>/dev/null || echo 0)
            latency=$(( (end_ts - start_ts) / 1000000 ))
            pass "Veza HTTPS ${veza_host}:443 reachable (${latency}ms)"
        else
            fail "Veza HTTPS ${veza_host}:443 unreachable — check URL and outbound HTTPS"
        fi
    else
        warn "VEZA_URL not set — skipping Veza connectivity check"
    fi
}

# ---------------------------------------------------------------------------
# Check 5 — API authentication
# ---------------------------------------------------------------------------
check_auth() {
    banner "── [5/7] API Authentication ─────────────────────────────────"

    if [[ -f "${ENV_FILE}" ]]; then
        set -o allexport
        # shellcheck source=/dev/null
        source "${ENV_FILE}" 2>/dev/null || true
        set +o allexport
    fi

    local python_bin="python3"
    [[ -x "${VENV_PYTHON}" ]] && python_bin="${VENV_PYTHON}"

    # Oracle thin-mode auth test — derived from fetch_access_data() in edw_security.py
    local db_host="${EDW_DB_HOST:-}"
    local db_port="${EDW_DB_PORT:-1526}"
    local db_service="${EDW_DB_SERVICE:-}"
    local db_user="${EDW_DB_USER:-}"
    local db_password="${EDW_DB_PASSWORD:-}"

    if [[ -n "${db_host}" && -n "${db_service}" && -n "${db_user}" && -n "${db_password}" ]]; then
        info "Testing Oracle login (SELECT 1 FROM dual)..."
        local oracle_result
        oracle_result=$("${python_bin}" - <<PYEOF 2>&1
import sys
try:
    import oracledb
    dsn = (
        f"(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)"
        f"(HOST=${db_host})(PORT=${db_port}))"
        f"(CONNECT_DATA=(SID=${db_service})))"
    )
    conn = oracledb.connect(user="${db_user}", password="${db_password}", dsn=dsn)
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM dual")
    row = cur.fetchone()
    conn.close()
    print("OK" if row and row[0] == 1 else "UNEXPECTED")
except Exception as e:
    print(f"FAIL: {e}")
PYEOF
        )
        if [[ "${oracle_result}" == "OK" ]]; then
            pass "Oracle authentication successful"
        else
            fail "Oracle authentication failed: ${oracle_result}"
        fi
    else
        warn "Oracle DB credentials not fully configured — skipping auth test"
    fi

    # Veza API key test — derived from push_to_veza() in edw_security.py
    local veza_url="${VEZA_URL:-}"
    local veza_api_key="${VEZA_API_KEY:-}"

    if [[ -n "${veza_url}" && -n "${veza_api_key}" ]]; then
        info "Testing Veza API key (GET /api/v1/providers)..."
        if command -v curl &>/dev/null; then
            local http_status response_body
            response_body=$(curl -s -o /tmp/veza_preflight_resp.txt -w "%{http_code}" \
                -H "Authorization: Bearer ${veza_api_key}" \
                -H "Content-Type: application/json" \
                "${veza_url%/}/api/v1/providers" 2>/dev/null)
            http_status="${response_body}"
            if [[ "${http_status}" == "200" ]]; then
                pass "Veza API key valid (HTTP 200)"
            else
                local resp_snippet
                resp_snippet=$(head -c 200 /tmp/veza_preflight_resp.txt 2>/dev/null || echo "(no body)")
                fail "Veza API key test failed (HTTP ${http_status}): ${resp_snippet}"
            fi
            rm -f /tmp/veza_preflight_resp.txt
        else
            warn "curl not available — skipping Veza API key test"
        fi
    else
        warn "VEZA_URL or VEZA_API_KEY not set — skipping Veza auth test"
    fi
}

# ---------------------------------------------------------------------------
# Check 6 — Veza endpoint access (OAA write)
# ---------------------------------------------------------------------------
check_veza_endpoint() {
    banner "── [6/7] Veza Endpoint Access ───────────────────────────────"

    if [[ -f "${ENV_FILE}" ]]; then
        set -o allexport
        # shellcheck source=/dev/null
        source "${ENV_FILE}" 2>/dev/null || true
        set +o allexport
    fi

    local veza_url="${VEZA_URL:-}"
    local veza_api_key="${VEZA_API_KEY:-}"

    if [[ -z "${veza_url}" || -z "${veza_api_key}" ]]; then
        warn "Veza credentials not set — skipping endpoint access check"
        return
    fi

    if ! command -v curl &>/dev/null; then
        warn "curl not available — skipping Veza OAA endpoint check"
        return
    fi

    info "Testing Veza Query API (POST /api/v1/query)..."
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${veza_api_key}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{}"}' \
        "${veza_url%/}/api/v1/query" 2>/dev/null)

    # 200 or 400 (bad query syntax) both confirm the key has access
    if [[ "${http_status}" == "200" || "${http_status}" == "400" ]]; then
        pass "Veza Query API accessible (HTTP ${http_status})"
    elif [[ "${http_status}" == "403" ]]; then
        fail "Veza API key lacks read permissions (HTTP 403)"
    else
        warn "Veza Query API returned HTTP ${http_status} — check key permissions"
    fi
}

# ---------------------------------------------------------------------------
# Check 7 — Deployment structure
# ---------------------------------------------------------------------------
check_deployment() {
    banner "── [7/7] Deployment Structure ───────────────────────────────"

    # Main Python script
    if [[ -f "${SCRIPT_DIR}/edw_security.py" && -r "${SCRIPT_DIR}/edw_security.py" ]]; then
        pass "edw_security.py exists and is readable"
    else
        fail "edw_security.py not found at ${SCRIPT_DIR}/edw_security.py"
    fi

    # requirements.txt
    if [[ -f "${SCRIPT_DIR}/requirements.txt" ]]; then
        pass "requirements.txt exists"
    else
        warn "requirements.txt not found"
    fi

    # logs/ directory
    local logs_dir
    if [[ -d "${SCRIPT_DIR}/logs" ]]; then
        if [[ -w "${SCRIPT_DIR}/logs" ]]; then
            pass "logs/ directory exists and is writable"
        else
            fail "logs/ directory exists but is not writable by current user"
        fi
    else
        if mkdir -p "${SCRIPT_DIR}/logs" 2>/dev/null; then
            pass "logs/ directory created successfully"
        else
            fail "Could not create logs/ directory — check permissions"
        fi
    fi

    # Running user
    info "Running as user: $(id -un) (uid=$(id -u))"

    # --help smoke test
    local python_bin="python3"
    [[ -x "${VENV_PYTHON}" ]] && python_bin="${VENV_PYTHON}"
    if "${python_bin}" "${SCRIPT_DIR}/edw_security.py" --help &>/dev/null 2>&1; then
        pass "edw_security.py --help executes without error"
    else
        fail "edw_security.py --help failed — check Python syntax and imports"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo
    printf '%s\n' "============================================================"
    printf '  Preflight Summary\n'
    printf '  Log: %s\n' "${LOG_FILE}"
    printf '%s\n' "============================================================"
    printf '\033[0;32m  ✓ Passed : %d\033[0m\n'  "${TESTS_PASSED}"
    printf '\033[0;33m  ⚠ Warning: %d\033[0m\n'  "${TESTS_WARNING}"
    printf '\033[0;31m  ✗ Failed : %d\033[0m\n'  "${TESTS_FAILED}"
    printf '%s\n' "============================================================"
    echo

    if [[ "${TESTS_FAILED}" -gt 0 ]]; then
        printf '\033[0;31mOne or more checks failed. Resolve the issues above before deploying.\033[0m\n'
        exit 1
    else
        printf '\033[0;32mAll required checks passed.\033[0m\n'
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    echo
    printf '\033[1;37m================================================================\033[0m\n'
    printf '\033[1;37m  EDW Security OAA — Pre-flight Validation\033[0m\n'
    printf '\033[1;37m================================================================\033[0m\n'
    echo
    echo "  1. System requirements"
    echo "  2. Python dependencies"
    echo "  3. Configuration (.env)"
    echo "  4. Network connectivity"
    echo "  5. API authentication"
    echo "  6. Veza endpoint access"
    echo "  7. Deployment structure"
    echo "  8. Run ALL checks"
    echo "  9. Show current configuration"
    echo " 10. Generate .env template"
    echo "  0. Exit"
    echo
    read -r -p "Select option: " choice </dev/tty

    case "${choice}" in
        1) check_system         ; print_summary ;;
        2) check_python_deps    ; print_summary ;;
        3) check_config         ; print_summary ;;
        4) check_network        ; print_summary ;;
        5) check_auth           ; print_summary ;;
        6) check_veza_endpoint  ; print_summary ;;
        7) check_deployment     ; print_summary ;;
        8) run_all_checks ;;
        9) show_config ;;
        10) generate_env_template ;;
        0) exit 0 ;;
        *) echo "Invalid option"; interactive_menu ;;
    esac
}

show_config() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -o allexport
        # shellcheck source=/dev/null
        source "${ENV_FILE}" 2>/dev/null || true
        set +o allexport
    fi
    echo
    printf '\033[0;34m── Current Configuration ───────────────────────────────\033[0m\n'
    printf '  EDW_DB_HOST     = %s\n'  "${EDW_DB_HOST:-<not set>}"
    printf '  EDW_DB_PORT     = %s\n'  "${EDW_DB_PORT:-1526}"
    printf '  EDW_DB_SERVICE  = %s\n'  "${EDW_DB_SERVICE:-<not set>}"
    printf '  EDW_DB_USER     = %s\n'  "${EDW_DB_USER:-<not set>}"
    printf '  EDW_DB_PASSWORD = %s\n'  "${EDW_DB_PASSWORD:+****${EDW_DB_PASSWORD: -4}}"
    printf '  EDW_WEB_APP_ID  = %s\n'  "${EDW_WEB_APP_ID:-<not set>}"
    printf '  VEZA_URL        = %s\n'  "${VEZA_URL:-<not set>}"
    printf '  VEZA_API_KEY    = %s\n'  "${VEZA_API_KEY:+****${VEZA_API_KEY: -4}}"
    echo
}

generate_env_template() {
    local target="${SCRIPT_DIR}/.env.new"
    cp "${SCRIPT_DIR}/.env.example" "${target}" 2>/dev/null \
        || printf '# EDW Security .env template\nEDW_DB_HOST=\nEDW_DB_PORT=1526\nEDW_DB_SERVICE=\nEDW_DB_USER=\nEDW_DB_PASSWORD=\nEDW_WEB_APP_ID=\nVEZA_URL=\nVEZA_API_KEY=\n' > "${target}"
    chmod 600 "${target}"
    info "Template written to: ${target}"
}

run_all_checks() {
    info "Running all checks at $(date)..."
    echo
    check_system
    echo
    check_python_deps
    echo
    check_config
    echo
    check_network
    echo
    check_auth
    echo
    check_veza_endpoint
    echo
    check_deployment
    echo
    print_summary
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
info "Preflight log: ${LOG_FILE}"

if [[ "${1:-}" == "--all" ]]; then
    run_all_checks
else
    interactive_menu
fi
