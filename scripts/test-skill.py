import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SKILL = ROOT / "skills" / "arc-jumpstart" / "SKILL.md"


class SkillTests(unittest.TestCase):
    def test_skill_has_required_frontmatter_and_runbooks(self):
        text = SKILL.read_text()
        self.assertTrue(text.startswith("---\n"))
        frontmatter = text.split("---\n", 2)[1]
        self.assertRegex(frontmatter, r"(?m)^name: arc-jumpstart$")
        self.assertRegex(frontmatter, r"(?m)^description: .+")
        for path in (
            "AGENTS.md",
            "docs/00-agent-bootstrap.md",
            "infra/README.md",
            "scripts/README.md",
            "docs/03-arc-onboarding.md",
        ):
            with self.subTest(path=path):
                self.assertIn(path, text)
                self.assertTrue((ROOT / path).exists())

    def test_skill_preserves_safety_and_execution_contract(self):
        text = SKILL.read_text()
        for requirement in (
            "WSL2",
            "ENV_FILE",
            "./scripts/validate.sh",
            "./scripts/preflight.sh infra",
            "./scripts/deploy.sh all",
            "./scripts/lab.sh build-status",
            "Never rerun `deploy.sh all`",
            "Do not silently onboard Arc",
        ):
            with self.subTest(requirement=requirement):
                self.assertIn(requirement, text)
        self.assertIsNone(re.search(r"(?i)(password|secret)\s*=\s*[^\s`]+", text))


if __name__ == "__main__":
    unittest.main()
