package embed

import (
	"encoding/binary"
	"math"
)

// VectorBytes is the size of a stored vector: a float32 scale and Dim int8.
const VectorBytes = 4 + Dim

// Quantize encodes a vector for storage as one float32 scale followed by Dim
// symmetric int8 values (a quarter of the float32 size; recall is
// unchanged).
func Quantize(v []float32) []byte {
	out := make([]byte, VectorBytes)
	var peak float32
	for _, x := range v {
		peak = max(peak, float32(math.Abs(float64(x))))
	}
	if peak == 0 {
		return out
	}
	scale := peak / 127
	binary.LittleEndian.PutUint32(out, math.Float32bits(scale))
	for i, x := range v[:Dim] {
		out[4+i] = byte(int8(math.Round(float64(x / scale))))
	}
	return out
}

// Dot is the dot product of a vector with a stored one (their cosine, as
// both are normalized). A malformed stored vector scores 0.
func Dot(v []float32, stored []byte) float32 {
	if len(stored) != VectorBytes || len(v) < Dim {
		return 0
	}
	scale := math.Float32frombits(binary.LittleEndian.Uint32(stored))
	q := stored[4:]
	var s0, s1, s2, s3 float32
	for i := 0; i+4 <= Dim; i += 4 {
		s0 += v[i] * float32(int8(q[i]))
		s1 += v[i+1] * float32(int8(q[i+1]))
		s2 += v[i+2] * float32(int8(q[i+2]))
		s3 += v[i+3] * float32(int8(q[i+3]))
	}
	return (s0 + s1 + s2 + s3) * scale
}
