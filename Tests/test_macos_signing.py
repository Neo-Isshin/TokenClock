import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tc_signing", ROOT / "scripts/macos-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningPolicyTests(unittest.TestCase):
    def profile(self, directory):
        path = Path(directory) / "local-identity.json"
        path.write_text(json.dumps({"schema": "tokenclock-local-signing/v1", "identity_sha1": "A" * 40}))
        return path

    def test_local_requirement_is_bound_to_certificate_not_binary_hash(self):
        requirement = signing.local_requirement({"identity_sha1": "A" * 40}, "glass")
        self.assertIn('identifier "com.tokenclock.app.glass"', requirement)
        self.assertIn('certificate leaf = H"' + "A" * 40 + '"', requirement)
        self.assertNotIn("cdhash", requirement)

    def test_reads_both_explicit_and_synthesized_requirements(self):
        for prefix in ["designated => ", "# designated => "]:
            with patch.object(signing, "run", return_value=SimpleNamespace(stdout="", stderr=prefix + "identifier \"example\"\n")):
                self.assertEqual(signing.designated_requirement("fixture"), 'identifier "example"')

    def test_deployment_waits_for_launchd_removal_without_force(self):
        responses = [SimpleNamespace(returncode=0), SimpleNamespace(returncode=0), SimpleNamespace(returncode=1)]
        with patch.object(signing, "run", side_effect=responses) as run, patch.object(signing.time, "sleep") as sleep:
            signing.wait_unloaded("fixture", attempts=3)
            self.assertEqual(run.call_count, 3)
            self.assertEqual(sleep.call_count, 2)
        with patch.object(signing, "run", return_value=SimpleNamespace(returncode=0)), patch.object(signing.time, "sleep"):
            with self.assertRaises(RuntimeError):
                signing.wait_unloaded("fixture", attempts=2)

    def test_enrolment_is_explicit_and_existing_identity_is_reused(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(signing, "run") as run:
            with self.assertRaises(RuntimeError):
                signing.init_local(Path(directory) / "new.json", False)
            path = self.profile(directory)
            signing.init_local(path, True)
            run.assert_not_called()

    def test_bad_profile_never_becomes_adhoc_signing(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(signing, "run") as run:
            path = self.profile(directory)
            path.write_text(json.dumps({"schema": "wrong", "identity_sha1": "-"}))
            with self.assertRaises(RuntimeError):
                signing.sign_local("fixture", "glass", path)
            run.assert_not_called()

    def test_public_release_requires_developer_id_and_fixed_identifier(self):
        good = {"identifier": "com.tokenclock.app.glass", "team": "EXAMPLE1234",
                "authorities": ["Developer ID Application: Example"], "adhoc": False}
        with patch.object(signing, "run"), patch.object(signing, "signature", return_value=good):
            self.assertEqual(signing.verify_release("fixture", "glass"), good)
        for replacement in [{"team": "not set"}, {"identifier": "TokenClock"},
                            {"authorities": ["TokenClock Local Code Signing"]}]:
            with patch.object(signing, "run"), patch.object(signing, "signature", return_value=good | replacement):
                with self.assertRaises(RuntimeError):
                    signing.verify_release("fixture", "glass")

    @unittest.skipUnless(sys.platform == "darwin", "macOS installer and plutil policy")
    def shell_policy(self, mode, local=False, fail_sign=False):
        with tempfile.TemporaryDirectory(prefix="tc-sign-policy-") as directory:
            root = Path(directory)
            log = root / "calls.jsonl"
            mock = root / "codesign"
            mock.write_text("""#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ['TC_SIGN_TEST_LOG'],'a') as f:f.write(json.dumps(args)+'\\n')
mode=os.environ['TC_SIGN_TEST_MODE']
if '--sign' in args and os.environ.get('TC_SIGN_FAIL')=='1':sys.exit(1)
if '-dv' in args:
 adhoc=mode=='legacy' or (mode=='downgrade' and args[-1].endswith('new'))
 print('Identifier=com.tokenclock.app.glass',file=sys.stderr)
 print('Signature=adhoc' if adhoc else 'Authority=Developer ID Application: Example',file=sys.stderr)
if '-d' in args and '-r-' in args:
 print('# designated => identifier "com.tokenclock.app.glass" and certificate leaf = H"'+'A'*40+'"',file=sys.stderr)
if '--verify' in args and '-R' in args and mode=='downgrade':sys.exit(1)
if '-R' in args and not args[args.index('-R')+1].startswith('='):sys.exit(3)
""")
            mock.chmod(0o755)
            staged, old = root / "new", root / "old"
            staged.write_bytes(b"new bytes")
            old.write_bytes(b"old bytes")
            if local:
                folder = root / "signing"
                folder.mkdir()
                self.profile(folder)
            source = (ROOT / "cli/install.sh").read_text()
            start = source.index("# BEGIN MACOS SIGNATURE POLICY")
            end = source.index("# END MACOS SIGNATURE POLICY")
            policy = source[start:end].replace("/usr/bin/codesign", str(mock))
            script = 'warn() { printf "%s\\n" "$*"; }\n' + policy + '\nmacos_prepare_signature "$1" "$2" glass\n'
            environment = dict(os.environ, HOME_DIR=str(root), TC_SIGN_TEST_MODE=mode,
                               TC_SIGN_TEST_LOG=str(log), TC_SIGN_FAIL="1" if fail_sign else "0")
            result = subprocess.run(["/bin/bash", "-c", script, "test", str(staged), str(old)],
                                    env=environment, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            self.assertEqual(staged.read_bytes(), b"new bytes")
            self.assertEqual(old.read_bytes(), b"old bytes")
            return result, calls

    def test_installer_preserves_developer_id_signed_bytes_and_checks_old_requirement(self):
        result, calls = self.shell_policy("public")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("--sign" in args for args in calls))
        self.assertTrue(any("-R" in args and "certificate leaf" in args[args.index("-R") + 1] for args in calls))

    def test_installer_keeps_enrolled_identity(self):
        result, calls = self.shell_policy("public", local=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = next(args for args in calls if "--sign" in args)
        self.assertEqual(sign[sign.index("--sign") + 1], "A" * 40)
        self.assertIn("--requirements", sign)

    def test_missing_private_key_is_failure_without_adhoc_fallback(self):
        result, calls = self.shell_policy("public", local=True, fail_sign=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("--sign" in args and args[args.index("--sign") + 1] == "-" for args in calls))

    def test_signed_to_adhoc_downgrade_is_rejected(self):
        result, _ = self.shell_policy("downgrade")
        self.assertNotEqual(result.returncode, 0)

    def test_legacy_development_signing_warns_about_permissions(self):
        result, calls = self.shell_policy("legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("privacy access may be requested again", result.stdout)
        self.assertTrue(any("--sign" in args and args[args.index("--sign") + 1] == "-" for args in calls))

    def test_signing_and_release_tools_never_reset_tcc_or_change_trust(self):
        source = (ROOT / "scripts/macos-signing.py").read_text()
        self.assertNotIn("tccutil", source)
        self.assertNotIn("add-trusted-cert", source)
        self.assertNotIn("set-key-partition-list", source)
        installer = (ROOT / "cli/install.sh").read_text()
        self.assertIn("macos_prepare_signature", installer)
        wrapper = (ROOT / "cli/tokenclock").read_text()
        self.assertIn("protected_signature", wrapper)
        self.assertIn("cannot preserve this signing identity", wrapper)

    def test_failed_managed_deployment_restores_binary_and_preserves_plist(self):
        import plistlib
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            root = home / ".tokenclock"
            destination = root / "glass/TokenClock"
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"old-runtime")
            incoming = home / "new-runtime"
            incoming.write_bytes(b"new-runtime")
            profile = self.profile(home)
            agents = home / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            plist = agents / "com.tokenclock.app.glass.plist"
            contents = plistlib.dumps({"Label": "com.tokenclock.app.glass", "ProgramArguments": [str(destination)], "RunAtLoad": True})
            plist.write_bytes(contents)
            bootstraps = []

            def command(args, **kwargs):
                if "print" in args:
                    return SimpleNamespace(stdout="", stderr="", returncode=1)
                if "bootstrap" in args:
                    bootstraps.append(args)
                    if len(bootstraps) == 1:
                        raise RuntimeError("fixture bootstrap failure")
                return SimpleNamespace(stdout="", stderr="", returncode=0)

            with patch.object(signing.Path, "home", return_value=home), patch.object(signing, "run", side_effect=command), \
                 patch.object(signing, "signature", return_value={"adhoc": True}), patch.object(signing, "sign_local"):
                with self.assertRaises(RuntimeError):
                    signing.deploy_local(incoming, "glass", profile, root)
            self.assertEqual(destination.read_bytes(), b"old-runtime")
            self.assertEqual(plist.read_bytes(), contents)
            self.assertEqual(len(bootstraps), 2)


if __name__ == "__main__":
    unittest.main()
