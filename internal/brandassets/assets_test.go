package brandassets

import (
	"encoding/json"
	"image"
	_ "image/png"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestBrandPackIsWiredIntoReleaseSurfaces(t *testing.T) {
	root := repositoryRoot(t)

	for _, name := range []string{
		"assets/brand/README.md",
		"assets/brand/brand-guide.html",
		"assets/brand/theme.css",
		"assets/brand/tokens.json",
		"assets/brand/manifest.webmanifest",
		"assets/brand/assets/Nauclio.icns",
		"assets/brand/assets/svg/mark.svg",
		"assets/brand/assets/svg/mark-mono-dark.svg",
		"assets/brand/assets/svg/mark-mono-light.svg",
		"assets/brand/assets/svg/favicon.svg",
		"assets/brand/assets/svg/logo-horizontal-dark.svg",
		"assets/brand/assets/svg/logo-horizontal-light.svg",
		"assets/brand/assets/social/og-image.svg",
	} {
		requireFile(t, filepath.Join(root, name))
	}

	images := map[string]image.Point{
		"assets/brand/assets/png/app-icon-dark-1024.png":                         {X: 1024, Y: 1024},
		"assets/brand/assets/png/app-icon-light-1024.png":                        {X: 1024, Y: 1024},
		"assets/brand/assets/png/favicon-32.png":                                 {X: 32, Y: 32},
		"assets/brand/assets/social/og-image.png":                                {X: 1200, Y: 630},
		"apps/android/app/src/main/res/drawable-nodpi/ic_nauclio_foreground.png": {X: 1024, Y: 1024},
		"apps/android/app/src/main/res/drawable-nodpi/ic_nauclio_monochrome.png": {X: 1024, Y: 1024},
		"apps/android/app/src/main/res/drawable-nodpi/ic_notification.png":       {X: 192, Y: 192},
		"apps/android/app/src/main/res/mipmap-mdpi/ic_launcher.png":              {X: 48, Y: 48},
		"apps/android/app/src/main/res/mipmap-hdpi/ic_launcher.png":              {X: 72, Y: 72},
		"apps/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png":             {X: 96, Y: 96},
		"apps/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png":            {X: 144, Y: 144},
		"apps/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png":           {X: 192, Y: 192},
	}
	for name, want := range images {
		assertImageSize(t, filepath.Join(root, name), want)
	}

	assertContains(t, filepath.Join(root, "README.md"),
		"One command deck. Every coding agent.",
		"assets/brand/assets/social/og-image.png",
	)
	assertContains(t, filepath.Join(root, "apps/android/app/src/main/AndroidManifest.xml"),
		`android:icon="@mipmap/ic_launcher"`,
		`android:roundIcon="@mipmap/ic_launcher_round"`,
	)
	assertContains(t, filepath.Join(root, "apps/android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml"),
		`android:drawable="@drawable/ic_nauclio_foreground_layer"`,
		`android:drawable="@drawable/ic_nauclio_monochrome_layer"`,
	)
	assertContains(t, filepath.Join(root, "apps/android/app/src/main/java/com/dbpprt/nauclio/ui/theme/Theme.kt"),
		"val NauclioCobalt = Color(0xFF2563EB)",
		"val NauclioAegean = Color(0xFF22D3EE)",
		"val NauclioSeafoam = Color(0xFF5EEAD4)",
	)
	assertContains(t, filepath.Join(root, "apps/mac/scripts/build.sh"),
		`$BRAND_ROOT/assets/Nauclio.icns`,
		`$BRAND_ROOT/assets/png/app-icon-dark-1024.png`,
		`$BRAND_ROOT/assets/png/favicon-32.png`,
	)
	assertContains(t, filepath.Join(root, "apps/mac/Sources/NauclioMac/UI/NauclioTheme.swift"),
		"Color(rgb: 0x2563EB)",
		"Color(rgb: 0x22D3EE)",
		"Color(rgb: 0x5EEAD4)",
	)

	tokensData, err := os.ReadFile(filepath.Join(root, "assets/brand/tokens.json"))
	if err != nil {
		t.Fatal(err)
	}
	var tokens map[string]any
	if err := json.Unmarshal(tokensData, &tokens); err != nil {
		t.Fatalf("parse tokens.json: %v", err)
	}
	for _, value := range []string{"#071426", "#2563EB", "#22D3EE", "#5EEAD4"} {
		if !strings.Contains(string(tokensData), value) {
			t.Errorf("tokens.json does not contain required brand color %s", value)
		}
	}

	icns, err := os.ReadFile(filepath.Join(root, "assets/brand/assets/Nauclio.icns"))
	if err != nil {
		t.Fatal(err)
	}
	if len(icns) < 8 || string(icns[:4]) != "icns" {
		t.Fatal("Nauclio.icns does not have a valid icns header")
	}
}

func repositoryRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
}

func requireFile(t *testing.T, path string) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("required brand file %s: %v", path, err)
	}
	if info.IsDir() || info.Size() == 0 {
		t.Fatalf("required brand file %s is empty or is a directory", path)
	}
}

func assertImageSize(t *testing.T, path string, want image.Point) {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	config, _, err := image.DecodeConfig(file)
	if err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	got := image.Pt(config.Width, config.Height)
	if got != want {
		t.Errorf("%s dimensions = %v, want %v", path, got, want)
	}
}

func assertContains(t *testing.T, path string, values ...string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range values {
		if !strings.Contains(string(data), value) {
			t.Errorf("%s does not contain %q", path, value)
		}
	}
}
