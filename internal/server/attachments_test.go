package server

import (
	"encoding/base64"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
)

type testUserMessagePart struct {
	Type, Text, MediaType, Filename, URL string
}

func TestValidateUserMessagePartsAcceptsDocuments(t *testing.T) {
	payload := []byte("%PDF-1.7\nfixture")
	parts, err := validateUserMessageParts([]testUserMessagePart{{
		Type: "file", MediaType: "application/pdf", Filename: "../plan.pdf",
		URL: "data:application/pdf;base64," + base64.StdEncoding.EncodeToString(payload),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) != 1 || parts[0].Type != "file" || parts[0].Filename != "plan.pdf" || parts[0].MediaType != "application/pdf" {
		t.Fatalf("parts = %#v", parts)
	}
}

func TestModelUserMessagePartsAcceptsRawAttachmentBytes(t *testing.T) {
	parts, err := modelUserMessageParts([]*dieterv1.MessagePart{{
		Type: "attachment", MediaType: "text/plain", Filename: "notes.txt", Data: []byte("hello"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) != 1 || parts[0].Type != "file" || parts[0].URL != "data:text/plain;base64,aGVsbG8=" {
		t.Fatalf("parts = %#v", parts)
	}
}

func TestProtoMessagePartReturnsLocalAttachmentBytes(t *testing.T) {
	payload := []byte("hello")
	part := protoMessagePart(model.UIMessagePart{
		Type:      "file",
		MediaType: "text/plain",
		Filename:  "notes.txt",
		URL:       "data:text/plain;base64," + base64.StdEncoding.EncodeToString(payload),
	})
	if string(part.Data) != string(payload) || part.Url != "" {
		t.Fatalf("part = %#v", part)
	}
}

func TestValidateUserMessagePartsRejectsInvalidAttachments(t *testing.T) {
	tests := map[string][]testUserMessagePart{
		"mismatched data type": {{
			Type: "file", MediaType: "application/pdf", URL: "data:text/plain;base64,aGVsbG8=",
		}},
		"invalid base64": {{
			Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,%%%",
		}},
		"too many": {
			{Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,YQ=="},
			{Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,YQ=="},
			{Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,YQ=="},
			{Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,YQ=="},
			{Type: "file", MediaType: "text/plain", URL: "data:text/plain;base64,YQ=="},
		},
	}
	for name, wire := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := validateUserMessageParts(wire); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestValidateUserMessagePartsEnforcesAttachmentSize(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString(make([]byte, maxMessageAttachmentBytes+1))
	_, err := validateUserMessageParts([]testUserMessagePart{{
		Type: "file", MediaType: "application/octet-stream", URL: "data:application/octet-stream;base64," + encoded,
	}})
	if err == nil || !strings.Contains(err.Error(), "5 MB") {
		t.Fatalf("error = %v", err)
	}
}
