#!/usr/bin/env bash

is_native_windows_posix_shell() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

require_deployment_runtime() {
  if is_native_windows_posix_shell; then
    cat >&2 <<'EOF'
This command is not supported from Git Bash, MSYS2, or Cygwin.
On Windows, run the deployment and lab-management commands inside WSL2 with
Azure CLI and Python installed in that same WSL distribution. See
docs/01-prerequisites.md. Without WSL2, use scripts/validate.sh only.
EOF
    return 1
  fi
}
