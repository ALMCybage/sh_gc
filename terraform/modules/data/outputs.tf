output "redis_host" {
  value       = google_redis_instance.cache.host
  description = "Private IP of the Memorystore primary."
}

output "redis_port" {
  value = google_redis_instance.cache.port
}

output "redis_auth_secret_id" {
  value       = google_secret_manager_secret.redis_auth.secret_id
  description = "Secret Manager id holding the Redis AUTH string."
}

output "firestore_database" {
  value = google_firestore_database.default.name
}

output "topics" {
  value = { for k, v in google_pubsub_topic.work : k => v.name }
}

output "subscriptions" {
  value = { for k, v in google_pubsub_subscription.worker : k => v.name }
}

output "dead_letter_topic" {
  value = google_pubsub_topic.dead_letter.name
}

output "dead_letter_subscription" {
  value       = google_pubsub_subscription.dead_letter_inspect.name
  description = "Where poison messages accumulate; the DLQ alert watches this."
}

output "artifact_registry_url" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
  description = "Image prefix for both services."
}

output "frontend_bucket" {
  value = google_storage_bucket.frontend.name
}
