package test

import (
	"os"
	"testing"
)

var osb *OSBClient

func TestMain(m *testing.M) {
	brokerURL := os.Getenv("BROKER_URL")
	if brokerURL == "" {
		brokerURL = "http://cf-marketplace-broker.cf-services.svc:80"
	}
	username := os.Getenv("BROKER_USER")
	if username == "" {
		username = "marketplace-broker"
	}
	password := os.Getenv("BROKER_PASSWORD")
	if password == "" {
		password = "changeme"
	}

	osb = NewOSBClient(brokerURL, username, password)
	os.Exit(m.Run())
}
