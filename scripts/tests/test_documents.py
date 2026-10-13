import json
from pathlib import Path
import re
import sys
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release
import gates


READMES = [ROOT / "README.md", ROOT / "README.ja.md"]
GUIDES = [ROOT / "docs/release.en.md", ROOT / "docs/release.ja.md"]
DOCUMENTS = READMES + GUIDES + [ROOT / "PRIVACY.md"]
LOCALIZATIONS = {
    "en", "ja", "zh-Hans", "zh-Hant", "ko", "fr",
    "de", "es", "pt-BR", "it", "ar", "hi",
}


class DocumentTests(unittest.TestCase):
    def test_both_application_products_are_named_miledge(self):
        project = (ROOT / "project.yml").read_text()
        for target in ("Miledge-iOS", "Miledge-macOS"):
            block = re.search(rf"^  {target}:\n(.*?)(?=^  \S|\Z)", project, re.MULTILINE | re.DOTALL)
            with self.subTest(target=target):
                self.assertIsNotNone(block)
                self.assertIn("productName: Miledge\n", block.group(1))
                self.assertIn("PRODUCT_NAME: Miledge\n", block.group(1))
        self.assertEqual(gates.APP_PRODUCT_NAME, "Miledge")

    def test_requested_bundle_identity_matches_products_workflow_and_readmes(self):
        project = (ROOT / "project.yml").read_text()
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertEqual(project.count("PRODUCT_BUNDLE_IDENTIFIER: st.rio.miledge\n"), 2)
        for name in ("IOS_BUNDLE_ID", "MACOS_BUNDLE_ID"):
            self.assertIn(f"{name}: st.rio.miledge", workflow)
        for path in READMES:
            self.assertIn("`st.rio.miledge`", path.read_text())

    def test_current_version_is_documented(self):
        project = (ROOT / "project.yml").read_text()
        version = re.search(r'MARKETING_VERSION: "([^"]+)"', project).group(1)
        build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', project).group(1)
        for path in DOCUMENTS:
            with self.subTest(path=path.name):
                self.assertIn(f"**{version}**", path.read_text())
                self.assertIn(f"**{build}**", path.read_text())
                self.assertIn("TestFlight", path.read_text())

    def test_readmes_disclose_publication_status_and_health_exclusion(self):
        self.assertIn("has not been released yet", READMES[0].read_text())
        self.assertIn("現在は未公開", READMES[1].read_text())
        self.assertIn("Health information is excluded", READMES[0].read_text())
        self.assertIn("健康情報は対象外", READMES[1].read_text())
        for path in READMES:
            self.assertIn("HealthKit", path.read_text())

    def test_localizations_match_resources_and_release_gate(self):
        resources = ROOT / "App/Resources"
        actual = {path.name.removesuffix(".lproj") for path in resources.glob("*.lproj")}
        self.assertEqual(actual, LOCALIZATIONS)
        self.assertEqual(set(release.LAUNCH_LOCALIZATIONS), LOCALIZATIONS)
        for path in READMES:
            for locale in LOCALIZATIONS:
                with self.subTest(path=path.name, locale=locale):
                    self.assertIn(f"`{locale}`", path.read_text())

    def test_device_and_language_requirements_are_wired_into_workflow_and_guides(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        for variable in ("IOS_TEST_DESTINATION", "IPAD_TEST_DESTINATION"):
            self.assertIn(f"{variable}: ${{{{ vars.{variable} }}}}", workflow)
        for path in GUIDES:
            text = path.read_text()
            with self.subTest(path=path.name):
                for requirement in ("IPAD_TEST_DESTINATION", "arm64", "UIDeviceFamily", "12"):
                    self.assertIn(requirement, text)

    def test_local_markdown_links_resolve(self):
        for path in DOCUMENTS:
            for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", path.read_text()):
                parsed = urlsplit(link)
                if parsed.scheme or not parsed.path:
                    continue
                with self.subTest(path=path.name, link=link):
                    self.assertTrue((path.parent / unquote(parsed.path)).is_file())

    def test_release_evidence_covers_all_required_checks_and_scopes(self):
        readiness = json.loads((ROOT / "docs/release-readiness.json").read_text())
        review = json.loads((ROOT / "docs/release-security-review.json").read_text())
        self.assertEqual(readiness["schemaVersion"], 1)
        self.assertEqual(set(readiness["checks"]), set(gates.READINESS_CHECKS))
        for check in readiness["checks"].values():
            self.assertIn(check["status"], ("blocked", "passed"))
            self.assertTrue(check["evidence"].strip())
        self.assertEqual(review["schemaVersion"], 1)
        self.assertIn(review["status"], ("blocked", "approved"))
        self.assertEqual(set(review["scopes"]), set(gates.SECURITY_REVIEW_SCOPES))

    def test_swift_analysis_retains_independent_review_and_python_codeql(self):
        security = (ROOT / ".github/workflows/security.yml").read_text()
        self.assertIn("scripts/swift_security.py", security)
        self.assertIn("--require-hashes", security)
        self.assertIn("languages: python", security)
        self.assertNotIn("languages: swift", security)
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        for variable in ("SECURITY_REVIEWER_ID", "SECURITY_REVIEW_PUBLIC_KEY"):
            self.assertIn(f"{variable}: ${{{{ vars.{variable} }}}}", workflow)
        for path in GUIDES:
            for requirement in ("1.179.0", "2.27.2", "MASVS/MASTG", "release-security-review.json"):
                self.assertIn(requirement, path.read_text())


if __name__ == "__main__":
    unittest.main()
