set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

core_root := "apps/core"
sdk := env_var_or_default("ANDROID_HOME", env_var_or_default("ANDROID_SDK_ROOT", home_directory() / "Library/Android/sdk"))
java := env_var_or_default("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
gradle := 'ANDROID_HOME="' + sdk + '" JAVA_HOME="' + java + '" ' + core_root + '/gradlew --project-dir ' + core_root + ' --console=plain'

# List the shared Kotlin core commands.
default:
    @just --justfile just/core.just --list

# Run the core's unit tests and its end-to-end tests against isolated gateways and daemons.
test *args:
    {{ gradle }} :shared:jvmTest {{ args }}

# Run the common tests natively on macOS and assemble the DieterShared XCFramework.
native-test:
    {{ gradle }} :shared:macosArm64Test :apple:assembleDieterSharedDebugXCFramework

# Drive DieterShared from Swift through the Mac app's bridge (SharedCore)
# against an isolated gateway and daemon.
apple-test: native-test
    just mac core-test

# Run every shared-core check this host supports.
check: test
    if [[ "$(uname -s)" == Darwin ]]; then just core apple-test; fi
