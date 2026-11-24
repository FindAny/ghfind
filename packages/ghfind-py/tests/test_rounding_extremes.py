"""Regression coverage for synthetic values outside normal scoring ranges."""
import json
import math
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ghfind._rounding import round_half_even
from ghfind.local import score_metrics, verify_scan

PACKAGE = Path(__file__).resolve().parents[1]
FIXTURE = PACKAGE.parents[1] / "scoring/fixtures/rounding-parity.json"
BASE_METRICS = json.loads(FIXTURE.read_text(encoding="utf-8"))["base_metrics"]


class FiniteRoundingRegressionTests(unittest.TestCase):
    def test_large_negative_finite_age_retains_finite_score(self):
        metrics = {**BASE_METRICS, "account_age_years": -1e308}
        expected = round((-1e308 / 6.0) * 7, 1)
        result = score_metrics(metrics)
        self.assertTrue(math.isfinite(result["sub_scores"]["account_maturity"]))
        self.assertEqual(result["sub_scores"]["account_maturity"], expected)
        self.assertEqual(result["base_score"], expected)

    def test_large_negative_activity_retains_finite_score(self):
        metrics = {**BASE_METRICS, "activity_type_count": -1e308}
        expected = round(-1e308 * 1.125, 1)
        result = score_metrics(metrics)
        self.assertEqual(result["sub_scores"]["activity_authenticity"], expected)
        self.assertTrue(math.isfinite(result["base_score"]))
        scan = {"metrics": metrics, "scoring": score_metrics(BASE_METRICS)}
        self.assertFalse(verify_scan(scan)["verified"])

    def test_large_and_nonfinite_values_at_scoring_precisions(self):
        for value in (-1e308, 1e308, -1e307, 1e307, -math.inf, math.inf, math.nan):
            for digits in (1, 2, 4):
                with self.subTest(value=value, digits=digits):
                    expected = round(value, digits)
                    result = round_half_even(value, digits)
                    if math.isnan(expected):
                        self.assertTrue(math.isnan(result))
                    else:
                        self.assertEqual(result, expected)

    def test_bounded_positive_and_negative_half_even_cases(self):
        for value, digits, expected in ((2.25, 1, 2.2), (-2.25, 1, -2.2),
                                        (1.245, 2, 1.24), (-1.245, 2, -1.24),
                                        (0.00625, 4, 0.0062), (-0.00625, 4, -0.0062)):
            with self.subTest(value=value, digits=digits):
                self.assertEqual(round_half_even(value, digits), expected)

    def test_public_verify_and_cli_for_synthetic_ages(self):
        normal = {**BASE_METRICS, "account_age_years": 1.5}
        server = score_metrics(normal)
        cases = ((1.5, 1.8, True), (-2.0, -2.3, False), (2.0, 2.3, False),
                 (-1e308, round((-1e308 / 6.0) * 7, 1), False), (1e308, 7.0, False),
                 (math.nan, math.nan, False), (math.inf, 7.0, False), (-math.inf, -math.inf, False))
        for age, expected, verified in cases:
            with self.subTest(age=age):
                metrics = {**BASE_METRICS, "account_age_years": age}
                scan = {"metrics": metrics, "scoring": server}
                maturity = score_metrics(metrics)["sub_scores"]["account_maturity"]
                if math.isnan(expected):
                    self.assertTrue(math.isnan(maturity))
                else:
                    self.assertEqual(maturity, expected)
                self.assertEqual(verify_scan(scan)["verified"], verified)
                with tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "scan.json"
                    # NaN and Infinity exercise Python's JSON extensions, not standard JSON.
                    path.write_text(json.dumps(scan), encoding="utf-8")
                    # Enter the real module CLI with an explicit source path, including on
                    # Python's isolated Windows embedded distribution.
                    launch = "import runpy,sys;sys.path.insert(0,sys.argv.pop(1));runpy.run_module('ghfind',run_name='__main__')"
                    result = subprocess.run(
                        [sys.executable, "-I", "-B", "-c", launch, str(PACKAGE),
                         "verify", str(path), "--json"],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                    )
                self.assertEqual(result.returncode, 0 if verified else 3, result.stderr)
                self.assertEqual(result.stderr, b"")
                self.assertEqual(json.loads(result.stdout.decode("utf-8"))["verified"], verified)
