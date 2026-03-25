package main

import (
	"context"
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/cfapps/cf-service-broker/broker"
	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	"github.com/pivotal-cf/brokerapi/v11"
)

func main() {
	username := os.Getenv("BROKER_USERNAME")
	password := os.Getenv("BROKER_PASSWORD")
	namespace := os.Getenv("SERVICE_NAMESPACE")
	valkeyImage := os.Getenv("VALKEY_IMAGE")
	port := os.Getenv("PORT")
	garageAdminURL := os.Getenv("GARAGE_ADMIN_URL")
	garageAdminToken := os.Getenv("GARAGE_ADMIN_TOKEN")
	garageS3Endpoint := os.Getenv("GARAGE_S3_ENDPOINT")

	if username == "" {
		username = "admin"
	}
	if password == "" {
		password = "changeme"
	}
	if namespace == "" {
		namespace = "cf-services"
	}
	if valkeyImage == "" {
		valkeyImage = "valkey/valkey:8.1-alpine"
	}
	if port == "" {
		port = "8080"
	}
	if garageAdminURL == "" {
		garageAdminURL = "http://garage.garage.svc.cluster.local:3903"
	}
	if garageS3Endpoint == "" {
		garageS3Endpoint = "http://garage.garage.svc.cluster.local:3900"
	}

	client, err := k8sclient.NewClient()
	if err != nil {
		log.Fatalf("Failed to create K8s client: %v", err)
	}

	b := broker.New(client, namespace, valkeyImage, broker.GarageConfig{
		AdminURL:   garageAdminURL,
		AdminToken: garageAdminToken,
		S3Endpoint: garageS3Endpoint,
	})
	logger := slog.Default()

	credentials := brokerapi.BrokerCredentials{
		Username: username,
		Password: password,
	}

	brokerHandler := brokerapi.New(b, logger, credentials)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	})
	mux.Handle("/", brokerHandler)

	log.Printf("CF Service Broker starting on :%s", port)
	log.Printf("  Namespace: %s", namespace)
	log.Printf("  Valkey image: %s", valkeyImage)
	log.Printf("  Garage Admin: %s", garageAdminURL)

	_ = context.Background()
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
