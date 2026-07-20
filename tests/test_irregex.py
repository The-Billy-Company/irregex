from __future__ import annotations

import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import irregex


class IrregexTests(unittest.TestCase):
    def test_records_decodes_native_ndjson(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, "irregex")
            binary.write_text(
                "#!/bin/sh\nprintf '%s\\n' '{\"path\":\"one.py\"}' '{\"path\":\"two.py\"}'\n"
            )
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)

            with patch.dict(os.environ, {"IRREGEX_BIN": str(binary)}):
                self.assertEqual(
                    irregex.records("context", "query"),
                    [{"path": "one.py"}, {"path": "two.py"}],
                )

    def test_missing_configured_executable_fails_loudly(self) -> None:
        with patch.dict(os.environ, {"IRREGEX_BIN": "/missing/irregex"}):
            with self.assertRaisesRegex(
                irregex.ExecutableNotFound, "IRREGEX_BIN is not executable"
            ):
                irregex.executable()


if __name__ == "__main__":
    unittest.main()
