<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class ImportSalesRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** @return array<string, mixed> */
    public function rules(): array
    {
        return [
            'source' => ['sometimes', 'string', 'max:60'],
            'rows' => ['required', 'array', 'min:1', 'max:2000'],
            'rows.*.external_id' => ['required', 'string', 'max:64'],
            'rows.*.rep_email' => ['required', 'email', 'max:190'],
            'rows.*.product' => ['sometimes', 'nullable', 'string', 'max:120'],
            'rows.*.amount' => ['required', 'numeric', 'min:0'],
            'rows.*.currency' => ['sometimes', 'string', 'size:3'],
            'rows.*.sold_at' => ['required', 'date'],
        ];
    }

    /** @return array<string, mixed> */
    public function payload(): array
    {
        $rows = array_map(static fn (array $row) => [
            'external_id' => (string) $row['external_id'],
            'rep_email' => (string) $row['rep_email'],
            'product' => $row['product'] ?? null,
            'amount' => round((float) $row['amount'], 2),
            'currency' => strtoupper($row['currency'] ?? 'USD'),
            'sold_at' => date('Y-m-d\TH:i:s\Z', strtotime((string) $row['sold_at'])),
        ], (array) $this->input('rows'));

        return [
            'source' => $this->input('source', 'api'),
            'rows' => $rows,
        ];
    }
}
