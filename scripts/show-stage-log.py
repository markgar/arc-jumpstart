#!/usr/bin/env python3
"""Display redacted stage logs or a short live progress view from the host."""

import argparse
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from urllib.parse import quote, quote_plus, unquote, unquote_plus


STAGES = {
    "10": "10-init-host",
    "20": "20-host-network",
    "30": "30-download-images",
    "40": "40-create-nested-vms",
    "45": "45-install-sql",
    "50": "50-configure-domain",
    "60": "60-configure-sql-ag",
}
COMMANDS = {
    "10": "stage10-init-host",
    "20": "stage20-host-network",
    "30": "stage30-images",
    "40": "stage40-nested-vms",
    "45": "stage45-sql-install",
    "50": "stage50-domain",
    "60": "stage60-sql-ag",
}
SENSITIVE_NAME = re.compile(
    r"password|passwd|secret|token|(?:^|_)sas(?:_|$)|"
    r"(?:access|account|storage|private|api)[_-]?key|connection[_-]?string",
    re.IGNORECASE,
)
SECRET_PARAMETER = re.compile(
    r"(?:^|[?&;])(?:sig|token|access_token|client_secret|password|"
    r"AccountKey|SharedAccessKey|SharedAccessSignature)=([^&#;\s]+)",
    re.IGNORECASE,
)
HEADER_START = re.compile(r"Windows PowerShell transcript start|Host\s+Application\s*:", re.IGNORECASE)
HEADER_END = re.compile(r"^\s*\*{6,}\s*$")
ANSI_SEQUENCE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
TERMINAL_STATES = {"Succeeded", "Failed", "Canceled"}

# Filter the entire header before tail selection: a tail beginning in a wrapped
# process argument would otherwise have lost the Host Application label.
TRANSCRIPT_FILTER = r"""
function Remove-TranscriptStartupHeader {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Line)
    begin { $suppress = $false }
    process {
        if ($Line -match 'Windows PowerShell transcript start|Host\s+Application\s*:') {
            if (-not $suppress) { '[Transcript startup header suppressed]' }
            $suppress = $true
        }
        elseif ($suppress) {
            if ($Line -match '^\s*\*{6,}\s*$') { $suppress = $false }
        }
        else { $Line }
    }
}
"""


def load_configuration(path):
    """Match lab.sh's literal KEY=value loader; never execute configuration."""
    settings = {}
    entries = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        settings.setdefault(key, value)
        entries.append((key, value))
    return settings, entries


class Redactor:
    def __init__(self, entries):
        secrets = set()
        for key, value in entries:
            if SENSITIVE_NAME.search(key) and value:
                secrets.add(value)
                if "sas" in key.lower():
                    secrets.add(value.lstrip("?"))
            # SAS signatures also occur inside otherwise non-sensitive URL settings.
            secrets.update(match.group(1) for match in SECRET_PARAMETER.finditer(value))

        variants = set()
        for secret in secrets:
            for decoded in {secret, unquote(secret), unquote_plus(secret)}:
                if not decoded:
                    continue
                variants.update({
                    decoded,
                    quote(decoded, safe=""),
                    quote_plus(decoded, safe=""),
                    html.escape(decoded, quote=True),
                    html.escape(decoded, quote=True).replace("&#x27;", "&apos;"),
                    json.dumps(decoded, ensure_ascii=True)[1:-1],
                    json.dumps(decoded, ensure_ascii=False)[1:-1],
                    decoded.replace("'", "''"),
                    re.sub(r'[`$"]', lambda match: "`" + match.group(), decoded),
                })
        # Percent-escape hex digits are case-insensitive; secret characters are not.
        def literal_pattern(value):
            return re.sub(r"%[0-9A-Fa-f]{2}", lambda match: "(?i:" + match.group() + ")", re.escape(value))

        self.pattern = (re.compile("|".join(literal_pattern(value) for value in
                                          sorted(variants, key=lambda value: (-len(value), value))))
                        if variants else None)

    def sanitize(self, text):
        if isinstance(text, bytes):
            text = text.decode("utf-8", errors="replace")
        text = ANSI_SEQUENCE.sub("", text)
        output = []
        suppress = False
        for line in text.splitlines(keepends=True):
            if HEADER_START.search(line):
                if not suppress:
                    output.append("[Transcript startup header suppressed]\n")
                suppress = True
            elif suppress:
                if HEADER_END.fullmatch(line):
                    suppress = False
            else:
                output.append(line)
        text = "".join(output)
        return self.pattern.sub("[REDACTED]", text) if self.pattern else text


def stage_script(stage, line_count=200):
    prefix = STAGES[stage]
    return TRANSCRIPT_FILTER + rf"""
$ErrorActionPreference = 'Stop'
$log = Get-ChildItem 'C:\ArcJumpstart\Logs\{prefix}-*.log' -ErrorAction Stop |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) {{ throw 'No matching stage transcript was found.' }}
Write-Host ('HostLog={0}' -f $log.FullName)
Write-Host ('LastWriteUtc={0:o}' -f $log.LastWriteTimeUtc)
Write-Host ('SizeBytes={0}' -f $log.Length)
Get-Content -LiteralPath $log.FullName -ErrorAction Stop |
    Remove-TranscriptStartupHeader | Select-Object -Last {line_count}
"""


def azure_cli_path():
    override = os.environ.get("AZURE_CLI_PATH")
    if override:
        return override
    candidates = ("az.cmd", "az.exe", "az") if os.name == "nt" else ("az", "az.cmd", "az.exe")
    for candidate in candidates:
        path = shutil.which(candidate)
        if path:
            return path
    raise FileNotFoundError("Azure CLI was not found on PATH.")


def run_az(arguments, redactor):
    # Raw output stays in memory, never in a temporary transcript/download file.
    try:
        result = subprocess.run(
            [azure_cli_path(), *arguments], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
    except OSError as error:
        print(f"Unable to run Azure CLI ({type(error).__name__}).", file=sys.stderr)
        return 1
    sys.stdout.write(redactor.sanitize(result.stdout))
    sys.stderr.write(redactor.sanitize(result.stderr))
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


def elapsed_time(start):
    if not start:
        return "unknown"
    try:
        # Azure commonly emits seven fractional-second digits; Python 3.9
        # accepts at most six.
        normalized_start = re.sub(r"(\.\d{6})\d+(?=[+-]|Z|$)", r"\1", start)
        started = datetime.fromisoformat(normalized_start.replace("Z", "+00:00"))
        return str(datetime.now(timezone.utc) - started).split(".", 1)[0]
    except (TypeError, ValueError):
        return "unknown"


def print_progress(stage, progress, redactor):
    start = progress.get("start")
    print(f"Stage={stage}")
    print(f"ExecutionState={progress.get('state') or 'unknown'}")
    print(f"StartUtc={start or 'unknown'}")
    print(f"EndUtc={progress.get('end') or ''}")
    print(f"Elapsed={elapsed_time(start)}")
    print("LatestOutput:")
    output = progress.get("output") or "(no output reported yet)"
    print(redactor.sanitize(output).rstrip())
    if progress.get("error"):
        print("LatestError:", file=sys.stderr)
        print(redactor.sanitize(progress["error"]).rstrip(), file=sys.stderr)


def run_json_az(arguments, redactor):
    try:
        result = subprocess.run(
            [azure_cli_path(), *arguments], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
    except OSError as error:
        print(f"Unable to run Azure CLI ({type(error).__name__}).", file=sys.stderr)
        return 1
    sys.stderr.write(redactor.sanitize(result.stderr))
    if result.returncode:
        sys.stdout.write(redactor.sanitize(result.stdout))
        return result.returncode, None
    try:
        return 0, json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError):
        print("Azure returned an unreadable progress response.", file=sys.stderr)
        return 1, None


def run_progress(settings, stage, redactor):
    status, progress = run_json_az([
        "vm", "run-command", "show",
        "--resource-group", settings["AZURE_RESOURCE_GROUP"],
        "--vm-name", settings["NAME_PREFIX"] + "-host",
        "--name", COMMANDS[stage],
        "--expand", "instanceView",
        "--query", "{state:instanceView.executionState,start:instanceView.startTime,"
                   "end:instanceView.endTime,output:instanceView.output,error:instanceView.error}",
        "--output", "json",
    ], redactor)
    if status:
        return status
    print_progress(stage, progress, redactor)
    return 0


def run_build_status(settings, redactor):
    status, commands = run_json_az([
        "vm", "run-command", "list",
        "--resource-group", settings["AZURE_RESOURCE_GROUP"],
        "--vm-name", settings["NAME_PREFIX"] + "-host",
        "--expand", "instanceView",
        "--output", "json",
    ], redactor)
    if status:
        return status

    stages_by_command = {command: stage for stage, command in COMMANDS.items()}
    observed = []
    for command in commands:
        stage = stages_by_command.get(command.get("name"))
        if not stage:
            continue
        instance_view = command.get("instanceView") or {}
        observed.append((stage, {
            "state": instance_view.get("executionState"),
            "start": instance_view.get("startTime"),
            "end": instance_view.get("endTime"),
            "output": instance_view.get("output"),
            "error": instance_view.get("error"),
        }))

    active = [
        item for item in observed
        if item[1].get("state") and item[1]["state"] not in TERMINAL_STATES
    ]
    if active:
        selected = sorted(active, key=lambda item: list(STAGES).index(item[0]))
        print("BuildState=Running")
        print("ActiveStages=" + ",".join(stage for stage, _ in selected))
    elif observed:
        selected = [max(observed, key=lambda item: item[1].get("start") or "")]
        print("BuildState=NoActiveStage")
        print("ActiveStages=")
        print(f"LatestStage={selected[0][0]}")
    else:
        print("BuildState=NotStarted")
        print("ActiveStages=")
        print("No canonical stage Run Command was found. Stage 00 or local preflight may still be running.")
        return 0

    for index, (stage, progress) in enumerate(selected):
        if index:
            print("---")
        print_progress(stage, progress, redactor)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True)
    parser.add_argument("--progress", action="store_true",
                        help="Show a concise live tail rather than the longer diagnostic view.")
    parser.add_argument("--auto", action="store_true",
                        help="Discover and show all active canonical stages.")
    parser.add_argument("stage", nargs="?")
    args = parser.parse_args(argv)
    try:
        settings, entries = load_configuration(args.env_file)
    except (OSError, UnicodeError) as error:
        # Exception messages can contain offending configuration bytes.
        print(f"Unable to read viewer configuration ({type(error).__name__}).", file=sys.stderr)
        return 1
    redactor = Redactor([*entries, *os.environ.items()])
    if args.auto and not args.progress:
        parser.error("--auto requires --progress")
    if not args.auto and args.stage not in STAGES:
        print("Usage: scripts/lab.sh <stage-progress|stage-log> <10|20|30|40|45|50|60>",
              file=sys.stderr)
        return 1
    required = ("AZURE_SUBSCRIPTION_ID", "AZURE_RESOURCE_GROUP", "NAME_PREFIX")
    if any(not settings.get(key) for key in required):
        print("AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, and NAME_PREFIX are required.", file=sys.stderr)
        return 1
    print("Display redaction only: stored host transcripts remain sensitive and unchanged.", file=sys.stderr)
    status = run_az(["account", "set", "--subscription", settings["AZURE_SUBSCRIPTION_ID"]], redactor)
    if status:
        return status
    if args.auto:
        return run_build_status(settings, redactor)
    if args.progress:
        return run_progress(settings, args.stage, redactor)
    return run_az([
        "vm", "run-command", "invoke",
        "--resource-group", settings["AZURE_RESOURCE_GROUP"],
        "--name", settings["NAME_PREFIX"] + "-host",
        "--command-id", "RunPowerShellScript",
        "--scripts", stage_script(args.stage, 60 if args.progress else 200),
        "--query", "value[0].message", "--output", "tsv",
    ], redactor)


if __name__ == "__main__":
    sys.exit(main())
