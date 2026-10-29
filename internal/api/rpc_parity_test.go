package api

import (
	"reflect"
	"sort"
	"strings"
	"testing"

	_ "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
)

// TestGRPCAPIImplementsEveryDeclaredRPC keeps one explicit implementation for
// every operation. The service composes only domain handler types and never
// embeds a generated Unimplemented handler, so every declared RPC must be
// defined by exactly one domain; Connect and gRPC serve the same methods for
// loopback, direct-TLS, and relay routes.
func TestGRPCAPIImplementsEveryDeclaredRPC(t *testing.T) {
	t.Parallel()
	composed := reflect.TypeOf(service{})
	owners := map[string][]string{}
	for index := 0; index < composed.NumField(); index++ {
		field := composed.Field(index)
		if !field.Anonymous {
			continue
		}
		if strings.Contains(field.Type.String(), "Unimplemented") {
			t.Fatalf("service embeds %s; implement RPCs explicitly", field.Type)
		}
		for method := 0; method < field.Type.NumMethod(); method++ {
			name := field.Type.Method(method).Name
			owners[name] = append(owners[name], field.Type.Elem().Name())
		}
	}
	var missing, ambiguous []string
	declared := 0
	protoregistry.GlobalFiles.RangeFilesByPackage("dieter.v1", func(file protoreflect.FileDescriptor) bool {
		for service := 0; service < file.Services().Len(); service++ {
			methods := file.Services().Get(service).Methods()
			for index := 0; index < methods.Len(); index++ {
				method := string(methods.Get(index).Name())
				declared++
				switch len(owners[method]) {
				case 0:
					missing = append(missing, method)
				case 1:
				default:
					ambiguous = append(ambiguous, method+" "+strings.Join(owners[method], ","))
				}
			}
		}
		return true
	})
	if declared == 0 {
		t.Fatal("no dieter.v1 services are registered")
	}
	sort.Strings(missing)
	if len(missing) > 0 || len(ambiguous) > 0 {
		t.Fatalf("domain handlers lack declared RPCs %v; defined by several domains: %v", missing, ambiguous)
	}
}
