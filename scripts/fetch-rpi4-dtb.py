#!/usr/bin/env python3

import hashlib
from pathlib import Path
import sys
from urllib.request import urlopen


URL = "https://raw.githubusercontent.com/raspberrypi/firmware/1.20260521/boot/bcm2711-rpi-4-b.dtb"
SHA256 = bytes.fromhex(
    "75 76 1b 73 c2 84 e2 66 23 e4 d1 62 4b ff 13 e6 "
    "7b ce 2a e6 20 88 0e fd 81 d6 57 1a 37 39 fc fb"
).hex()


def main() -> None:
    output = Path(sys.argv[1])
    with urlopen(URL, timeout=30) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SHA256:
        raise RuntimeError(f"Raspberry Pi 4 DTB digest mismatch: {digest}")
    output.write_bytes(data)


if __name__ == "__main__":
    main()
