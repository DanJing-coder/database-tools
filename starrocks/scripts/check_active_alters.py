# -*- coding: utf-8 -*-
import mysql.connector
from mysql.connector import Error
import argparse
from datetime import datetime
import sys
import os

# ==================== Default connection settings (modify these for your cluster) ====================
DEFAULT_HOST     = "172.16.1.10"          # ← Change to your FE address or domain
DEFAULT_PORT     = 9030
DEFAULT_USER     = "root"
DEFAULT_PASSWORD = "your_secure_password"  # ← Change to your actual password
# ====================================================================================


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check active schema change (ALTER) jobs in StarRocks cluster"
    )
    parser.add_argument("--host",      default=DEFAULT_HOST,     help=f"StarRocks FE host or IP (default: {DEFAULT_HOST})")
    parser.add_argument("--port",      type=int, default=DEFAULT_PORT, help=f"Query port (default: {DEFAULT_PORT})")
    parser.add_argument("--user",      default=DEFAULT_USER,     help=f"Username (default: {DEFAULT_USER})")
    parser.add_argument("--password",  default=DEFAULT_PASSWORD, help="Password (default: value set in script)")
    parser.add_argument("--cancel",    action="store_true",      help="Also generate CANCEL commands file")
    parser.add_argument("--output-dir", default=".",             help="Directory to save output files (default: current directory)")

    return parser.parse_args()


def connect_to_starrocks(host, port, user, password):
    try:
        conn = mysql.connector.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            connection_timeout=30
        )
        print(f"Connected to StarRocks {host}:{port}")
        return conn
    except Error as e:
        print(f"Connection failed: {e}", file=sys.stderr)
        sys.exit(1)


def get_all_databases(cursor):
    cursor.execute("SHOW DATABASES")
    rows = cursor.fetchall()
    dbs = [row[0] for row in rows 
           if row[0] not in ('information_schema', 'sys', '__internal_schema', 'mysql')]
    return sorted(dbs)


def get_active_alters(cursor, db_name, alter_type="COLUMN"):
    query = f"SHOW ALTER TABLE {alter_type} FROM `{db_name}`"
    try:
        cursor.execute(query)
        rows = cursor.fetchall()
        if not rows:
            return []

        columns = [col[0].lower() for col in cursor.description]

        idx_jobid    = next((i for i, c in enumerate(columns) if 'job' in c and 'id' in c), -1)
        idx_table    = next((i for i, c in enumerate(columns) if 'table' in c), -1)
        idx_state    = next((i for i, c in enumerate(columns) if 'state' in c), -1)
        idx_progress = next((i for i, c in enumerate(columns) if 'progress' in c), -1)
        idx_create   = next((i for i, c in enumerate(columns) if 'create' in c), -1)
        idx_base     = next((i for i, c in enumerate(columns) if 'base' in c), -1)
        idx_rollup   = next((i for i, c in enumerate(columns) if 'rollup' in c and 'name' in c), -1)

        active = []
        for row in rows:
            state = str(row[idx_state]).strip().upper() if idx_state >= 0 else ""
            if state in ("FINISHED", "CANCELLED", ""):
                continue

            job_info = {
                "type": alter_type.upper(),
                "job_id": str(row[idx_jobid]) if idx_jobid >= 0 else "N/A",
                "table": str(row[idx_table]) if idx_table >= 0 else "N/A",
                "db": db_name,
                "state": state,
                "progress": str(row[idx_progress]) if idx_progress >= 0 else "N/A",
                "create_time": str(row[idx_create]) if idx_create >= 0 else "N/A",
                "base_index": str(row[idx_base]) if idx_base >= 0 else "",
                "rollup_index": str(row[idx_rollup]) if idx_rollup >= 0 else "",
            }
            active.append(job_info)
        return active
    except Error as e:
        print(f"Failed: {query} → {e}", file=sys.stderr)
        return []


def format_job_line(job):
    rollup_part = f" → {job['rollup_index']}" if job['rollup_index'] and job['type'] == "ROLLUP" else ""
    base_part   = f" (base: {job['base_index']})" if job['base_index'] else ""
    return (
        f"JobId: {job['job_id']}\n"
        f"  Type: {job['type']:8} | DB: {job['db']} | Table: {job['table']}{rollup_part}{base_part}\n"
        f"  State: {job['state']:<10}  Progress: {job['progress']}\n"
        f"  Created: {job['create_time']}\n"
    )


def generate_cancel_command(job):
    return f"CANCEL ALTER TABLE {job['type']} FROM `{job['db']}`.`{job['table']}` ({job['job_id']});"


def main():
    args = parse_args()

    # Security note: warn if using default or empty password
    if args.password in ("your_secure_password", ""):
        print("Warning: Using default or empty password. Please update DEFAULT_PASSWORD in the script.", file=sys.stderr)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    report_file = os.path.join(args.output_dir, f"active_alters_report_{timestamp}.txt")
    cancel_file = os.path.join(args.output_dir, f"cancel_commands_{timestamp}.sql") if args.cancel else None

    conn = connect_to_starrocks(args.host, args.port, args.user, args.password)
    cursor = conn.cursor()

    databases = get_all_databases(cursor)

    lines = []
    cancel_lines = []
    has_active = False

    lines.append(f"Scan time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"Host: {args.host}:{args.port}")
    lines.append(f"Found {len(databases)} user databases")
    lines.append("-" * 60)
    lines.append("")

    for db in databases:
        active_jobs = []
        for alter_type in ["COLUMN", "OPTIMIZE", "ROLLUP"]:
            jobs = get_active_alters(cursor, db, alter_type)
            active_jobs.extend(jobs)

        if not active_jobs:
            continue

        has_active = True
        lines.append(f"Database: {db}")
        lines.append("  Active schema change jobs:")

        for job in active_jobs:
            lines.append(format_job_line(job))
            if args.cancel:
                cancel_lines.append(generate_cancel_command(job))

        lines.append("")

    if not has_active:
        lines.append("No active schema change (ALTER) operations found.")

    # Write report file
    with open(report_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print("\n".join(lines))  # Also print to console

    if args.cancel and cancel_lines:
        with open(cancel_file, "w", encoding="utf-8") as f:
            f.write("-- Auto generated CANCEL commands for active ALTER jobs\n")
            f.write(f"-- Generated at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("-- Please REVIEW carefully before executing!\n\n")
            f.write("\n".join(cancel_lines))
            f.write("\n")
        print(f"\nCANCEL commands saved to: {cancel_file}")
    elif args.cancel:
        print("\nNo active jobs → no CANCEL commands generated.")

    print(f"\nReport saved to: {report_file}")

    cursor.close()
    conn.close()
    print("Connection closed.")


if __name__ == "__main__":
    main()