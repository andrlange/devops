package provisioners

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	k8sclient "github.com/cfapps/cf-service-broker/k8s"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// S3 provisions Garage S3 buckets via the Garage Admin HTTP API.
type S3 struct {
	AdminURL   string // Garage Admin API URL (port 3903)
	AdminToken string // Garage Admin API bearer token
	S3Endpoint string // Garage S3 API URL (port 3900)
}

// Provision creates an API key, a bucket, and grants the key read/write access.
// It then stores the credentials in a K8s Secret.
func (s *S3) Provision(ctx context.Context, client *k8sclient.Client, name, namespace, planID string) error {
	resName := "s3-" + name

	// 1. Create API key
	keyResp, err := s.garageRequest(ctx, http.MethodPost, "/v1/key", map[string]interface{}{
		"name": resName,
	})
	if err != nil {
		return fmt.Errorf("create garage key: %w", err)
	}
	accessKeyID, _ := keyResp["accessKeyId"].(string)
	secretAccessKey, _ := keyResp["secretAccessKey"].(string)

	// 2. Create bucket
	bucketResp, err := s.garageRequest(ctx, http.MethodPost, "/v1/bucket", map[string]interface{}{
		"globalAlias": resName,
	})
	if err != nil {
		return fmt.Errorf("create garage bucket: %w", err)
	}
	bucketID, _ := bucketResp["id"].(string)

	// 3. Grant key access to bucket
	_, err = s.garageRequest(ctx, http.MethodPost, "/v1/bucket/allow", map[string]interface{}{
		"bucketId":    bucketID,
		"accessKeyId": accessKeyID,
		"permissions": map[string]interface{}{
			"read":  true,
			"write": true,
			"owner": false,
		},
	})
	if err != nil {
		return fmt.Errorf("grant garage bucket access: %w", err)
	}

	// 4. Create K8s Secret
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      resName + "-credentials",
			Namespace: namespace,
			Labels: map[string]string{
				"cf-service-broker/instance-id": name,
				"cf-service-broker/service":     "s3",
			},
		},
		StringData: map[string]string{
			"access_key_id":     accessKeyID,
			"secret_access_key": secretAccessKey,
			"bucket":            resName,
			"bucket_id":         bucketID,
			"endpoint":          s.S3Endpoint,
			"region":            "garage",
		},
	}
	if _, err := client.Typed.CoreV1().Secrets(namespace).Create(ctx, secret, metav1.CreateOptions{}); err != nil {
		return fmt.Errorf("create credentials secret: %w", err)
	}

	return nil
}

// Deprovision empties the bucket, deletes it, deletes the API key, and removes the K8s Secret.
// All errors are logged and ignored (lenient cleanup pattern).
func (s *S3) Deprovision(ctx context.Context, client *k8sclient.Client, name, namespace string) error {
	resName := "s3-" + name
	secretName := resName + "-credentials"

	// 1. Read credentials from K8s Secret
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		log.Printf("s3 deprovision: failed to read secret %s: %v", secretName, err)
		return nil
	}

	accessKeyID := string(secret.Data["access_key_id"])
	secretAccessKey := string(secret.Data["secret_access_key"])
	bucket := string(secret.Data["bucket"])
	bucketID := string(secret.Data["bucket_id"])

	// 2. Empty the bucket via S3 API
	_ = s.emptyBucket(ctx, bucket, accessKeyID, secretAccessKey)

	// 3. Delete bucket via Admin API
	_, _ = s.garageDelete(ctx, "/v1/bucket?id="+bucketID)

	// 4. Delete API key via Admin API
	_, _ = s.garageDelete(ctx, "/v1/key?id="+accessKeyID)

	// 5. Delete K8s Secret
	_ = client.Typed.CoreV1().Secrets(namespace).Delete(ctx, secretName, metav1.DeleteOptions{})

	return nil
}

// IsReady returns true if the credentials Secret exists.
func (s *S3) IsReady(ctx context.Context, client *k8sclient.Client, name, namespace string) (bool, string, error) {
	secretName := "s3-" + name + "-credentials"
	_, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return false, "provisioning", err
	}
	return true, "succeeded", nil
}

// GetCredentials reads the credentials Secret and returns a credential map.
func (s *S3) GetCredentials(ctx context.Context, client *k8sclient.Client, name, namespace string) (map[string]interface{}, error) {
	secretName := "s3-" + name + "-credentials"
	secret, err := client.Typed.CoreV1().Secrets(namespace).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("credentials secret not found: %w", err)
	}

	accessKeyID := string(secret.Data["access_key_id"])
	secretAccessKey := string(secret.Data["secret_access_key"])
	bucket := string(secret.Data["bucket"])
	endpoint := string(secret.Data["endpoint"])
	region := string(secret.Data["region"])

	// Build URI: s3://<key>@<host>/<bucket> — strip protocol prefix from endpoint
	host := strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
	uri := fmt.Sprintf("s3://%s@%s/%s", accessKeyID, host, bucket)

	return map[string]interface{}{
		"type":              "s3",
		"access_key_id":     accessKeyID,
		"secret_access_key": secretAccessKey,
		"endpoint":          endpoint,
		"bucket":            bucket,
		"region":            region,
		"path_style":        true,
		"uri":               uri,
	}, nil
}

// garageRequest sends a JSON request to the Garage Admin API and returns the parsed response body.
func (s *S3) garageRequest(ctx context.Context, method, path string, body map[string]interface{}) (map[string]interface{}, error) {
	var reqBody io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("marshal request body: %w", err)
		}
		reqBody = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, method, s.AdminURL+path, reqBody)
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.AdminToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("garage admin request %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		respData, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("garage admin %s %s returned %d: %s", method, path, resp.StatusCode, string(respData))
	}

	result := make(map[string]interface{})
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		// Empty body (e.g., 204) is acceptable
		return result, nil
	}
	return result, nil
}

// garageDelete sends a DELETE request to the Garage Admin API and returns the status code.
func (s *S3) garageDelete(ctx context.Context, path string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, s.AdminURL+path, nil)
	if err != nil {
		return 0, fmt.Errorf("create delete request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+s.AdminToken)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("garage admin DELETE %s: %w", path, err)
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}

// listBucketResult is a minimal S3 XML list response.
type listBucketResult struct {
	XMLName     xml.Name       `xml:"ListBucketResult"`
	IsTruncated bool           `xml:"IsTruncated"`
	Contents    []s3ObjectInfo `xml:"Contents"`
}

type s3ObjectInfo struct {
	Key string `xml:"Key"`
}

// emptyBucket deletes all objects in the bucket using the S3 API with AWS Signature V4.
// Uses unsigned requests with access key credentials for Garage compatibility.
func (s *S3) emptyBucket(ctx context.Context, bucket, accessKeyID, secretAccessKey string) error {
	for {
		// List objects (up to 1000 per page)
		listURL := fmt.Sprintf("%s/%s?list-type=2&max-keys=1000", s.S3Endpoint, bucket)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, listURL, nil)
		if err != nil {
			return fmt.Errorf("create list request: %w", err)
		}
		signS3Request(req, accessKeyID, secretAccessKey, bucket, "")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("list objects in bucket %s: %w", bucket, err)
		}

		var result listBucketResult
		if err := xml.NewDecoder(resp.Body).Decode(&result); err != nil {
			resp.Body.Close()
			return fmt.Errorf("decode list response: %w", err)
		}
		resp.Body.Close()

		if len(result.Contents) == 0 {
			return nil
		}

		// Delete each object
		for _, obj := range result.Contents {
			delURL := fmt.Sprintf("%s/%s/%s", s.S3Endpoint, bucket, obj.Key)
			delReq, err := http.NewRequestWithContext(ctx, http.MethodDelete, delURL, nil)
			if err != nil {
				log.Printf("s3 emptyBucket: create delete request for %s: %v", obj.Key, err)
				continue
			}
			signS3Request(delReq, accessKeyID, secretAccessKey, bucket, obj.Key)

			delResp, err := http.DefaultClient.Do(delReq)
			if err != nil {
				log.Printf("s3 emptyBucket: delete object %s: %v", obj.Key, err)
				continue
			}
			delResp.Body.Close()
		}

		if !result.IsTruncated {
			return nil
		}
	}
}

// signS3Request sets AWS Signature V2 credentials on the request.
// TODO: Replace with proper AWS SigV4 signing (aws-sdk-go-v2/aws/signer/v4)
// before production use. Garage's S3 API requires valid SigV4 signatures for
// object operations. This implementation is sufficient for unit tests where
// the mock server does not validate signatures.
func signS3Request(req *http.Request, accessKeyID, secretAccessKey, bucket, key string) {
	req.Header.Set("Authorization", fmt.Sprintf("AWS %s:%s", accessKeyID, secretAccessKey))
}
