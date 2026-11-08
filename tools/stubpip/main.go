// Command stubpip is a local PIP contract stub used to exercise replica-lag
// enforcement (stale_attributes / lag_unknown) without changing the reference
// PIP. It is test infrastructure, not a production PIP: attributes come from a
// fixture and the reported lag comes from a small state file that the test
// rewrites between requests.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"strings"
)

const apiVersion = "1.0"

type fixtures struct {
	Resources       map[string]map[string]map[string]any `json:"resources"`
	Classifications map[string]map[string]string         `json:"classifications"`
}

type lagState struct {
	LagSeconds int  `json:"lagSeconds"`
	LagKnown   bool `json:"lagKnown"`
}

type ref struct {
	Type   string   `json:"type"`
	ID     string   `json:"id"`
	Fields []string `json:"fields,omitempty"`
}

type batchRequest struct {
	Requests []ref `json:"requests"`
}

type attribute struct {
	Type       string         `json:"type"`
	ID         string         `json:"id"`
	Found      bool           `json:"found"`
	Attributes map[string]any `json:"attributes"`
	Version    string         `json:"version"`
	TTLSeconds int            `json:"ttlSeconds"`
	LagSeconds int            `json:"lagSeconds"`
	LagKnown   bool           `json:"lagKnown"`
}

type batchResponse struct {
	Results []attribute `json:"results"`
}

type classificationResponse struct {
	ResourceType string            `json:"resourceType"`
	Fields       map[string]string `json:"fields"`
	TTLSeconds   int               `json:"ttlSeconds"`
}

func main() {
	addr := flag.String("addr", ":8082", "listen address")
	fixturePath := flag.String("fixtures", "/etc/controls/attributes.json", "PIP fixture file")
	statePath := flag.String("state", "", "optional JSON state file with lagSeconds/lagKnown")
	defaultLag := flag.Int("lag", 2, "default lagSeconds when the state file is absent")
	defaultKnown := flag.Bool("lag-known", true, "default lagKnown when the state file is absent")
	flag.Parse()

	raw, err := os.ReadFile(*fixturePath)
	if err != nil {
		log.Fatalf("read fixtures: %v", err)
	}
	var fx fixtures
	if err := json.Unmarshal(raw, &fx); err != nil {
		log.Fatalf("parse fixtures: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"apiVersion": apiVersion, "build": "stub"})
	})
	mux.HandleFunc("POST /v1/attributes:batch", func(w http.ResponseWriter, r *http.Request) {
		var req batchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid_json"}`, http.StatusBadRequest)
			return
		}
		st := loadState(*statePath, lagState{LagSeconds: *defaultLag, LagKnown: *defaultKnown})
		out := make([]attribute, 0, len(req.Requests))
		for _, request := range req.Requests {
			attrs, found := lookup(fx, request.Type, request.ID, request.Fields)
			out = append(out, attribute{
				Type:       request.Type,
				ID:         request.ID,
				Found:      found,
				Attributes: attrs,
				Version:    "stub-v1",
				TTLSeconds: 30,
				LagSeconds: st.LagSeconds,
				LagKnown:   st.LagKnown,
			})
		}
		writeJSON(w, http.StatusOK, batchResponse{Results: out})
	})
	mux.HandleFunc("GET /v1/classification/{type}", func(w http.ResponseWriter, r *http.Request) {
		resourceType := r.PathValue("type")
		fields, ok := fx.Classifications[resourceType]
		if !ok {
			http.Error(w, `{"error":"unknown_resource_type"}`, http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, classificationResponse{
			ResourceType: resourceType,
			Fields:       fields,
			TTLSeconds:   300,
		})
	})

	log.Printf("stub PIP listening on %s (fixtures=%s state=%s)", *addr, *fixturePath, *statePath)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func loadState(path string, fallback lagState) lagState {
	if strings.TrimSpace(path) == "" {
		return fallback
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return fallback
	}
	var st lagState
	if err := json.Unmarshal(raw, &st); err != nil {
		return fallback
	}
	return st
}

func lookup(fx fixtures, resourceType, id string, fields []string) (map[string]any, bool) {
	byID, ok := fx.Resources[resourceType]
	if !ok {
		return map[string]any{}, false
	}
	attrs, ok := byID[id]
	if !ok {
		return map[string]any{}, false
	}
	out := map[string]any{}
	if len(fields) == 0 {
		for k, v := range attrs {
			out[k] = v
		}
		return out, true
	}
	for _, field := range fields {
		if v, present := attrs[field]; present {
			out[field] = v
		}
	}
	return out, true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
