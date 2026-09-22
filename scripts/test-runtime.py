import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class RuntimeTests(unittest.TestCase):
    def run_check(self, kernel):
        command = (
            "source scripts/runtime.sh; "
            f"uname() {{ printf '%s\\n' '{kernel}'; }}; "
            "require_deployment_runtime"
        )
        return subprocess.run(
            ["bash", "-c", command],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )

    def test_linux_runtime_is_supported(self):
        result = self.run_check("Linux")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_git_bash_runtime_is_rejected_with_wsl_guidance(self):
        for kernel in ("MINGW64_NT-10.0", "MSYS_NT-10.0", "CYGWIN_NT-10.0"):
            with self.subTest(kernel=kernel):
                result = self.run_check(kernel)
                self.assertEqual(result.returncode, 1)
                self.assertIn("not supported from Git Bash, MSYS2, or Cygwin", result.stderr)
                self.assertIn("WSL2", result.stderr)
                self.assertIn("scripts/validate.sh only", result.stderr)


if __name__ == "__main__":
    unittest.main()
