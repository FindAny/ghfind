import { describe, expect, it } from "vitest";
import { roundHalfEven, score } from "../src/score";
import type { RawMetrics } from "../src/types";
import fixture from "../fixtures/rounding-parity.json";

describe("shared rounding parity", () => {
  it("rounds tolerance boundaries in each supported precision", () => {
    for (const edge of fixture.rounding_edges) {
      expect(roundHalfEven(edge.value, edge.digits)).toBe(edge.expected);
    }
    expect(Math.round(2.5)).toBe(3);
  });
  for (const test of fixture.cases) {
    it(test.name, () => {
      const result = score({ ...fixture.base_metrics, ...test.overrides } as RawMetrics);
      const risk = result.risk_assessment!;
      expect({
        sub_scores: result.sub_scores,
        base_score: result.base_score,
        final_score: result.final_score,
        total_penalty: result.total_penalty,
        risk: {
          coverage: risk.coverage,
          confidence: risk.confidence,
          risk_score: risk.risk_score,
          applied_penalty: risk.applied_penalty,
          signals: risk.signals.map((signal) => ({
            flag: signal.flag,
            severity: signal.severity,
            confidence: signal.confidence,
            penalty: signal.penalty,
            coverage: signal.evidence.coverage,
            observed: Object.fromEntries(Object.entries(signal.evidence.observed).filter(
              ([key]) => ["smoothed_rate", "wilson_lower", "follower_ratio"].includes(key),
            )),
          })),
        },
      }).toEqual(test.expected);
    });
  }
});
