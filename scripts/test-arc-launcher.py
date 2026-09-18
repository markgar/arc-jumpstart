from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "artifacts" / "scripts" / "prepare-arc-device-code-launchers.ps1"
STAGER = ROOT / "artifacts" / "scripts" / "stage-arc-device-code-launchers.ps1"
BICEP = ROOT / "infra" / "stages" / "arc-launchers" / "main.bicep"


class ArcLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = SCRIPT.read_text(encoding="utf-8")

    def test_targets_every_windows_guest_public_desktop(self):
        for vm_name in ("JS-DC-01", "JS-SQL-01", "JS-SQL-AG-01", "JS-SQL-AG-02"):
            self.assertIn(f"'{vm_name}'", self.content)
        self.assertIn("Join-Path $env:PUBLIC 'Desktop'", self.content)
        self.assertIn("Join-Path $programRoot 'Connect to Azure Arc.ps1'", self.content)
        self.assertIn("'Connect to Azure Arc.cmd'", self.content)
        self.assertIn("Remove-Item -LiteralPath (Join-Path $publicDesktop 'Connect to Azure Arc.ps1')", self.content)

    def test_domain_password_is_supplied_as_a_secure_string(self):
        self.assertIn("[securestring]$DomainAdministratorPassword", self.content)
        self.assertNotIn("ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText", self.content)

    def test_installs_checks_then_connects(self):
        install = self.content.index("https://aka.ms/AzureConnectedMachineAgent")
        check = self.content.index("& $agent check --location")
        connect = self.content.index("& $agent connect --subscription-id")
        self.assertLess(install, check)
        self.assertLess(check, connect)
        self.assertIn("--use-device-code", self.content)

    def test_does_not_transcribe_device_code(self):
        self.assertNotIn("Start-Transcript", self.content)
        self.assertIn("The device code is intentionally not written to the evidence log.", self.content)
        self.assertNotIn("Tee-Object", self.content)

    def test_already_connected_guest_is_retained(self):
        self.assertIn("if ($current.status -eq 'Connected')", self.content)
        self.assertIn("Azure Arc is already connected", self.content)

    def test_managed_stager_keeps_password_protected(self):
        stager = STAGER.read_text(encoding="utf-8")
        bicep = BICEP.read_text(encoding="utf-8")
        self.assertIn("ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force", stager)
        self.assertNotIn("Write-Host $NestedWindowsPassword", stager)
        self.assertIn("protectedScriptParameters", bicep)
        self.assertIn("name: 'NestedWindowsPassword'", bicep)
        self.assertIn("base64(loadTextContent('../../../artifacts/scripts/prepare-arc-device-code-launchers.ps1'))", bicep)


if __name__ == "__main__":
    unittest.main()
