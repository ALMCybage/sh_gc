package handler

import "testing"

// The calculation engine is the one place in this system where a bug costs real
// money, so these tests are deliberately specific about the arithmetic rather than
// just asserting "something came back".

func TestCalculatePayrollSingleEmployeeNoCommission(t *testing.T) {
	lines, totals := CalculatePayroll(PayrollInput{
		Employees:  []EmployeeComp{{ID: 1, AnnualSalary: 6_000_000}}, // 60,000.00
		PaidDays:   15,
		TaxRate:    0.22,
		DaysInYear: 365,
	})

	if len(lines) != 1 {
		t.Fatalf("got %d lines, want 1", len(lines))
	}

	// 60000 * 15/365 = 2465.7534 -> 2465.75
	// tax = 2465.75 * 0.22 = 542.465 -> 542.47 (half up)
	// net = 2465.75 - 542.47 = 1923.28
	want := PayrollLine{EmployeeID: 1, Gross: 246575, Commission: 0, Tax: 54247, Net: 192328}

	if lines[0] != want {
		t.Errorf("line = %+v, want %+v", lines[0], want)
	}

	if totals.Net != want.Net || totals.EmployeeCount != 1 {
		t.Errorf("totals = %+v, want net %d and count 1", totals, want.Net)
	}
}

func TestCalculatePayrollTaxesCommissionToo(t *testing.T) {
	// Commission is taxable income. Taxing only base salary would under-withhold
	// for every sales rep, which surfaces much later as a tax liability.
	lines, _ := CalculatePayroll(PayrollInput{
		Employees:      []EmployeeComp{{ID: 7, AnnualSalary: 3_650_000, CommissionRate: 0.045}},
		CommissionBase: map[int64]Money{7: 1_000_000}, // 10,000.00 of sales
		PaidDays:       365,
		TaxRate:        0.20,
		DaysInYear:     365,
	})

	line := lines[0]

	if line.Gross != 3_650_000 {
		t.Fatalf("gross = %d, want 3650000", line.Gross)
	}

	if line.Commission != 45_000 { // 10,000.00 * 4.5% = 450.00
		t.Fatalf("commission = %d, want 45000", line.Commission)
	}

	// The assertion that matters: tax is 20% of (gross + commission), not of gross.
	wantTax := Money(739_000) // (3,650,000 + 45,000) * 0.20
	if line.Tax != wantTax {
		t.Errorf("tax = %d, want %d — commission must be taxed", line.Tax, wantTax)
	}

	if line.Net != line.Gross+line.Commission-line.Tax {
		t.Errorf("net %d does not equal gross + commission - tax", line.Net)
	}
}

func TestCalculatePayrollCommissionOnlyWhenEmployeeHasSales(t *testing.T) {
	lines, _ := CalculatePayroll(PayrollInput{
		Employees: []EmployeeComp{
			{ID: 1, AnnualSalary: 1_000_000, CommissionRate: 0.05},
			{ID: 2, AnnualSalary: 1_000_000, CommissionRate: 0.05},
		},
		// Only employee 1 sold anything. Employee 2 has a rate but no sales, which
		// must yield zero rather than being skipped or inheriting a neighbour's base.
		CommissionBase: map[int64]Money{1: 200_000},
		PaidDays:       365,
		TaxRate:        0,
		DaysInYear:     365,
	})

	if lines[0].Commission != 10_000 {
		t.Errorf("employee 1 commission = %d, want 10000", lines[0].Commission)
	}

	if lines[1].Commission != 0 {
		t.Errorf("employee 2 commission = %d, want 0", lines[1].Commission)
	}
}

// TestCalculatePayrollTotalsEqualSumOfLines is the invariant an auditor checks
// first: a run total that does not equal the sum of its lines cannot be reconciled.
// Computing totals independently from the raw inputs would break this by a cent or
// two, which is why they are accumulated from the rounded line values.
func TestCalculatePayrollTotalsEqualSumOfLines(t *testing.T) {
	employees := make([]EmployeeComp, 0, 500)
	base := make(map[int64]Money, 500)

	for i := 1; i <= 500; i++ {
		// Deliberately awkward salaries and sales, to provoke rounding.
		employees = append(employees, EmployeeComp{
			ID:             int64(i),
			AnnualSalary:   Money(4_500_000 + i*1_337),
			CommissionRate: 0.0333,
		})
		base[int64(i)] = Money(i * 977)
	}

	lines, totals := CalculatePayroll(PayrollInput{
		Employees:      employees,
		CommissionBase: base,
		PaidDays:       17,
		TaxRate:        0.2237,
		DaysInYear:     365,
	})

	var sum PayrollTotals
	for _, line := range lines {
		sum.Gross += line.Gross
		sum.Commission += line.Commission
		sum.Tax += line.Tax
		sum.Net += line.Net
	}

	if totals.Gross != sum.Gross {
		t.Errorf("gross total %d != sum of lines %d", totals.Gross, sum.Gross)
	}

	if totals.Commission != sum.Commission {
		t.Errorf("commission total %d != sum of lines %d", totals.Commission, sum.Commission)
	}

	if totals.Tax != sum.Tax {
		t.Errorf("tax total %d != sum of lines %d", totals.Tax, sum.Tax)
	}

	if totals.Net != sum.Net {
		t.Errorf("net total %d != sum of lines %d", totals.Net, sum.Net)
	}

	if totals.EmployeeCount != 500 {
		t.Errorf("employee count = %d, want 500", totals.EmployeeCount)
	}
}

func TestCalculatePayrollEdgeCases(t *testing.T) {
	t.Run("no employees yields empty totals", func(t *testing.T) {
		lines, totals := CalculatePayroll(PayrollInput{PaidDays: 15, TaxRate: 0.2, DaysInYear: 365})

		if len(lines) != 0 || totals.EmployeeCount != 0 || totals.Net != 0 {
			t.Errorf("got %d lines and %+v, want empty", len(lines), totals)
		}
	})

	t.Run("zero tax rate leaves net equal to gross plus commission", func(t *testing.T) {
		lines, _ := CalculatePayroll(PayrollInput{
			Employees:      []EmployeeComp{{ID: 1, AnnualSalary: 1_000_000, CommissionRate: 0.1}},
			CommissionBase: map[int64]Money{1: 100_000},
			PaidDays:       365,
			TaxRate:        0,
			DaysInYear:     365,
		})

		if lines[0].Tax != 0 {
			t.Errorf("tax = %d, want 0", lines[0].Tax)
		}

		if lines[0].Net != lines[0].Gross+lines[0].Commission {
			t.Errorf("net = %d, want gross + commission", lines[0].Net)
		}
	})

	t.Run("missing DaysInYear falls back to the default", func(t *testing.T) {
		withDefault, _ := CalculatePayroll(PayrollInput{
			Employees: []EmployeeComp{{ID: 1, AnnualSalary: 6_000_000}},
			PaidDays:  15,
		})

		explicit, _ := CalculatePayroll(PayrollInput{
			Employees:  []EmployeeComp{{ID: 1, AnnualSalary: 6_000_000}},
			PaidDays:   15,
			DaysInYear: DefaultDaysInYear,
		})

		if withDefault[0] != explicit[0] {
			t.Errorf("zero DaysInYear = %+v, want the same as %d: %+v",
				withDefault[0], DefaultDaysInYear, explicit[0])
		}
	})

	t.Run("a zero salary employee still produces a line", func(t *testing.T) {
		// Unpaid interns exist, and dropping them would make the employee count on
		// the run disagree with the number of people processed.
		lines, totals := CalculatePayroll(PayrollInput{
			Employees:  []EmployeeComp{{ID: 1, AnnualSalary: 0}},
			PaidDays:   15,
			TaxRate:    0.22,
			DaysInYear: 365,
		})

		if len(lines) != 1 || totals.EmployeeCount != 1 {
			t.Fatalf("got %d lines, want 1", len(lines))
		}

		if lines[0].Net != 0 {
			t.Errorf("net = %d, want 0", lines[0].Net)
		}
	})
}
