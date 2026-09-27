package handler

// The payroll calculation, extracted from the database transaction.
//
// Pure input -> pure output: no SQL, no context, no clock. That is what makes the
// arithmetic testable, and the arithmetic is the one part of this system where a
// bug costs real money. Everything I/O-related stays in payroll.go.

// EmployeeComp is one employee's compensation inputs.
type EmployeeComp struct {
	ID             int64
	AnnualSalary   Money
	CommissionRate float64
}

// PayrollLine is the computed result for one employee.
type PayrollLine struct {
	EmployeeID int64
	Gross      Money
	Commission Money
	Tax        Money
	Net        Money
}

// PayrollTotals is the run-level summary.
type PayrollTotals struct {
	EmployeeCount int
	Gross         Money
	Commission    Money
	Tax           Money
	Net           Money
}

// PayrollInput is everything needed to compute a run.
type PayrollInput struct {
	Employees []EmployeeComp
	// CommissionBase is each employee's sales total inside the period, keyed by
	// employee id. Absent means no sales, which is not the same as zero rate.
	CommissionBase map[int64]Money
	// PaidDays is the inclusive day count of the pay period.
	PaidDays int
	// TaxRate is a fraction, e.g. 0.22 for 22%.
	TaxRate float64
	// DaysInYear is the proration denominator. Held as a parameter rather than a
	// constant so a leap year, or a 360-day convention, is a caller decision.
	DaysInYear int
}

// DefaultDaysInYear is the proration denominator used by the worker.
const DefaultDaysInYear = 365

// CalculatePayroll computes every line and the run totals.
//
// Order of operations matters and is deliberate:
//
//	gross      = annual salary prorated over the paid days
//	commission = sales in the period * the employee's rate
//	tax        = (gross + commission) * tax rate     <- commission IS taxable
//	net        = gross + commission - tax
//
// Taxing the sum rather than the gross alone is the correct treatment for
// commission income; taxing only base salary would under-withhold for every sales
// rep, which is the kind of error that surfaces as a tax liability much later.
//
// Totals are accumulated from the rounded per-line values, never computed
// independently from the raw inputs. Two separate calculations would disagree by a
// cent or two, and a run whose total does not equal the sum of its lines is
// impossible to reconcile.
func CalculatePayroll(input PayrollInput) ([]PayrollLine, PayrollTotals) {
	daysInYear := input.DaysInYear
	if daysInYear <= 0 {
		daysInYear = DefaultDaysInYear
	}

	lines := make([]PayrollLine, 0, len(input.Employees))
	totals := PayrollTotals{}

	for _, employee := range input.Employees {
		gross := employee.AnnualSalary.Prorate(input.PaidDays, daysInYear)

		var commission Money
		if base, ok := input.CommissionBase[employee.ID]; ok {
			commission = base.MulRate(employee.CommissionRate)
		}

		tax := (gross + commission).MulRate(input.TaxRate)

		line := PayrollLine{
			EmployeeID: employee.ID,
			Gross:      gross,
			Commission: commission,
			Tax:        tax,
			Net:        gross + commission - tax,
		}

		lines = append(lines, line)

		totals.Gross += line.Gross
		totals.Commission += line.Commission
		totals.Tax += line.Tax
		totals.Net += line.Net
	}

	totals.EmployeeCount = len(lines)

	return lines, totals
}
