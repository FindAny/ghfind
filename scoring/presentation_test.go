package scoring

import (
	"encoding/json"
	"math"
	"os"
	"testing"
)

func TestPresentationSignalsMatchSharedFixtures(t *testing.T) {
	data, err := os.ReadFile("fixtures/presentation-fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []struct {
		Name     string             `json:"name"`
		PRs      []RecentPR         `json:"prs"`
		OwnRepos []string           `json:"own_repos"`
		Expected map[string]float64 `json:"expected"`
		Discount float64            `json:"discount"`
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	for _, f := range fixtures {
		t.Run(f.Name, func(t *testing.T) {
			var metrics RawMetrics
			applyPresentationSignals(&metrics, f.PRs, "fixture-account-045", f.OwnRepos)
			actual := map[string]float64{
				"presentation_churn_share":        *metrics.PresentationChurnShare,
				"presentation_core_churn_share":   *metrics.PresentationCoreChurnShare,
				"presentation_repo_concentration": *metrics.PresentationRepoConcentration,
				"presentation_pr_sample":          *metrics.PresentationPRSample,
				"presentation_core_pr_count":      *metrics.PresentationCorePRCount,
			}
			for key, want := range f.Expected {
				if got, ok := actual[key]; !ok || math.Abs(got-want) > 1e-12 {
					t.Errorf("%s: got %v want %v", key, got, want)
				}
			}
			if got := presentationDiscount(metrics); math.Abs(got-f.Discount) > 1e-12 {
				t.Errorf("discount: got %v want %v", got, f.Discount)
			}
		})
	}
}
