package embed

import (
	"sync"

	"github.com/ebitengine/purego"
)

// Accelerate's BLAS is part of macOS and runs on Apple silicon's matrix
// units; binding it with purego keeps the daemon's CGO_ENABLED=0 build.
const (
	cblasRowMajor = 101
	cblasNoTrans  = 111
)

func init() {
	gemms = append(gemms, gemmBackend{name: "accelerate", priority: 2, load: loadAccelerate})
}

var loadAccelerate = sync.OnceValues(func() (gemmFunc, bool) {
	library, err := purego.Dlopen("/System/Library/Frameworks/Accelerate.framework/Accelerate", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil, false
	}
	symbol, err := purego.Dlsym(library, "cblas_sgemm")
	if err != nil {
		_ = purego.Dlclose(library)
		return nil, false
	}
	var sgemm func(order, transA, transB, m, n, k int32, alpha float32, a *float32, lda int32, b *float32, ldb int32, beta float32, c *float32, ldc int32)
	purego.RegisterFunc(&sgemm, symbol)
	return func(m, n, k int, a []float32, lda int, b []float32, ldb int, c []float32, ldc int, acc bool) {
		if m == 0 || n == 0 {
			return
		}
		if k == 0 {
			if !acc {
				for i := 0; i < m; i++ {
					clear(c[i*ldc : i*ldc+n])
				}
			}
			return
		}
		// Bounds the native call by the slices Go would have checked.
		_, _, _ = a[(m-1)*lda+k-1], b[(k-1)*ldb+n-1], c[(m-1)*ldc+n-1]
		beta := float32(0)
		if acc {
			beta = 1
		}
		sgemm(cblasRowMajor, cblasNoTrans, cblasNoTrans, int32(m), int32(n), int32(k), 1, &a[0], int32(lda), &b[0], int32(ldb), beta, &c[0], int32(ldc))
	}, true
})
