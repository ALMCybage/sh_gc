<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Pub/Sub guarantees at-least-once delivery, so the Go worker claims each
     * event_id here inside the same transaction as its writes. A duplicate
     * delivery hits the unique key, the transaction rolls back, and the worker
     * acks the message without doing the work twice.
     */
    public function up(): void
    {
        Schema::create('processed_events', function (Blueprint $table) {
            $table->id();
            $table->uuid('event_id')->unique();
            $table->string('event_type', 64);
            $table->string('subscription', 190)->nullable();
            $table->string('worker', 120)->nullable();
            $table->timestamp('processed_at')->useCurrent();

            $table->index('event_type');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('processed_events');
    }
};
