#!/usr/bin/env python3
"""Display redacted stage logs or a short live progress view from the host."""

import argparse
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
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


def run_az(arguments, redactor):
    # Raw output stays in memory, never in a temporary transcript/download file.
    try:
        result = subprocess.run(
            ["az", *arguments], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
    except OSError as error:
        print(f"Unable to run Azure CLI ({type(error).__name__}).", file=sys.stderr)
        return 1
    sys.stdout.write(redactor.sanitize(result.stdout))
    sys.stderr.write(redactor.sanitize(result.stderr))
    return result.returncode if result.returncode >= 0 else 128 - result.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True)
    parser.add_argument("--progress", action="store_true",
                        help="Show a concise live tail rather than the longer diagnostic view.")
    parser.add_argument("stage")
    args = parser.parse_args(argv)
    try:
        settings, entries = load_configuration(args.env_file)
    except (OSError, UnicodeError) as error:
        # Exception messages can contain offending configuration bytes.
        print(f"Unable to read viewer configuration ({type(error).__name__}).", file=sys.stderr)
        return 1
    redactor = Redactor([*entries, *os.environ.items()])
    if args.stage not in STAGES:
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
