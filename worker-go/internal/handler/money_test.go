package handler

import "testing"

func TestParseMoney(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    Money
		wantErr bool
	}{
		{name: "empty is zero", input: "", want: 0},
		{name: "whole amount", input: "48200.00", want: 4820000},
		{name: "cents", input: "0.01", want: 1},
		{name: "no decimal point", input: "100", want: 10000},
		{name: "negative", input: "-25.50", want: -2550},
		// MySQL DECIMAL(12,2) never sends more than two places, but a third would
		// otherwise silently truncate rather than round.
		{name: "rounds half up", input: "1.005", want: 101},
		{name: "rounds down", input: "1.004", want: 100},
		{name: "garbage is an error", input: "not-a-number", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseMoney(tc.input)

			if tc.wantErr {
				if err == nil {
					t.Fatalf("ParseMoney(%q) = %d, want an error", tc.input, got)
				}

				return
			}

			if err != nil {
				t.Fatalf("ParseMoney(%q) returned an unexpected error: %v", tc.input, err)
			}

			if got != tc.want {
				t.Errorf("ParseMoney(%q) = %d cents, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestMoneyString(t *testing.T) {
	tests := []struct {
		cents Money
		want  string
	}{
		{0, "0.00"},
		{1, "0.01"},
		{99, "0.99"},
		{100, "1.00"},
		{4820000, "48200.00"},
		{-2550, "-25.50"},
		// The bug this guards: formatting -1 as "-0.-1" or "0.-1" if the sign is
		// not extracted before splitting into units and cents.
		{-1, "-0.01"},
		{-100, "-1.00"},
	}

	for _, tc := range tests {
		if got := tc.cents.String(); got != tc.want {
			t.Errorf("Money(%d).String() = %q, want %q", tc.cents, got, tc.want)
		}
	}
}

func TestMoneyMulRate(t *testing.T) {
	tests := []struct {
		name  string
		cents Money
		rate  float64
		want  Money
	}{
		{name: "22 percent tax", cents: 100000, rate: 0.22, want: 22000},
		{name: "zero rate", cents: 100000, rate: 0, want: 0},
		{name: "4.5 percent commission", cents: 149999, rate: 0.045, want: 6750},
		// 33.333 cents must land on 33, not 34: half-up applies at the boundary,
		// not below it.
		{name: "rounds at the cent boundary", cents: 100, rate: 0.33333, want: 33},
		{name: "rounds half up", cents: 1000, rate: 0.005, want: 5},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.cents.MulRate(tc.rate); got != tc.want {
				t.Errorf("Money(%d).MulRate(%v) = %d, want %d", tc.cents, tc.rate, got, tc.want)
			}
		})
	}
}

func TestMoneyProrate(t *testing.T) {
	annual := Money(6000000) // 60,000.00

	tests := []struct {
		name       string
		days       int
		daysInYear int
		want       Money
	}{
		{name: "full year", days: 365, daysInYear: 365, want: 6000000},
		{name: "half a month", days: 15, daysInYear: 365, want: 246575},
		{name: "single day", days: 1, daysInYear: 365, want: 16438},
		{name: "zero days", days: 0, daysInYear: 365, want: 0},
		// Guards a division by zero that would panic mid-transaction.
		{name: "zero denominator is safe", days: 15, daysInYear: 0, want: 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := annual.Prorate(tc.days, tc.daysInYear); got != tc.want {
				t.Errorf("Prorate(%d, %d) = %d, want %d", tc.days, tc.daysInYear, got, tc.want)
			}
		})
	}
}

// TestMoneyAvoidsFloatDrift is the reason Money exists.
//
// Summing 0.01 ten thousand times in float64 does not give exactly 100.00, and a
// payroll run over thousands of lines accumulates exactly that error until the run
// total disagrees with the sum of its lines. Integer cents cannot drift.
func TestMoneyAvoidsFloatDrift(t *testing.T) {
	const iterations = 10_000

	var (
		exact Money
		naive float64
	)

	for i := 0; i < iterations; i++ {
		exact += MoneyFromFloat(0.01)
		naive += 0.01
	}

	// 10,000 x 1 cent = 10,000 cents = 100.00 exactly.
	if exact != 10_000 {
		t.Fatalf("integer cents drifted: got %d, want 10000", exact)
	}

	if exact.String() != "100.00" {
		t.Errorf("got %q, want \"100.00\"", exact.String())
	}

	// The failure mode being avoided: the float sum is not exactly 100.
	if naive == 100.0 {
		t.Log("float64 happened to be exact here; the integer path is still the safe one")
	} else {
		t.Logf("float64 sum drifted to %.17f — this is why Money is an integer", naive)
	}
}

func TestParseMoneyExactDecimalHandling(t *testing.T) {
	// These are the cases float64 gets wrong. "1.005" is 1.00499999999999989 as a
	// float64, so ParseFloat + round-half-up returns 100 cents instead of 101.
	tests := []struct {
		input string
		want  Money
	}{
		{"1.005", 101},
		{"2.675", 268},
		{"0.615", 62},
		{"1.0049", 100},
		{"0.995", 100}, // rounding carries into the units
		{"-0.995", -100},
		{".50", 50},
		{"+3.25", 325},
		{"  7.10  ", 710},
	}

	for _, tc := range tests {
		got, err := ParseMoney(tc.input)
		if err != nil {
			t.Errorf("ParseMoney(%q) errored: %v", tc.input, err)

			continue
		}

		if got != tc.want {
			t.Errorf("ParseMoney(%q) = %d, want %d", tc.input, got, tc.want)
		}
	}
}

func TestParseMoneyRejectsBadInput(t *testing.T) {
	for _, input := range []string{"not-a-number", "1.2.3", "12x.00", "1.0a", "-", "+"} {
		if _, err := ParseMoney(input); err == nil {
			t.Errorf("ParseMoney(%q) should have failed", input)
		}
	}
}
