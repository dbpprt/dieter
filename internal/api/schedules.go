package api

import (
	"context"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *schedulesAPI) ListSchedules(_ context.Context, request *dieterv1.ListSchedulesRequest) (*dieterv1.SchedulesResponse, error) {
	page, err := api.server.schedules.ListPage(request.GetProjectId(), int(request.GetPageSize()), request.GetPageToken())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.SchedulesResponse{NextPageToken: page.NextPageToken, TotalCount: int32(page.TotalCount)}
	for _, value := range page.Items {
		result.Schedules = append(result.Schedules, protoSchedule(value))
	}
	return result, nil
}

func (api *schedulesAPI) GetSchedule(_ context.Context, request *dieterv1.ScheduleRef) (*dieterv1.Schedule, error) {
	value, err := api.server.store.Schedules.Resolve(request.GetScheduleId())
	if err != nil {
		return nil, err
	}
	return protoSchedule(value), nil
}

func (api *schedulesAPI) PreviewSchedule(_ context.Context, request *dieterv1.PreviewScheduleRequest) (*dieterv1.SchedulePreview, error) {
	values, err := api.server.schedules.Preview(request.GetCron(), request.GetTimezone(), int(request.GetCount()))
	if err != nil {
		return nil, err
	}
	return &dieterv1.SchedulePreview{Times: values}, nil
}

func (api *schedulesAPI) CreateSchedule(ctx context.Context, request *dieterv1.SaveScheduleRequest) (*dieterv1.Schedule, error) {
	input, err := scheduleInput(request)
	if err != nil {
		return nil, err
	}
	if input.MailAccess {
		caller, err := api.server.capabilityCaller(ctx)
		if err == nil {
			err = caller.grantMail(true)
		}
		if err != nil {
			return nil, err
		}
	}
	value, err := api.server.schedules.Create(input)
	if err != nil {
		return nil, err
	}
	return protoSchedule(value), nil
}

func (api *schedulesAPI) UpdateSchedule(ctx context.Context, request *dieterv1.SaveScheduleRequest) (*dieterv1.Schedule, error) {
	input, err := scheduleInput(request)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(request.GetScheduleId()) == "" {
		return nil, fault.New(fault.Invalid, "schedule ID is required")
	}
	if input.MailAccess {
		// Only turning mail on is a grant; an agent may keep the current value.
		caller, err := api.server.capabilityCaller(ctx)
		if err != nil {
			return nil, err
		}
		if caller.agent {
			current, err := api.server.store.Schedules.Resolve(request.GetScheduleId())
			if err != nil {
				return nil, err
			}
			if err := caller.grantMail(!current.MailAccess); err != nil {
				return nil, err
			}
		}
	}
	value, err := api.server.schedules.Update(request.GetScheduleId(), input)
	if err != nil {
		return nil, err
	}
	return protoSchedule(value), nil
}

func (api *schedulesAPI) DeleteSchedule(_ context.Context, request *dieterv1.ScheduleRef) (*emptypb.Empty, error) {
	if err := api.server.store.Schedules.Delete(request.GetScheduleId()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

func (api *schedulesAPI) RunSchedule(_ context.Context, request *dieterv1.ScheduleRef) (*dieterv1.ScheduleRun, error) {
	value, err := api.server.schedules.RunNow(request.GetScheduleId())
	if err != nil {
		return nil, err
	}
	return protoScheduleRun(value), nil
}

func (api *schedulesAPI) SetScheduleEnabled(_ context.Context, request *dieterv1.SetScheduleEnabledRequest) (*dieterv1.Schedule, error) {
	value, err := api.server.schedules.SetEnabled(request.GetScheduleId(), request.GetEnabled())
	if err != nil {
		return nil, err
	}
	return protoSchedule(value), nil
}

func (api *schedulesAPI) ListScheduleRuns(_ context.Context, request *dieterv1.ListScheduleRunsRequest) (*dieterv1.ScheduleRunsResponse, error) {
	page, err := api.server.store.Schedules.ListRunsPage(request.GetScheduleId(), int(request.GetPageSize()), request.GetPageToken())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.ScheduleRunsResponse{NextPageToken: page.NextPageToken}
	for _, value := range page.Items {
		result.Runs = append(result.Runs, protoScheduleRun(value))
	}
	return result, nil
}
