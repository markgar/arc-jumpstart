import re
import unittest
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_FILES = [
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    ROOT / "infra" / "README.md",
    ROOT / "scripts" / "README.md",
    ROOT / "skills" / "arc-jumpstart" / "SKILL.md",
    *sorted((ROOT / "docs").glob("*.md")),
]
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")


class DocumentationTests(unittest.TestCase):
    def test_local_links_resolve(self):
        failures = []
        for document in MARKDOWN_FILES:
            for target in LINK.findall(document.read_text()):
                target = target.strip().split(maxsplit=1)[0].strip("<>")
                if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                    continue
                path = unquote(target.split("#", 1)[0])
                if path and not (document.parent / path).resolve().exists():
                    failures.append(f"{document.relative_to(ROOT)} -> {target}")
        self.assertEqual(failures, [])

    def test_readme_leads_with_agent_instruction(self):
        lines = (ROOT / "README.md").read_text().splitlines()
        self.assertEqual(lines[0], "# Arc Jumpstart v2")
        self.assertEqual(
            lines[2],
            '**Clone this repo and ask your agent: "Help me use this to make an Arc environment."**',
        )
        opening = "\n".join(lines[:20])
        self.assertIn("without further\nintervention", opening)
        self.assertIn("stops before adding the servers to Azure Arc", opening)
        self.assertIn("SQL Server extension should then deploy automatically", opening)

    def test_active_docs_use_current_defaults(self):
        readme = (ROOT / "README.md").read_text()
        prerequisites = (ROOT / "docs" / "01-prerequisites.md").read_text()
        scripts = (ROOT / "scripts" / "README.md").read_text()
        self.assertIn("Standard_E16s_v7", readme)
        self.assertIn("westus2", readme)
        self.assertIn("SQL Server 2025 Enterprise Developer", readme.replace("\n", " "))
        self.assertNotIn("lab.local.env", readme + prerequisites + scripts)
        self.assertNotIn("imageSourceUrl", readme)
        self.assertNotIn("Hyper-V replication", readme)
        self.assertIn("arc-sql-modeling-inventory.kql", (ROOT / "docs" / "04-assessment.md").read_text())
        self.assertIn("JumpstartStandaloneDB", (ROOT / "docs" / "05-migration.md").read_text())

    def test_configuration_uses_visible_folder(self):
        for relative in (
            "README.md",
            "AGENTS.md",
            "docs/00-agent-bootstrap.md",
            "docs/01-prerequisites.md",
            "docs/02-deploy.md",
            "scripts/README.md",
            "skills/arc-jumpstart/SKILL.md",
        ):
            with self.subTest(document=relative):
                text = (ROOT / relative).read_text()
                self.assertIn("$HOME/ArcJumpstart/lab.env", text)
                self.assertNotIn(".config/arc-jumpstart", text)

    def test_configuration_handoff_is_explicit_and_platform_specific(self):
        for relative in (
            "AGENTS.md",
            "docs/00-agent-bootstrap.md",
            "skills/arc-jumpstart/SKILL.md",
        ):
            with self.subTest(document=relative):
                text = " ".join((ROOT / relative).read_text().split())
                for requirement in (
                    "actual full",
                    "user-facing",
                    "Finder",
                    "TextEdit",
                    "File Explorer",
                    "Notepad",
                    "execution host",
                ):
                    self.assertIn(requirement, text)
        bootstrap = (ROOT / "docs/00-agent-bootstrap.md").read_text()
        self.assertIn("WSL_DISTRO_NAME", bootstrap)
        self.assertIn("Verify that this file still exists", bootstrap)
        self.assertIn("must not be shared or committed", bootstrap)


if __name__ == "__main__":
    unittest.main()
