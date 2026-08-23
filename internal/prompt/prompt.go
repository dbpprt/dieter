package prompt

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

const (
	MaxTemplateBytes = 32 << 10
	MaxRenderedBytes = 64 << 10

	DefaultTemplate = `You are working inside Board.

Project: {{project.name}}
Working tree: {{project.path}}

{{project.instructions_block}}

{{labels.instructions_block}}`

	DefaultBoardSkillTemplate = `Board operating instructions:
- Use the Dieter CLI for Dieter operations; never call the browser API or edit DIETER_HOME directly.
- Load bounded card context with: dieter card context {{card.id}}
- Work directly in the registered Git working tree.
- Post concise, non-triggering progress notes with: dieter card comment {{card.id}} --message "..."
- Keep this card in Running while implementation or verification is incomplete.
- When the requested outcome is implemented and relevant checks pass, move with: dieter card move {{card.id}} --lane {{board.target_lane}}
- If blocked, leave the card in Running and comment the exact blocker and required next action.
- Create a separate Todo card only when explicitly asked to capture distinct follow-up work. Use: dieter card create --project {{project.id}} --board {{board.id}} --lane todo ...
- Available board labels: {{board.labels}}
- Use exact label IDs with: dieter card labels {{card.id}} --set <label-id>,<label-id>
- Comments never count as approval. Human messages continue this same durable harness session.`

	DefaultChatSkillTemplate = `Standalone chat instructions:
- Work directly in the registered Git working tree.
- This is a standalone chat, not a Kanban card. Do not move it between lanes or assign board labels.
- Human messages continue this same durable harness session.
- Keep updates focused in the conversation.`
)

var placeholderPattern = regexp.MustCompile(`\{\{\s*([a-z0-9_.]+)\s*\}\}`)

var allowedVariables = map[string]bool{
	"scope":        true,
	"project.name": true, "project.id": true, "project.path": true, "project.summary": true,
	"project.instructions": true, "project.instructions_block": true,
	"board.name": true, "board.id": true, "board.workflow": true, "board.description": true,
	"board.labels": true, "board.target_lane": true,
	"card.id": true, "card.title": true, "card.lane": true, "card.labels": true,
	"labels.instructions": true, "labels.instructions_block": true,
}

type Resolution struct {
	Source        string
	Template      string
	Context       string
	Skill         string
	Instructions  string
	AppliedLabels []model.Label
}

func NormalizeSettings(settings model.Settings) model.Settings {
	if strings.TrimSpace(settings.PromptTemplate) == "" {
		settings.PromptTemplate = DefaultTemplate
	}
	if strings.TrimSpace(settings.BoardSkillTemplate) == "" {
		settings.BoardSkillTemplate = DefaultBoardSkillTemplate
	}
	if strings.TrimSpace(settings.ChatSkillTemplate) == "" {
		settings.ChatSkillTemplate = DefaultChatSkillTemplate
	}
	return settings
}

func ValidateContextTemplate(value string) error {
	if err := validateTemplate(value); err != nil {
		return err
	}
	counts := placeholderCounts(value)
	for _, required := range []string{"project.instructions_block", "labels.instructions_block"} {
		if counts[required] != 1 {
			return fmt.Errorf("template must contain {{%s}} exactly once", required)
		}
	}
	return nil
}

func ValidateSkillTemplate(value string) error { return validateTemplate(value) }

func validateTemplate(value string) error {
	if strings.TrimSpace(value) == "" {
		return errors.New("template is required")
	}
	if len(value) > MaxTemplateBytes {
		return fmt.Errorf("template exceeds %d KiB", MaxTemplateBytes>>10)
	}
	for _, match := range placeholderPattern.FindAllStringSubmatch(value, -1) {
		if !allowedVariables[match[1]] {
			return fmt.Errorf("unknown template variable {{%s}}", match[1])
		}
	}
	stripped := placeholderPattern.ReplaceAllString(value, "")
	if strings.Contains(stripped, "{{") || strings.Contains(stripped, "}}") {
		return errors.New("template contains a malformed variable")
	}
	return nil
}

func placeholderCounts(value string) map[string]int {
	counts := map[string]int{}
	for _, match := range placeholderPattern.FindAllStringSubmatch(value, -1) {
		counts[match[1]]++
	}
	return counts
}

func Resolve(settings model.Settings, detail model.CardDetail, labelIDs []string) (Resolution, error) {
	settings = NormalizeSettings(settings)
	template, source := settings.PromptTemplate, "global"
	if strings.TrimSpace(detail.Project.PromptTemplate) != "" {
		template, source = detail.Project.PromptTemplate, "project"
	}
	if detail.Card.Scope == model.ConversationScopeBoard && strings.TrimSpace(detail.Board.PromptTemplate) != "" {
		template, source = detail.Board.PromptTemplate, "board"
	}
	if err := ValidateContextTemplate(template); err != nil {
		return Resolution{}, fmt.Errorf("%s prompt template: %w", source, err)
	}

	requested := map[string]bool{}
	for _, id := range labelIDs {
		requested[id] = true
	}
	labels := make([]model.Label, 0, len(requested))
	for _, label := range detail.Board.Labels {
		if requested[label.ID] {
			labels = append(labels, label)
		}
	}
	projectBlock := ""
	if value := strings.TrimSpace(detail.Project.Prompt); value != "" {
		projectBlock = "Project instructions:\n" + value
	}
	labelNames := make([]string, 0, len(labels))
	labelSections := make([]string, 0, len(labels))
	for _, label := range labels {
		labelNames = append(labelNames, label.Name)
		if value := strings.TrimSpace(label.Instructions); value != "" {
			labelSections = append(labelSections, "## "+label.Name+"\n"+value)
		}
	}
	labelInstructions := strings.Join(labelSections, "\n\n")
	labelBlock := ""
	if labelInstructions != "" {
		labelBlock = "Label-specific instructions:\n\n" + labelInstructions
	}
	availableLabels := make([]string, 0, len(detail.Board.Labels))
	for _, label := range detail.Board.Labels {
		availableLabels = append(availableLabels, label.Name+" ("+label.ID+")")
	}
	if len(availableLabels) == 0 {
		availableLabels = []string{"none"}
	}
	targetLane := model.LaneDone
	if detail.Board.Workflow == model.WorkflowReview {
		targetLane = model.LaneReview
	}
	variables := map[string]string{
		"scope":        detail.Card.Scope,
		"project.name": detail.Project.Name, "project.id": detail.Project.ID, "project.path": detail.Project.Path,
		"project.summary": detail.Project.Summary, "project.instructions": detail.Project.Prompt,
		"project.instructions_block": projectBlock,
		"board.name":                 detail.Board.Name, "board.id": detail.Board.ID, "board.workflow": detail.Board.Workflow,
		"board.description": detail.Board.Description, "board.labels": strings.Join(availableLabels, ", "), "board.target_lane": targetLane,
		"card.id": detail.Card.ID, "card.title": detail.Card.Title, "card.lane": detail.Card.Lane,
		"card.labels": strings.Join(labelNames, ", "), "labels.instructions": labelInstructions,
		"labels.instructions_block": labelBlock,
	}
	context := render(template, variables)
	skillTemplate := settings.ChatSkillTemplate
	if detail.Card.Scope == model.ConversationScopeBoard {
		skillTemplate = settings.BoardSkillTemplate
	}
	if err := ValidateSkillTemplate(skillTemplate); err != nil {
		return Resolution{}, fmt.Errorf("skill template: %w", err)
	}
	skill := render(skillTemplate, variables)
	instructions := joinSections(context, skill)
	if len(instructions) > MaxRenderedBytes {
		return Resolution{}, fmt.Errorf("rendered instructions exceed %d KiB", MaxRenderedBytes>>10)
	}
	return Resolution{Source: source, Template: template, Context: context, Skill: skill, Instructions: instructions, AppliedLabels: labels}, nil
}

func render(value string, variables map[string]string) string {
	return strings.TrimSpace(placeholderPattern.ReplaceAllStringFunc(value, func(match string) string {
		parts := placeholderPattern.FindStringSubmatch(match)
		return variables[parts[1]]
	}))
}

func joinSections(values ...string) string {
	sections := make([]string, 0, len(values))
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			sections = append(sections, value)
		}
	}
	return strings.Join(sections, "\n\n")
}

func Variables() []string {
	result := make([]string, 0, len(allowedVariables))
	for value := range allowedVariables {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}
