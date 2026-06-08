#!/usr/bin/env python3
"""
Enterprise Data Warehouse (EDW) Security — Veza OAA Integration

Queries the Oracle database table Dwt_web_app_access_control and pushes
identity and permission data into Veza's Access Graph using the OAA API.

Entity model:
    Local User        → USER_NAME
    Application Resource → PROGRAM_NAME (type: Program)
    Custom Permissions   → program_access, admin_access, security_access

Usage:
    python3 edw_security.py --dry-run --save-json
    python3 edw_security.py --env-file .env --log-level DEBUG
    python3 edw_security.py --env-file .env --web-app-id 100005
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
import time
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

from dotenv import load_dotenv

try:
    import oracledb
except ImportError:
    print("ERROR: oracledb is not installed. Run: pip install oracledb", file=sys.stderr)
    sys.exit(1)

try:
    from oaaclient.client import OAAClient, OAAClientError
    from oaaclient.templates import CustomApplication, OAAPermission
except ImportError:
    print("ERROR: oaaclient is not installed. Run: pip install oaaclient", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Module logger
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ---------------------------------------------------------------------------
# Milestone tracker
# ---------------------------------------------------------------------------
class MilestoneTracker:
    """Logs and displays named progress milestones with elapsed-time info."""

    _DIVIDER = "=" * 64

    def __init__(self, total: int) -> None:
        self._total = total
        self._current = 0
        self._start = time.monotonic()
        self._lap = time.monotonic()

    def reached(self, name: str) -> None:
        """Record and log that a named milestone has been reached."""
        self._current += 1
        lap_elapsed = time.monotonic() - self._lap
        self._lap = time.monotonic()
        total_elapsed = time.monotonic() - self._start

        log.info(self._DIVIDER)
        log.info(
            "MILESTONE [%d/%d]  %s  (+%.1fs, total %.1fs)",
            self._current, self._total, name, lap_elapsed, total_elapsed,
        )
        log.info(self._DIVIDER)

    def complete(
        self,
        users: int = 0,
        resources: int = 0,
        permissions: int = 0,
    ) -> None:
        """Log the final completion summary."""
        total_elapsed = time.monotonic() - self._start
        log.info(self._DIVIDER)
        log.info(
            "COMPLETE  users=%d  programs=%d  permission-grants=%d  elapsed=%.1fs",
            users, resources, permissions, total_elapsed,
        )
        log.info(self._DIVIDER)


# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------
def load_config(args: argparse.Namespace) -> dict:
    """
    Load configuration with precedence: CLI arg > env var > .env file.
    No credentials are ever hardcoded here; all values come from the
    caller's environment or the .env file.
    """
    env_file = args.env_file or ".env"
    if os.path.exists(env_file):
        load_dotenv(env_file)
        log.debug("Loaded environment from: %s", env_file)
    else:
        log.debug(
            "No .env file found at %s — relying on environment variables",
            env_file,
        )

    return {
        # Veza connection
        "veza_url": (args.veza_url or os.getenv("VEZA_URL", "")).rstrip("/"),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY", ""),
        # Oracle database
        "db_host": args.db_host or os.getenv("EDW_DB_HOST", ""),
        "db_port": int(args.db_port or os.getenv("EDW_DB_PORT", "1526")),
        "db_service": args.db_service or os.getenv("EDW_DB_SERVICE", ""),
        "db_user": args.db_user or os.getenv("EDW_DB_USER", ""),
        "db_password": args.db_password or os.getenv("EDW_DB_PASSWORD", ""),
        # Integration settings
        "web_app_id": args.web_app_id or os.getenv("EDW_WEB_APP_ID", ""),
        "provider_name": (
            args.provider_name or os.getenv("PROVIDER_NAME", "EDW Security")
        ),
        "datasource_name": (
            args.datasource_name or os.getenv("DATASOURCE_NAME", "EDW Security")
        ),
    }


def _validate_config(cfg: dict, dry_run: bool) -> None:
    """Exit early with a clear message if any required config is missing."""
    required_db = {
        "EDW_DB_HOST": cfg["db_host"],
        "EDW_DB_SERVICE": cfg["db_service"],
        "EDW_DB_USER": cfg["db_user"],
        "EDW_DB_PASSWORD": cfg["db_password"],
        "EDW_WEB_APP_ID": cfg["web_app_id"],
    }
    missing = [k for k, v in required_db.items() if not v]
    if missing:
        log.error("Missing required configuration: %s", ", ".join(missing))
        log.error("Set these in your .env file or as environment variables.")
        sys.exit(1)

    if not dry_run:
        required_veza = {
            "VEZA_URL": cfg["veza_url"],
            "VEZA_API_KEY": cfg["veza_api_key"],
        }
        missing_veza = [k for k, v in required_veza.items() if not v]
        if missing_veza:
            log.error(
                "Missing required Veza configuration: %s "
                "(add --dry-run to skip the Veza push)",
                ", ".join(missing_veza),
            )
            sys.exit(1)


# ---------------------------------------------------------------------------
# Oracle query — parameterized to avoid SQL injection
# ---------------------------------------------------------------------------
_ACCESS_QUERY = """
SELECT
    CASE WHEN ADMIN_ACCESS    = 'Y' THEN 'ADMIN_ACCESS'    ELSE NULL END AS ADMIN_ACCESS,
    CASE WHEN PROGRAM_ACCESS  = 'Y' THEN 'PROGRAM_ACCESS'  ELSE NULL END AS PROGRAM_ACCESS,
    CASE WHEN SECURITY_ACCESS = 'Y' THEN 'SECURITY_ACCESS' ELSE NULL END AS SECURITY_ACCESS,
    USER_NAME,
    WEB_APP_ID,
    PROGRAM_NAME,
    ROW_INSERT_USER_ID,
    ROW_INSERT_TASK_ID,
    ADDITIONAL_ROLE
FROM Dwt_web_app_access_control
WHERE WEB_APP_ID = :web_app_id
"""


def fetch_access_data(cfg: dict) -> list:
    """
    Open a thin Oracle connection, run the access-control query, and return
    all rows as a list of dicts.  The connection is closed before returning.
    No credentials are logged.
    """
    # Build a full TNS connect descriptor so the SID (not service name) is
    # used — matching the source system's JDBC URL format.
    dsn = (
        f"(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)"
        f"(HOST={cfg['db_host']})(PORT={cfg['db_port']}))"
        f"(CONNECT_DATA=(SID={cfg['db_service']})))"
    )
    log.debug(
        "Connecting to Oracle: user=%s host=%s port=%s sid=%s",
        cfg["db_user"],
        cfg["db_host"],
        cfg["db_port"],
        cfg["db_service"],
    )

    try:
        conn = oracledb.connect(
            user=cfg["db_user"],
            password=cfg["db_password"],
            dsn=dsn,
        )
    except oracledb.DatabaseError as exc:
        log.error("Oracle connection failed: %s", exc)
        sys.exit(1)

    rows: list = []
    try:
        with conn.cursor() as cur:
            cur.execute(_ACCESS_QUERY, web_app_id=cfg["web_app_id"])
            columns = [col[0] for col in cur.description]
            for raw_row in cur:
                rows.append(dict(zip(columns, raw_row)))
    except oracledb.DatabaseError as exc:
        log.error("Query failed: %s", exc)
        sys.exit(1)
    finally:
        conn.close()

    log.info(
        "Fetched %d rows from Dwt_web_app_access_control (WEB_APP_ID=%s)",
        len(rows),
        cfg["web_app_id"],
    )
    return rows


# ---------------------------------------------------------------------------
# OAA payload builder
# ---------------------------------------------------------------------------
def build_oaa_payload(rows: list, cfg: dict) -> tuple:
    """
    Construct the OAA CustomApplication payload from access-control rows.

    Mapping:
        USER_NAME    → Local User
        PROGRAM_NAME → Application Resource (type: Program)
        Access flags → Custom Permissions (program_access, admin_access,
                                           security_access)

    Returns (app, stats) where stats is a dict of entity counts.
    """
    app = CustomApplication(
        name=cfg["datasource_name"],
        application_type=cfg["provider_name"],
        description=(
            f"EDW Security access control — WEB_APP_ID {cfg['web_app_id']}"
        ),
    )

    # ── Define custom permissions (ordered least- to most-privileged)
    app.add_custom_permission("program_access", [OAAPermission.DataRead])
    app.add_custom_permission(
        "admin_access",
        [
            OAAPermission.DataRead,
            OAAPermission.DataWrite,
            OAAPermission.MetadataRead,
            OAAPermission.MetadataWrite,
        ],
    )
    app.add_custom_permission(
        "security_access",
        [OAAPermission.DataRead, OAAPermission.MetadataRead],
    )

    # Local caches — add_local_user / add_resource return the object only
    # on first call; keep our own references for subsequent rows.
    user_cache: dict = {}
    resource_cache: dict = {}
    stats = {"users": 0, "resources": 0, "permissions": 0}

    for row in rows:
        user_name = row.get("USER_NAME")
        program_name = row.get("PROGRAM_NAME")

        if not user_name:
            log.warning("Skipping row with empty USER_NAME: %s", row)
            continue

        # ── Add local user (idempotent via cache)
        if user_name not in user_cache:
            user_obj = app.add_local_user(user_name)
            user_cache[user_name] = user_obj
            stats["users"] += 1
        else:
            user_obj = user_cache[user_name]

        # ── Add program resource (idempotent via cache)
        if program_name:
            if program_name not in resource_cache:
                resource_obj = app.add_resource(
                    resource_name=program_name,
                    resource_type="Program",
                )
                resource_cache[program_name] = resource_obj
                stats["resources"] += 1
            else:
                resource_obj = resource_cache[program_name]

            # ── Grant permissions based on access flags
            if row.get("PROGRAM_ACCESS") == "PROGRAM_ACCESS":
                user_obj.add_permission(
                    "program_access", resources=[resource_obj]
                )
                stats["permissions"] += 1

            if row.get("ADMIN_ACCESS") == "ADMIN_ACCESS":
                user_obj.add_permission(
                    "admin_access", resources=[resource_obj]
                )
                stats["permissions"] += 1

            if row.get("SECURITY_ACCESS") == "SECURITY_ACCESS":
                user_obj.add_permission(
                    "security_access", resources=[resource_obj]
                )
                stats["permissions"] += 1
        else:
            log.debug("Row for user %s has no PROGRAM_NAME; no resource grant.", user_name)

    log.info(
        "Payload built — users=%d  programs=%d  permission-grants=%d",
        stats["users"],
        stats["resources"],
        stats["permissions"],
    )
    return app, stats


# ---------------------------------------------------------------------------
# Veza push
# ---------------------------------------------------------------------------
def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: bool = False,
) -> None:
    """Push the OAA payload to Veza, or perform a dry-run (no side-effects)."""
    if save_json:
        import json

        script_dir = os.path.dirname(os.path.abspath(__file__))
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        json_path = os.path.join(script_dir, f"edw_security_payload_{ts}.json")
        with open(json_path, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("OAA payload saved to: %s", json_path)

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — Veza push skipped")
        return

    log.info(
        "Pushing to Veza: provider=%s  datasource=%s  url=%s",
        provider_name,
        datasource_name,
        veza_url,
    )
    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for warning in response["warnings"]:
                log.warning("Veza warning: %s", warning)
        log.info(
            "Successfully pushed to Veza — provider=%s  datasource=%s",
            provider_name,
            datasource_name,
        )
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error,
            exc.message,
            exc.status_code,
        )
        if hasattr(exc, "details") and exc.details:
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI argument parser
# ---------------------------------------------------------------------------
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Enterprise Data Warehouse (EDW) Security — Veza OAA Integration",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # .env / Veza
    parser.add_argument(
        "--env-file",
        default=".env",
        metavar="PATH",
        help="Path to .env credentials file",
    )
    parser.add_argument(
        "--veza-url",
        default=None,
        metavar="URL",
        help="Veza tenant URL (overrides VEZA_URL env var)",
    )
    parser.add_argument(
        "--veza-api-key",
        default=None,
        metavar="KEY",
        help="Veza API key (overrides VEZA_API_KEY env var)",
    )
    parser.add_argument(
        "--provider-name",
        default=None,
        metavar="NAME",
        help="OAA provider name in Veza (overrides PROVIDER_NAME env var)",
    )
    parser.add_argument(
        "--datasource-name",
        default=None,
        metavar="NAME",
        help="OAA datasource name in Veza (overrides DATASOURCE_NAME env var)",
    )

    # Oracle DB
    parser.add_argument(
        "--db-host",
        default=None,
        metavar="HOST",
        help="Oracle DB hostname (overrides EDW_DB_HOST env var)",
    )
    parser.add_argument(
        "--db-port",
        default=None,
        metavar="PORT",
        help="Oracle DB port (overrides EDW_DB_PORT env var; default 1526)",
    )
    parser.add_argument(
        "--db-service",
        default=None,
        metavar="SID",
        help="Oracle DB SID or service name (overrides EDW_DB_SERVICE env var)",
    )
    parser.add_argument(
        "--db-user",
        default=None,
        metavar="USER",
        help="Oracle DB username (overrides EDW_DB_USER env var)",
    )
    parser.add_argument(
        "--db-password",
        default=None,
        metavar="PASS",
        help="Oracle DB password (overrides EDW_DB_PASSWORD env var)",
    )
    parser.add_argument(
        "--web-app-id",
        dest="web_app_id",
        default=None,
        metavar="ID",
        help="WEB_APP_ID filter value (overrides EDW_WEB_APP_ID env var)",
    )

    # Run control
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build payload without pushing to Veza",
    )
    parser.add_argument(
        "--save-json",
        action="store_true",
        help="Save the OAA JSON payload to disk for inspection",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity",
    )

    # OAA Dry-Run Tester compatibility shim
    parser.add_argument("--data-dir", default=None, help=argparse.SUPPRESS)

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    args = parse_args()
    _setup_logging(args.log_level)

    # Startup banner — print() is intentional for operator visibility
    print("=" * 64)
    print("  EDW Security  →  Veza OAA Integration")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Mode: {'DRY RUN (no Veza push)' if args.dry_run else 'LIVE'}")
    print("=" * 64)

    milestones = MilestoneTracker(total=5)

    # ── Milestone 1: Config
    milestones.reached("Loading and validating configuration")
    cfg = load_config(args)
    _validate_config(cfg, args.dry_run)
    log.info(
        "Config — provider=%s  datasource=%s  web_app_id=%s  db_host=%s  db_port=%s  db_sid=%s",
        cfg["provider_name"],
        cfg["datasource_name"],
        cfg["web_app_id"],
        cfg["db_host"],
        cfg["db_port"],
        cfg["db_service"],
    )

    # ── Milestone 2: Connect + query Oracle
    milestones.reached("Connecting to Oracle database")
    rows = fetch_access_data(cfg)

    # ── Milestone 3: Data confirmed
    milestones.reached(f"Fetched {len(rows)} access-control rows from Oracle")

    # ── Milestone 4: Build OAA payload
    milestones.reached("Building OAA payload")
    app, stats = build_oaa_payload(rows, cfg)

    # ── Milestone 5: Push to Veza
    milestones.reached(
        "Pushing payload to Veza" if not args.dry_run else "Finalising dry-run"
    )
    push_to_veza(
        veza_url=cfg["veza_url"],
        veza_api_key=cfg["veza_api_key"],
        provider_name=cfg["provider_name"],
        datasource_name=cfg["datasource_name"],
        app=app,
        dry_run=args.dry_run,
        save_json=args.save_json,
    )

    milestones.complete(
        users=stats["users"],
        resources=stats["resources"],
        permissions=stats["permissions"],
    )


if __name__ == "__main__":
    main()
