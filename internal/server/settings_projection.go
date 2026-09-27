package server

import (
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
)

func protoSettings(value model.Settings) *dieterv1.Settings {
	return &dieterv1.Settings{UpdatedAt: value.UpdatedAt, PromptTemplate: value.PromptTemplate, BoardSkillTemplate: value.BoardSkillTemplate, ChatSkillTemplate: value.ChatSkillTemplate}
}

func modelSettings(value *dieterv1.Settings) model.Settings {
	return model.Settings{PromptTemplate: value.GetPromptTemplate(), BoardSkillTemplate: value.GetBoardSkillTemplate(), ChatSkillTemplate: value.GetChatSkillTemplate()}
}

func protoPromptSettings(value model.Settings) *dieterv1.PromptSettings {
	value = dieterprompt.NormalizeSettings(value)
	return &dieterv1.PromptSettings{PromptTemplate: value.PromptTemplate, BoardSkillTemplate: value.BoardSkillTemplate, ChatSkillTemplate: value.ChatSkillTemplate, Variables: dieterprompt.Variables()}
}
