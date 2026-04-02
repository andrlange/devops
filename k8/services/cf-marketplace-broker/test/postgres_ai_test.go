package test

import (
	"database/sql"
	"fmt"
	"testing"
	"time"

	_ "github.com/lib/pq"
)

const (
	pgaiServiceID = "b1a2c3d4-e5f6-7890-abcd-100000000001"
	pgaiSmallPlan = "c2d3e4f5-a1b2-7890-abcd-100000000011"
)

func TestPostgresAILifecycle(t *testing.T) {
	instanceID := "test-pgai-01"
	bindingID := "bind-pgai-01"

	// 1. Provision
	status, err := osb.Provision(instanceID, ProvisionRequest{
		ServiceID:        pgaiServiceID,
		PlanID:           pgaiSmallPlan,
		OrganizationGUID: "test-org",
		SpaceGUID:        "test-space",
	})
	if err != nil {
		t.Fatalf("Provision failed: %v", err)
	}
	if status != 202 {
		t.Fatalf("Expected 202, got %d", status)
	}

	// 2. Wait for ready
	if err := osb.WaitForReady(instanceID, 180*time.Second); err != nil {
		t.Fatalf("WaitForReady failed: %v", err)
	}

	// 3. Bind
	bindResp, status, err := osb.Bind(instanceID, bindingID, BindRequest{
		ServiceID: pgaiServiceID,
		PlanID:    pgaiSmallPlan,
	})
	if err != nil {
		t.Fatalf("Bind failed: %v", err)
	}
	if status != 200 && status != 201 {
		t.Fatalf("Bind expected 200/201, got %d", status)
	}

	creds := bindResp.Credentials
	t.Logf("Credentials: type=%v, extensions=%v", creds["type"], creds["extensions"])

	if creds["type"] != "postgres-ai" {
		t.Errorf("Expected type postgres-ai, got %v", creds["type"])
	}

	uri, ok := creds["uri"].(string)
	if !ok || uri == "" {
		t.Fatalf("No URI in credentials")
	}

	db, err := sql.Open("postgres", uri)
	if err != nil {
		t.Fatalf("Failed to open DB: %v", err)
	}
	defer db.Close()

	rows, err := db.Query("SELECT extname FROM pg_extension ORDER BY extname")
	if err != nil {
		t.Fatalf("Failed to query extensions: %v", err)
	}
	defer rows.Close()

	extensions := map[string]bool{}
	for rows.Next() {
		var name string
		rows.Scan(&name)
		extensions[name] = true
	}

	required := []string{"vector", "pg_trgm", "postgis", "pgcrypto", "unaccent", "pg_stat_statements"}
	for _, ext := range required {
		if !extensions[ext] {
			t.Errorf("Extension %s not found", ext)
		}
	}

	_, err = db.Exec("CREATE TABLE test_vec (id serial PRIMARY KEY, embedding vector(3))")
	if err != nil {
		t.Fatalf("Failed to create vector table: %v", err)
	}
	_, err = db.Exec("INSERT INTO test_vec (embedding) VALUES ('[1,2,3]'), ('[4,5,6]')")
	if err != nil {
		t.Fatalf("Failed to insert vectors: %v", err)
	}
	var id int
	err = db.QueryRow("SELECT id FROM test_vec ORDER BY embedding <-> '[1,2,3]' LIMIT 1").Scan(&id)
	if err != nil {
		t.Fatalf("Similarity query failed: %v", err)
	}
	if id != 1 {
		t.Errorf("Expected nearest vector id=1, got %d", id)
	}
	db.Exec("DROP TABLE test_vec")
	t.Log("Vector operations verified")

	// 5. Unbind
	status, err = osb.Unbind(instanceID, bindingID, pgaiServiceID, pgaiSmallPlan)
	if err != nil {
		t.Fatalf("Unbind failed: %v", err)
	}

	// 6. Deprovision
	status, err = osb.Deprovision(instanceID, pgaiServiceID, pgaiSmallPlan)
	if err != nil {
		t.Fatalf("Deprovision failed: %v", err)
	}

	if err := osb.WaitForGone(instanceID, 60*time.Second); err != nil {
		t.Logf("Warning: WaitForGone: %v", err)
	}

	fmt.Println("PostgreSQL AI lifecycle test passed")
}
