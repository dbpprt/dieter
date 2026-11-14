package api

import (
	"context"
	"net/http"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
)

// Each handler type implements one dieter.v1 service over the shared Server.
type (
	machineAPI       struct{ server *Server }
	stateAPI         struct{ server *Server }
	settingsAPI      struct{ server *Server }
	projectsAPI      struct{ server *Server }
	boardsAPI        struct{ server *Server }
	cardsAPI         struct{ server *Server }
	conversationsAPI struct{ server *Server }
	gitAPI           struct{ server *Server }
	filesAPI         struct{ server *Server }
	terminalsAPI     struct{ server *Server }
	executionsAPI    struct{ server *Server }
	screensAPI       struct{ server *Server }
	controlAPI       struct{ server *Server }
	schedulesAPI     struct{ server *Server }
	vaultAPI         struct{ server *Server }
	kvAPI            struct{ server *Server }
	peerAPI          struct{ server *Server }
	trustAPI         struct{ server *Server }
	channelsAPI      struct{ server *Server }
	mailAPI          struct{ server *Server }
)

// service composes every domain handler: the whole daemon API, Dieter's only
// network application boundary. connect-go serves each service over Connect
// and native gRPC on the same handler.
type service struct {
	server *Server
	*machineAPI
	*stateAPI
	*settingsAPI
	*projectsAPI
	*boardsAPI
	*cardsAPI
	*conversationsAPI
	*gitAPI
	*filesAPI
	*terminalsAPI
	*executionsAPI
	*screensAPI
	*controlAPI
	*schedulesAPI
	*vaultAPI
	*kvAPI
	*peerAPI
	*trustAPI
	*channelsAPI
	*mailAPI
}

var (
	_ dieterv1connect.MachineServiceHandler      = (*machineAPI)(nil)
	_ dieterv1connect.StateServiceHandler        = (*stateAPI)(nil)
	_ dieterv1connect.SettingsServiceHandler     = (*settingsAPI)(nil)
	_ dieterv1connect.ProjectServiceHandler      = (*projectsAPI)(nil)
	_ dieterv1connect.BoardServiceHandler        = (*boardsAPI)(nil)
	_ dieterv1connect.CardServiceHandler         = (*cardsAPI)(nil)
	_ dieterv1connect.ConversationServiceHandler = (*conversationsAPI)(nil)
	_ dieterv1connect.GitServiceHandler          = (*gitAPI)(nil)
	_ dieterv1connect.FileServiceHandler         = (*filesAPI)(nil)
	_ dieterv1connect.TerminalServiceHandler     = (*terminalsAPI)(nil)
	_ dieterv1connect.ExecutionServiceHandler    = (*executionsAPI)(nil)
	_ dieterv1connect.ScreenServiceHandler       = (*screensAPI)(nil)
	_ dieterv1connect.ControlServiceHandler      = (*controlAPI)(nil)
	_ dieterv1connect.ScheduleServiceHandler     = (*schedulesAPI)(nil)
	_ dieterv1connect.VaultServiceHandler        = (*vaultAPI)(nil)
	_ dieterv1connect.KVServiceHandler           = (*kvAPI)(nil)
	_ dieterv1connect.PeerServiceHandler         = (*peerAPI)(nil)
	_ dieterv1connect.TrustServiceHandler        = (*trustAPI)(nil)
	_ dieterv1connect.ChannelServiceHandler      = (*channelsAPI)(nil)
	_ dieterv1connect.MailServiceHandler         = (*mailAPI)(nil)
)

func newService(s *Server) *service {
	return &service{
		server: s, machineAPI: &machineAPI{s}, stateAPI: &stateAPI{s}, settingsAPI: &settingsAPI{s},
		projectsAPI: &projectsAPI{s}, boardsAPI: &boardsAPI{s}, cardsAPI: &cardsAPI{s},
		conversationsAPI: &conversationsAPI{s}, gitAPI: &gitAPI{s}, filesAPI: &filesAPI{s},
		terminalsAPI: &terminalsAPI{s}, executionsAPI: &executionsAPI{s}, screensAPI: &screensAPI{s},
		controlAPI: &controlAPI{s}, schedulesAPI: &schedulesAPI{s}, vaultAPI: &vaultAPI{s},
		kvAPI: &kvAPI{s}, peerAPI: &peerAPI{s}, trustAPI: &trustAPI{s}, channelsAPI: &channelsAPI{s},
		mailAPI: &mailAPI{s},
	}
}

// handlers mounts every dieter.v1 service with the same handler options.
func (svc *service) handlers(options ...connect.HandlerOption) map[string]http.Handler {
	result := map[string]http.Handler{}
	add := func(path string, handler http.Handler) { result[path] = handler }
	add(dieterv1connect.NewMachineServiceHandler(svc.machineAPI, options...))
	add(dieterv1connect.NewStateServiceHandler(svc.stateAPI, options...))
	add(dieterv1connect.NewSettingsServiceHandler(svc.settingsAPI, options...))
	add(dieterv1connect.NewProjectServiceHandler(svc.projectsAPI, options...))
	add(dieterv1connect.NewBoardServiceHandler(svc.boardsAPI, options...))
	add(dieterv1connect.NewCardServiceHandler(svc.cardsAPI, options...))
	add(dieterv1connect.NewConversationServiceHandler(svc.conversationsAPI, options...))
	add(dieterv1connect.NewGitServiceHandler(svc.gitAPI, options...))
	add(dieterv1connect.NewFileServiceHandler(svc.filesAPI, options...))
	add(dieterv1connect.NewTerminalServiceHandler(svc.terminalsAPI, options...))
	add(dieterv1connect.NewExecutionServiceHandler(svc.executionsAPI, options...))
	add(dieterv1connect.NewScreenServiceHandler(svc.screensAPI, options...))
	add(dieterv1connect.NewControlServiceHandler(svc.controlAPI, options...))
	add(dieterv1connect.NewScheduleServiceHandler(svc.schedulesAPI, options...))
	add(dieterv1connect.NewVaultServiceHandler(svc.vaultAPI, options...))
	add(dieterv1connect.NewKVServiceHandler(svc.kvAPI, options...))
	add(dieterv1connect.NewPeerServiceHandler(svc.peerAPI, options...))
	add(dieterv1connect.NewTrustServiceHandler(svc.trustAPI, options...))
	add(dieterv1connect.NewChannelServiceHandler(svc.channelsAPI, options...))
	add(dieterv1connect.NewMailServiceHandler(svc.mailAPI, options...))
	return result
}

// requestHeader returns one request header of the RPC in ctx.
func requestHeader(ctx context.Context, name string) string {
	if call, ok := connect.CallInfoForHandlerContext(ctx); ok {
		return call.RequestHeader().Get(name)
	}
	return ""
}

// operatorContext records the operator subject the DirectServer forwarded. connect-go
// terminates the gRPC HTTP/2 request, so transport metadata is available as
// headers rather than grpc/metadata on this boundary.
func operatorContext(ctx context.Context) context.Context {
	return context.WithValue(ctx, remoteDesktopOperatorKey{}, requestHeader(ctx, operatorSubjectMetadata))
}

// vaultContext records the operator, device, and agent turn of a vault call.
func vaultContext(ctx context.Context) context.Context {
	return context.WithValue(ctx, vaultHeadersKey{}, vaultHeaders{
		operator: requestHeader(ctx, operatorSubjectMetadata), device: requestHeader(ctx, deviceIDMetadata), token: requestHeader(ctx, turnTokenMetadata),
	})
}
