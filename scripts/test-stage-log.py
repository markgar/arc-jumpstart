import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import quote

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("show_stage_log", Path(__file__).with_name("show-stage-log.py"))
viewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(viewer)


class RedactionTests(unittest.TestCase):
    def test_configured_values_and_representations(self):
        password = 'fake<&>"\'$pass\\word'
        signature = "fake+signature/value="
        sas = "?sv=2025-01-01&sig=" + quote(signature, safe="")
        redactor = viewer.Redactor([
            ("NESTED_WINDOWS_PASSWORD", password),
            ("IMAGE_SOURCE_SAS_TOKEN", sas),
            ("CLIENT_SECRET", "fake-client-secret"),
            ("AZURE_STORAGE_KEY", "fake-storage-key"),
            ("SQL_DOWNLOAD_URL", "https://example.invalid/image?sig=another-fake-signature"),
            ("EMPTY_PASSWORD", ""),
        ])
        variants = [
            password, quote(password, safe=""), viewer.html.escape(password),
            json.dumps(password)[1:-1], password.replace("'", "''"),
            sas, sas.lstrip("?"), signature, quote(signature, safe=""),
            quote(signature, safe="").replace("%2B", "%2b").replace("%2F", "%2f"),
            "fake-client-secret", "fake-storage-key", "another-fake-signature",
        ]
        for value in variants:
            with self.subTest(value_type=variants.index(value)):
                self.assertEqual(redactor.sanitize(value), "[REDACTED]")
        self.assertEqual(redactor.sanitize("LicenseStatus=1; error 0xC004FD02\n"), "LicenseStatus=1; error 0xC004FD02\n")

    def test_longest_literal_match_and_ansi(self):
        redactor = viewer.Redactor([("PASSWORD", "fake.*"), ("TOKEN", "fake.*-long")])
        self.assertEqual(redactor.sanitize("\x1b[31mfake.*-long\x1b[0m fake.*"), "[REDACTED] [REDACTED]")
        self.assertEqual(redactor.sanitize("fake-ordinary"), "fake-ordinary")

    def test_headers_and_wrapped_arguments_even_without_current_secret(self):
        redactor = viewer.Redactor([])
        for start in ("Windows PowerShell transcript start", "Host Application: powershell.exe -Password fake-old-password"):
            raw = (
                "before\n" + start + "\r\n"
                " -NestedWindowsPassword fake-unconfigured\r\n"
                "wrapped-without-indentation fake-another-old-secret\r\n"
                "Process ID: 123\r\nPSVersion: 5.1\r\n"
                "**********************\r\nnative diagnostic preserved\n"
            )
            output = redactor.sanitize(raw)
            self.assertNotIn("fake-", output)
            self.assertNotIn("Host Application", output)
            self.assertIn("before", output)
            self.assertIn("native diagnostic preserved", output)
            self.assertIn("header suppressed", output)
        self.assertNotIn("fake", redactor.sanitize("Host Application: fake\nunfinished wrapped fake"))

    def test_configuration_is_literal_and_all_duplicate_secrets_are_redacted(self):
        with tempfile.TemporaryDirectory(dir=ROOT, prefix=".stage-log-test-") as directory:
            path = Path(directory) / "fake.env"
            path.write_text("# comment\nNAME_PREFIX=first\nNAME_PREFIX=second\nPASSWORD=fake-one\nPASSWORD=fake-two\nSECRET=$(do-not-execute)\n")
            settings, entries = viewer.load_configuration(path)
            self.assertEqual(settings["NAME_PREFIX"], "first")
            redactor = viewer.Redactor(entries)
            self.assertEqual(redactor.sanitize("fake-one fake-two $(do-not-execute)"), "[REDACTED] [REDACTED] [REDACTED]")

    def test_both_streams_and_exit_status(self):
        redactor = viewer.Redactor([("PASSWORD", "fake-sensitive")])
        result = subprocess.CompletedProcess(
            [], 17, b"stdout fake-sensitive useful\n",
            b"Host Application: fake-old-unconfigured\nwrapped old arguments\n**********************\nstderr fake-sensitive failure\n",
        )
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(viewer.subprocess, "run", return_value=result) as run, contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = viewer.run_az(["test"], redactor)
        self.assertEqual(status, 17)
        self.assertEqual(stdout.getvalue(), "stdout [REDACTED] useful\n")
        self.assertEqual(stderr.getvalue(), "[Transcript startup header suppressed]\nstderr [REDACTED] failure\n")
        self.assertEqual(run.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.PIPE)


class ViewerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=ROOT, prefix=".stage-log-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env_file = self.root / "fake.env"
        self.env_file.write_text(
            "AZURE_SUBSCRIPTION_ID=fake-subscription\nAZURE_RESOURCE_GROUP=fake-group\n"
            "NAME_PREFIX=fake-lab\nHOST_ADMIN_PASSWORD=fake-host-password\n"
            "SAFE_MODE_PASSWORD=fake-dsrm-password\nSQL_SERVICE_ACCOUNT_PASSWORD=fake-sql-password\n"
            "IMAGE_SOURCE_SAS_TOKEN=?sv=2025-01-01&sig=fake-sas-signature\n"
        )
        self.calls = self.root / "calls.jsonl"
        az = self.root / "az"
        az.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "with open(os.environ['FAKE_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
            "account = sys.argv[1:3] == ['account', 'set']\n"
            "progress = sys.argv[1:4] == ['vm', 'run-command', 'show']\n"
            "code = int(os.environ.get('FAKE_ACCOUNT_EXIT' if account else 'FAKE_LOG_EXIT', '0'))\n"
            "if progress and not code:\n"
            "    print(json.dumps({'state':'Running','start':'2026-09-16T15:22:41.8721341+00:00','end':None,\n"
            "      'output':'2026-09-16T15:22:51Z [stage40] waiting fake-host-password','error':''}))\n"
            "elif not account or code:\n"
            "    print('Host Application: powershell.exe -Password fake-unconfigured-old')\n"
            "    print('wrapped fake-old-value\\nProcess ID: 123\\n**********************')\n"
            "    print('diagnostic: fake-host-password fake-dsrm-password fake-sql-password fake-sas-signature')\n"
            "    print('error: fake-host-password fake-environment-secret 0x80070005', file=sys.stderr)\n"
            "sys.exit(code)\n"
        )
        az.chmod(0o700)
        # Do not inherit real credentials or configuration into the fake CLI.
        self.environment = {
            "PATH": str(self.root) + os.pathsep + os.path.dirname(sys.executable) + os.pathsep + "/usr/bin:/bin",
            "HOME": str(self.root), "ENV_FILE": str(self.env_file),
            "FAKE_CALLS": str(self.calls), "AZURE_CLIENT_SECRET": "fake-environment-secret",
        }

    def run_viewer(self, stage="60", command="stage-log"):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/lab.sh"), command, stage],
            env=self.environment, capture_output=True, text=True, check=False,
        )

    def assert_safe_output(self, result):
        combined = result.stdout + result.stderr
        for secret in ("fake-host-password", "fake-dsrm-password", "fake-sql-password",
                       "fake-sas-signature", "fake-environment-secret", "fake-unconfigured-old", "fake-old-value"):
            self.assertNotIn(secret, combined)
        self.assertIn("diagnostic:", result.stdout)
        self.assertIn("0x80070005", result.stderr)
        self.assertIn("stored host transcripts remain sensitive and unchanged", result.stderr)

    def test_real_shell_dispatch_uses_only_fake_cli_and_sanitizes_failure(self):
        self.environment["FAKE_LOG_EXIT"] = "23"
        result = self.run_viewer()
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assert_safe_output(result)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[0], ["account", "set", "--subscription", "fake-subscription"])
        self.assertEqual(calls[1][:3], ["vm", "run-command", "invoke"])
        script = calls[1][calls[1].index("--scripts") + 1]
        self.assertIn("60-configure-sql-ag-*.log", script)
        self.assertIn("Select-Object -Last 200", script)
        self.assertIn("LastWriteUtc=", script)
        self.assertNotIn("-Tail", script)
        self.assertLess(script.rindex("Remove-TranscriptStartupHeader"), script.rindex("Select-Object -Last 200"))
        for secret in ("fake-host-password", "fake-dsrm-password", "fake-sql-password", "fake-sas-signature"):
            self.assertNotIn(secret, json.dumps(calls))

    def test_account_failure_is_sanitized_and_stops(self):
        self.environment["FAKE_ACCOUNT_EXIT"] = "19"
        result = self.run_viewer()
        self.assertEqual(result.returncode, 19)
        self.assert_safe_output(result)
        self.assertEqual(len(self.calls.read_text().splitlines()), 1)

    def test_success_status_and_invalid_stage(self):
        result = self.run_viewer("45")
        self.assertEqual(result.returncode, 0)
        self.assert_safe_output(result)
        before = self.calls.read_text()
        result = self.run_viewer("--fake-host-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("fake-host-password", result.stderr)
        self.assertEqual(self.calls.read_text(), before)

    def test_progress_view_is_a_short_live_tail(self):
        result = self.run_viewer("40", "stage-progress")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[1][:3], ["vm", "run-command", "show"])
        self.assertIn("stage40-nested-vms", calls[1])
        self.assertNotIn("invoke", calls[1])
        self.assertIn("ExecutionState=Running", result.stdout)
        self.assertIn("Elapsed=", result.stdout)
        self.assertNotIn("Elapsed=unknown", result.stdout)
        self.assertIn("[stage40] waiting [REDACTED]", result.stdout)
        self.assertNotIn("fake-host-password", result.stdout + result.stderr)

    def test_every_stage_has_timestamped_progress_or_worker_logging(self):
        direct = ("10-init-host.ps1", "20-host-network.ps1", "30-download-images.ps1",
                  "40-create-nested-vms.ps1", "50-configure-domain.ps1",
                  "60-configure-sql-ag.ps1")
        for name in direct:
            with self.subTest(name=name):
                source = (ROOT / "artifacts" / "scripts" / name).read_text()
                self.assertIn("[DateTime]::UtcNow.ToString('o')", source)
                self.assertRegex(source, r"\[stage(?:10|20|30|40|50|60)\]")
        sql = (ROOT / "artifacts" / "scripts" / "45-install-sql.ps1").read_text()
        self.assertIn("function Write-StageLog", sql)
        self.assertIn("remains $($worker.Job.State)", sql)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required for the native transcript-filter test")
    def test_actual_remote_filter_suppresses_header_before_tail(self):
        log = self.root / "fake.log"
        lines = ["**********************", "Windows PowerShell transcript start", "Host Application: fake-old-secret"]
        lines += ["unindented wrapped fake-old-secret"] * 250
        lines += ["Process ID: 123", "PSVersion: 5.1", "**********************"]
        lines += ["useful diagnostic " + str(index) for index in range(20)]
        log.write_text("\r\n".join(lines))
        script = self.root / "filter.ps1"
        script.write_text(
            "param([string]$LogPath)\n" + viewer.TRANSCRIPT_FILTER +
            "\nGet-Content -LiteralPath $LogPath | Remove-TranscriptStartupHeader | Select-Object -Last 200\n"
        )
        result = subprocess.run(
            [shutil.which("pwsh"), "-NoProfile", "-NonInteractive", "-File", str(script), "-LogPath", str(log)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("fake-old-secret", result.stdout)
        self.assertIn("useful diagnostic 0", result.stdout)
        self.assertIn("useful diagnostic 19", result.stdout)


if __name__ == "__main__":
    unittest.main()
