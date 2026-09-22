package server

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"
)

func legacyPreview(value string, limit int) string {
	value = strings.Join(strings.Fields(value), " ")
	if utf8.RuneCountInString(value) <= limit {
		return value
	}
	return string([]rune(value)[:limit-1]) + "…"
}

func TestTruncatePreviewMatchesWhitespaceAndUnicodeBoundaries(t *testing.T) {
	values := []string{"", "  ", "a", "abc ", "  abc\tdef \n", "é 👋🏼 résumé\u2003next", strings.Repeat("large output\n", 100000)}
	for _, value := range values {
		for _, limit := range []int{1, 2, 3, 7, 160} {
			if got, want := truncatePreview(value, limit), legacyPreview(value, limit); got != want {
				t.Errorf("limit=%d got=%q want=%q", limit, got, want)
			}
		}
	}
	if truncatePreview("text", 0) != "" {
		t.Fatal("empty budget")
	}
}

func TestPayloadSummaryRetainsSemanticsAndInvalidatesChangedResults(t *testing.T) {
	for _, value := range []string{
		`{"command":"ls -la","output":"` + strings.Repeat("result ", 1000) + `"}`,
		`{"path":"/tmp/é","count":9007199254740993,"output":"` + strings.Repeat("result ", 1000) + `"}`,
		`"` + strings.Repeat("résumé 👋🏼 ", 1000) + `"`,
		`{"output":"` + strings.Repeat("text ", 1000) + `"}`,
		strings.Repeat("malformed JSON\n", 1000),
	} {
		want := payloadPreview([]byte(value))
		for range 2 {
			got, present, size := payloadSummary(json.RawMessage(value))
			if got != want || !present || size != int64(len(value)) {
				t.Fatalf("preview=%q size=%d", got, size)
			}
		}
	}
	a := json.RawMessage(`{"command":"first","output":"` + strings.Repeat("x", 5000) + `"}`)
	b := json.RawMessage(strings.Replace(string(a), "first", "other", 1))
	first, _, _ := payloadSummary(a)
	second, _, _ := payloadSummary(b)
	if first != "first" || second != "other" {
		t.Fatal("stale preview after payload change")
	}
	empty, present, size := payloadSummary(json.RawMessage(" \n "))
	if empty != "" || present || size != 0 {
		t.Fatal("empty payload marked present")
	}
	padded := append([]byte("\n "), a...)
	got, present, size := payloadSummary(padded)
	if got != first || !present || size != int64(len(padded)) {
		t.Fatal("raw payload byte count changed on cache hit")
	}
}

func TestPayloadPreviewCacheIsBoundedAndConcurrent(t *testing.T) {
	var cache payloadPreviewCache
	key := func(i int) [32]byte { return sha256.Sum256([]byte(fmt.Sprint(i))) }
	for i := 0; i < maxPayloadPreviews+1; i++ {
		cache.put(key(i), fmt.Sprint(i))
	}
	if len(cache.entries) != maxPayloadPreviews {
		t.Fatal("unbounded cache")
	}
	if _, ok := cache.get(key(0)); ok {
		t.Fatal("oldest entry was not evicted")
	}
	var group sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		group.Add(1)
		go func() {
			defer group.Done()
			for i := 0; i < 512; i++ {
				cache.put(key(i), fmt.Sprint(i))
				if got, ok := cache.get(key(i)); ok && got != fmt.Sprint(i) {
					t.Error("wrong cached content")
				}
			}
		}()
	}
	group.Wait()
	if len(cache.entries) != maxPayloadPreviews {
		t.Fatal("concurrent admission exceeded bound")
	}
}

func BenchmarkLargeToolPreview(b *testing.B) {
	for _, size := range []int{8 << 10, 1 << 20} {
		raw, _ := json.Marshal(strings.Repeat("tool output\n", size/12))
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			b.Run("decode", func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					_ = payloadPreview(raw)
				}
			})
			b.Run("cached", func(b *testing.B) {
				_, _, _ = payloadSummary(raw)
				b.ReportAllocs()
				b.ResetTimer()
				for b.Loop() {
					_, _, _ = payloadSummary(raw)
				}
			})
		})
	}
}

func BenchmarkLargePreviewTruncation(b *testing.B) {
	value := strings.Repeat("tool output\n", 100000)
	b.Run("previous", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			_ = legacyPreview(value, 160)
		}
	})
	b.Run("bounded", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			_ = truncatePreview(value, 160)
		}
	})
}
