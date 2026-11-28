// Command embedmodel converts the sentence-transformers all-MiniLM-L6-v2
// checkpoint into the int8 asset that internal/memory/embed embeds.
//
//	go run ./tools/embedmodel -src DIR [-out internal/memory/embed/minilm]
//
// DIR holds the checkpoint's model.safetensors and tokenizer.json at the
// pinned revision (their SHA-256 are checked). Linear weights and the word
// embeddings become symmetric int8 with one float32 scale per row; biases,
// layer norms, position and token type embeddings stay float32. The output is
// a safetensors file plus the WordPiece vocabulary, one token per line.
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	source            = "sentence-transformers/all-MiniLM-L6-v2"
	revision          = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
	modelSHA256       = "53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db"
	vocabSourceSHA256 = "be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037"
	format            = "dieter-embed-int8-1"
	layers            = 6
)

func main() {
	src := flag.String("src", "", "directory with the checkpoint's model.safetensors and tokenizer.json")
	out := flag.String("out", "internal/memory/embed/minilm", "output directory")
	flag.Parse()
	if *src == "" {
		fail(fmt.Errorf("-src is required"))
	}
	modelRaw := read(filepath.Join(*src, "model.safetensors"), modelSHA256)
	tokenizerRaw := read(filepath.Join(*src, "tokenizer.json"), vocabSourceSHA256)
	tensors, err := parse(modelRaw)
	fail(err)

	var outputs []tensor
	keep := func(name string) {
		value, ok := tensors[name]
		if !ok {
			fail(fmt.Errorf("missing tensor %s", name))
		}
		outputs = append(outputs, tensor{name: name, shape: value.shape, f32: value.data})
	}
	quantize := func(name string) {
		value, ok := tensors[name]
		if !ok || len(value.shape) != 2 {
			fail(fmt.Errorf("missing matrix %s", name))
		}
		rows, cols := value.shape[0], value.shape[1]
		q := make([]int8, rows*cols)
		scales := make([]float32, rows)
		for r := 0; r < rows; r++ {
			row := value.data[r*cols : (r+1)*cols]
			var peak float32
			for _, x := range row {
				peak = max(peak, float32(math.Abs(float64(x))))
			}
			if peak == 0 {
				continue
			}
			scale := peak / 127
			scales[r] = scale
			for c, x := range row {
				q[r*cols+c] = int8(math.Round(float64(x / scale)))
			}
		}
		outputs = append(outputs, tensor{name: name, shape: value.shape, i8: q}, tensor{name: name + ".scale", shape: []int{rows}, f32: scales})
	}
	quantize("embeddings.word_embeddings.weight")
	keep("embeddings.position_embeddings.weight")
	keep("embeddings.token_type_embeddings.weight")
	keep("embeddings.LayerNorm.weight")
	keep("embeddings.LayerNorm.bias")
	for l := 0; l < layers; l++ {
		p := fmt.Sprintf("encoder.layer.%d.", l)
		for _, linear := range []string{"attention.self.query", "attention.self.key", "attention.self.value", "attention.output.dense", "intermediate.dense", "output.dense"} {
			quantize(p + linear + ".weight")
			keep(p + linear + ".bias")
		}
		for _, norm := range []string{"attention.output.LayerNorm", "output.LayerNorm"} {
			keep(p + norm + ".weight")
			keep(p + norm + ".bias")
		}
	}
	metadata := map[string]string{
		"format":        format,
		"source":        source,
		"revision":      revision,
		"source_sha256": modelSHA256,
		"quantization":  "symmetric int8 per row for linear weights and word embeddings; everything else float32",
	}
	fail(os.MkdirAll(*out, 0o755))
	fail(os.WriteFile(filepath.Join(*out, "model.safetensors"), encode(outputs, metadata), 0o644))

	var tokenizer struct {
		Model struct {
			Vocab map[string]int `json:"vocab"`
		} `json:"model"`
	}
	fail(json.Unmarshal(tokenizerRaw, &tokenizer))
	vocab := make([]string, len(tokenizer.Model.Vocab))
	for token, id := range tokenizer.Model.Vocab {
		if id < 0 || id >= len(vocab) || vocab[id] != "" || strings.ContainsAny(token, "\r\n") {
			fail(fmt.Errorf("unexpected vocabulary entry %q (%d)", token, id))
		}
		vocab[id] = token
	}
	fail(os.WriteFile(filepath.Join(*out, "vocab.txt"), []byte(strings.Join(vocab, "\n")+"\n"), 0o644))
	for _, name := range []string{"model.safetensors", "vocab.txt"} {
		raw, err := os.ReadFile(filepath.Join(*out, name))
		fail(err)
		sum := sha256.Sum256(raw)
		fmt.Printf("%s  %s (%d bytes)\n", hex.EncodeToString(sum[:]), name, len(raw))
	}
}

type tensor struct {
	name  string
	shape []int
	f32   []float32
	i8    []int8
}

type source32 struct {
	shape []int
	data  []float32
}

func read(path, want string) []byte {
	raw, err := os.ReadFile(path)
	fail(err)
	sum := sha256.Sum256(raw)
	if got := hex.EncodeToString(sum[:]); got != want {
		fail(fmt.Errorf("%s: sha256 %s, want %s (revision %s)", path, got, want, revision))
	}
	return raw
}

func parse(raw []byte) (map[string]source32, error) {
	if len(raw) < 8 {
		return nil, fmt.Errorf("short safetensors file")
	}
	size := binary.LittleEndian.Uint64(raw)
	if size > uint64(len(raw)-8) {
		return nil, fmt.Errorf("bad safetensors header")
	}
	var header map[string]json.RawMessage
	if err := json.Unmarshal(raw[8:8+size], &header); err != nil {
		return nil, err
	}
	data := raw[8+size:]
	out := map[string]source32{}
	for name, entry := range header {
		if name == "__metadata__" {
			continue
		}
		var info struct {
			Dtype   string `json:"dtype"`
			Shape   []int  `json:"shape"`
			Offsets [2]int `json:"data_offsets"`
		}
		if err := json.Unmarshal(entry, &info); err != nil {
			return nil, err
		}
		if info.Dtype != "F32" {
			continue
		}
		bytes := data[info.Offsets[0]:info.Offsets[1]]
		values := make([]float32, len(bytes)/4)
		for i := range values {
			values[i] = math.Float32frombits(binary.LittleEndian.Uint32(bytes[i*4:]))
		}
		out[name] = source32{shape: info.Shape, data: values}
	}
	return out, nil
}

func encode(tensors []tensor, metadata map[string]string) []byte {
	sort.Slice(tensors, func(i, j int) bool { return tensors[i].name < tensors[j].name })
	header := map[string]any{"__metadata__": metadata}
	var body []byte
	for _, t := range tensors {
		start := len(body)
		dtype := "F32"
		if t.i8 != nil {
			dtype = "I8"
			for _, v := range t.i8 {
				body = append(body, byte(v))
			}
		} else {
			for _, v := range t.f32 {
				body = binary.LittleEndian.AppendUint32(body, math.Float32bits(v))
			}
		}
		header[t.name] = map[string]any{"dtype": dtype, "shape": t.shape, "data_offsets": []int{start, len(body)}}
	}
	encoded, err := json.Marshal(header)
	fail(err)
	for len(encoded)%8 != 0 {
		encoded = append(encoded, ' ')
	}
	out := binary.LittleEndian.AppendUint64(nil, uint64(len(encoded)))
	out = append(out, encoded...)
	return append(out, body...)
}

func fail(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "embedmodel:", err)
		os.Exit(1)
	}
}
