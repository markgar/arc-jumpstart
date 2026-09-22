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

    def test_active_docs_use_current_defaults(self):
        readme = (ROOT / "README.md").read_text()
        prerequisites = (ROOT / "docs" / "01-prerequisites.md").read_text()
        scripts = (ROOT / "scripts" / "README.md").read_text()
        self.assertIn("Standard_E16s_v7", readme)
        self.assertIn("westus2", readme)
        self.assertIn("SQL Server 2025\nEnterprise Developer", readme)
        self.assertNotIn("lab.local.env", readme + prerequisites + scripts)
        self.assertNotIn("imageSourceUrl", readme)


if __name__ == "__main__":
    unittest.main()
