// Package tenant resolves a tenant id to its Cloud SQL schema and hands out
// per-tenant connection pools.
package tenant

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Tenant is one row of the registry.
type Tenant struct {
	ID       string `json:"-"`
	Name     string `json:"name"`
	Database string `json:"database"`
	Domain   string `json:"domain,omitempty"`
}

// Registry is the worker's own view of which tenants exist. Deliberately not
// taken from the incoming message: an event only supplies a tenant id, and the
// schema name is looked up here. That way a malformed or malicious event cannot
// redirect writes into another tenant's schema.
type Registry struct {
	tenants map[string]Tenant
}

// DefaultTenantsJSON mirrors config/tenancy.php in the Laravel app. Override in
// both places (or point both at TENANTS_JSON) when onboarding a tenant.
const DefaultTenantsJSON = `{
  "acme":        {"name": "Acme Corp",    "database": "tenant_acme",        "domain": "acme.sequifi.com"},
  "whiteknight": {"name": "White Knight", "database": "tenant_whiteknight", "domain": "whiteknight.sequifi.com"},
  "frdm":        {"name": "FRDM",         "database": "tenant_frdm",        "domain": "frdm.sequifi.com"}
}`

// NewRegistry builds a registry from a JSON document. An empty document falls
// back to DefaultTenantsJSON.
func NewRegistry(tenantsJSON, schemaPrefix string) (*Registry, error) {
	if strings.TrimSpace(tenantsJSON) == "" {
		tenantsJSON = DefaultTenantsJSON
	}

	raw := map[string]Tenant{}
	if err := json.Unmarshal([]byte(tenantsJSON), &raw); err != nil {
		return nil, fmt.Errorf("invalid TENANTS_JSON: %w", err)
	}

	if len(raw) == 0 {
		return nil, fmt.Errorf("tenant registry is empty")
	}

	tenants := make(map[string]Tenant, len(raw))

	for id, t := range raw {
		t.ID = id

		if t.Database == "" {
			t.Database = schemaPrefix + id
		}

		if err := validateSchemaName(t.Database); err != nil {
			return nil, fmt.Errorf("tenant %q: %w", id, err)
		}

		tenants[id] = t
	}

	return &Registry{tenants: tenants}, nil
}

// Get resolves a tenant id.
func (r *Registry) Get(id string) (Tenant, error) {
	t, ok := r.tenants[strings.ToLower(strings.TrimSpace(id))]
	if !ok {
		return Tenant{}, fmt.Errorf("unknown tenant %q", id)
	}

	return t, nil
}

// All returns the tenants sorted by id, for deterministic startup logs.
func (r *Registry) All() []Tenant {
	out := make([]Tenant, 0, len(r.tenants))
	for _, t := range r.tenants {
		out = append(out, t)
	}

	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })

	return out
}

// validateSchemaName keeps the identifier safe to interpolate into a DSN and
// into "USE"-style statements, since MySQL schema names cannot be bound as
// query parameters.
func validateSchemaName(name string) error {
	if name == "" {
		return fmt.Errorf("empty schema name")
	}

	if len(name) > 64 {
		return fmt.Errorf("schema name %q is longer than 64 characters", name)
	}

	for _, r := range name {
		isSafe := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_'
		if !isSafe {
			return fmt.Errorf("schema name %q contains an unsupported character %q", name, r)
		}
	}

	return nil
}
