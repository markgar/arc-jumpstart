#!/usr/bin/env python3

import csv
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "export_arc_inventory", ROOT / "scripts" / "export-arc-inventory.py"
)
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


class ExportArcInventoryTests(unittest.TestCase):
    def test_render_query_scopes_resource_group(self):
        query = EXPORTER.render_query(
            ROOT / "queries" / "arc-sql-modeling-inventory.kql",
            "rg-arc",
        )
        self.assertIn('| where resourceGroup =~ "rg-arc"', query)
        self.assertNotIn(EXPORTER.RESOURCE_GROUP_MARKER, query)

    def test_query_resources_reads_graph_envelope(self):
        response = {
            "count": 1,
            "totalRecords": 1,
            "data": [{"RecordType": "ARC_MACHINE", "ResourceName": "JS-SQL-01"}],
        }
        completed = type(
            "Completed",
            (),
            {"returncode": 0, "stdout": json.dumps(response), "stderr": ""},
        )()
        with patch.object(EXPORTER.subprocess, "run", return_value=completed) as run:
            payload, records = EXPORTER.query_resources("az", "resources", "sub-id")
        self.assertEqual(payload, response)
        self.assertEqual(records, response["data"])
        command = run.call_args.args[0]
        self.assertIn("--subscriptions", command)
        self.assertIn("sub-id", command)

    def test_write_export_preserves_raw_and_csv(self):
        record = {
            "RecordType": "DATABASE",
            "ResourceName": "JumpstartStandaloneDB",
            "Properties": '{"status":"Online"}',
        }
        with tempfile.TemporaryDirectory() as directory:
            raw_path, csv_path = EXPORTER.write_export(
                Path(directory),
                {"data": [record], "count": 1, "totalRecords": 1},
                [record],
                "20260922T120000Z",
            )
            self.assertEqual(json.loads(raw_path.read_text())["data"], [record])
            with csv_path.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(rows[0]["ResourceName"], "JumpstartStandaloneDB")
            self.assertEqual(rows[0]["Properties"], '{"status":"Online"}')

    def test_lab_inventory_uses_configured_arc_scope(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".inventory-test-") as directory:
            work = Path(directory)
            bin_dir = work / "bin"
            bin_dir.mkdir()
            az = bin_dir / "az"
            az.write_text(
                """#!/usr/bin/env bash
if [[ "$1" == account && "$2" == set ]]; then
  exit 0
fi
if [[ "$1" == graph && "$2" == query ]]; then
  printf '%s\\n' '{"count":1,"totalRecords":1,"data":[{"RecordType":"ARC_MACHINE","ResourceName":"JS-SQL-01"}]}'
  exit 0
fi
exit 2
"""
            )
            az.chmod(0o755)
            env_file = work / "lab.env"
            env_file.write_text(
                "\n".join(
                    [
                        "AZURE_SUBSCRIPTION_ID=sub-id",
                        "AZURE_RESOURCE_GROUP=rg-infra",
                        "NAME_PREFIX=jsarc",
                        "ARC_RESOURCE_GROUP=rg-arc",
                    ]
                )
                + "\n"
            )
            output_dir = work / "output"
            env = os.environ.copy()
            env["ENV_FILE"] = str(env_file)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts" / "lab.sh"), "inventory", str(output_dir)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Exported 1 records.", result.stdout)
            exports = list(output_dir.glob("*/inventory.csv"))
            self.assertEqual(len(exports), 1)


if __name__ == "__main__":
    unittest.main()
