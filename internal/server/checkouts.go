package server

import (
	"connectrpc.com/connect"
	"context"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"google.golang.org/protobuf/types/known/emptypb"
)

func protoCheckout(value model.Checkout) *dieterv1.Checkout {
	result := &dieterv1.Checkout{Id: value.ID, ProjectId: value.ProjectID, DaemonId: value.DaemonID, Name: value.Name, Path: value.Path, Detached: value.Detached}
	for _, command := range value.ValidationCommands {
		result.ValidationCommands = append(result.ValidationCommands, protoValidationCommand(command))
	}
	return result
}
func (api *grpcAPI) AttachCheckout(ctx context.Context, r *dieterv1.AttachCheckoutRequest) (*dieterv1.Checkout, error) {
	value, err := api.server.store.AttachCheckout(r.GetProjectId(), r.GetPath(), r.GetName())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCheckout(value), nil
}
func (api *grpcAPI) DetachCheckout(ctx context.Context, r *dieterv1.CheckoutRef) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, grpcFailure(api.server.store.DetachCheckout(r.GetCheckoutId()))
}
func (api *grpcAPI) ListCheckouts(ctx context.Context, r *dieterv1.ProjectRef) (*dieterv1.CheckoutsResponse, error) {
	values, err := api.server.store.ListCheckouts(r.GetProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.CheckoutsResponse{}
	for _, value := range values {
		result.Checkouts = append(result.Checkouts, protoCheckout(value))
	}
	return result, nil
}
func (api *connectAPI) AttachCheckout(ctx context.Context, r *connect.Request[dieterv1.AttachCheckoutRequest]) (*connect.Response[dieterv1.Checkout], error) {
	return connectUnary(ctx, r, api.core.AttachCheckout)
}
func (api *connectAPI) DetachCheckout(ctx context.Context, r *connect.Request[dieterv1.CheckoutRef]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, r, api.core.DetachCheckout)
}
func (api *connectAPI) ListCheckouts(ctx context.Context, r *connect.Request[dieterv1.ProjectRef]) (*connect.Response[dieterv1.CheckoutsResponse], error) {
	return connectUnary(ctx, r, api.core.ListCheckouts)
}

func (api *grpcAPI) ConsolidateProject(ctx context.Context, r *dieterv1.ConsolidateProjectRequest) (*dieterv1.Project, error) {
	value, err := api.server.store.ConsolidateProject(r.GetSourceProjectId(), r.GetDestinationProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoProject(value), nil
}
func (api *connectAPI) ConsolidateProject(ctx context.Context, r *connect.Request[dieterv1.ConsolidateProjectRequest]) (*connect.Response[dieterv1.Project], error) {
	return connectUnary(ctx, r, api.core.ConsolidateProject)
}
