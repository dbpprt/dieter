package app

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/model"
)

var ErrInvalidContentPresentation = errors.New("invalid content presentation")

const maxPresentationFileBytes = 5 << 20

// PresentConversationContent is shared by the authenticated RPC and the
// harness output handler. The caller binds cardID; content never supplies it.
func (s *Service) PresentConversationContent(ctx context.Context, cardID, turnID string, content model.ContentPresentation) (model.ContentPresentation, error) {
	invalid := func(message string) (model.ContentPresentation, error) {
		return model.ContentPresentation{}, fmt.Errorf("%w: %s", ErrInvalidContentPresentation, message)
	}
	if (content.Path == "") == (content.URL == "") {
		return invalid("provide exactly one path or URL")
	}
	if len(content.Path) > 4096 || len(content.URL) > 8192 || utf8.RuneCountInString(content.Title) > 256 ||
		!utf8.ValidString(content.Path) || !utf8.ValidString(content.URL) || !utf8.ValidString(content.Title) ||
		strings.ContainsFunc(content.Path+content.URL+content.Title, unicode.IsControl) {
		return invalid("path, URL, or title exceeds its limit or contains control characters")
	}
	if content.Line < 0 || content.Line > 10_000_000 || (content.URL != "" && content.Line != 0) {
		return invalid("line must be 1–10000000 for a file, or omitted")
	}
	card, err := s.Store.ResolveCard(cardID)
	if err != nil {
		return model.ContentPresentation{}, err
	}
	if card.ID != cardID {
		return invalid("an exact conversation ID is required")
	}
	if err := ctx.Err(); err != nil {
		return model.ContentPresentation{}, err
	}
	if content.URL != "" {
		parsed, err := url.Parse(content.URL)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" || parsed.User != nil || parsed.Opaque != "" {
			return invalid("URL must be an absolute HTTP(S) URL without credentials")
		}
		content.URL = parsed.String()
		// Escaping Unicode path/fragment text can expand a short input well
		// beyond the wire limit. Bound the value clients will actually receive.
		if len(content.URL) > 8192 {
			return invalid("normalized URL exceeds the 8192-byte limit")
		}
	} else {
		workspace, err := s.Workspaces.ResolvePath(ctx, card.ID)
		if err != nil {
			return model.ContentPresentation{}, err
		}
		root, err := filepath.EvalSymlinks(workspace.Path)
		if err != nil {
			return model.ContentPresentation{}, err
		}
		root, err = filepath.Abs(root)
		if err != nil {
			return model.ContentPresentation{}, err
		}
		if strings.Contains(content.Path, "\\") {
			return invalid("file paths must use forward slashes")
		}
		target := content.Path
		if !filepath.IsAbs(target) {
			target = filepath.Join(root, filepath.FromSlash(target))
		}
		relative, err := filepath.Rel(root, target)
		if err != nil || presentationPathProtected(relative) || (!filepath.IsAbs(content.Path) && !presentationPathContained(relative)) {
			return invalid("file must belong to this conversation's workspace")
		}
		resolved, err := filepath.EvalSymlinks(target)
		if err != nil {
			return model.ContentPresentation{}, err
		}
		resolvedRelative, err := filepath.Rel(root, resolved)
		if err != nil || !presentationPathContained(resolvedRelative) {
			return invalid("file must belong to this conversation's workspace")
		}
		// macOS commonly exposes the same workspace as /var and /private/var.
		// Canonical absolute aliases are valid; persist a root-relative path.
		if !presentationPathContained(relative) {
			relative = resolvedRelative
		}
		info, err := os.Stat(resolved)
		if err != nil {
			return model.ContentPresentation{}, err
		}
		if !info.Mode().IsRegular() {
			return invalid("path must identify a regular file")
		}
		if info.Size() > maxPresentationFileBytes {
			return invalid("file exceeds the 5 MiB viewer limit")
		}
		content.Path = filepath.ToSlash(relative)
	}
	content.Title = strings.TrimSpace(content.Title)
	return s.Store.PresentConversationContent(card.ID, turnID, content)
}

func presentationPathContained(relative string) bool {
	if relative == "." || relative == ".." || filepath.IsAbs(relative) || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return false
	}
	return !presentationPathProtected(relative)
}

func presentationPathProtected(relative string) bool {
	for _, part := range strings.Split(filepath.ToSlash(relative), "/") {
		if strings.EqualFold(part, ".git") {
			return true
		}
	}
	return false
}
