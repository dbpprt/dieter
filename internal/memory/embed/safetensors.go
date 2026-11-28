package embed

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
)

type tensorSet struct {
	f32 map[string][]float32
	i8  map[string][]int8
}

// readSafetensors decodes the F32 and I8 tensors of a safetensors file.
func readSafetensors(raw []byte) (tensorSet, error) {
	set := tensorSet{f32: map[string][]float32{}, i8: map[string][]int8{}}
	if len(raw) < 8 {
		return set, fmt.Errorf("short file")
	}
	size := binary.LittleEndian.Uint64(raw)
	if size > uint64(len(raw)-8) {
		return set, fmt.Errorf("bad header size")
	}
	var header map[string]json.RawMessage
	if err := json.Unmarshal(raw[8:8+size], &header); err != nil {
		return set, err
	}
	data := raw[8+size:]
	for name, entry := range header {
		if name == "__metadata__" {
			continue
		}
		var info struct {
			Dtype   string `json:"dtype"`
			Offsets [2]int `json:"data_offsets"`
		}
		if err := json.Unmarshal(entry, &info); err != nil {
			return set, fmt.Errorf("tensor %s: %w", name, err)
		}
		start, end := info.Offsets[0], info.Offsets[1]
		if start < 0 || end < start || end > len(data) {
			return set, fmt.Errorf("tensor %s: bad offsets", name)
		}
		bytes := data[start:end]
		switch info.Dtype {
		case "F32":
			values := make([]float32, len(bytes)/4)
			for i := range values {
				values[i] = math.Float32frombits(binary.LittleEndian.Uint32(bytes[i*4:]))
			}
			set.f32[name] = values
		case "I8":
			values := make([]int8, len(bytes))
			for i, b := range bytes {
				values[i] = int8(b)
			}
			set.i8[name] = values
		default:
			return set, fmt.Errorf("tensor %s: dtype %s", name, info.Dtype)
		}
	}
	return set, nil
}
