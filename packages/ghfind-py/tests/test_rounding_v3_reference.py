"""Regressions against synthetic scans produced by the TypeScript scorer."""
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from ghfind._rounding import round_half_even
from ghfind.local import score_metrics, verify_scan

PACKAGE = Path(__file__).resolve().parents[1]
REFERENCE = json.loads((Path(__file__).parent / "fixtures/rounding-v3-ts.json").read_text(encoding="utf-8"))


def negative_zero(value):
    return value == 0 and math.copysign(1.0, value) < 0


class TypeScriptRoundingRegressionTests(unittest.TestCase):
    def test_large_finite_public_score_and_verify(self):
        for name, field in (("age_edge", "account_maturity"), ("activity_edge", "activity_authenticity")):
            scan = REFERENCE["scans"][name]
            with self.subTest(name=name):
                score = score_metrics(scan["metrics"])
                self.assertEqual(score["sub_scores"][field], scan["scoring"]["sub_scores"][field])
                self.assertTrue(verify_scan(scan)["verified"])

    def test_large_finite_actual_module_cli(self):
        for name in ("normal", "age_edge", "activity_edge"):
            scan = REFERENCE["scans"][name]
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "scan.json"
                path.write_text(json.dumps(scan, allow_nan=False), encoding="utf-8")
                launch = ("import runpy,sys\n"
                          "sys.path.insert(0,sys.argv.pop(1))\n"
                          "def audit(event,args):\n"
                          " if event.startswith('socket.'): raise RuntimeError('network disabled')\n"
                          "sys.addaudithook(audit)\n"
                          "runpy.run_module('ghfind',run_name='__main__')")
                proc = subprocess.run([sys.executable, "-I", "-B", "-c", launch, str(PACKAGE),
                                       "verify", str(path), "--json"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
                self.assertEqual(proc.returncode, 0, (proc.stdout, proc.stderr))
                self.assertTrue(json.loads(proc.stdout)["verified"])

    def test_public_score_and_verify_retain_negative_zero(self):
        scan = REFERENCE["scans"]["negative_zero"]
        self.assertTrue(REFERENCE["public_negative_zero"])
        score = score_metrics(scan["metrics"])
        self.assertTrue(negative_zero(score["sub_scores"]["account_maturity"]))
        verified = verify_scan(scan)
        self.assertTrue(verified["verified"])
        self.assertTrue(negative_zero(verified["local"]["sub_scores"]["account_maturity"]))

    def test_typescript_boundary_values_and_zero_signs(self):
        cases = REFERENCE["helper"]
        self.assertEqual(len(cases), 213)
        for case in cases:
            with self.subTest(name=case["name"], digits=case["digits"], branch=case["branch"]):
                value = -0.0 if case["value_negative_zero"] else case["value"]
                result = round_half_even(value, case["digits"])
                self.assertEqual(result, case["result"])
                if result == 0:
                    self.assertEqual(negative_zero(result), case["result_negative_zero"])
