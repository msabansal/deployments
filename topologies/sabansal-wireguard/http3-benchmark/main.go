package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go/http3"
)

type cpuSample struct {
	total uint64
	idle  uint64
}

type serverMetrics struct {
	mu        sync.Mutex
	startCPU  cpuSample
	startTime time.Time
	bytes     atomic.Uint64
}

type serverResult struct {
	Bytes            uint64  `json:"bytes"`
	Seconds          float64 `json:"seconds"`
	VMCPUPercent     float64 `json:"vm_cpu_percent"`
	BitsPerSecond    float64 `json:"bits_per_second"`
	MeasurementReady bool    `json:"measurement_ready"`
}

type benchmarkResult struct {
	Protocol              string  `json:"protocol"`
	Target                string  `json:"target"`
	ParallelRequests      int     `json:"parallel_requests"`
	DurationSeconds       float64 `json:"duration_seconds"`
	BytesReceived         uint64  `json:"bytes_received"`
	BitsPerSecondReceived float64 `json:"bits_per_second_received"`
	ClientVMCPUPercent    float64 `json:"client_vm_cpu_percent"`
	ServerVMCPUPercent    float64 `json:"server_vm_cpu_percent"`
	ServerBytesSent       uint64  `json:"server_bytes_sent"`
	ServerBitsPerSecond   float64 `json:"server_bits_per_second"`
}

type zeroReader struct{}

func (zeroReader) Read(buffer []byte) (int, error) {
	clear(buffer)
	return len(buffer), nil
}

func readCPUSample() (cpuSample, error) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return cpuSample{}, err
	}

	line, _, found := strings.Cut(string(data), "\n")
	if !found {
		return cpuSample{}, errors.New("could not read the aggregate CPU line from /proc/stat")
	}

	fields := strings.Fields(line)
	if len(fields) < 9 || fields[0] != "cpu" {
		return cpuSample{}, fmt.Errorf("unexpected aggregate CPU line: %q", line)
	}

	values := make([]uint64, 0, len(fields)-1)
	for _, field := range fields[1:] {
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			return cpuSample{}, fmt.Errorf("parse /proc/stat value %q: %w", field, err)
		}
		values = append(values, value)
	}

	var total uint64
	for _, value := range values {
		total += value
	}

	return cpuSample{
		total: total,
		idle:  values[3] + values[4],
	}, nil
}

func cpuPercent(start, end cpuSample) float64 {
	totalDelta := end.total - start.total
	idleDelta := end.idle - start.idle
	if totalDelta == 0 || idleDelta > totalDelta {
		return 0
	}
	return 100 * float64(totalDelta-idleDelta) / float64(totalDelta)
}

func generateCertificate(directory string) (string, string, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return "", "", err
	}

	now := time.Now()
	template := x509.Certificate{
		SerialNumber: big.NewInt(now.UnixNano()),
		Subject:      pkix.Name{CommonName: "http3-benchmark"},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  nil,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return "", "", err
	}

	certificatePath := filepath.Join(directory, "certificate.pem")
	keyPath := filepath.Join(directory, "key.pem")
	certificateFile, err := os.OpenFile(certificatePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return "", "", err
	}
	if err := pem.Encode(certificateFile, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}); err != nil {
		certificateFile.Close()
		return "", "", err
	}
	if err := certificateFile.Close(); err != nil {
		return "", "", err
	}

	keyFile, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return "", "", err
	}
	if err := pem.Encode(keyFile, &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(privateKey)}); err != nil {
		keyFile.Close()
		return "", "", err
	}
	if err := keyFile.Close(); err != nil {
		return "", "", err
	}

	return certificatePath, keyPath, nil
}

func runServer(listenAddress string) error {
	tempDirectory, err := os.MkdirTemp("", "http3-benchmark-certificate-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDirectory)

	certificatePath, keyPath, err := generateCertificate(tempDirectory)
	if err != nil {
		return err
	}

	metrics := &serverMetrics{}
	mux := http.NewServeMux()
	mux.HandleFunc("/reset", func(response http.ResponseWriter, _ *http.Request) {
		sample, err := readCPUSample()
		if err != nil {
			http.Error(response, err.Error(), http.StatusInternalServerError)
			return
		}

		metrics.mu.Lock()
		metrics.startCPU = sample
		metrics.startTime = time.Now()
		metrics.bytes.Store(0)
		metrics.mu.Unlock()
		response.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/download", func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("Content-Type", "application/octet-stream")
		buffer := make([]byte, 256*1024)
		for {
			written, err := io.CopyBuffer(response, io.LimitReader(zeroReader{}, int64(len(buffer))), buffer)
			if written > 0 {
				metrics.bytes.Add(uint64(written))
			}
			if err != nil || request.Context().Err() != nil {
				return
			}
		}
	})
	mux.HandleFunc("/result", func(response http.ResponseWriter, _ *http.Request) {
		endCPU, err := readCPUSample()
		if err != nil {
			http.Error(response, err.Error(), http.StatusInternalServerError)
			return
		}

		metrics.mu.Lock()
		startCPU := metrics.startCPU
		startTime := metrics.startTime
		metrics.mu.Unlock()

		seconds := time.Since(startTime).Seconds()
		bytesSent := metrics.bytes.Load()
		result := serverResult{
			Bytes:            bytesSent,
			Seconds:          seconds,
			VMCPUPercent:     cpuPercent(startCPU, endCPU),
			MeasurementReady: !startTime.IsZero(),
		}
		if seconds > 0 {
			result.BitsPerSecond = float64(bytesSent) * 8 / seconds
		}

		response.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(response).Encode(result); err != nil {
			log.Printf("encode result: %v", err)
		}
	})

	server := http3.Server{
		Addr:    listenAddress,
		Handler: mux,
	}
	log.Printf("HTTP/3 benchmark server listening on %s/udp", listenAddress)
	return server.ListenAndServeTLS(certificatePath, keyPath)
}

func request(client *http.Client, method, url string, contextValue context.Context) (*http.Response, error) {
	request, err := http.NewRequestWithContext(contextValue, method, url, nil)
	if err != nil {
		return nil, err
	}
	return client.Do(request)
}

func runClient(baseURL string, duration time.Duration, parallelRequests int) error {
	transport := &http3.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
			NextProtos:         []string{http3.NextProtoH3},
		},
	}
	defer transport.Close()
	client := &http.Client{Transport: transport}

	resetResponse, err := request(client, http.MethodPost, baseURL+"/reset", context.Background())
	if err != nil {
		return fmt.Errorf("reset server metrics: %w", err)
	}
	resetResponse.Body.Close()
	if resetResponse.StatusCode != http.StatusNoContent {
		return fmt.Errorf("reset server metrics: %s", resetResponse.Status)
	}

	startCPU, err := readCPUSample()
	if err != nil {
		return err
	}
	startTime := time.Now()
	benchmarkContext, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var bytesReceived atomic.Uint64
	var firstError error
	var errorMutex sync.Mutex
	var waitGroup sync.WaitGroup
	for range parallelRequests {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			response, err := request(client, http.MethodGet, baseURL+"/download", benchmarkContext)
			if err != nil {
				if benchmarkContext.Err() == nil {
					errorMutex.Lock()
					if firstError == nil {
						firstError = err
					}
					errorMutex.Unlock()
				}
				return
			}
			defer response.Body.Close()
			if response.StatusCode != http.StatusOK {
				errorMutex.Lock()
				if firstError == nil {
					firstError = fmt.Errorf("download: %s", response.Status)
				}
				errorMutex.Unlock()
				return
			}

			buffer := make([]byte, 256*1024)
			for {
				read, err := response.Body.Read(buffer)
				if read > 0 {
					bytesReceived.Add(uint64(read))
				}
				if err != nil {
					if !errors.Is(err, io.EOF) && benchmarkContext.Err() == nil {
						errorMutex.Lock()
						if firstError == nil {
							firstError = err
						}
						errorMutex.Unlock()
					}
					return
				}
			}
		}()
	}
	waitGroup.Wait()
	elapsed := time.Since(startTime)
	endCPU, err := readCPUSample()
	if err != nil {
		return err
	}
	if firstError != nil {
		return firstError
	}

	resultResponse, err := request(client, http.MethodGet, baseURL+"/result", context.Background())
	if err != nil {
		return fmt.Errorf("read server metrics: %w", err)
	}
	defer resultResponse.Body.Close()
	if resultResponse.StatusCode != http.StatusOK {
		return fmt.Errorf("read server metrics: %s", resultResponse.Status)
	}

	var serverMetrics serverResult
	if err := json.NewDecoder(resultResponse.Body).Decode(&serverMetrics); err != nil {
		return fmt.Errorf("decode server metrics: %w", err)
	}
	if !serverMetrics.MeasurementReady {
		return errors.New("server CPU measurement was not initialized")
	}

	received := bytesReceived.Load()
	result := benchmarkResult{
		Protocol:              "HTTP/3",
		Target:                baseURL,
		ParallelRequests:      parallelRequests,
		DurationSeconds:       elapsed.Seconds(),
		BytesReceived:         received,
		BitsPerSecondReceived: float64(received) * 8 / elapsed.Seconds(),
		ClientVMCPUPercent:    cpuPercent(startCPU, endCPU),
		ServerVMCPUPercent:    serverMetrics.VMCPUPercent,
		ServerBytesSent:       serverMetrics.Bytes,
		ServerBitsPerSecond:   serverMetrics.BitsPerSecond,
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func main() {
	mode := flag.String("mode", "", "server or client")
	listenAddress := flag.String("listen", "0.0.0.0:4433", "server listen address")
	baseURL := flag.String("url", "", "HTTP/3 server base URL")
	duration := flag.Duration("duration", 30*time.Second, "client benchmark duration")
	parallelRequests := flag.Int("parallel", 8, "number of concurrent HTTP/3 requests")
	flag.Parse()

	var err error
	switch *mode {
	case "server":
		err = runServer(*listenAddress)
	case "client":
		if *baseURL == "" {
			err = errors.New("-url is required in client mode")
		} else if *parallelRequests < 1 {
			err = errors.New("-parallel must be at least 1")
		} else {
			err = runClient(strings.TrimRight(*baseURL, "/"), *duration, *parallelRequests)
		}
	default:
		err = errors.New("-mode must be server or client")
	}
	if err != nil {
		log.Fatal(err)
	}
}
