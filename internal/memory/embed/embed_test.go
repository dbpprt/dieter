package embed

import (
	"encoding/json"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type golden struct {
	Text   string    `json:"text"`
	IDs    []int32   `json:"ids"`
	Vector []float32 `json:"vector"`
}

func loadGolden(t testing.TB) []golden {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Cases []golden }
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture.Cases
}

var (
	testModelOnce sync.Once
	testModel     *Model
	testModelErr  error
)

func model(t testing.TB) *Model {
	t.Helper()
	testModelOnce.Do(func() { testModel, testModelErr = Load() })
	if testModelErr != nil {
		t.Fatal(testModelErr)
	}
	return testModel
}

func cosine(a, b []float32) float64 {
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / math.Sqrt(na*nb)
}

func isZero(v []float32) bool {
	for _, x := range v {
		if x != 0 {
			return false
		}
	}
	return true
}

// TestGoldenVectors checks the tokenizer against Hugging Face tokenizers and
// every kernel set against the float32 checkpoint run by onnxruntime
// (tools/embedmodel/reference.py). The int8 weights cost a little precision,
// never ranking quality (tools/spikes/memory-embeddings).
func TestGoldenVectors(t *testing.T) {
	m := model(t)
	cases := loadGolden(t)
	for _, k := range availableKernels() {
		worst := 1.0
		for _, c := range cases {
			ids := m.tokenizer.encode(c.Text, MaxTokens-2)
			if len(ids) != len(c.IDs) {
				t.Fatalf("%q: %d ids, want %d", c.Text, len(ids), len(c.IDs))
			}
			for i := range ids {
				if ids[i] != c.IDs[i] {
					t.Fatalf("%q: id %d is %d, want %d", c.Text, i, ids[i], c.IDs[i])
				}
			}
			got := m.embedWith(c.Text, k)
			if isZero(c.Vector) {
				if !isZero(got) {
					t.Errorf("%s %q: want the zero vector", k.name, c.Text)
				}
				continue
			}
			similarity := cosine(got, c.Vector)
			worst = min(worst, similarity)
			if similarity < 0.995 {
				t.Errorf("%s %q: cosine with the reference %.5f", k.name, c.Text, similarity)
			}
		}
		t.Logf("%s kernels: worst cosine with the float32 reference %.5f over %d texts", k.name, worst, len(cases))
	}
}

// TestKernelsAgree compares every kernel set with plain Go on the shapes the
// encoder uses, including column and row tails.
func TestKernelsAgree(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	random := func(n int) []float32 {
		out := make([]float32, n)
		for i := range out {
			out[i] = rng.Float32()*2 - 1
		}
		return out
	}
	shapes := [][3]int{{6, 1152, 384}, {12, 1536, 384}, {18, 384, 1536}, {12, 9, 32}, {12, 32, 9}, {258, 37, 5}, {6, 1, 1}}
	for _, k := range availableKernels() {
		for _, shape := range shapes {
			m, n, depth := shape[0], shape[1], shape[2]
			a, b, base := random(m*depth), random(depth*n), random(m*n)
			for _, acc := range []bool{false, true} {
				want := append([]float32(nil), base...)
				got := append([]float32(nil), base...)
				gemmGo(m, n, depth, a, depth, b, n, want, n, acc)
				k.gemm(m, n, depth, a, depth, b, n, got, n, acc)
				for i := range want {
					if diff := math.Abs(float64(got[i] - want[i])); diff > 1e-4*float64(depth) {
						t.Fatalf("%s gemm %v acc=%v: element %d is %g, want %g", k.name, shape, acc, i, got[i], want[i])
					}
				}
			}
		}
		x := random(6 * 37)
		want, got := append([]float32(nil), x...), append([]float32(nil), x...)
		softmaxGo(want, 37)
		k.softmax(got, 37)
		near(t, k.name+" softmax", got, want, 1e-6)
		x = random(6 * Dim)
		w, b := random(Dim), random(Dim)
		want, got = append([]float32(nil), x...), append([]float32(nil), x...)
		layerNormGo(want, Dim, w, b)
		k.layerNorm(got, Dim, w, b)
		near(t, k.name+" layer norm", got, want, 1e-5)
		x = random(1000)
		for i := range x {
			x[i] *= 8
		}
		want, got = append([]float32(nil), x...), append([]float32(nil), x...)
		geluGo(want)
		k.gelu(got)
		near(t, k.name+" gelu", got, want, 1e-5)
		y := random(1000)
		want, got = make([]float32, 1000), make([]float32, 1000)
		addGo(want, x, y)
		k.add(got, x, y)
		near(t, k.name+" add", got, want, 0)
	}
}

func near(t *testing.T, what string, got, want []float32, tolerance float64) {
	t.Helper()
	for i := range want {
		if diff := math.Abs(float64(got[i] - want[i])); diff > tolerance {
			t.Fatalf("%s: element %d is %g, want %g", what, i, got[i], want[i])
		}
	}
}

func TestApproximations(t *testing.T) {
	for step := -90.0; step <= 0; step += 0.01 {
		x := float64(float32(step))
		want := math.Exp(x)
		got := float64(expNonPositive(float32(x)))
		if x < expCut {
			want = 0
		}
		if math.Abs(got-want) > 2e-7*want {
			t.Fatalf("exp(%g) = %g, want %g", x, got, want)
		}
	}
	for x := -10.0; x <= 10; x += 0.001 {
		want := 0.5 * x * (1 + math.Erf(x/math.Sqrt2))
		if got := float64(gelu(float32(x))); math.Abs(got-want) > 2e-6 {
			t.Fatalf("gelu(%g) = %g, want %g", x, got, want)
		}
	}
}

func TestQuantizedVectors(t *testing.T) {
	m := model(t)
	a := m.Embed("Mac stays disconnected after waking from sleep")
	b := m.Embed("Dieter stays offline for minutes after the MacBook wakes up")
	if got, want := Dot(a, Quantize(b)), float32(cosine(a, b)); math.Abs(float64(got-want)) > 0.01 {
		t.Fatalf("quantized dot %.4f, float dot %.4f", got, want)
	}
	if got := Dot(a, Quantize(a)); got < 0.99 {
		t.Fatalf("self similarity %.4f", got)
	}
	if Dot(a, Quantize(make([]float32, Dim))) != 0 || Dot(a, []byte{1, 2}) != 0 {
		t.Fatal("zero and malformed vectors must score 0")
	}
}

func TestSharedLoadsAndReleases(t *testing.T) {
	shared := NewShared(50 * time.Millisecond)
	if shared.Loaded() {
		t.Fatal("loaded before use")
	}
	var wait sync.WaitGroup
	results := make([][]float32, 8)
	for i := range results {
		wait.Add(1)
		go func() {
			defer wait.Done()
			vectors, err := shared.Embed("concurrent recall query")
			if err != nil {
				t.Error(err)
				return
			}
			results[i] = vectors[0]
		}()
	}
	wait.Wait()
	for _, v := range results[1:] {
		if cosine(v, results[0]) < 0.99999 {
			t.Fatal("concurrent encodings differ")
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for shared.Loaded() {
		if time.Now().After(deadline) {
			t.Fatal("the model stayed loaded after the idle time")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func BenchmarkEmbed(b *testing.B) {
	m := model(b)
	for _, k := range availableKernels() {
		for _, text := range []struct{ name, text string }{
			{"query", "Mac stays disconnected after waking from sleep"},
			{"answer", "The gateway tunnel kept its reconnect deadline across sleep, so the redial fired late; compare wall clock time on wake. The gateway tunnel kept its reconnect deadline across sleep, so the redial fired late; compare wall clock time on wake. The gateway tunnel kept its reconnect deadline across sleep."},
			{"long", loadGolden(b)[len(loadGolden(b))-1].Text},
		} {
			b.Run(k.name+"/"+text.name, func(b *testing.B) {
				for b.Loop() {
					m.embedWith(text.text, k)
				}
			})
		}
	}
}

// BenchmarkGemm measures each matrix kernel on random data and on the
// encoder's real activations (which could hold slow subnormal values).
func BenchmarkGemm(b *testing.B) {
	rng := rand.New(rand.NewSource(1))
	m, n, k := 84, 1536, 384
	a, w := make([]float32, m*k), make([]float32, k*n)
	for i := range a {
		a[i] = rng.Float32()*2 - 1
	}
	for i := range w {
		w[i] = (rng.Float32()*2 - 1) * 0.05
	}
	c := make([]float32, m*n)
	for _, kernel := range availableKernels() {
		b.Run(kernel.name, func(b *testing.B) {
			for b.Loop() {
				kernel.gemm(m, n, k, a, k, w, n, c, n, false)
			}
			b.ReportMetric(float64(m*n*k)*float64(b.N)/b.Elapsed().Seconds()/1e9, "GMAC/s")
		})
	}
}
