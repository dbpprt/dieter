package com.getdieter.core.api

import com.getdieter.api.v1.BoardServiceClient
import com.getdieter.api.v1.CardServiceClient
import com.getdieter.api.v1.ChannelServiceClient
import com.getdieter.api.v1.ControlServiceClient
import com.getdieter.api.v1.ConversationServiceClient
import com.getdieter.api.v1.ExecutionServiceClient
import com.getdieter.api.v1.FileServiceClient
import com.getdieter.api.v1.GitServiceClient
import com.getdieter.api.v1.GrpcBoardServiceClient
import com.getdieter.api.v1.GrpcCardServiceClient
import com.getdieter.api.v1.GrpcChannelServiceClient
import com.getdieter.api.v1.GrpcControlServiceClient
import com.getdieter.api.v1.GrpcConversationServiceClient
import com.getdieter.api.v1.GrpcExecutionServiceClient
import com.getdieter.api.v1.GrpcFileServiceClient
import com.getdieter.api.v1.GrpcGitServiceClient
import com.getdieter.api.v1.GrpcKVServiceClient
import com.getdieter.api.v1.GrpcMachineServiceClient
import com.getdieter.api.v1.GrpcPeerServiceClient
import com.getdieter.api.v1.GrpcProjectServiceClient
import com.getdieter.api.v1.GrpcScheduleServiceClient
import com.getdieter.api.v1.GrpcScreenServiceClient
import com.getdieter.api.v1.GrpcSettingsServiceClient
import com.getdieter.api.v1.GrpcStateServiceClient
import com.getdieter.api.v1.GrpcTerminalServiceClient
import com.getdieter.api.v1.GrpcTrustServiceClient
import com.getdieter.api.v1.GrpcVaultServiceClient
import com.getdieter.api.v1.KVServiceClient
import com.getdieter.api.v1.MachineServiceClient
import com.getdieter.api.v1.PeerServiceClient
import com.getdieter.api.v1.ProjectServiceClient
import com.getdieter.api.v1.ScheduleServiceClient
import com.getdieter.api.v1.ScreenServiceClient
import com.getdieter.api.v1.SettingsServiceClient
import com.getdieter.api.v1.StateServiceClient
import com.getdieter.api.v1.TerminalServiceClient
import com.getdieter.api.v1.TrustServiceClient
import com.getdieter.api.v1.VaultServiceClient
import com.squareup.wire.GrpcClient

/**
 * Every dieter.v1 service of one daemon. The schema keeps one service per domain; the core
 * addresses a daemon's API as a whole through this interface.
 */
interface DaemonApi :
    MachineServiceClient,
    StateServiceClient,
    SettingsServiceClient,
    ProjectServiceClient,
    BoardServiceClient,
    CardServiceClient,
    ConversationServiceClient,
    GitServiceClient,
    FileServiceClient,
    TerminalServiceClient,
    ExecutionServiceClient,
    ScreenServiceClient,
    ControlServiceClient,
    ScheduleServiceClient,
    VaultServiceClient,
    KVServiceClient,
    PeerServiceClient,
    TrustServiceClient,
    ChannelServiceClient

/** [DaemonApi] over Wire's generated clients, all sharing [client]'s channel. */
class GrpcDaemonApi(client: GrpcClient) :
    DaemonApi,
    MachineServiceClient by GrpcMachineServiceClient(client),
    StateServiceClient by GrpcStateServiceClient(client),
    SettingsServiceClient by GrpcSettingsServiceClient(client),
    ProjectServiceClient by GrpcProjectServiceClient(client),
    BoardServiceClient by GrpcBoardServiceClient(client),
    CardServiceClient by GrpcCardServiceClient(client),
    ConversationServiceClient by GrpcConversationServiceClient(client),
    GitServiceClient by GrpcGitServiceClient(client),
    FileServiceClient by GrpcFileServiceClient(client),
    TerminalServiceClient by GrpcTerminalServiceClient(client),
    ExecutionServiceClient by GrpcExecutionServiceClient(client),
    ScreenServiceClient by GrpcScreenServiceClient(client),
    ControlServiceClient by GrpcControlServiceClient(client),
    ScheduleServiceClient by GrpcScheduleServiceClient(client),
    VaultServiceClient by GrpcVaultServiceClient(client),
    KVServiceClient by GrpcKVServiceClient(client),
    PeerServiceClient by GrpcPeerServiceClient(client),
    TrustServiceClient by GrpcTrustServiceClient(client),
    ChannelServiceClient by GrpcChannelServiceClient(client)
