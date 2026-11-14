package replica

import (
	"strconv"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
)

const orderAlphabet = "0123456789abcdefghijklmnopqrstuvwxyz"

// OrderBetween creates an immutable fractional position. A random operation
// suffix makes simultaneous insertions in the same gap distinct. No lane-wide
// renumbering is replicated, and future moves can address either new neighbor.
func OrderBetween(left, right string) (string, error) {
	if right != "" && left >= right {
		return "", fault.New(fault.Invalid, "invalid ordering anchors")
	}
	// Reserve a wide integer prefix for appends/prepends. Repeated end insertion
	// must not consume one fractional digit per few cards on a large board.
	if right == "" {
		value := uint64(3656158440062976) // 36^10, room on both sides
		if len(left) >= 12 {
			if n, e := strconv.ParseUint(left[:12], 36, 64); e == nil {
				value = n + 1
			}
		}
		prefix := strconv.FormatUint(value, 36)
		if len(prefix) <= 12 {
			return strings.Repeat("0", 12-len(prefix)) + prefix + home.NewID("") + "h", nil
		}
	}
	if left == "" && len(right) >= 12 {
		if n, e := strconv.ParseUint(right[:12], 36, 64); e == nil && n > 1 {
			prefix := strconv.FormatUint(n-1, 36)
			return strings.Repeat("0", 12-len(prefix)) + prefix + home.NewID("") + "h", nil
		}
	}
	prefix := ""
	for i := 0; i < 480; i++ {
		lo, hi := 0, len(orderAlphabet)-1
		if i < len(left) {
			lo = strings.IndexByte(orderAlphabet, left[i])
		}
		if i < len(right) {
			hi = strings.IndexByte(orderAlphabet, right[i])
		}
		if lo < 0 || hi < 0 {
			return "", fault.New(fault.Invalid, "invalid position key")
		}
		if hi-lo > 1 {
			return prefix + string(orderAlphabet[(lo+hi)/2]) + home.NewID("") + "h", nil
		}
		prefix += string(orderAlphabet[lo])
		if hi > lo {
			right = ""
		}
	}
	return "", fault.New(fault.Invalid, "position key exhausted; move using wider anchors")
}
