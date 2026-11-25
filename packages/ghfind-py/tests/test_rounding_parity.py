"""The Python port matches the shared TypeScript/Go rounding cases."""
import json
import unittest
from pathlib import Path

from ghfind._score import _math_round, score
from ghfind._rounding import round_half_even

FIXTURE = Path(__file__).resolve().parents[3] / "scoring/fixtures/rounding-parity.json"
DATA = json.loads(FIXTURE.read_text(encoding="utf-8"))


class RoundingParityTests(unittest.TestCase):
    def test_scaled_midpoint_tolerance_and_math_round_remain_distinct(self):
        for case in DATA["rounding_edges"]:
            with self.subTest(case=case):
                self.assertEqual(round_half_even(case["value"], case["digits"]), case["expected"])
        self.assertEqual(_math_round(2.5), 3)
        self.assertEqual(round_half_even(2.5), 2)

    def test_shared_scoring_and_risk_cases(self):
        for case in DATA["cases"]:
            result = score({**DATA["base_metrics"], **case["overrides"]})
            expected = case["expected"]
            for field in ("sub_scores", "base_score", "final_score", "total_penalty"):
                with self.subTest(case=case["name"], field=field):
                    self.assertEqual(result[field], expected[field])
            risk = result["risk_assessment"]
            for field in ("coverage", "confidence", "risk_score", "applied_penalty"):
                with self.subTest(case=case["name"], field="risk." + field):
                    self.assertEqual(risk[field], expected["risk"][field])
            signals = [
                {**{key: signal[key] for key in ("flag", "severity", "confidence", "penalty")},
                 "coverage": signal["evidence"]["coverage"],
                 "observed": {key: value for key, value in signal["evidence"]["observed"].items()
                              if key in ("smoothed_rate", "wilson_lower", "follower_ratio")}}
                for signal in risk["signals"]
            ]
            with self.subTest(case=case["name"], field="risk.signals"):
                self.assertEqual(signals, expected["risk"]["signals"])
