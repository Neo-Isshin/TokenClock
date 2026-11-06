"""Publisher tests use synthetic feeds and temporary directories only."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load("publisher", "publish-pricing-catalog.py")
pricing = publisher.load_generator()


def feed():
    rows = [{"provider":"openai", "model":f"fixture-{i}", "category":"api", "original":True,
             "currency":"USD", "unit":"USD / 1M tokens", "tier":"standard", "input":2., "output":10.}
            for i in range(60)]
    for provider, model in [("anthropic","claude-sonnet-5-5"),("google","gemini-4-argon")]:
        rows.append({**rows[0],"provider":provider,"model":model})
    return {"unit":"USD / 1M tokens","generated_at":"2026-11-04T06:00:00Z","rows":rows}


class PublisherTests(unittest.TestCase):
    def test_publish_then_unchanged_does_not_rewrite_file(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(pricing, "fetch_upstream", return_value=feed()):
            target = Path(directory) / "pricing-catalog.json"
            self.assertTrue(publisher.publish(target, pricing))
            before = target.read_bytes(), target.stat().st_mtime_ns
            self.assertIn("gemini-4-argon", json.loads(before[0])["models"])
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            self.assertFalse(publisher.publish(target, pricing))
            self.assertEqual((target.read_bytes(), target.stat().st_mtime_ns), before)

    def test_new_models_and_changed_prices_publish_without_dropping_history(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "pricing-catalog.json"
            target.write_text(json.dumps({"models": {"retired": {"in": 1, "out": 2}}}))
            changed = feed()
            changed["rows"][0]["input"] = 3.
            with patch.object(pricing, "fetch_upstream", return_value=changed):
                publisher.publish(target, pricing)
            models = json.loads(target.read_bytes())["models"]
            self.assertIn("retired", models)
            self.assertEqual(models["fixture-0"]["in"], 3)

    def test_invalid_or_unavailable_upstream_preserves_last_good_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "pricing-catalog.json"
            original = b'{"models":{"retired":{"in":1,"out":2}}}'
            target.write_bytes(original)
            invalid = feed()
            invalid["rows"][0]["input"] = -1
            for data in [{}, invalid]:
                with patch.object(pricing, "fetch_upstream", return_value=data), self.assertRaises(ValueError):
                    publisher.publish(target, pricing)
                self.assertEqual(target.read_bytes(), original)
            with patch.object(pricing, "fetch_upstream", side_effect=OSError("offline")), self.assertRaises(OSError):
                publisher.publish(target, pricing)
            self.assertEqual(target.read_bytes(), original)

    def test_activation_failure_keeps_previous_file_and_removes_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "pricing-catalog.json"
            original = b'{"models":{"retired":{"in":1,"out":2}}}'
            target.write_bytes(original)
            with patch.object(pricing, "fetch_upstream", return_value=feed()), \
                 patch.object(publisher.os, "replace", side_effect=OSError("fixture failure")), \
                 self.assertRaises(OSError):
                publisher.publish(target, pricing)
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(list(Path(directory).glob(".pricing-*")), [])


if __name__ == "__main__":
    unittest.main()
