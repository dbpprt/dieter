package kv_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/testkit"
)

func TestChannelSettingsResolveBoardOverProjectOverGlobal(t *testing.T) {
	data := testkit.Store(t)
	settings, err := data.KV.ChannelSettings()
	if err != nil || settings.Global || settings.Enabled("p_1", "b_1") {
		t.Fatalf("default settings = %+v, %v; want off", settings, err)
	}
	for _, step := range []struct{ scope, id, value string }{
		{"global", "", "on"}, {"project", "p_1", "off"}, {"board", "b_1", "on"}, {"board", "b_2", "off"},
	} {
		if err := data.KV.SetChannelSetting(step.scope, step.id, step.value); err != nil {
			t.Fatalf("set %+v: %v", step, err)
		}
	}
	settings, err = data.KV.ChannelSettings()
	if err != nil {
		t.Fatal(err)
	}
	for _, check := range []struct {
		project, board string
		want           bool
	}{
		{"p_1", "b_1", true}, {"p_1", "b_3", false}, {"p_1", "", false}, {"p_2", "", true}, {"p_2", "b_2", false},
	} {
		if got := settings.Enabled(check.project, check.board); got != check.want {
			t.Fatalf("Enabled(%s, %s) = %v, want %v (%+v)", check.project, check.board, got, check.want, settings)
		}
	}
	if !settings.ProjectEnabled("p_1", []string{"b_1"}) || settings.ProjectEnabled("p_1", []string{"b_3"}) {
		t.Fatalf("ProjectEnabled ignores board overrides: %+v", settings)
	}
	if err := data.KV.SetChannelSetting("board", "b_1", "inherit"); err != nil {
		t.Fatal(err)
	}
	if err := data.KV.SetChannelSetting("board", "b_1", "inherit"); err != nil {
		t.Fatalf("repeated inherit: %v", err)
	}
	settings, _ = data.KV.ChannelSettings()
	if _, ok := settings.Boards["b_1"]; ok || settings.Enabled("p_1", "b_1") {
		t.Fatalf("inherit kept the override: %+v", settings)
	}
	for _, bad := range []struct{ scope, id, value string }{
		{"global", "", "inherit"}, {"project", "", "on"}, {"board", "b.1", "on"}, {"card", "c_1", "on"}, {"project", "p_1", "yes"},
	} {
		if err := data.KV.SetChannelSetting(bad.scope, bad.id, bad.value); err == nil {
			t.Fatalf("SetChannelSetting(%+v) accepted", bad)
		}
	}
}
