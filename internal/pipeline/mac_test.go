package pipeline

import (
	"slices"
	"testing"
)

func TestMacReportsRequireEveryAssertion(t *testing.T) {
	for _, tc := range []struct {
		name   string
		report map[string]string
		want   string
	}{
		{"complete", map[string]string{"prepare.window": "passed", "verify.restore": "passed"}, "passed"},
		{"missing phase", map[string]string{"prepare.window": "passed"}, "failed"},
		{"skip", map[string]string{"prepare.window": "passed", "verify.restore": "skipped"}, "failed"},
		{"extra failure", map[string]string{"prepare.window": "passed", "verify.restore": "passed", "unexpected": "failed: broken"}, "failed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, _ := macReportResult(tc.report, []string{"prepare.window", "verify.restore"})
			if status != tc.want {
				t.Fatal(status)
			}
		})
	}
}
func TestMacNativeContract(t *testing.T) {
	if err := validateMacNative(Native{Suite: "sidebar", Checks: []string{"prepare.window", "verify.restore"}}, "gateway"); err != nil {
		t.Fatal(err)
	}
	for _, n := range []Native{{Suite: "unknown", Checks: []string{"unknown.x"}}, {Suite: "sidebar"}, {Suite: "sidebar", Checks: []string{"wrong.x"}}, {Suite: "sidebar", Checks: []string{"prepare.x", "prepare.x"}}} {
		if validateMacNative(n, "gateway") == nil {
			t.Fatalf("accepted %+v", n)
		}
	}
	if validateMacNative(Native{Suite: "core", Checks: []string{"core.window"}}, "none") == nil {
		t.Fatal("wrong fixture")
	}
	if validateMacNative(Native{Suite: "sidebar", Checks: []string{"prepare.window"}}, "none") == nil {
		t.Fatal("the sidebar needs a gateway for shared navigation")
	}
}
func TestAffectedNativePlatforms(t *testing.T) {
	cases := []Case{{ID: "mac", Platform: "mac"}, {ID: "android", Platform: "android"}}
	for _, tc := range []struct{ path, want string }{{"apps/mac/Sources/DieterMac/UI/WorkspaceSplit.swift", "mac"}, {"apps/android/app/build.gradle.kts", "android"}} {
		got := affected(cases, []string{tc.path})
		if len(got) != 1 || got[0].ID != tc.want {
			t.Fatal(tc, got)
		}
	}
	if len(affected(cases, []string{"api/proto/dieter/v1/dieter.proto"})) != 2 {
		t.Fatal("shared schema must select both")
	}
}

func TestAffectedSharedCore(t *testing.T) {
	cases := []Case{
		{ID: "mac", Platform: "mac"},
		{ID: "android", Platform: "android"},
		{ID: "android-machines", Platform: "android", Components: []string{"machines"}},
		{ID: "ios", Platform: "ios"},
	}
	for _, tc := range []struct {
		path string
		want []string
	}{
		{"apps/core/shared/src/commonMain/kotlin/com/dbpprt/dieter/core/machines/MachineRows.kt", []string{"mac", "android", "android-machines", "ios"}},
		{"apps/core/shared/src/jvmSharedMain/kotlin/com/dbpprt/dieter/core/platform/OkHttpTransport.kt", []string{"mac", "android", "android-machines", "ios"}},
		{"apps/core/model/src/commonMain/proto/dieter/client/v1/client.proto", []string{"mac", "android", "android-machines", "ios"}},
		{"apps/core/gradle/libs.versions.toml", []string{"mac", "android", "android-machines", "ios"}},
		{"apps/core/build-logic/src/main/kotlin/dieter.kmp.gradle.kts", []string{"mac", "android", "android-machines", "ios"}},
		{"apps/core/apple/src/appleMain/kotlin/com/dbpprt/dieter/shared/DieterShared.kt", []string{"mac", "ios"}},
		{"apps/core/apple/build.gradle.kts", []string{"mac", "ios"}},
		{"apps/core/shared/src/appleMain/kotlin/com/dbpprt/dieter/core/runtime/CoreLock.apple.kt", []string{"mac", "ios"}},
		{"apps/core/shared/src/commonTest/kotlin/com/dbpprt/dieter/core/machines/MachineRowsTest.kt", nil},
		{"apps/core/shared/src/jvmTest/kotlin/com/dbpprt/dieter/core/OutboxEndToEndTest.kt", nil},
		{"apps/core/testing/src/jvmMain/kotlin/com/dbpprt/dieter/core/testing/IsolatedGateway.kt", nil},
		{"apps/core/README.md", nil},
		// The Apple apps' side of the core reaches both Apple apps.
		{"apps/mac/Sources/SharedCore/CoreHost.swift", []string{"mac", "ios"}},
		{"apps/mac/Sources/DieterTransport/ControlRTCBridge.swift", []string{"mac", "ios"}},
		{"fastlane/lib/dieter/platforms/framework.rb", []string{"mac", "ios"}},
		// The iOS adapter tests run in the simulator only.
		{"apps/mac/Tests/DieterIOSTests/IOSCoreAdapterTests.swift", []string{"ios"}},
	} {
		got := []string{}
		for _, c := range affected(cases, []string{tc.path}) {
			got = append(got, c.ID)
		}
		if !slices.Equal(got, tc.want) {
			t.Errorf("%s selected %v, want %v", tc.path, got, tc.want)
		}
	}
}
