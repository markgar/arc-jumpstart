#!/usr/bin/env python3
"""Download and inspect SQL media without running a Windows installer."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.parse
import urllib.request


def validate_media(path, media_format):
    with path.open("rb") as stream:
        if media_format == "iso":
            for sector in range(16, 32):
                stream.seek(sector * 2048 + 1)
                if stream.read(5) in (b"CD001", b"BEA01", b"NSR02", b"NSR03"):
                    return
            raise ValueError("Downloaded file has no ISO/UDF volume descriptor.")
        if stream.read(2) != b"MZ":
            raise ValueError("Downloaded file is not a Windows PE executable.")
        stream.seek(0x3C)
        offset_bytes = stream.read(4)
        if len(offset_bytes) != 4:
            raise ValueError("Truncated executable header.")
        stream.seek(int.from_bytes(offset_bytes, "little"))
        if stream.read(4) != b"PE\0\0":
            raise ValueError("Downloaded file has no valid PE signature.")


def download(url, output, media_format, expected_hash=None, timeout=1800):
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("Use an HTTPS media URL.")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError("Output already exists; choose a new path to avoid reusing stale media.")
    started = time.monotonic()
    last_report = started
    digest = hashlib.sha256()
    received = 0
    temporary = None
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            if urllib.parse.urlsplit(response.url).scheme != "https":
                raise ValueError("Media download redirected to a non-HTTPS URL.")
            length = response.headers.get("Content-Length")
            expected_size = int(length) if length else None
            with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".partial", delete=False) as stream:
                temporary = Path(stream.name)
                while True:
                    if time.monotonic() - started > timeout:
                        raise TimeoutError("Media download exceeded its overall time limit.")
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    stream.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    if time.monotonic() - last_report >= 10:
                        print(f"Downloaded {received / 1024**2:.1f} MiB", flush=True)
                        last_report = time.monotonic()
        if expected_size is not None and received != expected_size:
            raise ValueError(f"Truncated download: received {received} of {expected_size} bytes.")
        validate_media(temporary, media_format)
        checksum = digest.hexdigest()
        if expected_hash and checksum.lower() != expected_hash.lower():
            raise ValueError("Downloaded media does not match the supplied SHA-256.")
        # Publish without overwriting a file created concurrently by another process.
        os.link(temporary, output)
        elapsed = time.monotonic() - started
        print(f"Saved: {output}")
        print(f"Bytes: {received}; elapsed: {elapsed:.1f}s")
        print(f"SHA-256: {checksum}")
        print("File structure verified. Windows execution, edition and licensing are not verified.")
        if not expected_hash:
            print("No published hash supplied: this checksum records the download, not its authenticity.")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Direct HTTPS media URL, not a download page.")
    parser.add_argument("--output", required=True, help="New file path outside the repository.")
    parser.add_argument("--format", choices=("iso", "pe"), default="iso")
    parser.add_argument("--sha256", help="Expected SHA-256 from a trusted publisher, if available.")
    parser.add_argument("--timeout", type=int, default=1800, help="Overall download limit in seconds.")
    args = parser.parse_args()
    try:
        download(args.url, args.output, args.format, args.sha256, args.timeout)
    except (OSError, ValueError, TimeoutError) as error:
        message = re.sub(r'https?://[^\s\'"]+', '[URL redacted]', str(error))
        print(f"Media check failed ({type(error).__name__}): {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
