// Package dieterclient composes the per-domain dieter.v1 service clients into
// one value, so callers address the daemon API as a whole while the schema
// keeps one service per domain.
package dieterclient

import (
	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"google.golang.org/grpc"
)

// Client is every dieter.v1 service over one gRPC connection.
type Client interface {
	dieterv1.MachineServiceClient
	dieterv1.StateServiceClient
	dieterv1.SettingsServiceClient
	dieterv1.ProjectServiceClient
	dieterv1.BoardServiceClient
	dieterv1.CardServiceClient
	dieterv1.ConversationServiceClient
	dieterv1.GitServiceClient
	dieterv1.FileServiceClient
	dieterv1.TerminalServiceClient
	dieterv1.ExecutionServiceClient
	dieterv1.ScreenServiceClient
	dieterv1.ControlServiceClient
	dieterv1.ScheduleServiceClient
	dieterv1.VaultServiceClient
	dieterv1.KVServiceClient
	dieterv1.PeerServiceClient
	dieterv1.TrustServiceClient
	dieterv1.ChannelServiceClient
	dieterv1.MailServiceClient
}

type client struct {
	dieterv1.MachineServiceClient
	dieterv1.StateServiceClient
	dieterv1.SettingsServiceClient
	dieterv1.ProjectServiceClient
	dieterv1.BoardServiceClient
	dieterv1.CardServiceClient
	dieterv1.ConversationServiceClient
	dieterv1.GitServiceClient
	dieterv1.FileServiceClient
	dieterv1.TerminalServiceClient
	dieterv1.ExecutionServiceClient
	dieterv1.ScreenServiceClient
	dieterv1.ControlServiceClient
	dieterv1.ScheduleServiceClient
	dieterv1.VaultServiceClient
	dieterv1.KVServiceClient
	dieterv1.PeerServiceClient
	dieterv1.TrustServiceClient
	dieterv1.ChannelServiceClient
	dieterv1.MailServiceClient
}

// New returns the gRPC clients of every dieter.v1 service sharing conn.
func New(conn grpc.ClientConnInterface) Client {
	return client{
		MachineServiceClient:      dieterv1.NewMachineServiceClient(conn),
		StateServiceClient:        dieterv1.NewStateServiceClient(conn),
		SettingsServiceClient:     dieterv1.NewSettingsServiceClient(conn),
		ProjectServiceClient:      dieterv1.NewProjectServiceClient(conn),
		BoardServiceClient:        dieterv1.NewBoardServiceClient(conn),
		CardServiceClient:         dieterv1.NewCardServiceClient(conn),
		ConversationServiceClient: dieterv1.NewConversationServiceClient(conn),
		GitServiceClient:          dieterv1.NewGitServiceClient(conn),
		FileServiceClient:         dieterv1.NewFileServiceClient(conn),
		TerminalServiceClient:     dieterv1.NewTerminalServiceClient(conn),
		ExecutionServiceClient:    dieterv1.NewExecutionServiceClient(conn),
		ScreenServiceClient:       dieterv1.NewScreenServiceClient(conn),
		ControlServiceClient:      dieterv1.NewControlServiceClient(conn),
		ScheduleServiceClient:     dieterv1.NewScheduleServiceClient(conn),
		VaultServiceClient:        dieterv1.NewVaultServiceClient(conn),
		KVServiceClient:           dieterv1.NewKVServiceClient(conn),
		PeerServiceClient:         dieterv1.NewPeerServiceClient(conn),
		TrustServiceClient:        dieterv1.NewTrustServiceClient(conn),
		ChannelServiceClient:      dieterv1.NewChannelServiceClient(conn),
		MailServiceClient:         dieterv1.NewMailServiceClient(conn),
	}
}

// ConnectClient is every dieter.v1 service over Connect.
type ConnectClient interface {
	dieterv1connect.MachineServiceClient
	dieterv1connect.StateServiceClient
	dieterv1connect.SettingsServiceClient
	dieterv1connect.ProjectServiceClient
	dieterv1connect.BoardServiceClient
	dieterv1connect.CardServiceClient
	dieterv1connect.ConversationServiceClient
	dieterv1connect.GitServiceClient
	dieterv1connect.FileServiceClient
	dieterv1connect.TerminalServiceClient
	dieterv1connect.ExecutionServiceClient
	dieterv1connect.ScreenServiceClient
	dieterv1connect.ControlServiceClient
	dieterv1connect.ScheduleServiceClient
	dieterv1connect.VaultServiceClient
	dieterv1connect.KVServiceClient
	dieterv1connect.PeerServiceClient
	dieterv1connect.TrustServiceClient
	dieterv1connect.ChannelServiceClient
	dieterv1connect.MailServiceClient
}

type connectClient struct {
	dieterv1connect.MachineServiceClient
	dieterv1connect.StateServiceClient
	dieterv1connect.SettingsServiceClient
	dieterv1connect.ProjectServiceClient
	dieterv1connect.BoardServiceClient
	dieterv1connect.CardServiceClient
	dieterv1connect.ConversationServiceClient
	dieterv1connect.GitServiceClient
	dieterv1connect.FileServiceClient
	dieterv1connect.TerminalServiceClient
	dieterv1connect.ExecutionServiceClient
	dieterv1connect.ScreenServiceClient
	dieterv1connect.ControlServiceClient
	dieterv1connect.ScheduleServiceClient
	dieterv1connect.VaultServiceClient
	dieterv1connect.KVServiceClient
	dieterv1connect.PeerServiceClient
	dieterv1connect.TrustServiceClient
	dieterv1connect.ChannelServiceClient
	dieterv1connect.MailServiceClient
}

// NewConnect returns the Connect clients of every dieter.v1 service at baseURL.
func NewConnect(httpClient connect.HTTPClient, baseURL string, options ...connect.ClientOption) ConnectClient {
	return connectClient{
		MachineServiceClient:      dieterv1connect.NewMachineServiceClient(httpClient, baseURL, options...),
		StateServiceClient:        dieterv1connect.NewStateServiceClient(httpClient, baseURL, options...),
		SettingsServiceClient:     dieterv1connect.NewSettingsServiceClient(httpClient, baseURL, options...),
		ProjectServiceClient:      dieterv1connect.NewProjectServiceClient(httpClient, baseURL, options...),
		BoardServiceClient:        dieterv1connect.NewBoardServiceClient(httpClient, baseURL, options...),
		CardServiceClient:         dieterv1connect.NewCardServiceClient(httpClient, baseURL, options...),
		ConversationServiceClient: dieterv1connect.NewConversationServiceClient(httpClient, baseURL, options...),
		GitServiceClient:          dieterv1connect.NewGitServiceClient(httpClient, baseURL, options...),
		FileServiceClient:         dieterv1connect.NewFileServiceClient(httpClient, baseURL, options...),
		TerminalServiceClient:     dieterv1connect.NewTerminalServiceClient(httpClient, baseURL, options...),
		ExecutionServiceClient:    dieterv1connect.NewExecutionServiceClient(httpClient, baseURL, options...),
		ScreenServiceClient:       dieterv1connect.NewScreenServiceClient(httpClient, baseURL, options...),
		ControlServiceClient:      dieterv1connect.NewControlServiceClient(httpClient, baseURL, options...),
		ScheduleServiceClient:     dieterv1connect.NewScheduleServiceClient(httpClient, baseURL, options...),
		VaultServiceClient:        dieterv1connect.NewVaultServiceClient(httpClient, baseURL, options...),
		KVServiceClient:           dieterv1connect.NewKVServiceClient(httpClient, baseURL, options...),
		PeerServiceClient:         dieterv1connect.NewPeerServiceClient(httpClient, baseURL, options...),
		TrustServiceClient:        dieterv1connect.NewTrustServiceClient(httpClient, baseURL, options...),
		ChannelServiceClient:      dieterv1connect.NewChannelServiceClient(httpClient, baseURL, options...),
		MailServiceClient:         dieterv1connect.NewMailServiceClient(httpClient, baseURL, options...),
	}
}
