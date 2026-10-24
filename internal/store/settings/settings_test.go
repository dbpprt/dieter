package settings_test

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/leases"
)

func TestRuntimeAdmissionOnlySerializesSameConversation(t *testing.T) {
	t.Parallel()
	data := store.New(t.TempDir())
	for i := 0; i < 12; i++ {
		lease, err := data.Kanban.AcquireRuntimeLeaseFor("p_one", "b_one", fmt.Sprintf("c_%d", i), "codex")
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = data.Leases.Release(lease) }()
		if _, err := data.Kanban.AcquireRuntimeLeaseFor("p_one", "b_one", lease.CardID, "codex"); !errors.Is(err, leases.ErrCardActive) {
			t.Fatalf("duplicate start: %v", err)
		}
	}
}

func TestSettingsStoreOnlyCustomizedTemplates(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	data := store.New(root)
	custom := "Custom board rules for {{card.id}}."
	if _, err := data.Settings.UpdatePrompts(prompt.DefaultTemplate, custom, prompt.DefaultChatSkillTemplate); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "settings.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if text := string(raw); strings.Contains(text, "prompt_template") || strings.Contains(text, "chat_skill_template") || !strings.Contains(text, "Custom board rules") {
		t.Fatalf("settings.yaml must hold only the customized template:\n%s", text)
	}
	value, err := data.Settings.Get()
	if err != nil {
		t.Fatal(err)
	}
	if value.PromptTemplate != prompt.DefaultTemplate || value.ChatSkillTemplate != prompt.DefaultChatSkillTemplate || value.BoardSkillTemplate != custom {
		t.Fatalf("settings = %+v", value)
	}
}
