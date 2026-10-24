#!/usr/bin/env python3
"""Stage public release files from local assets and committed source, without GitHub."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

BASE_URL = "https://www.ailyre.com/tokenclock"
FILES = (
    "TokenClock-glass-universal.tar.gz", "TokenClock-normal-universal.tar.gz",
    "TokenClock-windows-x86_64.zip", "TokenClock-windows-x86_64.zip.sha256",
    "TokenClock-x86_64.AppImage", "TokenClock-x86_64.AppImage.sha256",
)


def version_key(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Expected a stable vX.Y.Z version")
    return tuple(map(int, tag[1:].split(".")))


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def atomic_write(path, body):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(body)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def publish(version, assets_dir, output, repo, source_refs=(), without_windows=False):
    version_key(version)
    assets_dir, output, repo = Path(assets_dir), Path(output), Path(repo)
    assets = []
    files = tuple(name for name in FILES if not (without_windows and "windows" in name))
    for name in files:
        source = assets_dir / name
        if not source.is_file() or source.stat().st_size == 0:
            raise ValueError(f"Missing asset: {name}")
        assets.append({"name": name, "size": source.stat().st_size,
                       "digest": "sha256:" + digest(source),
                       "browser_download_url": f"{BASE_URL}/releases/download/{version}/{name}"})
    for name in files:
        if name.endswith(".sha256"):
            if (assets_dir / name).read_text().split()[0].lower() != digest(assets_dir / name[:-7]):
                raise ValueError(f"Checksum mismatch: {name}")
    target = output / "releases" / "download" / version
    # Never silently replace an already-published version with different bytes.
    for asset in assets:
        existing = target / asset["name"]
        if existing.exists() and "sha256:" + digest(existing) != asset["digest"]:
            raise ValueError(f"Published asset differs: {asset['name']}")
    target.mkdir(parents=True, exist_ok=True)
    for asset in assets:
        destination = target / asset["name"]
        if not destination.exists():
            shutil.copyfile(assets_dir / asset["name"], destination)
        destination.chmod(0o644)
    release = {"tag_name": version, "draft": False, "prerelease": False,
               "html_url": f"{BASE_URL}/releases/{version}/", "assets": assets}
    metadata = (json.dumps(release, indent=2) + "\n").encode()
    atomic_write(output / "releases" / f"{version}.json", metadata)
    links = "\n".join(f'<li><a href="{html.escape(a["browser_download_url"])}">'
                      f'{html.escape(a["name"])}</a><br><small>{a["digest"]}</small></li>' for a in assets)
    windows_note = ('<p>Windows build pending. The Windows installer continues to provide '
                    'the previous verified build.</p>' if without_windows else '')
    page = (f'<!doctype html><html lang="en"><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>TokenClock {version}</title><body><h1>TokenClock {version}</h1>'
            f'<p>Official downloads · SHA-256 verified packages</p>{windows_note}<ul>{links}</ul>'
            f'<p><a href="{BASE_URL}/install.sh">macOS / Linux installer</a> · '
            f'<a href="{BASE_URL}/install.ps1">Windows installer</a></p></body></html>')
    atomic_write(output / "releases" / version / "index.html", page.encode())
    for channel, ref in source_refs:
        if channel not in {"glass", "normal", "windows", "linux"}:
            raise ValueError(f"Unknown source channel: {channel}")
        source = output / "sources" / f"{channel}.tar.gz"
        source.parent.mkdir(parents=True, exist_ok=True)
        # git archive exports tracked, committed files only, never local WIP or credentials.
        subprocess.run(["git", "-C", str(repo), "archive", "--format=tar.gz",
                        "--prefix=TokenClock/", f"--output={source}", ref], check=True)
        source.chmod(0o644)
        atomic_write(Path(str(source) + ".sha256"), f"{digest(source)}  {source.name}\n".encode())
    for name in ("install.sh", "install.ps1", "tokenclock"):
        body = subprocess.check_output(["git", "-C", str(repo), "show", f"HEAD:cli/{name}"])
        atomic_write(output / name, body)
    latest = output / "releases" / "latest.json"
    if not latest.exists() or version_key(json.loads(latest.read_bytes())["tag_name"]) <= version_key(version):
        atomic_write(latest, metadata)
        if not without_windows:
            atomic_write(output / "releases" / "latest-windows.json", metadata)
        atomic_write(output / "releases" / "index.html", page.encode())
    print(f"Staged {version}: {len(assets)} assets; committed source only")
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--assets-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--source-ref", action="append", default=[], metavar="CHANNEL=REF")
    parser.add_argument("--without-windows", action="store_true",
                        help="Publish macOS/Linux only; do not change the Windows latest pointer")
    args = parser.parse_args()
    publish(args.version, args.assets_dir, args.output, args.repo,
            [value.split("=", 1) for value in args.source_ref], args.without_windows)


if __name__ == "__main__":
    main()
