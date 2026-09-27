package tenant

import (
	"context"
	"database/sql"
	"fmt"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"

	"worker-go/internal/config"
)

// Pool hands out one lazily-created *sql.DB per tenant schema, with an LRU bound.
//
// Connections terminate at the Cloud SQL Auth Proxy sidecar on localhost, and the
// proxy multiplexes them onto the instance. Keeping the pools separate (rather
// than one pool plus "USE <schema>") avoids a whole class of cross-tenant bleed
// when a pooled connection is reused.
//
// WHY THE LRU BOUND EXISTS
// The naive version kept a pool per tenant forever. At the stated scale that is
// 20 pods x 150 tenants x MaxOpenConns each - tens of thousands of connections
// against a Cloud SQL instance that allows a few thousand. Connection exhaustion
// would then hit every tenant at once, including the ones doing nothing wrong.
//
// So the number of *simultaneously open* schemas per pod is capped and the least
// recently used pool is closed when the cap is reached. Cost of a miss is one
// reconnect; cost of no cap is an outage.
type Pool struct {
	cfg     config.DBConfig
	maxOpen int
	onEvict func(schema string)
	nowFunc func() time.Time

	mu       sync.Mutex
	dbs      map[string]*entry
	openedTo int64
}

type entry struct {
	db       *sql.DB
	lastUsed time.Time
}

// NewPool creates an empty pool set. maxOpenSchemas of 0 or less disables the
// bound, which is only appropriate for single-tenant tests.
func NewPool(cfg config.DBConfig, maxOpenSchemas int) *Pool {
	return &Pool{
		cfg:     cfg,
		maxOpen: maxOpenSchemas,
		dbs:     make(map[string]*entry),
		nowFunc: time.Now,
	}
}

// For returns the connection pool for a tenant, opening it on first use.
func (p *Pool) For(ctx context.Context, t Tenant) (*sql.DB, error) {
	p.mu.Lock()

	if existing, ok := p.dbs[t.Database]; ok {
		existing.lastUsed = p.nowFunc()
		db := existing.db
		p.mu.Unlock()

		return db, nil
	}

	p.mu.Unlock()

	// Open outside the lock: a Ping against a slow Cloud SQL must not block every
	// other tenant's lookup.
	db, err := p.open(ctx, t)
	if err != nil {
		return nil, err
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Another goroutine may have won the race for this schema while we dialled.
	if existing, ok := p.dbs[t.Database]; ok {
		_ = db.Close()
		existing.lastUsed = p.nowFunc()

		return existing.db, nil
	}

	p.dbs[t.Database] = &entry{db: db, lastUsed: p.nowFunc()}
	p.openedTo++

	p.evictLocked()

	return db, nil
}

// evictLocked closes least-recently-used pools until the cap is respected.
// Caller must hold the lock.
func (p *Pool) evictLocked() {
	if p.maxOpen <= 0 || len(p.dbs) <= p.maxOpen {
		return
	}

	for len(p.dbs) > p.maxOpen {
		var (
			oldestSchema string
			oldestAt     time.Time
		)

		for schema, e := range p.dbs {
			if oldestSchema == "" || e.lastUsed.Before(oldestAt) {
				oldestSchema, oldestAt = schema, e.lastUsed
			}
		}

		if oldestSchema == "" {
			return
		}

		victim := p.dbs[oldestSchema]
		delete(p.dbs, oldestSchema)

		// Close asynchronously: sql.DB.Close waits for in-flight queries to
		// finish, and holding the pool lock through that would stall every tenant.
		go func(db *sql.DB) { _ = db.Close() }(victim.db)

		if p.onEvict != nil {
			p.onEvict(oldestSchema)
		}
	}
}

// OnEvict registers a callback, used to feed the eviction counter metric.
func (p *Pool) OnEvict(fn func(schema string)) {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.onEvict = fn
}

// Stats reports the current pool population, exposed as a gauge so the cap can be
// tuned from evidence rather than guesswork.
func (p *Pool) Stats() (open int, cap int, totalOpened int64) {
	p.mu.Lock()
	defer p.mu.Unlock()

	return len(p.dbs), p.maxOpen, p.openedTo
}

func (p *Pool) open(ctx context.Context, t Tenant) (*sql.DB, error) {
	if err := validateSchemaName(t.Database); err != nil {
		return nil, err
	}

	dsnCfg := mysql.NewConfig()
	dsnCfg.User = p.cfg.User
	dsnCfg.Passwd = p.cfg.Password
	dsnCfg.Net = "tcp"
	dsnCfg.Addr = fmt.Sprintf("%s:%d", p.cfg.Host, p.cfg.Port)
	dsnCfg.DBName = t.Database
	dsnCfg.Collation = "utf8mb4_unicode_ci"
	dsnCfg.ParseTime = true
	dsnCfg.AllowNativePasswords = true
	dsnCfg.Params = map[string]string{
		// Everything is stored and compared in UTC; the app tier does the same.
		"time_zone": "'+00:00'",
		"sql_mode":  "'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'",
	}

	db, err := sql.Open("mysql", dsnCfg.FormatDSN())
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", t.Database, err)
	}

	db.SetMaxOpenConns(p.cfg.MaxOpenConns)
	db.SetMaxIdleConns(p.cfg.MaxIdleConns)
	db.SetConnMaxLifetime(p.cfg.ConnMaxLifetime)
	db.SetConnMaxIdleTime(p.cfg.ConnMaxIdleTime)

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()

		return nil, fmt.Errorf("ping %s: %w", t.Database, err)
	}

	return db, nil
}

// Ping checks every already-open pool. Used by the readiness endpoint; it does not
// force-open pools for idle tenants.
func (p *Pool) Ping(ctx context.Context) error {
	p.mu.Lock()
	handles := make(map[string]*sql.DB, len(p.dbs))

	for schema, e := range p.dbs {
		handles[schema] = e.db
	}

	p.mu.Unlock()

	// Ping outside the lock so a hung connection cannot block For().
	for schema, db := range handles {
		if err := db.PingContext(ctx); err != nil {
			return fmt.Errorf("%s: %w", schema, err)
		}
	}

	return nil
}

// Close shuts every pool down. Called during graceful shutdown so in-flight
// transactions get a chance to finish first.
func (p *Pool) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	var firstErr error

	for schema, e := range p.dbs {
		if err := e.db.Close(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("close %s: %w", schema, err)
		}

		delete(p.dbs, schema)
	}

	return firstErr
}
