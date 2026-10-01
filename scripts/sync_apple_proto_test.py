from pathlib import Path
import tempfile
import unittest
import sync_apple_proto


class AppleProtoTests(unittest.TestCase):
    def test_authoritative_import_transform_is_atomic_and_unchanged_copy_is_reused(self):
        with tempfile.TemporaryDirectory(prefix="dieter schema spaces ") as directory:
            root = Path(directory)
            for source in sync_apple_proto.SCHEMAS:
                file = root / "api/proto" / source
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('syntax = "proto3";\nimport "dieter/gateway/v1/gateway.proto";\n')
            self.assertFalse(sync_apple_proto.sync(root, check=True))
            self.assertFalse(sync_apple_proto.sync(root))
            target = root / "apps/mac/Sources/DieterAPI/dieter.proto"
            self.assertIn('import "gateway.proto";', target.read_text())
            before = target.stat().st_mtime_ns
            self.assertTrue(sync_apple_proto.sync(root))
            self.assertTrue(sync_apple_proto.sync(root, check=True))
            self.assertEqual(before, target.stat().st_mtime_ns)
            (root / "api/proto/dieter/v1/dieter.proto").write_text("updated authoritative schema")
            self.assertFalse(sync_apple_proto.sync(root, check=True))
            self.assertEqual(before, target.stat().st_mtime_ns)

    def test_client_schemas_are_copied_with_package_local_imports_and_stale_copies_removed(self):
        with tempfile.TemporaryDirectory(prefix="dieter client schema ") as directory:
            root = Path(directory)
            for source in sync_apple_proto.SCHEMAS:
                file = root / "api/proto" / source
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('syntax = "proto3";\n')
            client = root / sync_apple_proto.CLIENT_SCHEMA_DIR
            client.mkdir(parents=True)
            (client / "client.proto").write_text(
                'import "dieter/v1/dieter.proto";\nimport "dieter/client/v1/files.proto";\n')
            (client / "files.proto").write_text('import "dieter/v1/dieter.proto";\n')
            self.assertFalse(sync_apple_proto.sync(root))
            copies = root / "apps/mac/Sources/DieterAPI/client"
            self.assertEqual(
                'import "dieter.proto";\nimport "client/files.proto";\n', (copies / "client.proto").read_text())
            self.assertTrue(sync_apple_proto.sync(root, check=True))
            (client / "files.proto").unlink()
            self.assertFalse(sync_apple_proto.sync(root, check=True))
            self.assertTrue((copies / "files.proto").exists(), "a check never deletes")
            self.assertFalse(sync_apple_proto.sync(root))
            self.assertFalse((copies / "files.proto").exists())
            self.assertTrue(sync_apple_proto.sync(root, check=True))


if __name__ == "__main__": unittest.main()
