<?php

namespace App\Services\Status;

/**
 * Lifecycle of an asynchronous API request, tracked in Firestore.
 *
 *  ACCEPTED  - validated by the web tier, about to be published
 *  QUEUED    - handed to Pub/Sub, message id known
 *  PROCESSING- a Go worker pod leased the message
 *  COMPLETED - worker finished and committed rows to Cloud SQL
 *  FAILED    - terminal failure (validation, DB error, retries exhausted)
 */
final class RequestStatus
{
    public const ACCEPTED = 'ACCEPTED';
    public const QUEUED = 'QUEUED';
    public const PROCESSING = 'PROCESSING';
    public const COMPLETED = 'COMPLETED';
    public const FAILED = 'FAILED';
}
