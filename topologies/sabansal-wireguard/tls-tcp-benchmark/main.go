package main

import (
	"bufio"
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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type cpuSample struct {
	total uint64
	idle  uint64
}

type benchmarkResult struct {
	Protocol          string  `json:"protocol"`
	ParallelStreams   int     `json:"parallel_streams"`
	DurationSeconds   float64 `json:"duration_seconds"`
	BytesTransferred  uint64  `json:"bytes_transferred"`
	BitsPerSecond     float64 `json:"bits_per_second"`
	VMCPUPercent      float64 `json:"vm_cpu_percent"`
	TLSCipherSuite    string  `json:"tls_cipher_suite,omitempty"`
	RemoteEndpoint    string  `json:"remote_endpoint,omitempty"`
	MeasurementSource string  `json:"measurement_source"`
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

func generateCertificate(directory string) (tls.Certificate, error) {
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, err
	}

	now := time.Now()
	template := x509.Certificate{
		SerialNumber: big.NewInt(now.UnixNano()),
		Subject:      pkix.Name{CommonName: "tls-tcp-benchmark"},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return tls.Certificate{}, err
	}

	certificatePath := filepath.Join(directory, "certificate.pem")
	keyPath := filepath.Join(directory, "key.pem")
	if err := os.WriteFile(certificatePath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes}), 0600); err != nil {
		return tls.Certificate{}, err
	}
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(privateKey)}), 0600); err != nil {
		return tls.Certificate{}, err
	}

	return tls.LoadX509KeyPair(certificatePath, keyPath)
}

func prepareConnection(connection *tls.Conn) error {
	if err := connection.Handshake(); err != nil {
		return err
	}

	reader := bufio.NewReader(connection)
	command, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	if command != "READY\n" {
		return fmt.Errorf("unexpected readiness command %q", command)
	}
	if _, err := io.WriteString(connection, "READY\n"); err != nil {
		return err
	}

	command, err = reader.ReadString('\n')
	if err != nil {
		return err
	}
	if command != "GO\n" {
		return fmt.Errorf("unexpected start command %q", command)
	}
	return nil
}

func writeStream(connection *tls.Conn, deadline time.Time, bytesWritten *atomic.Uint64) error {
	defer connection.Close()
	if err := connection.SetWriteDeadline(deadline.Add(2 * time.Second)); err != nil {
		return err
	}
	if _, err := connection.Write([]byte{'D'}); err != nil {
		return err
	}

	buffer := make([]byte, 256*1024)
	for time.Now().Before(deadline) {
		written, err := connection.Write(buffer)
		if written > 0 {
			bytesWritten.Add(uint64(written))
		}
		if err != nil {
			if time.Now().After(deadline) {
				return nil
			}
			return err
		}
	}
	return nil
}

func runServer(listenAddress string, duration time.Duration, parallelStreams int, resultPath string) error {
	tempDirectory, err := os.MkdirTemp("", "tls-tcp-benchmark-certificate-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tempDirectory)

	certificate, err := generateCertificate(tempDirectory)
	if err != nil {
		return err
	}

	listener, err := tls.Listen("tcp", listenAddress, &tls.Config{
		Certificates: []tls.Certificate{certificate},
		MinVersion:   tls.VersionTLS13,
		MaxVersion:   tls.VersionTLS13,
	})
	if err != nil {
		return err
	}
	defer listener.Close()
	log.Printf("TLS 1.3 TCP benchmark server listening on %s", listenAddress)

	type preparedConnection struct {
		connection *tls.Conn
		err        error
	}
	prepared := make(chan preparedConnection, parallelStreams)
	for range parallelStreams {
		connection, err := listener.Accept()
		if err != nil {
			return err
		}
		tlsConnection := connection.(*tls.Conn)
		go func() {
			prepared <- preparedConnection{
				connection: tlsConnection,
				err:        prepareConnection(tlsConnection),
			}
		}()
	}

	connections := make([]*tls.Conn, 0, parallelStreams)
	for range parallelStreams {
		item := <-prepared
		if item.err != nil {
			item.connection.Close()
			return item.err
		}
		connections = append(connections, item.connection)
	}

	startCPU, err := readCPUSample()
	if err != nil {
		return err
	}
	startTime := time.Now()
	deadline := startTime.Add(duration)
	var bytesWritten atomic.Uint64
	var firstError error
	var errorMutex sync.Mutex
	var waitGroup sync.WaitGroup
	for _, connection := range connections {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			if err := writeStream(connection, deadline, &bytesWritten); err != nil {
				errorMutex.Lock()
				if firstError == nil {
					firstError = err
				}
				errorMutex.Unlock()
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

	transferred := bytesWritten.Load()
	result := benchmarkResult{
		Protocol:          "TLS 1.3/TCP",
		ParallelStreams:   parallelStreams,
		DurationSeconds:   elapsed.Seconds(),
		BytesTransferred:  transferred,
		BitsPerSecond:     float64(transferred) * 8 / elapsed.Seconds(),
		VMCPUPercent:      cpuPercent(startCPU, endCPU),
		MeasurementSource: "server",
	}
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	return os.WriteFile(resultPath, data, 0644)
}

func runClient(serverAddress string, duration time.Duration, parallelStreams int) error {
	tlsConfig := &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
	}

	connections := make([]*tls.Conn, 0, parallelStreams)
	for range parallelStreams {
		connection, err := tls.Dial("tcp", serverAddress, tlsConfig)
		if err != nil {
			return err
		}
		if _, err := io.WriteString(connection, "READY\n"); err != nil {
			connection.Close()
			return err
		}
		response, err := bufio.NewReader(connection).ReadString('\n')
		if err != nil {
			connection.Close()
			return err
		}
		if response != "READY\n" {
			connection.Close()
			return fmt.Errorf("unexpected readiness response %q", response)
		}
		connections = append(connections, connection)
	}
	defer func() {
		for _, connection := range connections {
			connection.Close()
		}
	}()

	startCPU, err := readCPUSample()
	if err != nil {
		return err
	}
	startTime := time.Now()
	for _, connection := range connections {
		if err := connection.SetReadDeadline(startTime.Add(duration + 10*time.Second)); err != nil {
			return err
		}
		if _, err := io.WriteString(connection, "GO\n"); err != nil {
			return err
		}
	}

	var bytesRead atomic.Uint64
	var firstError error
	var cipherSuite string
	var errorMutex sync.Mutex
	var waitGroup sync.WaitGroup
	for _, connection := range connections {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			marker := make([]byte, 1)
			if _, err := io.ReadFull(connection, marker); err != nil {
				errorMutex.Lock()
				if firstError == nil {
					firstError = err
				}
				errorMutex.Unlock()
				return
			}
			if marker[0] != 'D' {
				errorMutex.Lock()
				if firstError == nil {
					firstError = fmt.Errorf("unexpected data marker %q", marker[0])
				}
				errorMutex.Unlock()
				return
			}

			errorMutex.Lock()
			if cipherSuite == "" {
				cipherSuite = tls.CipherSuiteName(connection.ConnectionState().CipherSuite)
			}
			errorMutex.Unlock()

			buffer := make([]byte, 256*1024)
			for {
				read, err := connection.Read(buffer)
				if read > 0 {
					bytesRead.Add(uint64(read))
				}
				if err != nil {
					if !errors.Is(err, io.EOF) {
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

	transferred := bytesRead.Load()
	result := benchmarkResult{
		Protocol:          "TLS 1.3/TCP",
		ParallelStreams:   parallelStreams,
		DurationSeconds:   elapsed.Seconds(),
		BytesTransferred:  transferred,
		BitsPerSecond:     float64(transferred) * 8 / elapsed.Seconds(),
		VMCPUPercent:      cpuPercent(startCPU, endCPU),
		TLSCipherSuite:    cipherSuite,
		RemoteEndpoint:    serverAddress,
		MeasurementSource: "client",
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}

func main() {
	mode := flag.String("mode", "", "server or client")
	listenAddress := flag.String("listen", "0.0.0.0:4434", "server listen address")
	serverAddress := flag.String("server", "", "client target address")
	duration := flag.Duration("duration", 30*time.Second, "benchmark duration")
	parallelStreams := flag.Int("parallel", 8, "number of parallel TLS/TCP streams")
	resultPath := flag.String("result", "/tmp/tls-tcp-benchmark-result.json", "server result file")
	flag.Parse()

	if *parallelStreams < 1 {
		log.Fatal("-parallel must be at least 1")
	}

	var err error
	switch *mode {
	case "server":
		err = runServer(*listenAddress, *duration, *parallelStreams, *resultPath)
	case "client":
		if *serverAddress == "" {
			err = errors.New("-server is required in client mode")
		} else {
			err = runClient(*serverAddress, *duration, *parallelStreams)
		}
	default:
		err = errors.New("-mode must be server or client")
	}
	if err != nil {
		log.Fatal(err)
	}
}
