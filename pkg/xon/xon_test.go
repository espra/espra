// Public Domain (-) 2026-present, The Espra Core Authors.
// See the Espra Core UNLICENSE file for details.

package xon

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	data, err := os.ReadFile("parse.tests")
	if err != nil {
		t.Fatalf("failed to read parse.tests: %v", err)
	}
	buf := &bytes.Buffer{}
	enc := json.NewEncoder(buf)
	enc.SetIndent("", "")
	tests := strings.Split(string(data), "-----\n")
	for _, test := range tests {
		test = strings.TrimSpace(test)
		if test == "" {
			continue
		}
		split := strings.SplitN(test, "---\n", 2)
		if len(split) != 2 {
			t.Errorf("failed to split test: %v", test)
			continue
		}
		src, want := split[0], split[1]
		nodes, err := Parse([]byte(src))
		buf.Reset()
		if err != nil {
			jerr := enc.Encode(err)
			if jerr != nil {
				t.Errorf("failed to marshal parse error: %v", jerr)
				continue
			}
			got := strings.TrimSuffix(buf.String(), "\n")
			if got != want {
				t.Errorf("unexpected parse error for:\n\n%s\n---\n\ngot:\n\n%s\n\nwant:\n\n%s\n\n", src, got, want)
				continue
			}
			continue
		}
		buf.Reset()
		for _, node := range nodes {
			enc.Encode(node)
		}
		got := strings.TrimSuffix(buf.String(), "\n")
		if got != want {
			t.Errorf("unexpected parsed result for:\n\n%s\n---\n\ngot:\n\n%s\n\nwant:\n\n%s\n\n", src, got, want)
		}
	}
}
