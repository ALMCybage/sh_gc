// Package config loads worker configuration from the environment, which is how
// Kubernetes ConfigMaps and Secrets reach the container.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is the full worker configuration.
type Config struct {
	ProjectID string

	// Subscriptions the worker pulls from, in "name=eventType" form. Both
	// topics from the architecture diagram are consumed by the same pod pool,
	// which keeps the deployment surface small while the router dispatches.
	PayrollSubscription string
	SalesSubscription   string

	// Concurrency knobs. MaxOutstanding is the real backpressure control: it
	// caps how much work one pod leases, so the HPA scales out instead of a
	// single pod queueing up thousands of messages.
	MaxOutstandingMessages int
	NumGoroutines          int
	AckDeadline            time.Duration
	MaxRetries             int

	DB DBConfig

	FirestoreDatabase   string
	FirestoreCollection string
	StatusDriver        string // firestore | none

	HTTPAddr        string
	ShutdownTimeout time.Duration

	WorkerName string

	// TenantsJSON, when set, replaces the built-in tenant registry.
	TenantsJSON  string
	SchemaPrefix string
}

// DBConfig describes how to reach Cloud SQL. In GKE this is always
// 127.0.0.1:3306, served by the Cloud SQL Auth Proxy sidecar.
type DBConfig struct {
	Host     string
	Port     int
	User     string
	Password string

	// MaxOpenConns is PER TENANT SCHEMA, not per pod. Total connections from one
	// pod is roughly MaxOpenConns x MaxOpenSchemas, and every pod adds to the
	// instance total, so keep the product small:
	//
	//   pods x MaxOpenSchemas x MaxOpenConns  <  Cloud SQL max_connections
	//
	// At 20 pods, 8 schemas and 4 conns that is 640, comfortably inside a
	// db-custom-4-16384 instance's budget with headroom for the web tier.
	MaxOpenConns int
	MaxIdleConns int

	// MaxOpenSchemas caps how many tenant pools one pod holds open at once. The
	// least recently used is closed beyond that. Without a cap, a pod that sees
	// traffic from every tenant would hold a pool for every tenant forever.
	MaxOpenSchemas int

	ConnMaxLifetime time.Duration
	ConnMaxIdleTime time.Duration
	QueryTimeout    time.Duration
}

// Load reads the environment and applies defaults.
func Load() (*Config, error) {
	cfg := &Config{
		ProjectID:              env("GOOGLE_CLOUD_PROJECT", ""),
		PayrollSubscription:    env("PUBSUB_SUB_PAYROLL", "payroll-calc-events-worker"),
		SalesSubscription:      env("PUBSUB_SUB_SALES", "sales-import-worker"),
		MaxOutstandingMessages: envInt("PUBSUB_MAX_OUTSTANDING", 20),
		NumGoroutines:          envInt("PUBSUB_NUM_GOROUTINES", 4),
		AckDeadline:            envDuration("PUBSUB_ACK_EXTENSION", 5*time.Minute),
		MaxRetries:             envInt("WORKER_MAX_RETRIES", 5),
		FirestoreDatabase:      env("FIRESTORE_DATABASE", "(default)"),
		FirestoreCollection:    env("FIRESTORE_COLLECTION", "api_request_statuses"),
		StatusDriver:           env("STATUS_DRIVER", "firestore"),
		HTTPAddr:               env("HTTP_ADDR", ":8081"),
		ShutdownTimeout:        envDuration("SHUTDOWN_TIMEOUT", 30*time.Second),
		WorkerName:             env("POD_NAME", hostname()),
		TenantsJSON:            env("TENANTS_JSON", ""),
		SchemaPrefix:           env("TENANCY_SCHEMA_PREFIX", "tenant_"),
		DB: DBConfig{
			Host:            env("DB_HOST", "127.0.0.1"),
			Port:            envInt("DB_PORT", 3306),
			User:            env("DB_USERNAME", "app"),
			Password:        env("DB_PASSWORD", ""),
			MaxOpenConns:    envInt("DB_MAX_OPEN_CONNS", 4),
			MaxIdleConns:    envInt("DB_MAX_IDLE_CONNS", 2),
			MaxOpenSchemas:  envInt("DB_MAX_OPEN_SCHEMAS", 8),
			ConnMaxLifetime: envDuration("DB_CONN_MAX_LIFETIME", 30*time.Minute),
			ConnMaxIdleTime: envDuration("DB_CONN_MAX_IDLE_TIME", 5*time.Minute),
			QueryTimeout:    envDuration("DB_QUERY_TIMEOUT", 60*time.Second),
		},
	}

	if cfg.ProjectID == "" {
		return nil, fmt.Errorf("GOOGLE_CLOUD_PROJECT is required")
	}

	if cfg.MaxOutstandingMessages < 1 {
		return nil, fmt.Errorf("PUBSUB_MAX_OUTSTANDING must be >= 1")
	}

	return cfg, nil
}

// UsingPubSubEmulator reports whether the Pub/Sub client will hit the local
// emulator. The Google client library honours this variable itself; we only read
// it so startup logs make the target obvious.
func (c *Config) UsingPubSubEmulator() bool {
	return os.Getenv("PUBSUB_EMULATOR_HOST") != ""
}

// UsingFirestoreEmulator mirrors UsingPubSubEmulator for Firestore.
func (c *Config) UsingFirestoreEmulator() bool {
	return os.Getenv("FIRESTORE_EMULATOR_HOST") != ""
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}

	return fallback
}

func envInt(key string, fallback int) int {
	if v, err := strconv.Atoi(env(key, "")); err == nil {
		return v
	}

	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v, err := time.ParseDuration(env(key, "")); err == nil {
		return v
	}

	return fallback
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "worker"
	}

	return h
}
