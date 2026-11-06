#!/usr/bin/env python3
"""Persistent local signing and guarded deployment. Never changes TCC or trust settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

SIGNING_NAME = "TokenClock Local Code Signing"
IMPORT_HELPER = Path(__file__).resolve().with_name("macos-import-signing-identity.swift")
PROFILE = Path.home() / ".tokenclock/signing/local-identity.json"


def run(args, *, input=None, env=None, check=True):
    result = subprocess.run([str(x) for x in args], input=input, env=env, capture_output=True, text=True)
    if check and result.returncode:
        # Do not echo argv: signing import inputs can contain private material.
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Signing command failed")
    return result


def identifier(variant):
    if variant not in ("glass", "normal"):
        raise ValueError("Unsupported macOS edition")
    return "com.tokenclock.app." + variant


def signature(binary):
    result = run(["/usr/bin/codesign", "-dv", "--verbose=4", binary], check=False)
    text = result.stderr + result.stdout
    values = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return {"identifier": values.get("Identifier", [""])[0],
            "team": values.get("TeamIdentifier", [""])[0],
            "authorities": values.get("Authority", []),
            "adhoc": "Signature=adhoc" in text or "adhoc" in values.get("CodeDirectory v", [""])[0],
            "details": text}


def designated_requirement(binary):
    result = run(["/usr/bin/codesign", "-d", "-r-", binary])
    match = re.search(r"^(?:# )?designated => (.+)$", result.stderr + result.stdout, re.M)
    if not match:
        raise RuntimeError("No designated requirement was found")
    return match.group(1)


def verify_release(binary, variant):
    run(["/usr/bin/codesign", "--verify", "--strict", "-R",
         '=anchor apple generic and identifier "' + identifier(variant) + '"', binary])
    info = signature(binary)
    if (info["identifier"] != identifier(variant) or info["team"] in ("", "not set")
            or not any(a.startswith("Developer ID Application:") for a in info["authorities"])):
        raise RuntimeError("Public macOS releases require the fixed edition identifier and Apple Developer ID Application signing")
    return info


def load_profile(path):
    data = json.loads(Path(path).read_text())
    if data.get("schema") != "tokenclock-local-signing/v1" or not re.fullmatch(r"[A-Fa-f0-9]{40}", data.get("identity_sha1", "")):
        raise RuntimeError("Invalid local signing profile; refusing an ad-hoc fallback")
    return data


def local_requirement(profile, variant):
    return 'identifier "' + identifier(variant) + '" and certificate leaf = H"' + profile["identity_sha1"] + '"'


def sign_local(binary, variant, profile_path=PROFILE):
    profile = load_profile(profile_path)
    requirement = local_requirement(profile, variant)
    run(["/usr/bin/codesign", "--force", "--sign", profile["identity_sha1"], "--identifier", identifier(variant),
         "--timestamp=none", "--requirements", "=designated => " + requirement, binary])
    run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, binary])
    return requirement


def wait_unloaded(service, attempts=100):
    # bootout can return before launchd finishes removing a running service.
    # Re-bootstrap during that interval fails with EINPROGRESS (reported as EIO).
    for _ in range(attempts):
        if run(["/bin/launchctl", "print", service], check=False).returncode != 0:
            return
        time.sleep(0.1)
    raise RuntimeError("The previous launch job is still unloading; no replacement was activated")


def init_local(profile_path, confirmed):
    path = Path(profile_path).expanduser()
    if path.exists():
        profile = load_profile(path)
        print(json.dumps({"existing_identity": profile["identity_sha1"], "profile": str(path)}))
        return
    if not confirmed:
        raise RuntimeError("Creating a persistent private signing key requires explicit user approval")
    found = run(["/usr/bin/security", "find-certificate", "-c", SIGNING_NAME], check=False)
    if found.returncode == 0:
        raise RuntimeError("A TokenClock certificate already exists; recover its profile instead of creating another identity")
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("OpenSSL is required to create the local certificate")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="identity-import-", dir=path.parent) as directory:
        stage = Path(directory)
        key, cert, archive = stage / "encrypted-key.pem", stage / "certificate.pem", stage / "identity.p12"
        password = secrets.token_urlsafe(48)
        environment = dict(os.environ, TOKENCLOCK_LOCAL_IDENTITY_PASSPHRASE=password)
        password_source = "env:TOKENCLOCK_LOCAL_IDENTITY_PASSPHRASE"
        run([openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-aes-256-cbc",
             "-pass", password_source, "-out", key], env=environment)
        run([openssl, "req", "-new", "-x509", "-sha256", "-days", "3650", "-key", key, "-passin", password_source,
             "-subj", "/CN=" + SIGNING_NAME, "-addext", "basicConstraints=critical,CA:FALSE",
             "-addext", "keyUsage=critical,digitalSignature", "-addext", "extendedKeyUsage=critical,codeSigning",
             "-out", cert], env=environment)
        run([openssl, "pkcs12", "-export", "-inkey", key, "-passin", password_source, "-in", cert,
             "-name", SIGNING_NAME, "-out", archive, "-passout", password_source], env=environment)
        helper = stage / "import-identity"
        compiler_args = ["/Library/Developer/CommandLineTools/usr/bin/swiftc", "-parse-as-library",
                         "-target", os.uname().machine + "-apple-macosx12.0"]
        sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk")
        if sdk.exists():
            compiler_args += ["-sdk", sdk]
        run(compiler_args + [IMPORT_HELPER, "-o", helper])
        run([helper, archive], input=json.dumps({"passphrase": password}))
        fingerprint = run([openssl, "x509", "-in", cert, "-noout", "-fingerprint", "-sha1"]).stdout
        fingerprint = fingerprint.split("=", 1)[1].strip().replace(":", "").upper()
        if not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
            raise RuntimeError("Invalid certificate fingerprint")
        profile = {"schema": "tokenclock-local-signing/v1", "identity_sha1": fingerprint, "name": SIGNING_NAME}
        shutil.copyfile(cert, path.parent / "local-certificate.pem")
        temporary = path.with_suffix(".new.json")
        temporary.write_text(json.dumps(profile, indent=2) + "\n")
        temporary.chmod(0o600)
        os.replace(temporary, path)
    print(json.dumps({"identity_sha1": fingerprint, "profile": str(path), "trust_settings_changed": False}))


def deploy_local(binary, variant, profile_path, root):
    binary = Path(binary).resolve(strict=True)
    root = Path(root).expanduser().resolve()
    if root == Path.home() or root == Path("/"):
        raise RuntimeError("The install root must be a dedicated TokenClock directory")
    destination = root / variant / "TokenClock"
    destination.parent.mkdir(parents=True, exist_ok=True)
    profile = load_profile(profile_path)
    expected = local_requirement(profile, variant)
    previous = signature(destination) if destination.exists() else None
    if previous and not previous["adhoc"]:
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + expected, destination])
    with tempfile.TemporaryDirectory(prefix="signed-deploy-", dir=destination.parent) as directory:
        staged = Path(directory) / "TokenClock"
        shutil.copy2(binary, staged)
        staged.chmod(0o755)
        sign_local(staged, variant, profile_path)
        if previous and not previous["adhoc"]:
            old = designated_requirement(destination)
            run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + old, staged])
        backup = Path(tempfile.mkdtemp(prefix="signing-backup-", dir=root))
        if destination.exists():
            shutil.copy2(destination, backup / "TokenClock")
        plist = Path.home() / "Library/LaunchAgents" / ("com.tokenclock.app." + variant + ".plist")
        service = "gui/" + str(os.getuid()) + "/com.tokenclock.app." + variant
        if not plist.exists():
            raise RuntimeError("No existing managed LaunchAgent; registration must be reviewed separately")
        import plistlib
        original_plist = plist.read_bytes()
        if plistlib.loads(original_plist).get("ProgramArguments") != [str(destination)]:
            raise RuntimeError("LaunchAgent has a custom path; refusing to change it")
        shutil.copy2(plist, backup / plist.name)
        run(["/bin/launchctl", "bootout", service])
        try:
            wait_unloaded(service)
            os.replace(staged, destination)
            run(["/bin/launchctl", "bootstrap", "gui/" + str(os.getuid()), plist])
            healthy = False
            for _ in range(15):
                state = run(["/bin/launchctl", "print", service], check=False).stdout
                match = re.search(r"^\s*pid = ([0-9]+)$", state, re.M)
                if match:
                    try:
                        os.kill(int(match.group(1)), 0)
                        healthy = True
                        break
                    except ProcessLookupError:
                        pass
                time.sleep(1)
            if not healthy:
                raise RuntimeError("The newly signed runtime did not start; restoring the previous binary")
        except Exception:
            run(["/bin/launchctl", "bootout", service], check=False)
            wait_unloaded(service)
            if (backup / "TokenClock").exists():
                restored = Path(directory) / "TokenClock.restore"
                shutil.copy2(backup / "TokenClock", restored)
                os.replace(restored, destination)
            run(["/bin/launchctl", "bootstrap", "gui/" + str(os.getuid()), plist], check=False)
            raise
    print(json.dumps({"installed": str(destination), "backup": str(backup),
                      "requirement": expected, "one_time_identity_migration": bool(previous and previous["adhoc"])}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init-local", "sign-local", "verify-release", "deploy-local"])
    parser.add_argument("--binary")
    parser.add_argument("--variant", choices=["glass", "normal"], default="glass")
    parser.add_argument("--profile", default=str(PROFILE))
    parser.add_argument("--root", default=str(Path.home() / ".tokenclock"))
    parser.add_argument("--confirm-create-local-identity", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise RuntimeError("This tool is only for macOS signing")
    if args.command == "init-local":
        init_local(args.profile, args.confirm_create_local_identity)
    elif not args.binary:
        parser.error("--binary is required")
    elif args.command == "sign-local":
        print(sign_local(args.binary, args.variant, args.profile))
    elif args.command == "verify-release":
        print(json.dumps(verify_release(args.binary, args.variant)))
    else:
        deploy_local(args.binary, args.variant, args.profile, args.root)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
