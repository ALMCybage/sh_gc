<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class CalculatePayrollRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** @return array<string, mixed> */
    public function rules(): array
    {
        return [
            'period_start' => ['required', 'date_format:Y-m-d'],
            'period_end' => ['required', 'date_format:Y-m-d', 'after_or_equal:period_start'],
            'employee_ids' => ['sometimes', 'array', 'max:5000'],
            'employee_ids.*' => ['integer', 'min:1'],
            'include_commission' => ['sometimes', 'boolean'],
            'tax_rate' => ['sometimes', 'numeric', 'between:0,0.6'],
            'notes' => ['sometimes', 'string', 'max:500'],
        ];
    }

    /** @return array<string, mixed> */
    public function payload(): array
    {
        return [
            'period_start' => $this->input('period_start'),
            'period_end' => $this->input('period_end'),
            'employee_ids' => array_map('intval', (array) $this->input('employee_ids', [])),
            'include_commission' => $this->boolean('include_commission', true),
            'tax_rate' => (float) $this->input('tax_rate', 0.22),
            'notes' => $this->input('notes'),
        ];
    }
}
