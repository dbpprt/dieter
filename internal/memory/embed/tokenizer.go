package embed

import (
	"fmt"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// Special token ids of the uncased BERT vocabulary.
const (
	unkID = 100
	clsID = 101
	sepID = 102
)

const maxWordChars = 100

// wordPiece is the BERT uncased tokenizer of the model's tokenizer.json:
// BertNormalizer (clean text, CJK spacing, lowercase, strip accents),
// BertPreTokenizer (whitespace and punctuation) and greedy longest-match
// WordPiece with "##" continuations.
type wordPiece struct {
	vocab map[string]int32
}

func newWordPiece(vocab string) (*wordPiece, error) {
	tokens := strings.Split(strings.TrimSuffix(vocab, "\n"), "\n")
	if len(tokens) != vocabSize {
		return nil, fmt.Errorf("%d tokens, want %d", len(tokens), vocabSize)
	}
	if tokens[unkID] != "[UNK]" || tokens[clsID] != "[CLS]" || tokens[sepID] != "[SEP]" {
		return nil, fmt.Errorf("unexpected special tokens")
	}
	t := &wordPiece{vocab: make(map[string]int32, len(tokens))}
	for id, token := range tokens {
		t.vocab[token] = int32(id)
	}
	return t, nil
}

// specialTokens are matched in the raw text, before normalization, as
// Hugging Face tokenizers does for the vocabulary's added tokens.
var specialTokens = map[string]int32{"[PAD]": 0, "[UNK]": unkID, "[CLS]": clsID, "[SEP]": sepID, "[MASK]": 103}

// encode returns at most limit word piece ids of text, without the
// surrounding [CLS] and [SEP].
func (t *wordPiece) encode(text string, limit int) []int32 {
	var ids []int32
	for text != "" && len(ids) < limit {
		segment, special, rest := cutSpecial(text)
		for _, word := range preTokenize(normalizeText(segment)) {
			if ids = t.appendWord(ids, word); len(ids) >= limit {
				break
			}
		}
		if special >= 0 {
			ids = append(ids, special)
		}
		text = rest
	}
	if len(ids) > limit {
		ids = ids[:limit]
	}
	return ids
}

// cutSpecial splits text at its first special token: the text before it,
// the token's id (-1 when there is none) and the text after it.
func cutSpecial(text string) (string, int32, string) {
	for offset := 0; ; {
		i := strings.IndexByte(text[offset:], '[')
		if i < 0 {
			return text, -1, ""
		}
		i += offset
		if j := strings.IndexByte(text[i:], ']'); j > 0 && j <= len("[MASK]") {
			if id, ok := specialTokens[text[i:i+j+1]]; ok {
				return text[:i], id, text[i+j+1:]
			}
		}
		offset = i + 1
	}
}

func (t *wordPiece) appendWord(ids []int32, word string) []int32 {
	chars := []rune(word)
	if len(chars) > maxWordChars {
		return append(ids, unkID)
	}
	start := len(ids)
	for begin := 0; begin < len(chars); {
		found := int32(-1)
		end := len(chars)
		for ; end > begin; end-- {
			piece := string(chars[begin:end])
			if begin > 0 {
				piece = "##" + piece
			}
			if id, ok := t.vocab[piece]; ok {
				found = id
				break
			}
		}
		if found < 0 {
			return append(ids[:start], unkID)
		}
		ids = append(ids, found)
		begin = end
	}
	return ids
}

func normalizeText(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for _, r := range text {
		switch {
		case r == 0 || r == unicode.ReplacementChar || (unicode.IsControl(r) && r != '\t' && r != '\n' && r != '\r'):
		case unicode.IsSpace(r):
			b.WriteByte(' ')
		case isCJK(r):
			b.WriteByte(' ')
			b.WriteRune(r)
			b.WriteByte(' ')
		default:
			b.WriteRune(unicode.ToLower(r))
		}
	}
	// Strip accents: decompose, then drop combining marks.
	decomposed := norm.NFD.String(b.String())
	b.Reset()
	for _, r := range decomposed {
		if !unicode.Is(unicode.Mn, r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func preTokenize(text string) []string {
	var words []string
	start := -1
	for i, r := range text {
		switch {
		case unicode.IsSpace(r):
			if start >= 0 {
				words = append(words, text[start:i])
				start = -1
			}
		case isPunctuation(r):
			if start >= 0 {
				words = append(words, text[start:i])
				start = -1
			}
			words = append(words, string(r))
		default:
			if start < 0 {
				start = i
			}
		}
	}
	if start >= 0 {
		words = append(words, text[start:])
	}
	return words
}

func isPunctuation(r rune) bool {
	return (r >= 33 && r <= 47) || (r >= 58 && r <= 64) || (r >= 91 && r <= 96) || (r >= 123 && r <= 126) || unicode.IsPunct(r)
}

func isCJK(r rune) bool {
	return (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF) || (r >= 0x20000 && r <= 0x2A6DF) ||
		(r >= 0x2A700 && r <= 0x2B73F) || (r >= 0x2B740 && r <= 0x2B81F) || (r >= 0x2B820 && r <= 0x2CEAF) ||
		(r >= 0xF900 && r <= 0xFAFF) || (r >= 0x2F800 && r <= 0x2FA1F)
}
