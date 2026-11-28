//go:build goexperiment.simd

package embed

import "simd"

// The SIMD kernels use Go's portable vectors: NEON on arm64, AVX/AVX2/AVX-512
// on amd64 (vector length 4, 8 or 16 float32). They replace the plain-Go
// elementwise kernels and add a matrix kernel; on macOS Accelerate's matrix
// kernel still wins (accelerate_darwin.go).
func init() {
	if simd.Emulated() {
		return
	}
	gemms = append(gemms, gemmBackend{name: "simd", priority: 1, load: func() (gemmFunc, bool) { return gemmSIMD, true }})
	elementwise = kernels{softmax: softmaxSIMD, layerNorm: layerNormSIMD, gelu: geluSIMD, add: addSIMD}
}

func lanes() int { return simd.BroadcastFloat32s(0).Len() }

// gemmSIMD blocks C into 6 rows × 4 vectors (24 accumulators, for the 32
// vector registers of NEON and AVX-512) or 6 rows × 2 vectors (12, for the
// 16 of AVX2); leftover columns go one vector at a time.
func gemmSIMD(m, n, k int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
	L := lanes()
	j := 0
	if L == 8 {
		for ; j+2*L <= n; j += 2 * L {
			for i := 0; i < m; i += rowBlock {
				gemm6x2(i, j, k, L, a, lda, b, ldb, c, ldc, acc)
			}
		}
	} else {
		for ; j+4*L <= n; j += 4 * L {
			for i := 0; i < m; i += rowBlock {
				gemm6x4(i, j, k, L, a, lda, b, ldb, c, ldc, acc)
			}
		}
	}
	for ; j < n; j += L {
		for i := 0; i < m; i += rowBlock {
			gemm6x1(i, j, n, k, a, lda, b, ldb, c, ldc, acc)
		}
	}
}

func gemm6x4(i, j, k, L int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
	a0, a1, a2 := a[i*lda:i*lda+k], a[(i+1)*lda:(i+1)*lda+k], a[(i+2)*lda:(i+2)*lda+k]
	a3, a4, a5 := a[(i+3)*lda:(i+3)*lda+k], a[(i+4)*lda:(i+4)*lda+k], a[(i+5)*lda:(i+5)*lda+k]
	var c00, c01, c02, c03, c10, c11, c12, c13, c20, c21, c22, c23 simd.Float32s
	var c30, c31, c32, c33, c40, c41, c42, c43, c50, c51, c52, c53 simd.Float32s
	w := 4 * L
	for p := range a0 {
		bp := b[p*ldb+j : p*ldb+j+w]
		b0, b1, b2, b3 := simd.LoadFloat32s(bp), simd.LoadFloat32s(bp[L:]), simd.LoadFloat32s(bp[2*L:]), simd.LoadFloat32s(bp[3*L:])
		x := simd.BroadcastFloat32s(a0[p])
		c00, c01, c02, c03 = x.MulAdd(b0, c00), x.MulAdd(b1, c01), x.MulAdd(b2, c02), x.MulAdd(b3, c03)
		x = simd.BroadcastFloat32s(a1[p])
		c10, c11, c12, c13 = x.MulAdd(b0, c10), x.MulAdd(b1, c11), x.MulAdd(b2, c12), x.MulAdd(b3, c13)
		x = simd.BroadcastFloat32s(a2[p])
		c20, c21, c22, c23 = x.MulAdd(b0, c20), x.MulAdd(b1, c21), x.MulAdd(b2, c22), x.MulAdd(b3, c23)
		x = simd.BroadcastFloat32s(a3[p])
		c30, c31, c32, c33 = x.MulAdd(b0, c30), x.MulAdd(b1, c31), x.MulAdd(b2, c32), x.MulAdd(b3, c33)
		x = simd.BroadcastFloat32s(a4[p])
		c40, c41, c42, c43 = x.MulAdd(b0, c40), x.MulAdd(b1, c41), x.MulAdd(b2, c42), x.MulAdd(b3, c43)
		x = simd.BroadcastFloat32s(a5[p])
		c50, c51, c52, c53 = x.MulAdd(b0, c50), x.MulAdd(b1, c51), x.MulAdd(b2, c52), x.MulAdd(b3, c53)
	}
	store4(c[i*ldc+j:], L, acc, c00, c01, c02, c03)
	store4(c[(i+1)*ldc+j:], L, acc, c10, c11, c12, c13)
	store4(c[(i+2)*ldc+j:], L, acc, c20, c21, c22, c23)
	store4(c[(i+3)*ldc+j:], L, acc, c30, c31, c32, c33)
	store4(c[(i+4)*ldc+j:], L, acc, c40, c41, c42, c43)
	store4(c[(i+5)*ldc+j:], L, acc, c50, c51, c52, c53)
}

func gemm6x2(i, j, k, L int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
	a0, a1, a2 := a[i*lda:i*lda+k], a[(i+1)*lda:(i+1)*lda+k], a[(i+2)*lda:(i+2)*lda+k]
	a3, a4, a5 := a[(i+3)*lda:(i+3)*lda+k], a[(i+4)*lda:(i+4)*lda+k], a[(i+5)*lda:(i+5)*lda+k]
	var c00, c01, c10, c11, c20, c21, c30, c31, c40, c41, c50, c51 simd.Float32s
	w := 2 * L
	for p := range a0 {
		bp := b[p*ldb+j : p*ldb+j+w]
		b0, b1 := simd.LoadFloat32s(bp), simd.LoadFloat32s(bp[L:])
		x := simd.BroadcastFloat32s(a0[p])
		c00, c01 = x.MulAdd(b0, c00), x.MulAdd(b1, c01)
		x = simd.BroadcastFloat32s(a1[p])
		c10, c11 = x.MulAdd(b0, c10), x.MulAdd(b1, c11)
		x = simd.BroadcastFloat32s(a2[p])
		c20, c21 = x.MulAdd(b0, c20), x.MulAdd(b1, c21)
		x = simd.BroadcastFloat32s(a3[p])
		c30, c31 = x.MulAdd(b0, c30), x.MulAdd(b1, c31)
		x = simd.BroadcastFloat32s(a4[p])
		c40, c41 = x.MulAdd(b0, c40), x.MulAdd(b1, c41)
		x = simd.BroadcastFloat32s(a5[p])
		c50, c51 = x.MulAdd(b0, c50), x.MulAdd(b1, c51)
	}
	store2(c[i*ldc+j:], L, acc, c00, c01)
	store2(c[(i+1)*ldc+j:], L, acc, c10, c11)
	store2(c[(i+2)*ldc+j:], L, acc, c20, c21)
	store2(c[(i+3)*ldc+j:], L, acc, c30, c31)
	store2(c[(i+4)*ldc+j:], L, acc, c40, c41)
	store2(c[(i+5)*ldc+j:], L, acc, c50, c51)
}

// gemm6x1 computes one (possibly partial) vector of columns j..n.
func gemm6x1(i, j, n, k int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
	a0, a1, a2 := a[i*lda:i*lda+k], a[(i+1)*lda:(i+1)*lda+k], a[(i+2)*lda:(i+2)*lda+k]
	a3, a4, a5 := a[(i+3)*lda:(i+3)*lda+k], a[(i+4)*lda:(i+4)*lda+k], a[(i+5)*lda:(i+5)*lda+k]
	var c0, c1, c2, c3, c4, c5 simd.Float32s
	for p := range a0 {
		b0, _ := simd.LoadFloat32sPart(b[p*ldb+j : p*ldb+n])
		c0 = simd.BroadcastFloat32s(a0[p]).MulAdd(b0, c0)
		c1 = simd.BroadcastFloat32s(a1[p]).MulAdd(b0, c1)
		c2 = simd.BroadcastFloat32s(a2[p]).MulAdd(b0, c2)
		c3 = simd.BroadcastFloat32s(a3[p]).MulAdd(b0, c3)
		c4 = simd.BroadcastFloat32s(a4[p]).MulAdd(b0, c4)
		c5 = simd.BroadcastFloat32s(a5[p]).MulAdd(b0, c5)
	}
	for r, v := range [rowBlock]simd.Float32s{c0, c1, c2, c3, c4, c5} {
		out := c[(i+r)*ldc+j : (i+r)*ldc+n]
		if acc {
			previous, _ := simd.LoadFloat32sPart(out)
			v = v.Add(previous)
		}
		v.StorePart(out)
	}
}

func store4(out []float32, L int, acc bool, v0, v1, v2, v3 simd.Float32s) {
	if acc {
		v0 = v0.Add(simd.LoadFloat32s(out))
		v1 = v1.Add(simd.LoadFloat32s(out[L:]))
		v2 = v2.Add(simd.LoadFloat32s(out[2*L:]))
		v3 = v3.Add(simd.LoadFloat32s(out[3*L:]))
	}
	v0.Store(out)
	v1.Store(out[L:])
	v2.Store(out[2*L:])
	v3.Store(out[3*L:])
}

func store2(out []float32, L int, acc bool, v0, v1 simd.Float32s) {
	if acc {
		v0 = v0.Add(simd.LoadFloat32s(out))
		v1 = v1.Add(simd.LoadFloat32s(out[L:]))
	}
	v0.Store(out)
	v1.Store(out[L:])
}

// sum adds a vector's lanes.
func sum(v simd.Float32s) float32 {
	var lanes [16]float32
	v.Store(lanes[:])
	var total float32
	for _, x := range lanes[:v.Len()] {
		total += x
	}
	return total
}

func maxLane(v simd.Float32s) float32 {
	var lanes [16]float32
	v.Store(lanes[:])
	peak := lanes[0]
	for _, x := range lanes[1:v.Len()] {
		peak = max(peak, x)
	}
	return peak
}

// expv is expNonPositive on a vector.
func expv(x simd.Float32s) simd.Float32s {
	keep := x.GreaterEqual(simd.BroadcastFloat32s(expCut))
	x = x.Max(simd.BroadcastFloat32s(expCut)).Min(simd.BroadcastFloat32s(0))
	n := x.Mul(simd.BroadcastFloat32s(log2e)).Sub(simd.BroadcastFloat32s(0.5)).ConvertToInt32()
	nf := n.ConvertToFloat32()
	r := x.Sub(nf.Mul(simd.BroadcastFloat32s(ln2Hi))).Sub(nf.Mul(simd.BroadcastFloat32s(ln2Lo)))
	p := simd.BroadcastFloat32s(expP0).MulAdd(r, simd.BroadcastFloat32s(expP1))
	p = p.MulAdd(r, simd.BroadcastFloat32s(expP2))
	p = p.MulAdd(r, simd.BroadcastFloat32s(expP3))
	p = p.MulAdd(r, simd.BroadcastFloat32s(expP4))
	p = p.MulAdd(r, simd.BroadcastFloat32s(expP5))
	p = p.Mul(r).MulAdd(r, r).Add(simd.BroadcastFloat32s(1))
	scale := n.Add(simd.BroadcastInt32s(127)).ShiftAllLeft(23).ToBits().BitsToFloat32()
	return p.Mul(scale).Masked(keep)
}

func softmaxSIMD(x []float32, cols int) {
	L := lanes()
	for start := 0; start+cols <= len(x); start += cols {
		row := x[start : start+cols]
		i := 0
		peak := row[0]
		if cols >= L {
			vp := simd.LoadFloat32s(row)
			for i = L; i+L <= cols; i += L {
				vp = vp.Max(simd.LoadFloat32s(row[i:]))
			}
			peak = maxLane(vp)
		}
		for ; i < cols; i++ {
			peak = max(peak, row[i])
		}
		vpeak := simd.BroadcastFloat32s(peak)
		var vsum simd.Float32s
		for i = 0; i+L <= cols; i += L {
			e := expv(simd.LoadFloat32s(row[i:]).Sub(vpeak))
			e.Store(row[i:])
			vsum = vsum.Add(e)
		}
		total := sum(vsum)
		for ; i < cols; i++ {
			row[i] = expNonPositive(row[i] - peak)
			total += row[i]
		}
		inv := 1 / total
		vinv := simd.BroadcastFloat32s(inv)
		for i = 0; i+L <= cols; i += L {
			simd.LoadFloat32s(row[i:]).Mul(vinv).Store(row[i:])
		}
		for ; i < cols; i++ {
			row[i] *= inv
		}
	}
}

func layerNormSIMD(x []float32, width int, w, b []float32) {
	L := lanes()
	if width%L != 0 {
		layerNormGo(x, width, w, b)
		return
	}
	scale := 1 / float32(width)
	for start := 0; start+width <= len(x); start += width {
		row := x[start : start+width]
		var vs simd.Float32s
		for i := 0; i < width; i += L {
			vs = vs.Add(simd.LoadFloat32s(row[i:]))
		}
		mean := sum(vs) * scale
		vmean := simd.BroadcastFloat32s(mean)
		var vv simd.Float32s
		for i := 0; i < width; i += L {
			d := simd.LoadFloat32s(row[i:]).Sub(vmean)
			vv = d.MulAdd(d, vv)
		}
		variance := sum(vv) * scale
		inv := simd.BroadcastFloat32s(float32(1 / sqrt(float64(variance+layerNormEps))))
		for i := 0; i < width; i += L {
			d := simd.LoadFloat32s(row[i:]).Sub(vmean).Mul(inv)
			d.MulAdd(simd.LoadFloat32s(w[i:]), simd.LoadFloat32s(b[i:])).Store(row[i:])
		}
	}
}

func geluSIMD(x []float32) {
	L := lanes()
	half := simd.BroadcastFloat32s(0.5)
	one := simd.BroadcastFloat32s(1)
	i := 0
	for ; i+L <= len(x); i += L {
		v := simd.LoadFloat32s(x[i:])
		a := v.Abs()
		z := a.Mul(simd.BroadcastFloat32s(invSqrt2))
		t := one.Div(simd.BroadcastFloat32s(erfP).MulAdd(z, one))
		poly := simd.BroadcastFloat32s(erfA5).MulAdd(t, simd.BroadcastFloat32s(erfA4))
		poly = poly.MulAdd(t, simd.BroadcastFloat32s(erfA3))
		poly = poly.MulAdd(t, simd.BroadcastFloat32s(erfA2))
		poly = poly.MulAdd(t, simd.BroadcastFloat32s(erfA1)).Mul(t)
		erf := one.Sub(poly.Mul(expv(z.Mul(z).Neg())))
		a.MulAdd(erf, v).Mul(half).Store(x[i:])
	}
	for ; i < len(x); i++ {
		x[i] = gelu(x[i])
	}
}

func addSIMD(out, a, b []float32) {
	L := lanes()
	i := 0
	for ; i+L <= len(out); i += L {
		simd.LoadFloat32s(a[i:]).Add(simd.LoadFloat32s(b[i:])).Store(out[i:])
	}
	for ; i < len(out); i++ {
		out[i] = a[i] + b[i]
	}
}
