<?php

namespace App\Services\Messaging;

use App\Models\User;

/**
 * Who asked for the work.
 *
 * Carried on the envelope so the worker can stamp attribution onto the row it
 * writes. The worker cannot look this up itself - it has no session and no HTTP
 * context - so if the web tier does not pass it, the result is unattributable.
 */
final class Actor
{
    public function __construct(
        public readonly ?int $id,
        public readonly ?string $email,
        public readonly ?string $role,
    ) {
    }

    public static function fromUser(?User $user): self
    {
        return new self($user?->id, $user?->email, $user?->role);
    }

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'email' => $this->email,
            'role' => $this->role,
        ];
    }
}
