// Package main implements a lightweight HTTP gateway prototype for the
// MongoDB DBaaS self-service API. It translates REST requests into
// Crossplane MongoDBInstanceClaim resources via the Kubernetes API.
//
// This is a PROTOTYPE for demonstration purposes. Production deployments
// should add authentication, rate limiting, and input sanitization.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	claimGVR = schema.GroupVersionResource{
		Group:    "dbaas.platform.local",
		Version:  "v1alpha1",
		Resource: "mongodbinstanceclaims",
	}
	listenAddr = getEnv("LISTEN_ADDR", ":8081")
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func newDynamicClient() (dynamic.Interface, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		kubeconfig := os.Getenv("KUBECONFIG")
		if kubeconfig == "" {
			kubeconfig = os.Getenv("HOME") + "/.kube/config"
		}
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("failed to build kubeconfig: %w", err)
		}
	}
	return dynamic.NewForConfig(config)
}

// CreateRequest matches the OpenAPI CreateInstanceRequest schema.
type CreateRequest struct {
	TeamName          string `json:"teamName"`
	Environment       string `json:"environment"`
	Size              string `json:"size"`
	Version           string `json:"version,omitempty"`
	BackupEnabled     *bool  `json:"backupEnabled,omitempty"`
	MonitoringEnabled *bool  `json:"monitoringEnabled,omitempty"`
}

func claimName(teamName, env string) string {
	return fmt.Sprintf("%s-%s", teamName, env)
}

func handleList(client dynamic.Interface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		list, err := client.Resource(claimGVR).Namespace("").List(r.Context(), metav1.ListOptions{})
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}

		teamFilter := r.URL.Query().Get("teamName")
		envFilter := r.URL.Query().Get("environment")
		var items []map[string]interface{}
		for _, item := range list.Items {
			if teamFilter != "" || envFilter != "" {
				params, _, _ := unstructured.NestedMap(item.Object, "spec", "parameters")
				if teamFilter != "" && params["teamName"] != teamFilter {
					continue
				}
				if envFilter != "" && params["environment"] != envFilter {
					continue
				}
			}
			items = append(items, item.Object)
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"items": items, "total": len(items)})
	}
}

func handleCreate(client dynamic.Interface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req CreateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "invalid request body")
			return
		}
		if req.TeamName == "" || req.Environment == "" || req.Size == "" {
			writeError(w, http.StatusBadRequest, "teamName, environment, and size are required")
			return
		}
		if req.Version == "" {
			req.Version = "7.0"
		}

		name := claimName(req.TeamName, req.Environment)
		ns := name

		claim := &unstructured.Unstructured{
			Object: map[string]interface{}{
				"apiVersion": "dbaas.platform.local/v1alpha1",
				"kind":       "MongoDBInstanceClaim",
				"metadata": map[string]interface{}{
					"name":      name,
					"namespace": ns,
				},
				"spec": map[string]interface{}{
					"parameters": map[string]interface{}{
						"teamName":          req.TeamName,
						"environment":       req.Environment,
						"size":              req.Size,
						"version":           req.Version,
						"backupEnabled":     req.BackupEnabled,
						"monitoringEnabled": req.MonitoringEnabled,
					},
				},
			},
		}

		created, err := client.Resource(claimGVR).Namespace(ns).Create(r.Context(), claim, metav1.CreateOptions{})
		if err != nil {
			if strings.Contains(err.Error(), "already exists") {
				writeError(w, http.StatusConflict, "instance already exists")
				return
			}
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusCreated, created.Object)
	}
}

func handleGet(client dynamic.Interface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/api/v1alpha1/instances/")
		if name == "" {
			writeError(w, http.StatusBadRequest, "instance name required")
			return
		}

		item, err := client.Resource(claimGVR).Namespace(name).Get(r.Context(), name, metav1.GetOptions{})
		if err != nil {
			if strings.Contains(err.Error(), "not found") {
				writeError(w, http.StatusNotFound, "instance not found")
				return
			}
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, item.Object)
	}
}

func handleDelete(client dynamic.Interface) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/api/v1alpha1/instances/")
		if name == "" {
			writeError(w, http.StatusBadRequest, "instance name required")
			return
		}

		err := client.Resource(claimGVR).Namespace(name).Delete(r.Context(), name, metav1.DeleteOptions{})
		if err != nil {
			if strings.Contains(err.Error(), "not found") {
				writeError(w, http.StatusNotFound, "instance not found")
				return
			}
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]string{"message": "Instance deletion initiated"})
	}
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]interface{}{"code": code, "message": message})
}

func main() {
	client, err := newDynamicClient()
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1alpha1/instances", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			handleList(client)(w, r)
		case http.MethodPost:
			handleCreate(client)(w, r)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	})
	mux.HandleFunc("/api/v1alpha1/instances/", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			handleGet(client)(w, r)
		case http.MethodDelete:
			handleDelete(client)(w, r)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	srv := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("MongoDB DBaaS API gateway listening on %s", listenAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Shutting down server...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced shutdown: %v", err)
	}
	log.Println("Server stopped")
}
