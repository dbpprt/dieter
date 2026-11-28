package embed

const headSize = Dim / heads

// maxRows is MaxTokens rounded up to the kernels' row block.
const maxRows = (MaxTokens + rowBlock - 1) / rowBlock * rowBlock

// scratch holds one encoding's activations, reused across calls.
type scratch struct {
	x, qkv, ctx, attn, up, scores, keys []float32
	ids                                 []int32
}

func newScratch() *scratch {
	return &scratch{
		x:      make([]float32, maxRows*Dim),
		qkv:    make([]float32, maxRows*3*Dim),
		ctx:    make([]float32, maxRows*Dim),
		attn:   make([]float32, maxRows*Dim),
		up:     make([]float32, maxRows*intermediate),
		scores: make([]float32, maxRows*MaxTokens),
		keys:   make([]float32, headSize*MaxTokens),
		ids:    make([]int32, 0, MaxTokens),
	}
}

// encode runs the encoder over [CLS] ids [SEP] and mean-pools the tokens.
// Rows are padded to the kernels' row block; padded rows are computed but
// never attended to or pooled.
func (m *Model) encode(tokens []int32, s *scratch, k *kernels) []float32 {
	ids := append(append(append(s.ids[:0], clsID), tokens...), sepID)
	T := len(ids)
	R := (T + rowBlock - 1) / rowBlock * rowBlock
	x := s.x[:R*Dim]
	clear(x[T*Dim:])
	for t, id := range ids {
		row := x[t*Dim : (t+1)*Dim]
		word := m.word[int(id)*Dim : (int(id)+1)*Dim]
		scale := m.wordScale[id]
		position := m.position[t*Dim : (t+1)*Dim]
		for j := range row {
			row[j] = float32(word[j])*scale + position[j] + m.tokenType[j]
		}
	}
	k.layerNorm(x[:T*Dim], Dim, m.normW, m.normB)
	qkv, ctx, attn, up := s.qkv[:R*3*Dim], s.ctx[:R*Dim], s.attn[:R*Dim], s.up[:R*intermediate]
	scores, keys := s.scores[:R*T], s.keys[:headSize*T]
	for l := range m.layers {
		layer := &m.layers[l]
		project(k, qkv, nil, x, R, &layer.qkv)
		for h := 0; h < heads; h++ {
			// keys = Kₕᵀ, so scores = Qₕ·Kₕᵀ is a plain product.
			for t := 0; t < T; t++ {
				key := qkv[t*3*Dim+Dim+h*headSize : t*3*Dim+Dim+(h+1)*headSize]
				for j, v := range key {
					keys[j*T+t] = v
				}
			}
			k.gemm(R, T, headSize, qkv[h*headSize:], 3*Dim, keys, T, scores, T, false)
			k.softmax(scores, T)
			k.gemm(R, headSize, T, scores, T, qkv[2*Dim+h*headSize:], 3*Dim, ctx[h*headSize:], Dim, false)
		}
		project(k, attn, x, ctx, R, &layer.out)
		k.layerNorm(attn, Dim, layer.attnNormW, layer.attnNormB)
		project(k, up, nil, attn, R, &layer.up)
		k.gelu(up)
		project(k, x, attn, up, R, &layer.down)
		k.layerNorm(x, Dim, layer.outputNormW, layer.outputNormB)
	}
	out := make([]float32, Dim)
	for t := 0; t < T; t++ {
		row := x[t*Dim : (t+1)*Dim]
		for j, v := range row {
			out[j] += v
		}
	}
	return normalize(out)
}

// project computes out = residual + b + in·w for R rows (residual may be
// nil).
func project(k *kernels, out, residual, in []float32, R int, l *linear) {
	for r := 0; r < R; r++ {
		row := out[r*l.out : (r+1)*l.out]
		if residual != nil {
			k.add(row, residual[r*l.out:(r+1)*l.out], l.b)
		} else {
			copy(row, l.b)
		}
	}
	k.gemm(R, l.out, l.in, in, l.in, l.w, l.out, out, l.out, true)
}

func normalize(v []float32) []float32 {
	var sum float64
	for _, x := range v {
		sum += float64(x) * float64(x)
	}
	if sum == 0 {
		return v
	}
	inv := float32(1 / sqrt(sum))
	for i := range v {
		v[i] *= inv
	}
	return v
}
