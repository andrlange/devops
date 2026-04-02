package main

import (
	"log"
	"log/slog"
	"net/http"
	"os"

	"github.com/cfapps/cf-marketplace-broker/broker"
	k8sclient "github.com/cfapps/cf-marketplace-broker/k8s"
	"github.com/pivotal-cf/brokerapi/v11"
)

func main() {
	username := os.Getenv("BROKER_USERNAME")
	password := os.Getenv("BROKER_PASSWORD")
	namespace := os.Getenv("NAMESPACE")
	openbaoAddr := os.Getenv("OPENBAO_ADDR")
	openbaoToken := os.Getenv("OPENBAO_TOKEN")
	port := os.Getenv("PORT")

	if username == "" {
		username = "marketplace-broker"
	}
	if password == "" {
		password = "changeme"
	}
	if namespace == "" {
		namespace = "cf-services"
	}
	if openbaoAddr == "" {
		openbaoAddr = "http://openbao.openbao.svc.cluster.local:8200"
	}
	if openbaoToken == "" {
		log.Println("WARNING: OPENBAO_TOKEN not set — openbao-secrets service provisioning will fail")
	}
	if port == "" {
		port = "8081"
	}

	client, err := k8sclient.NewClient()
	if err != nil {
		log.Fatalf("Failed to create K8s client: %v", err)
	}

	b := broker.New(client, namespace, broker.OpenBaoConfig{
		Addr:  openbaoAddr,
		Token: openbaoToken,
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

	log.Printf("CF Marketplace Broker starting on :%s", port)
	log.Printf("  Namespace: %s", namespace)
	log.Printf("  OpenBao: %s", openbaoAddr)

	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
