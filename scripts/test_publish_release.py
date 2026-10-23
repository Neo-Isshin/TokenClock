"""Release distribution tests; all files and Git history are temporary fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class ReleasePublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.assets = self.root / "assets"
        self.site = self.root / "site"
        self.repo = self.root / "repo"
        self.assets.mkdir()
        (self.repo / "cli").mkdir(parents=True)
        for name in ("install.sh", "install.ps1", "tokenclock"):
            (self.repo / "cli" / name).write_text(f"fixture {name}\n")
        for args in (["init", "-q"], ["add", "cli"],
                     ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                      "commit", "-qm", "fixture"]):
            subprocess.run(["git", "-C", str(self.repo), *args], check=True)
        (self.repo / "private-untracked.txt").write_text("must not be published")
        (self.repo / "cli" / "install.sh").write_text("uncommitted WIP")
        for name in publisher.FILES:
            if not name.endswith(".sha256"):
                (self.assets / name).write_bytes(b"fixture:" + name.encode())
        for name in publisher.FILES:
            if name.endswith(".sha256"):
                (self.assets / name).write_text(publisher.digest(self.assets / name[:-7]) + "  " + name[:-7])

    def publish(self, version="v1.5.12", refs=()):
        return publisher.publish(version, self.assets, self.site, self.repo, refs)

    def test_assets_metadata_and_installer_use_exact_reviewed_bytes(self):
        release = self.publish(refs=[("glass", "HEAD")])
        self.assertEqual(release, json.loads((self.site / "releases/latest.json").read_text()))
        self.assertEqual(release, json.loads((self.site / "releases/latest-windows.json").read_text()))
        for asset in release["assets"]:
            target = self.site / "releases/download/v1.5.12" / asset["name"]
            self.assertEqual(target.read_bytes(), (self.assets / asset["name"]).read_bytes())
            self.assertEqual(asset["digest"], "sha256:" + publisher.digest(target))
            self.assertTrue(asset["browser_download_url"].startswith(publisher.BASE_URL + "/"))
        self.assertEqual((self.site / "install.sh").read_text(), "fixture install.sh\n")
        with tarfile.open(self.site / "sources/glass.tar.gz") as archive:
            self.assertNotIn("TokenClock/private-untracked.txt", archive.getnames())
            self.assertEqual(archive.extractfile("TokenClock/cli/install.sh").read(), b"fixture install.sh\n")

    def test_bad_checksum_and_missing_asset_do_not_publish_latest(self):
        (self.assets / "TokenClock-windows-x86_64.zip.sha256").write_text("0" * 64)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertFalse((self.site / "releases/latest.json").exists())
        (self.assets / "TokenClock-glass-universal.tar.gz").unlink()
        with self.assertRaises(ValueError):
            self.publish()

    def test_existing_asset_is_not_silently_replaced(self):
        self.publish()
        latest = (self.site / "releases/latest.json").read_bytes()
        (self.assets / "TokenClock-glass-universal.tar.gz").write_bytes(b"different package")
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual((self.site / "releases/latest.json").read_bytes(), latest)

    def test_older_version_does_not_replace_latest(self):
        self.publish("v1.5.12")
        self.publish("v1.5.11")
        self.assertEqual(json.loads((self.site / "releases/latest.json").read_text())["tag_name"], "v1.5.12")

    def test_unstable_and_unsafe_version_names_are_rejected(self):
        for version in ("../escape", "v1.5.12-rc.1", "v01.5.12", "1.5.12"):
            with self.assertRaises(ValueError):
                self.publish(version)


if __name__ == "__main__":
    unittest.main()
