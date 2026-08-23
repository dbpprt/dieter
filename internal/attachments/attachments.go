package attachments

import (
	"encoding/base64"
	"errors"
	"fmt"
	"mime"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

const (
	MaxCount      = 4
	MaxFileBytes  = 5 << 20
	MaxTotalBytes = 6 << 20
)

// NormalizeMessageParts validates user-authored text and file parts and
// converts every attachment to Dieter's durable data-URL representation.
func NormalizeMessageParts(parts []model.UIMessagePart) ([]model.UIMessagePart, error) {
	result := make([]model.UIMessagePart, 0, len(parts))
	attachmentCount, totalBytes := 0, 0
	for _, part := range parts {
		switch part.Type {
		case "text":
			if part.Text != "" {
				result = append(result, model.UIMessagePart{Type: "text", Text: part.Text})
			}
		case "file", "image", "attachment":
			attachmentCount++
			if attachmentCount > MaxCount {
				return nil, fmt.Errorf("a message can contain at most %d attachments", MaxCount)
			}
			mediaType := strings.ToLower(strings.TrimSpace(part.MediaType))
			parsedMediaType, params, err := mime.ParseMediaType(mediaType)
			if err != nil || parsedMediaType != mediaType || len(params) != 0 || !strings.Contains(mediaType, "/") {
				return nil, fmt.Errorf("invalid attachment type %q", part.MediaType)
			}
			prefix := "data:" + mediaType + ";base64,"
			if !strings.HasPrefix(part.URL, prefix) {
				return nil, errors.New("attachments must use a matching base64 data URL")
			}
			decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(part.URL, prefix))
			if err != nil {
				return nil, errors.New("attachment contains invalid base64 data")
			}
			if len(decoded) == 0 {
				return nil, errors.New("attachment is empty")
			}
			if len(decoded) > MaxFileBytes {
				return nil, errors.New("each attachment must be at most 5 MB")
			}
			if totalBytes+len(decoded) > MaxTotalBytes {
				return nil, errors.New("attachments must total at most 6 MB")
			}
			totalBytes += len(decoded)
			filename := filepath.Base(strings.ReplaceAll(strings.TrimSpace(part.Filename), "\\", "/"))
			if filename == "." || filename == ".." || filename == "" {
				filename = "attachment" + extension(mediaType)
			}
			result = append(result, model.UIMessagePart{
				Type: "file", MediaType: mediaType, Filename: filename, URL: part.URL,
			})
		default:
			return nil, fmt.Errorf("unsupported user message part %q", part.Type)
		}
	}
	if len(result) == 0 {
		return nil, errors.New("message is required")
	}
	return result, nil
}

// FilePart builds a message attachment from local file bytes. The returned
// value still goes through NormalizeMessageParts so every entry point shares
// the same limits and filename rules.
func FilePart(filename, mediaType string, data []byte) model.UIMessagePart {
	mediaType = strings.ToLower(strings.TrimSpace(strings.Split(mediaType, ";")[0]))
	if mediaType == "" || !strings.Contains(mediaType, "/") {
		mediaType = mime.TypeByExtension(strings.ToLower(filepath.Ext(filename)))
		mediaType = strings.ToLower(strings.TrimSpace(strings.Split(mediaType, ";")[0]))
	}
	if mediaType == "" {
		mediaType = http.DetectContentType(data)
		mediaType = strings.ToLower(strings.TrimSpace(strings.Split(mediaType, ";")[0]))
	}
	return model.UIMessagePart{
		Type: "file", MediaType: mediaType, Filename: filename,
		URL: "data:" + mediaType + ";base64," + base64.StdEncoding.EncodeToString(data),
	}
}

func extension(mediaType string) string {
	switch mediaType {
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/avif":
		return ".avif"
	case "image/png":
		return ".png"
	}
	extensions, _ := mime.ExtensionsByType(mediaType)
	if len(extensions) > 0 {
		return extensions[0]
	}
	return ".bin"
}
