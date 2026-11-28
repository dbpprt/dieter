package embed

import (
	"math"
	"sort"
	"sync"
)

// gemmFunc computes C = A·B, or C += A·B when acc, for row-major A (m×k,
// stride lda), B (k×n, stride ldb) and C (m×n, stride ldc). m is a multiple
// of rowBlock.
type gemmFunc func(m, n, k int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool)

// kernels is one complete set of the encoder's numeric kernels.
type kernels struct {
	name string
	gemm gemmFunc
	// softmax normalizes each row of length cols in place.
	softmax func(x []float32, cols int)
	// layerNorm normalizes each row of length width in place.
	layerNorm func(x []float32, width int, w, b []float32)
	// gelu applies the exact (erf) GELU in place.
	gelu func(x []float32)
	// add sets out = a + b elementwise.
	add func(out, a, b []float32)
}

// gemmBackend is a matrix kernel; load binds it (once) and reports whether
// it works here.
type gemmBackend struct {
	name     string
	priority int
	load     func() (gemmFunc, bool)
}

var (
	// gemms are the matrix kernels compiled in; platform files add theirs in
	// init. The highest priority that loads wins.
	gemms = []gemmBackend{{name: "go", load: func() (gemmFunc, bool) { return gemmGo, true }}}
	// elementwise are the vector kernels (replaced by the SIMD build).
	elementwise = kernels{softmax: softmaxGo, layerNorm: layerNormGo, gelu: geluGo, add: addGo}

	activeOnce sync.Once
	active     *kernels
)

func activeKernels() *kernels {
	activeOnce.Do(func() {
		all := availableKernels()
		active = all[len(all)-1]
	})
	return active
}

// availableKernels are the kernel sets that work here, lowest priority
// first.
func availableKernels() []*kernels {
	backends := append([]gemmBackend(nil), gemms...)
	sort.SliceStable(backends, func(i, j int) bool { return backends[i].priority < backends[j].priority })
	var out []*kernels
	for _, backend := range backends {
		if gemm, ok := backend.load(); ok {
			k := elementwise
			k.name, k.gemm = backend.name, gemm
			out = append(out, &k)
		}
	}
	return out
}

func gemmGo(m, n, k int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
	for i := 0; i < m; i++ {
		row := c[i*ldc : i*ldc+n]
		if !acc {
			clear(row)
		}
		for p, x := range a[i*lda : i*lda+k] {
			for j, v := range b[p*ldb : p*ldb+n] {
				row[j] += x * v
			}
		}
	}
}

func softmaxGo(x []float32, cols int) {
	for start := 0; start+cols <= len(x); start += cols {
		row := x[start : start+cols]
		peak := row[0]
		for _, v := range row[1:] {
			peak = max(peak, v)
		}
		var sum float32
		for i, v := range row {
			row[i] = expNonPositive(v - peak)
			sum += row[i]
		}
		inv := 1 / sum
		for i := range row {
			row[i] *= inv
		}
	}
}

func layerNormGo(x []float32, width int, w, b []float32) {
	for start := 0; start+width <= len(x); start += width {
		row := x[start : start+width]
		var mean float32
		for _, v := range row {
			mean += v
		}
		mean /= float32(width)
		var variance float32
		for _, v := range row {
			variance += (v - mean) * (v - mean)
		}
		variance /= float32(width)
		inv := float32(1 / math.Sqrt(float64(variance+layerNormEps)))
		for i, v := range row {
			row[i] = (v-mean)*inv*w[i] + b[i]
		}
	}
}

func geluGo(x []float32) {
	for i, v := range x {
		x[i] = gelu(v)
	}
}

func addGo(out, a, b []float32) {
	for i := range out {
		out[i] = a[i] + b[i]
	}
}

// Exponential and erf approximations shared by every kernel set, so all of
// them compute the same function.
const (
	// expCut flushes eˣ to 0 below it: e⁻⁶⁴ ≈ 1.6e-28 is far below float32
	// precision next to the softmax maximum (e⁰) or 1 − erf, and tinier
	// values would make subnormal products, which x86 computes very slowly.
	expCut   = -64
	log2e    = 1.44269504088896341
	ln2Hi    = 0.693359375
	ln2Lo    = -2.12194440e-4
	expP0    = 1.9875691500e-4
	expP1    = 1.3981999507e-3
	expP2    = 8.3334519073e-3
	expP3    = 4.1665795894e-2
	expP4    = 1.6666665459e-1
	expP5    = 5.0000001201e-1
	erfP     = 0.3275911
	erfA1    = 0.254829592
	erfA2    = -0.284496736
	erfA3    = 1.421413741
	erfA4    = -1.453152027
	erfA5    = 1.061405429
	invSqrt2 = 0.70710678118654752
)

// expNonPositive is eˣ for expCut ≤ x ≤ 0 (Cephes expf: relative error
// about 1e-7); below expCut it is 0 and above 0 it is 1.
func expNonPositive(x float32) float32 {
	if x < expCut {
		return 0
	}
	x = min(x, 0)
	// n = round(x·log2e); for x ≤ 0, truncating t - 0.5 rounds.
	n := int32(x*log2e - 0.5)
	nf := float32(n)
	r := x - nf*ln2Hi - nf*ln2Lo
	p := ((((expP0*r+expP1)*r+expP2)*r+expP3)*r+expP4)*r + expP5
	p = p*r*r + r + 1
	return p * math.Float32frombits(uint32(n+127)<<23)
}

// gelu is x·Φ(x) with erf from Abramowitz–Stegun 7.1.26 (|error| < 1.5e-7):
// 0.5·(x + |x|·erf(|x|/√2)).
func gelu(x float32) float32 {
	a := float32(math.Abs(float64(x)))
	z := a * invSqrt2
	t := 1 / (1 + erfP*z)
	poly := ((((erfA5*t+erfA4)*t+erfA3)*t+erfA2)*t + erfA1) * t
	erf := 1 - poly*expNonPositive(-z*z)
	return 0.5 * (x + a*erf)
}

func sqrt(x float64) float64 { return math.Sqrt(x) }
