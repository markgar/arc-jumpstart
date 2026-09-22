#!/usr/bin/env python3

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_QUERY = ROOT / "queries" / "arc-sql-modeling-inventory.kql"
DEFAULT_OUTPUT_DIR = ROOT / "out" / "arc-modeling"
RESOURCE_GROUP_MARKER = "// __RESOURCE_GROUP_FILTER__"
FIELDS = [
    "RecordType",
    "JoinKey",
    "ParentJoinKey",
    "ResourceId",
    "ResourceName",
    "SubscriptionId",
    "ResourceGroup",
    "Location",
    "Tags",
    "Properties",
]


def azure_cli_path():
    override = os.environ.get("AZURE_CLI_PATH")
    if override:
        return override
    candidates = ("az.cmd", "az.exe", "az") if os.name == "nt" else ("az", "az.cmd", "az.exe")
    for candidate in candidates:
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError("Azure CLI was not found.")


def resource_group_filter(resource_group):
    if not resource_group:
        return ""
    escaped = resource_group.replace("\\", "\\\\").replace('"', '\\"')
    return f'| where resourceGroup =~ "{escaped}"'


def render_query(query_path, resource_group):
    query = query_path.read_text(encoding="utf-8")
    if RESOURCE_GROUP_MARKER not in query:
        raise RuntimeError(f"{query_path} is missing {RESOURCE_GROUP_MARKER}.")
    return query.replace(RESOURCE_GROUP_MARKER, resource_group_filter(resource_group), 1)


def query_resources(az, query, subscription):
    command = [
        az,
        "graph",
        "query",
        "--graph-query",
        query,
        "--first",
        "1000",
        "--output",
        "json",
    ]
    if subscription:
        command.extend(["--subscriptions", subscription])
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown Azure CLI error"
        raise RuntimeError(f"Azure Resource Graph query failed: {detail}")
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("Azure CLI returned invalid JSON.") from error
    if isinstance(payload, list):
        records = payload
        total_records = len(records)
    elif isinstance(payload, dict) and isinstance(payload.get("data"), list):
        records = payload["data"]
        total_records = int(payload.get("totalRecords", len(records)))
    else:
        raise RuntimeError("Azure CLI returned an unexpected Resource Graph response.")
    if total_records > len(records):
        raise RuntimeError(
            f"The query returned {total_records} records, exceeding the 1000-record export limit."
        )
    return payload, records


def write_export(output_dir, payload, records, timestamp):
    destination = output_dir / timestamp
    destination.mkdir(parents=True, exist_ok=False)
    raw_path = destination / "inventory.raw.json"
    csv_path = destination / "inventory.csv"
    raw_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    with csv_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow({field: record.get(field, "") for field in FIELDS})
    return raw_path, csv_path


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Export Arc machine and Arc-enabled SQL inventory for modeling."
    )
    parser.add_argument("--subscription", help="Limit the query to one subscription ID.")
    parser.add_argument("--resource-group", help="Limit the query to one Arc resource group.")
    parser.add_argument("--query-file", type=Path, default=DEFAULT_QUERY)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        query = render_query(args.query_file, args.resource_group)
        payload, records = query_resources(azure_cli_path(), query, args.subscription)
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        raw_path, csv_path = write_export(args.output_dir, payload, records, timestamp)
    except (OSError, RuntimeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Exported {len(records)} records.")
    print(f"Raw JSON: {raw_path}")
    print(f"Modeling CSV: {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
