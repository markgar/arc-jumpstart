import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("check_sql_media", Path(__file__).with_name("check-sql-media.py"))
media = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media)


class DownloadChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "test.iso"
        self.data = bytes(16 * 2048 + 1) + b"CD001" + bytes(2048)

    def run_download(self, data=None, length=None, digest=None):
        data = self.data if data is None else data
        response = io.BytesIO(data)
        response.url = "https://download.microsoft.com/test.iso"
        response.headers = {"Content-Length": str(len(data) if length is None else length)}
        with patch.object(media.urllib.request, "urlopen", return_value=response), contextlib.redirect_stdout(io.StringIO()):
            media.download(response.url, self.output, "iso", digest)

    def test_full_iso_download(self):
        self.run_download()
        self.assertEqual(self.output.read_bytes(), self.data)
        self.assertEqual(list(self.output.parent.glob("*.partial")), [])

    def test_reject_html(self):
        with self.assertRaisesRegex(ValueError, "volume descriptor"):
            self.run_download(b"<html>not SQL media</html>")
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob("*.partial")), [])

    def test_reject_incomplete_download(self):
        with self.assertRaisesRegex(ValueError, "Truncated download"):
            self.run_download(length=len(self.data) + 100)
        self.assertFalse(self.output.exists())

    def test_reject_checksum_mismatch(self):
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.run_download(digest="0" * 64)
        self.assertFalse(self.output.exists())

    def test_preserve_existing_file(self):
        self.output.write_bytes(b"existing")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.run_download()
        self.assertEqual(self.output.read_bytes(), b"existing")

    def test_reject_http(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            media.download("http://example.test/media.iso", self.output, "iso")


if __name__ == "__main__":
    unittest.main()
