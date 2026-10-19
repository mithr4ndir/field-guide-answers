// Drill 8 (distributed systems): watch writes through leader loss and quorum loss.
//
// Writes lab/counter = 1, 2, 3 ... every 250 ms through etcd's HTTP/JSON gateway
// (no client library needed) and prints one line per write: which node took it,
// how long it took, and the Raft term. Kill nodes while it runs (see LAB.md):
//
//	kill the leader   a short burst of slow or failed writes, then writes resume
//	                  under a new Raft term (usually one higher; a split vote adds more)
//	kill two nodes    every write fails: one node of three is not a majority.
//	                  Serializable reads still answer from local, possibly stale, data.
//	start one again   quorum is back and writes resume
//
// Usage: go run ./08-etcd-lab/go [-endpoints localhost:2379,localhost:22379,localhost:32379] [-count N]
//
// In real Go code you would use the official client, go.etcd.io/etcd/client/v3,
// which also handles failover and leader changes for you.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

const key = "lab/counter"

type responseHeader struct {
	// uint64 fields come through the JSON gateway as strings.
	Revision string `json:"revision"`
	RaftTerm string `json:"raft_term"`
}

type putResponse struct {
	Header responseHeader `json:"header"`
}

type rangeResponse struct {
	Kvs []struct {
		Value string `json:"value"`
	} `json:"kvs"`
}

type gatewayError struct {
	Message string `json:"message"`
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

// post sends one JSON request and decodes the reply into out.
func post(client *http.Client, endpoint, path string, body, out any) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	resp, err := client.Post("http://"+endpoint+path, "application/json", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		var ge gatewayError
		if json.NewDecoder(resp.Body).Decode(&ge) == nil && ge.Message != "" {
			return errors.New(ge.Message)
		}
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// reason turns a transport error into a short description.
func reason(err error) string {
	var netErr interface{ Timeout() bool }
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "timed out"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection refused"
	}
	return err.Error()
}

func stamp() string { return time.Now().Format("15:04:05.000") }

func main() {
	endpointList := flag.String("endpoints", "localhost:2379,localhost:22379,localhost:32379", "comma-separated etcd client endpoints")
	count := flag.Int("count", 0, "number of writes (0 = until Ctrl+C)")
	interval := flag.Duration("interval", 250*time.Millisecond, "time between writes")
	timeout := flag.Duration("timeout", time.Second, "per-request timeout")
	flag.Parse()
	endpoints := strings.Split(*endpointList, ",")
	client := &http.Client{Timeout: *timeout}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)

	for i := 1; *count == 0 || i <= *count; i++ {
		tick := time.Now()
		var failures []string
		written := false
		for _, ep := range endpoints { // fail over in order
			start := time.Now()
			var put putResponse
			err := post(client, ep, "/v3/kv/put", map[string]string{"key": b64(key), "value": b64(fmt.Sprint(i))}, &put)
			if err != nil {
				failures = append(failures, ep+" "+reason(err))
				continue
			}
			fmt.Printf("%s  put %s=%-4d OK    via %-15s %5.0f ms  term %s  rev %s\n",
				stamp(), key, i, ep, float64(time.Since(start).Microseconds())/1000, put.Header.RaftTerm, put.Header.Revision)
			written = true
			break
		}
		if !written {
			fmt.Printf("%s  put %s=%-4d FAIL  %s\n", stamp(), key, i, strings.Join(failures, "; "))
			// No quorum means no writes, but a serializable read is answered from local data.
			for _, ep := range endpoints {
				var rr rangeResponse
				if err := post(client, ep, "/v3/kv/range", map[string]any{"key": b64(key), "serializable": true}, &rr); err != nil {
					continue
				}
				value := "(none)"
				if len(rr.Kvs) > 0 {
					raw, _ := base64.StdEncoding.DecodeString(rr.Kvs[0].Value)
					value = string(raw)
				}
				fmt.Printf("%12s  serializable read from %s: %s=%s (may be stale)\n", "", ep, key, value)
				break
			}
		}
		select {
		case <-stop:
			return
		case <-time.After(*interval - time.Since(tick)):
		}
	}
}
