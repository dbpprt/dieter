package dieterclient

import (
	"reflect"
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
)

// Every RPC declared in dieter.v1 must be reachable through both composites.
func TestCompositesCoverEveryDieterService(t *testing.T) {
	t.Parallel()
	grpcMethods := methodSet(reflect.TypeFor[Client]())
	connectMethods := methodSet(reflect.TypeFor[ConnectClient]())
	declared := 0
	protoregistry.GlobalFiles.RangeFilesByPackage("dieter.v1", func(file protoreflect.FileDescriptor) bool {
		services := file.Services()
		for i := 0; i < services.Len(); i++ {
			methods := services.Get(i).Methods()
			for j := 0; j < methods.Len(); j++ {
				name := string(methods.Get(j).Name())
				declared++
				if !grpcMethods[name] || !connectMethods[name] {
					t.Errorf("%s.%s is missing from a composite client", services.Get(i).Name(), name)
				}
			}
		}
		return true
	})
	if declared == 0 || declared != len(grpcMethods) || declared != len(connectMethods) {
		t.Fatalf("declared %d RPCs, composites expose %d gRPC and %d Connect methods", declared, len(grpcMethods), len(connectMethods))
	}
}

func methodSet(t reflect.Type) map[string]bool {
	result := map[string]bool{}
	for i := range t.NumMethod() {
		result[t.Method(i).Name] = true
	}
	return result
}
