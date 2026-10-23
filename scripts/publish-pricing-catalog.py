#!/usr/bin/env python3
"""Publish the validated catalog atomically; no Git login or app build required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile


def load_generator():
    path = Path(__file__).with_name("update-pricing-snapshot.py")
    spec = importlib.util.spec_from_file_location("catalog_generator", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def publish(destination, generator=None):
    destination = Path(destination)
    generator = generator or load_generator()
    current = json.loads(destination.read_text()) if destination.exists() else {}
    models = generator.validated_models(generator.fetch_upstream(), current)
    if not generator.snapshot_changed(current, models):
        print("Catalog unchanged")
        return False
    body = generator.render_snapshot(models).encode("utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".pricing-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(body)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Published catalog: {len(models)} models")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        publish(args.output)
    except (OSError, ValueError, TypeError, OverflowError) as error:
        print(f"Catalog not published; previous file retained: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
