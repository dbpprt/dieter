// Package embed turns text into vectors for agent memory recall
// (docs/adr/0008-memory-embeddings.md). It runs all-MiniLM-L6-v2, a
// 6-layer sentence encoder, in process: the int8 weights are embedded in the
// binary (minilm/), so there is no download, no extra process and no cgo.
//
// The matrix products run on the fastest kernel the build has: Apple's
// Accelerate (cblas_sgemm) through purego on macOS, Go's portable SIMD
// (GOEXPERIMENT=simd: NEON on arm64, AVX on amd64) elsewhere, and plain Go
// otherwise. Every kernel computes the same function as the plain-Go one.
package embed

import (
	_ "embed" // the model asset
	"errors"
	"fmt"
	"math"
	"strings"
	"sync"
	"time"
)

// Model identity and shape.
const (
	// ID names the model, its revision and the asset format. Stored vectors
	// from another ID are discarded and recomputed.
	ID = "all-MiniLM-L6-v2@1110a243/int8.1"
	// Dim is the vector length.
	Dim = 384
	// MaxTokens bounds the encoded tokens, [CLS] and [SEP] included; longer
	// texts are truncated, as sentence-transformers does for this model.
	MaxTokens = 256

	layers       = 6
	heads        = 12
	intermediate = 1536
	vocabSize    = 30522
	positions    = 512
	layerNormEps = 1e-12
	// rowBlock is the row multiple the kernels compute; inputs are padded.
	rowBlock = 6
)

//go:embed minilm/model.safetensors
var modelAsset []byte

//go:embed minilm/vocab.txt
var vocabAsset string

// Model is the loaded encoder. It is safe for concurrent use.
type Model struct {
	tokenizer *wordPiece

	word      []int8    // [vocab][Dim]
	wordScale []float32 // [vocab]
	position  []float32 // [positions][Dim]
	tokenType []float32 // [Dim], type 0
	normW     []float32
	normB     []float32
	layers    [layers]layer

	scratch sync.Pool
}

type layer struct {
	// qkv is the fused query, key and value projection, [Dim][3·Dim]; the
	// query part is pre-scaled by 1/√(head size).
	qkv, out, up, down       linear
	attnNormW, attnNormB     []float32
	outputNormW, outputNormB []float32
}

// linear is y = x·w + b with w stored [in][out] row-major.
type linear struct {
	w       []float32
	b       []float32
	in, out int
}

// Load decodes the embedded model. It takes tens of milliseconds and about
// 60 MB of memory; use Shared to keep one copy and release it when idle.
func Load() (*Model, error) {
	tensors, err := readSafetensors(modelAsset)
	if err != nil {
		return nil, fmt.Errorf("embedding model: %w", err)
	}
	tokenizer, err := newWordPiece(vocabAsset)
	if err != nil {
		return nil, fmt.Errorf("embedding vocabulary: %w", err)
	}
	m := &Model{tokenizer: tokenizer}
	var missing error
	f32 := func(name string, size int) []float32 {
		value, ok := tensors.f32[name]
		if !ok || len(value) != size {
			missing = errors.Join(missing, fmt.Errorf("tensor %s", name))
			return make([]float32, size)
		}
		return value
	}
	i8 := func(name string, rows, cols int) ([]int8, []float32) {
		value, ok := tensors.i8[name]
		if !ok || len(value) != rows*cols {
			missing = errors.Join(missing, fmt.Errorf("tensor %s", name))
			return make([]int8, rows*cols), make([]float32, rows)
		}
		return value, f32(name+".scale", rows)
	}
	// dense dequantizes a [out][in] int8 matrix into [in][out] float32.
	dense := func(name string, in, out int, factor float32) linear {
		q, scales := i8(name+".weight", out, in)
		w := make([]float32, in*out)
		for o := 0; o < out; o++ {
			scale := scales[o] * factor
			for i := 0; i < in; i++ {
				w[i*out+o] = float32(q[o*in+i]) * scale
			}
		}
		b := append([]float32(nil), f32(name+".bias", out)...)
		for i := range b {
			b[i] *= factor
		}
		return linear{w: w, b: b, in: in, out: out}
	}
	m.word, m.wordScale = i8("embeddings.word_embeddings.weight", vocabSize, Dim)
	m.position = f32("embeddings.position_embeddings.weight", positions*Dim)
	m.tokenType = f32("embeddings.token_type_embeddings.weight", 2*Dim)[:Dim]
	m.normW = f32("embeddings.LayerNorm.weight", Dim)
	m.normB = f32("embeddings.LayerNorm.bias", Dim)
	headScale := float32(1 / math.Sqrt(float64(Dim/heads)))
	for l := range m.layers {
		p := fmt.Sprintf("encoder.layer.%d.", l)
		q := dense(p+"attention.self.query", Dim, Dim, headScale)
		k := dense(p+"attention.self.key", Dim, Dim, 1)
		v := dense(p+"attention.self.value", Dim, Dim, 1)
		qkv := linear{w: make([]float32, Dim*3*Dim), b: make([]float32, 3*Dim), in: Dim, out: 3 * Dim}
		for i := 0; i < Dim; i++ {
			copy(qkv.w[i*3*Dim:], q.w[i*Dim:(i+1)*Dim])
			copy(qkv.w[i*3*Dim+Dim:], k.w[i*Dim:(i+1)*Dim])
			copy(qkv.w[i*3*Dim+2*Dim:], v.w[i*Dim:(i+1)*Dim])
		}
		copy(qkv.b, q.b)
		copy(qkv.b[Dim:], k.b)
		copy(qkv.b[2*Dim:], v.b)
		m.layers[l] = layer{
			qkv:         qkv,
			out:         dense(p+"attention.output.dense", Dim, Dim, 1),
			up:          dense(p+"intermediate.dense", Dim, intermediate, 1),
			down:        dense(p+"output.dense", intermediate, Dim, 1),
			attnNormW:   f32(p+"attention.output.LayerNorm.weight", Dim),
			attnNormB:   f32(p+"attention.output.LayerNorm.bias", Dim),
			outputNormW: f32(p+"output.LayerNorm.weight", Dim),
			outputNormB: f32(p+"output.LayerNorm.bias", Dim),
		}
	}
	if missing != nil {
		return nil, fmt.Errorf("embedding model: %w", missing)
	}
	m.scratch.New = func() any { return newScratch() }
	return m, nil
}

// Embed returns the L2-normalized vector of text. Empty text gives the
// zero vector.
func (m *Model) Embed(text string) []float32 { return m.embedWith(text, activeKernels()) }

func (m *Model) embedWith(text string, k *kernels) []float32 {
	ids := m.tokenizer.encode(text, MaxTokens-2)
	if len(ids) == 0 {
		return make([]float32, Dim)
	}
	s := m.scratch.Get().(*scratch)
	defer m.scratch.Put(s)
	return m.encode(ids, s, k)
}

// Backend names the matrix kernel in use: "accelerate", "simd" or "go".
func Backend() string { return activeKernels().name }

// Shared is a lazily loaded model that is released after it has been idle,
// so a daemon that does not use memory pays nothing and one that does keeps
// the model only while it works.
type Shared struct {
	idle time.Duration

	mu    sync.Mutex
	model *Model
	users int
	timer *time.Timer
	err   error
}

// NewShared returns a shared model released after idle (default 5 minutes).
func NewShared(idle time.Duration) *Shared {
	if idle <= 0 {
		idle = 5 * time.Minute
	}
	return &Shared{idle: idle}
}

// Embed encodes texts, loading the model first if needed.
func (s *Shared) Embed(texts ...string) ([][]float32, error) {
	model, err := s.acquire()
	if err != nil {
		return nil, err
	}
	defer s.release()
	out := make([][]float32, len(texts))
	for i, text := range texts {
		out[i] = model.Embed(strings.TrimSpace(text))
	}
	return out, nil
}

// Usable reports whether the model can run: false after it failed to load,
// which is permanent because the model is part of the binary.
func (s *Shared) Usable() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err == nil
}

// Loaded reports whether the model is in memory (tests).
func (s *Shared) Loaded() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.model != nil
}

func (s *Shared) acquire() (*Model, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err != nil {
		return nil, s.err
	}
	if s.model == nil {
		model, err := Load()
		if err != nil {
			// The asset is part of the binary: a failure is permanent.
			s.err = err
			return nil, err
		}
		s.model = model
	}
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	s.users++
	return s.model, nil
}

func (s *Shared) release() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.users--
	if s.users == 0 {
		s.timer = time.AfterFunc(s.idle, s.unload)
	}
}

func (s *Shared) unload() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.users == 0 {
		s.model = nil
		s.timer = nil
	}
}
