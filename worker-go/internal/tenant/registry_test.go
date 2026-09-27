package tenant

import (
	"strings"
	"testing"
)

func TestNewRegistryDefaults(t *testing.T) {
	registry, err := NewRegistry("", "tenant_")
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	all := registry.All()
	if len(all) != 3 {
		t.Fatalf("got %d tenants, want 3", len(all))
	}

	// All() is sorted so startup logs and test assertions are deterministic.
	if all[0].ID != "acme" || all[1].ID != "frdm" || all[2].ID != "whiteknight" {
		t.Errorf("tenants are not sorted by id: %v", []string{all[0].ID, all[1].ID, all[2].ID})
	}
}

func TestRegistryGet(t *testing.T) {
	registry, _ := NewRegistry("", "tenant_")

	tenant, err := registry.Get("acme")
	if err != nil {
		t.Fatalf("Get(acme): %v", err)
	}

	if tenant.Database != "tenant_acme" {
		t.Errorf("database = %q", tenant.Database)
	}

	// Case and whitespace are normalised, because tenant ids arrive from message
	// attributes and hostnames.
	if _, err := registry.Get("  ACME "); err != nil {
		t.Errorf("Get should normalise case and whitespace: %v", err)
	}

	if _, err := registry.Get("does-not-exist"); err == nil {
		t.Error("Get should fail for an unknown tenant")
	}
}

func TestNewRegistryDerivesSchemaFromPrefix(t *testing.T) {
	registry, err := NewRegistry(`{"newco": {"name": "New Co"}}`, "tenant_")
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}

	tenant, _ := registry.Get("newco")
	if tenant.Database != "tenant_newco" {
		t.Errorf("database = %q, want tenant_newco", tenant.Database)
	}
}

// The schema name is interpolated into a DSN, and MySQL cannot bind an identifier
// as a query parameter. Validation at registry-construction time means a bad name
// fails at pod startup rather than at the first query.
func TestNewRegistryRejectsUnsafeSchemaNames(t *testing.T) {
	tests := []struct {
		name string
		json string
	}{
		{"sql injection attempt", `{"evil": {"database": "tenant_a; DROP TABLE users"}}`},
		{"backtick escape", "{\"evil\": {\"database\": \"tenant_a`\"}}"},
		{"hyphen", `{"evil": {"database": "tenant-a"}}`},
		{"space", `{"evil": {"database": "tenant a"}}`},
		{"too long", `{"evil": {"database": "` + strings.Repeat("a", 65) + `"}}`},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewRegistry(tc.json, "tenant_"); err == nil {
				t.Errorf("NewRegistry accepted an unsafe schema name (%s)", tc.name)
			}
		})
	}
}

func TestNewRegistryRejectsBadInput(t *testing.T) {
	if _, err := NewRegistry(`{not json`, "tenant_"); err == nil {
		t.Error("NewRegistry should reject invalid JSON")
	}

	// An empty registry means every message would fail; better to refuse to start.
	if _, err := NewRegistry(`{}`, "tenant_"); err == nil {
		t.Error("NewRegistry should reject an empty registry")
	}
}
