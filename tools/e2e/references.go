package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Source reference validation catches renamed classes/methods before any build.
// Native assertions remain compiled and executed by the platform test runner.
func validateReferences(root string, cases []Case) error {
	sources := map[string]string{}
	for _, directory := range []string{"apps/android/app/src/androidTest", "apps/ios/DieterIOSUITests", "apps/ios/DieterIOSNativeTests"} {
		err := filepath.WalkDir(filepath.Join(root, directory), func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !(strings.HasSuffix(path, ".kt") || strings.HasSuffix(path, ".java") || strings.HasSuffix(path, ".swift")) {
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			source := string(data)
			prefix := ""
			if match := regexp.MustCompile(`(?m)^package\s+([\w.]+)`).FindStringSubmatch(source); len(match) > 0 {
				prefix = match[1] + "."
			}
			for _, match := range regexp.MustCompile(`\bclass\s+(\w+)`).FindAllStringSubmatch(source, -1) {
				sources[prefix+match[1]] = source
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	for _, c := range cases {
		if c.Platform == "mac" && c.Native != nil {
			names := map[string]string{"core": "Native", "board": "Native", "conversation": "Conversation", "machine": "Machine", "sidebar": "SidebarNavigation", "terminal": "Terminal", "island": "Island", "workspace": "Workspace", "inbox": "Inbox"}
			name := names[c.Native.Suite] + "UISmokeRunner"
			data, err := os.ReadFile(filepath.Join(root, "apps/mac/Sources/DieterMac/Testing", name+".swift"))
			if err != nil || !strings.Contains(string(data), "enum "+name) {
				return fmt.Errorf("%s: Mac suite %s has no runner source", c.Source, c.Native.Suite)
			}
			continue
		}
		if c.Native == nil {
			continue
		}
		source, ok := sources[c.Native.Class]
		if !ok {
			return fmt.Errorf("%s: native class %s has no source", c.Source, c.Native.Class)
		}
		for _, method := range c.Native.Methods {
			declaration := `\b(?:fun|func|void)\s+` + regexp.QuoteMeta(method) + `\s*\(`
			if !regexp.MustCompile(declaration).MatchString(source) {
				return fmt.Errorf("%s: native method %s#%s has no source", c.Source, c.Native.Class, method)
			}
		}
	}
	return nil
}
