"""Offline safeguards for unattended catalog publication."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import json
import tempfile
from datetime import datetime, timezone

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

    def test_existing_prices_update_without_adding_models(self):
        current = {"models": pricing.validated_models(feed(), {})}
        changed = feed()
        changed["fixture-0"].update(input_cost_per_token=0.000001, output_cost_per_token=0.000004,
                                  cache_read_input_token_cost=0.0000001)
        result = pricing.validated_models(changed, current)
        self.assertEqual(set(result), set(current["models"]))
        self.assertEqual(result["fixture-0"]["in"], 1)
        self.assertEqual(result["fixture-0"]["out"], 4)
        self.assertEqual(result["fixture-0"]["cr"], 0.1)
        self.assertTrue(pricing.snapshot_changed(current, result))

    def test_official_defaults_do_not_block_updated_prices_or_tiers(self):
        changed = feed()
        changed["gpt-6-sol"] = {
            "litellm_provider": "openai", "mode": "chat",
            "input_cost_per_token": 0.000001, "output_cost_per_token": 0.000005,
            "cache_read_input_token_cost": 0.00000005,
            "input_cost_per_token_above_272k_tokens": 0.000003,
            "output_cost_per_token_above_272k_tokens": 0.000012,
            "cache_read_input_token_cost_above_272k_tokens": 0.00000015,
            "input_cost_per_token_priority": 0.000003,
            "output_cost_per_token_priority": 0.000015,
        }
        result = pricing.validated_models(changed, {})["gpt-6-sol"]
        self.assertEqual((result["in"], result["out"], result["cr"]), (1, 5, 0.05))
        self.assertEqual((result["lt"], result["lin"], result["lout"], result["lcr"]), (272000, 3, 12, 0.15))
        self.assertEqual(result["pm"], 3)

    def test_wrong_provider_and_invalid_official_prices_fail(self):
        for provider, rate in (("anthropic", 0.000001), ("openai", -1), ("openai", True)):
            changed = feed()
            changed["gpt-6-sol"] = {"litellm_provider": provider, "mode": "chat",
                                    "input_cost_per_token": rate, "output_cost_per_token": 0.000010}
            with self.subTest(provider=provider, rate=rate), self.assertRaises(ValueError):
                pricing.validated_models(changed, {})

    def test_missing_feed_row_does_not_revert_a_previously_updated_price(self):
        current = {"models": pricing.validated_models(feed(), {})}
        current["models"]["gpt-6-sol"].update({"in": 1, "out": 5, "cr": 0.05, "lin": 3})
        result = pricing.validated_models(feed(), current)
        self.assertEqual(result["gpt-6-sol"], current["models"]["gpt-6-sol"])

    def test_future_routine_price_updates_do_not_require_manual_review(self):
        class FutureDateTime(datetime):
            @classmethod
            def now(cls, tz=None):
                return cls(2026, 12, 1, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "snapshot.json"
            current = {"models": pricing.validated_models(feed(), {})}
            snapshot.write_text(json.dumps(current))
            changed = feed()
            changed["fixture-0"]["input_cost_per_token"] = 0.000003
            with patch.object(pricing, "datetime", FutureDateTime), \
                 patch.object(pricing, "REPO_ROOT", Path(directory)), \
                 patch.object(pricing, "SNAPSHOT_PATH", snapshot), \
                 patch.object(pricing, "fetch_upstream", return_value=changed), \
                 patch("sys.argv", ["update-pricing-snapshot.py"]):
                self.assertEqual(pricing.main(), 0)
            self.assertEqual(json.loads(snapshot.read_text())["models"]["fixture-0"]["in"], 3)

if __name__ == "__main__":
    unittest.main()
