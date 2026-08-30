package server

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

// TestGRPCAPIImplementsEveryDeclaredRPC keeps one explicit protobuf core for
// every operation. The Connect/gRPC network adapter delegates to this core, so
// adding a native-client RPC cannot silently bypass the direct/relay backend.
func TestGRPCAPIImplementsEveryDeclaredRPC(t *testing.T) {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate server package")
	}
	directory := filepath.Dir(filename)
	packages, err := parser.ParseDir(token.NewFileSet(), directory, func(info os.FileInfo) bool {
		return filepath.Ext(info.Name()) == ".go" && !strings.HasSuffix(info.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatal(err)
	}
	implemented := map[string]bool{}
	for _, file := range packages["server"].Files {
		for _, declaration := range file.Decls {
			function, ok := declaration.(*ast.FuncDecl)
			if !ok || function.Recv == nil || len(function.Recv.List) != 1 {
				continue
			}
			pointer, ok := function.Recv.List[0].Type.(*ast.StarExpr)
			if !ok {
				continue
			}
			name, ok := pointer.X.(*ast.Ident)
			if ok && name.Name == "grpcAPI" {
				implemented[function.Name.Name] = true
			}
		}
	}
	service := dieterv1.File_dieter_v1_dieter_proto.Services().ByName("DieterService")
	if service == nil {
		t.Fatal("DieterService descriptor is missing")
	}
	var missing []string
	for index := 0; index < service.Methods().Len(); index++ {
		method := string(service.Methods().Get(index).Name())
		if !implemented[method] {
			missing = append(missing, method)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		t.Fatalf("grpcAPI lacks explicit implementations for declared RPCs: %v", missing)
	}
}
