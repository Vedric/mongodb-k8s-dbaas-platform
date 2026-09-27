package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// Keep the real client-go REST serialization and HTTP transport. Its synthetic
// Kubernetes boundary binds only loopback and never loads kubeconfig.
func isolatedKubernetes(t *testing.T) (dynamic.Interface, func() int) {
	t.Helper()
	var mutex sync.Mutex
	var claim map[string]interface{}
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mutex.Lock()
		defer mutex.Unlock()
		requests++
		collection := "/apis/dbaas.platform.local/v1alpha1/namespaces/synthetic-test/mongodbinstanceclaims"
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == collection:
			if err := json.NewDecoder(r.Body).Decode(&claim); err != nil {
				t.Error(err)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(claim)
		case r.Method == http.MethodGet && r.URL.Path == "/apis/dbaas.platform.local/v1alpha1/mongodbinstanceclaims":
			items := []interface{}{}
			if claim != nil {
				items = append(items, claim)
			}
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"apiVersion": "dbaas.platform.local/v1alpha1", "kind": "MongoDBInstanceClaimList", "items": items,
			})
		case r.Method == http.MethodGet && r.URL.Path == collection+"/synthetic-test" && claim != nil:
			_ = json.NewEncoder(w).Encode(claim)
		case r.Method == http.MethodDelete && r.URL.Path == collection+"/synthetic-test":
			claim = nil
			_ = json.NewEncoder(w).Encode(map[string]interface{}{"apiVersion": "v1", "kind": "Status", "status": "Success", "code": 200})
		default:
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{"apiVersion": "v1", "kind": "Status", "status": "Failure", "reason": "NotFound", "message": "synthetic claim not found", "code": 404})
		}
	}))
	t.Cleanup(server.Close)
	client, err := dynamic.NewForConfig(&rest.Config{Host: server.URL})
	if err != nil {
		t.Fatal(err)
	}
	return client, func() int { mutex.Lock(); defer mutex.Unlock(); return requests }
}

func TestClaimLifecycleWithIsolatedClient(t *testing.T) {
	client, requests := isolatedKubernetes(t)
	request := func(handler http.HandlerFunc, method, path, body string, status int) map[string]interface{} {
		t.Helper()
		response := httptest.NewRecorder()
		handler(response, httptest.NewRequest(method, path, strings.NewReader(body)))
		if response.Code != status {
			t.Fatalf("%s %s: status %d, want %d; response %s", method, path, response.Code, status, response.Body.String())
		}
		if response.Header().Get("Content-Type") != "application/json" {
			t.Fatal("handler response must be JSON")
		}
		var result map[string]interface{}
		if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}

	created := request(handleCreate(client), http.MethodPost, "/api/v1alpha1/instances",
		`{"teamName":"synthetic","environment":"test","size":"S","version":"8.0","backupEnabled":true,"monitoringEnabled":false}`, http.StatusCreated)
	metadata := created["metadata"].(map[string]interface{})
	if metadata["name"] != "synthetic-test" || metadata["namespace"] != "synthetic-test" {
		t.Fatalf("unexpected claim identity: %v", metadata)
	}
	parameters := created["spec"].(map[string]interface{})["parameters"].(map[string]interface{})
	if parameters["version"] != "8.0" || parameters["backupEnabled"] != true || parameters["monitoringEnabled"] != false {
		t.Fatalf("claim options did not survive JSON/Kubernetes conversion: %v", parameters)
	}
	request(handleGet(client), http.MethodGet, "/api/v1alpha1/instances/synthetic-test", "", http.StatusOK)
	listed := request(handleList(client), http.MethodGet, "/api/v1alpha1/instances?teamName=synthetic&environment=test", "", http.StatusOK)
	if listed["total"] != float64(1) {
		t.Fatalf("expected one matching claim: %v", listed)
	}
	filtered := request(handleList(client), http.MethodGet, "/api/v1alpha1/instances?teamName=another", "", http.StatusOK)
	if filtered["total"] != float64(0) {
		t.Fatalf("team filter returned another team's claim: %v", filtered)
	}
	request(handleDelete(client), http.MethodDelete, "/api/v1alpha1/instances/synthetic-test", "", http.StatusAccepted)
	request(handleGet(client), http.MethodGet, "/api/v1alpha1/instances/synthetic-test", "", http.StatusNotFound)
	if requests() != 6 {
		t.Fatalf("expected exactly six requests to the synthetic Kubernetes boundary, got %d", requests())
	}
}

func TestInvalidCreateNeverReachesKubernetes(t *testing.T) {
	for name, body := range map[string]string{"invalid JSON": "{", "missing fields": `{"teamName":"synthetic"}`} {
		t.Run(name, func(t *testing.T) {
			client, requests := isolatedKubernetes(t)
			response := httptest.NewRecorder()
			handleCreate(client)(response, httptest.NewRequest(http.MethodPost, "/api/v1alpha1/instances", strings.NewReader(body)))
			if response.Code != http.StatusBadRequest || requests() != 0 {
				t.Fatalf("invalid request escaped validation: status=%d requests=%d", response.Code, requests())
			}
		})
	}
}
