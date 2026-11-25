package scoring

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestSharedRoundingParity(t *testing.T) {
	contents, err := os.ReadFile("fixtures/rounding-parity.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		BaseMetrics   map[string]json.RawMessage `json:"base_metrics"`
		RoundingEdges []struct {
			Value    float64 `json:"value"`
			Digits   int     `json:"digits"`
			Expected float64 `json:"expected"`
		} `json:"rounding_edges"`
		Cases []struct {
			Name      string                     `json:"name"`
			Overrides map[string]json.RawMessage `json:"overrides"`
			Expected  any                        `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(contents, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, edge := range fixture.RoundingEdges {
		if got := roundToEven(edge.Value, edge.Digits); got != edge.Expected {
			t.Errorf("roundToEven(%v, %d) = %v, want %v", edge.Value, edge.Digits, got, edge.Expected)
		}
	}
	if roundJS(2.5) != 3 {
		t.Fatal("JavaScript Math.round semantics changed")
	}
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			metrics := make(map[string]json.RawMessage)
			for key, value := range fixture.BaseMetrics {
				metrics[key] = value
			}
			for key, value := range test.Overrides {
				metrics[key] = value
			}
			encoded, err := json.Marshal(metrics)
			if err != nil {
				t.Fatal(err)
			}
			var input RawMetrics
			if err := json.Unmarshal(encoded, &input); err != nil {
				t.Fatal(err)
			}
			result := Score(input)
			risk := result.RiskAssessment
			signals := make([]any, 0, len(risk.Signals))
			for _, s := range risk.Signals {
				observed := make(map[string]any)
				for _, key := range []string{"smoothed_rate", "wilson_lower", "follower_ratio"} {
					if value, ok := s.Evidence.Observed[key]; ok {
						observed[key] = value
					}
				}
				signals = append(signals, map[string]any{"flag": s.Flag, "severity": s.Severity, "confidence": s.Confidence, "penalty": s.Penalty, "coverage": s.Evidence.Coverage, "observed": observed})
			}
			actual := map[string]any{
				"sub_scores": result.SubScores, "base_score": result.BaseScore, "final_score": result.FinalScore, "total_penalty": result.TotalPenalty,
				"risk": map[string]any{"coverage": risk.Coverage, "confidence": risk.Confidence, "risk_score": risk.RiskScore, "applied_penalty": risk.AppliedPenalty, "signals": signals},
			}
			encoded, err = json.Marshal(actual)
			if err != nil {
				t.Fatal(err)
			}
			var normalized any
			if err := json.Unmarshal(encoded, &normalized); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(normalized, test.Expected) {
				expected, _ := json.Marshal(test.Expected)
				t.Errorf("rounding mismatch\ngot: %s\nwant: %s", encoded, expected)
			}
		})
	}
}
