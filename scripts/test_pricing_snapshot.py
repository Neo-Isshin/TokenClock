"""Offline safeguards for unattended catalog publication."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("pricing", Path(__file__).with_name("update-pricing-snapshot.py"))
pricing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pricing)

def feed():
    return {f"fixture-{i}": {"litellm_provider": "openai", "mode": "chat",
                           "input_cost_per_token": 0.000002, "output_cost_per_token": 0.000010}
            for i in range(120)}

class SnapshotTests(unittest.TestCase):
    def test_retains_historical_rows_and_applies_official_rates(self):
        result = pricing.validated_models(feed(), {"models": {"retired": {"in": 1, "out": 2}}})
        self.assertIn("retired", result)
        self.assertEqual(result["gpt-6-sol"]["in"], 2)
        self.assertEqual(result["gpt-6-luna"]["lout"], 0.75)
        self.assertEqual(result["claude-opus-5-5"]["cr"], 0.2)

    def test_rejects_partial_feed_even_with_official_overrides(self):
        with self.assertRaises(ValueError):
            pricing.validated_models({}, {})

    def test_rejects_invalid_prices(self):
        for invalid in (-1, float("nan"), float("inf"), 100):
            data = feed()
            data["fixture-0"]["input_cost_per_token"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                pricing.validated_models(data, {})

    def test_no_timestamp_only_changes(self):
        models = pricing.validated_models(feed(), {})
        import json
        current = json.loads(pricing.render_snapshot(models))
        current["_meta"]["generatedAt"] = "2000-01-01T00:00:00Z"
        self.assertFalse(pricing.snapshot_changed(current, models))
        models["fixture-0"]["in"] = 3
        self.assertTrue(pricing.snapshot_changed(current, models))

if __name__ == "__main__":
    unittest.main()
