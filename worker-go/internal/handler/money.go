package handler

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Money is an amount in minor units (cents).
//
// All payroll arithmetic runs in integer cents and only converts to a decimal
// string at the point of insertion. Doing the maths in float64 and rounding at
// the end lets sub-cent error accumulate across thousands of payroll lines and
// leaves the run totals disagreeing with the sum of their lines.
type Money int64

// ParseMoney converts a MySQL DECIMAL string (e.g. "48200.00") to cents.
//
// Parsed digit by digit rather than through strconv.ParseFloat, because float64
// cannot represent most decimal fractions exactly. "1.005" becomes
// 1.00499999999999989 as a float64, so ParseFloat followed by round-half-up gives
// 100 cents where the decimal value clearly says 101. Reading the string directly
// means the conversion is exact and the rounding decision is made on the digit that
// actually appears in the input.
func ParseMoney(raw string) (Money, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 0, nil
	}

	negative := false

	switch s[0] {
	case '-':
		negative = true
		s = s[1:]
	case '+':
		s = s[1:]
	}

	if s == "" {
		return 0, fmt.Errorf("unparseable amount %q: no digits", raw)
	}

	whole, fraction, _ := strings.Cut(s, ".")

	if whole == "" {
		whole = "0" // ".50"
	}

	units, err := strconv.ParseInt(whole, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("unparseable amount %q: %w", raw, err)
	}

	cents, err := centsFromFraction(fraction, raw)
	if err != nil {
		return 0, err
	}

	// Carry, for the "0.995 -> 1.00" case where rounding overflows the cents.
	if cents >= 100 {
		units += cents / 100
		cents %= 100
	}

	total := units*100 + cents
	if negative {
		total = -total
	}

	return Money(total), nil
}

// centsFromFraction turns the digits after the decimal point into 0..100 cents,
// rounding half up on the third digit.
func centsFromFraction(fraction, raw string) (int64, error) {
	for _, r := range fraction {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("unparseable amount %q: bad fractional digit %q", raw, r)
		}
	}

	// Pad so there are always at least three digits to inspect.
	padded := fraction + "000"

	cents, err := strconv.ParseInt(padded[:2], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("unparseable amount %q: %w", raw, err)
	}

	if padded[2] >= '5' {
		cents++
	}

	return cents, nil
}

// MoneyFromFloat converts a JSON amount to cents.
func MoneyFromFloat(v float64) Money {
	return Money(math.Round(v * 100))
}

// String renders the amount as a fixed-point decimal for SQL and JSON.
func (m Money) String() string {
	negative := m < 0
	if negative {
		m = -m
	}

	s := fmt.Sprintf("%d.%02d", int64(m)/100, int64(m)%100)

	if negative {
		return "-" + s
	}

	return s
}

// Float returns the amount as a float64, for JSON summaries only.
func (m Money) Float() float64 {
	return float64(m) / 100
}

// MulRate multiplies by a rate (tax %, commission %) with half-up rounding at
// the cent boundary.
func (m Money) MulRate(rate float64) Money {
	return Money(math.Round(float64(m) * rate))
}

// Prorate splits an annual amount across a number of days in a 365-day year.
func (m Money) Prorate(days, yearDays int) Money {
	if yearDays <= 0 {
		return 0
	}

	return Money(math.Round(float64(m) * float64(days) / float64(yearDays)))
}
