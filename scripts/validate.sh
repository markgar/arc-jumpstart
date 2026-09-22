#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source "$repo_root/scripts/runtime.sh"

if is_native_windows_posix_shell; then
  echo "Windows source-validation mode: deployment and lab-management commands require WSL2."
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required by scripts/validate.sh." >&2
  exit 1
fi

echo "Building Bicep templates..."
for template in infra/stages/*/main.bicep; do
  echo "  $template"
  az bicep build --file "$template" --stdout >/dev/null
done

echo "Checking Bash scripts..."
for script in scripts/*.sh; do
  bash -n "$script"
done
python3 scripts/test-check-sql-media.py
python3 scripts/test-arc-launcher.py
python3 scripts/test-docs.py
python3 scripts/test-export-arc-inventory.py
python3 scripts/test-runtime.py
python3 scripts/test-skill.py
python3 scripts/test-stage-log.py
python3 scripts/test-bastion.py

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh
else
  echo "  shellcheck not installed; skipped"
fi

if command -v pwsh >/dev/null 2>&1; then
  echo "Parsing PowerShell scripts..."
  # shellcheck disable=SC2016
  pwsh -NoLogo -NoProfile -Command '
    $failed = $false
    Get-ChildItem artifacts/scripts/*.ps1 | ForEach-Object {
      $tokens = $null
      $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$errors
      )
      if ($errors.Count -gt 0) {
        $failed = $true
        $errors | ForEach-Object { Write-Error "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }
      }
    }
    if ($failed) { exit 1 }
  '
  pwsh -NoLogo -NoProfile -File scripts/test-stage40.ps1
  pwsh -NoLogo -NoProfile -File scripts/test-stage45.ps1
  pwsh -NoLogo -NoProfile -File scripts/test-stage50.ps1
  pwsh -NoLogo -NoProfile -File scripts/test-stage60.ps1
else
  echo "PowerShell is not installed; parser validation skipped."
fi

echo "Validation completed."
