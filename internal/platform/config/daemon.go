package config

// Daemon is the environment configuration of one daemon process. Every
// variable the daemon honours is parsed here, once, after the optional
// DIETER_HOME/.env file has been loaded.
type Daemon struct {
	// HarnessConfig is DIETER_HARNESS_CONFIG: a harness registry YAML used
	// when --harness-config is unset.
	HarnessConfig string
	// ServiceManager is DIETER_SERVICE_MANAGER: the supervisor that started the
	// daemon (homebrew, systemd-user, or managed).
	ServiceManager string
	// NotifySocket is systemd's NOTIFY_SOCKET for readiness notification.
	NotifySocket string
	// MockHarness is DIETER_ENABLE_MOCK_HARNESS=1: register the mock harness.
	// Only isolated fixtures set it.
	MockHarness bool
	// MinimumFreeBytes is DIETER_MIN_FREE_BYTES: the free disk space a turn
	// requires. Nil keeps the release default.
	MinimumFreeBytes *uint64
	// HarnessRuntimeDir is DIETER_HARNESS_RUNTIME_DIR: a staged harness
	// runtime used instead of the embedded one (development only).
	HarnessRuntimeDir string
	// HarnessEnv is DIETER_HARNESS_ENV: additional variable names forwarded
	// to harness workers.
	HarnessEnv []string
	// CodexHome and ClaudeConfigDir are the active provider profiles
	// (CODEX_HOME, CLAUDE_CONFIG_DIR) used for quota account correlation.
	CodexHome, ClaudeConfigDir string
	// CodexAccountHomes and ClaudeAccountHomes are path lists of additional
	// provider profiles (DIETER_CODEX_ACCOUNT_HOMES, DIETER_CLAUDE_ACCOUNT_HOMES).
	CodexAccountHomes, ClaudeAccountHomes string
	// Shell is SHELL, the default shell of new terminals.
	Shell string
	// RemoteDesktop configures screen sharing.
	RemoteDesktop RemoteDesktop
	// Environment is the complete snapshot that child processes inherit.
	Environment Env
}

// RemoteDesktop is the screen-sharing configuration of a daemon.
type RemoteDesktop struct {
	// Source, Helper, and Display are DIETER_REMOTE_DESKTOP_SOURCE (screen or
	// synthetic), DIETER_REMOTE_DESKTOP_HELPER (capture helper path), and
	// DIETER_REMOTE_DESKTOP_DISPLAY (display selector).
	Source, Helper, Display string
	// DisableFEC, DisableFastBitrate, and DisableLongTermReferences are
	// DIETER_SCREEN_FEC=0, DIETER_SCREEN_FAST_BITRATE=0, and DIETER_SCREEN_LTR=0.
	DisableFEC, DisableFastBitrate, DisableLongTermReferences bool
	// ContentAdaptation is DIETER_SCREEN_CONTENT_ADAPTATION=1.
	ContentAdaptation bool
	// FrameOverlap is DIETER_SCREEN_OVERLAP=1.
	FrameOverlap bool
	// VirtualDisplay and VirtualDisable are DIETER_SCREEN_VIRTUAL_DISPLAY=1
	// and DIETER_SCREEN_VIRTUAL_DISABLE=1 (macOS).
	VirtualDisplay, VirtualDisable bool
}

// LoadDaemon parses the daemon configuration from env.
func LoadDaemon(env Env) Daemon {
	return Daemon{
		HarnessConfig:      env.Value("DIETER_HARNESS_CONFIG"),
		ServiceManager:     env.Value("DIETER_SERVICE_MANAGER"),
		NotifySocket:       env.Value("NOTIFY_SOCKET"),
		MockHarness:        env.Enabled("DIETER_ENABLE_MOCK_HARNESS"),
		MinimumFreeBytes:   env.Uint("DIETER_MIN_FREE_BYTES"),
		HarnessRuntimeDir:  env.Value("DIETER_HARNESS_RUNTIME_DIR"),
		HarnessEnv:         env.Fields("DIETER_HARNESS_ENV"),
		CodexHome:          env.Value("CODEX_HOME"),
		ClaudeConfigDir:    env.Value("CLAUDE_CONFIG_DIR"),
		CodexAccountHomes:  env.Value("DIETER_CODEX_ACCOUNT_HOMES"),
		ClaudeAccountHomes: env.Value("DIETER_CLAUDE_ACCOUNT_HOMES"),
		Shell:              env.Value("SHELL"),
		RemoteDesktop: RemoteDesktop{
			Source:                    env.Value("DIETER_REMOTE_DESKTOP_SOURCE"),
			Helper:                    env.Value("DIETER_REMOTE_DESKTOP_HELPER"),
			Display:                   env.Value("DIETER_REMOTE_DESKTOP_DISPLAY"),
			DisableFEC:                !env.NotDisabled("DIETER_SCREEN_FEC"),
			DisableFastBitrate:        !env.NotDisabled("DIETER_SCREEN_FAST_BITRATE"),
			DisableLongTermReferences: !env.NotDisabled("DIETER_SCREEN_LTR"),
			ContentAdaptation:         env.Enabled("DIETER_SCREEN_CONTENT_ADAPTATION"),
			FrameOverlap:              env.Enabled("DIETER_SCREEN_OVERLAP"),
			VirtualDisplay:            env.Enabled("DIETER_SCREEN_VIRTUAL_DISPLAY"),
			VirtualDisable:            env.Enabled("DIETER_SCREEN_VIRTUAL_DISABLE"),
		},
		Environment: env,
	}
}

// ServiceHandoff is the activation a re-executed service process inherits.
type ServiceHandoff struct {
	LockFD, Activation string
}

// LoadServiceHandoff reads DIETER_SERVICE_LOCK_FD and DIETER_SERVICE_ACTIVATION.
// It runs before the env file is loaded because only the parent process sets
// them.
func LoadServiceHandoff(env Env) ServiceHandoff {
	return ServiceHandoff{LockFD: env.Value(ServiceLockFDVar), Activation: env.Value(ServiceActivationVar)}
}

// Client is the environment configuration of a CLI process.
type Client struct {
	// Gateway is DIETER_GATEWAY: the gateway origin required when --gateway is
	// unset.
	Gateway string
	// TurnToken is DIETER_TURN_TOKEN: set by the daemon for commands an agent
	// runs inside its own turn.
	TurnToken string
	// RemoteDesktopHelper is DIETER_REMOTE_DESKTOP_HELPER for `dieter doctor`.
	RemoteDesktopHelper string
	// Shell is SHELL, reported by `dieter doctor`.
	Shell string
	// Environment is the complete snapshot used to install services and
	// spawn children (PATH, XDG_CONFIG_HOME, XDG_RUNTIME_DIR, ...).
	Environment Env
}

// LoadClient parses the CLI configuration from env.
func LoadClient(env Env) Client {
	return Client{
		Gateway:             env.Value("DIETER_GATEWAY"),
		TurnToken:           env.Value("DIETER_TURN_TOKEN"),
		RemoteDesktopHelper: env.Value("DIETER_REMOTE_DESKTOP_HELPER"),
		Shell:               env.Value("SHELL"),
		Environment:         env,
	}
}
