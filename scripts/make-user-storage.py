#!/usr/bin/env python3
"""Build deterministic initramfs and FAT16 images for the user programs."""

from __future__ import annotations

import pathlib
import struct
import sys


SECTOR_SIZE = 512
FAT_SECTORS = 32
FAT_COUNT = 2
ROOT_ENTRIES = 32
TOTAL_SECTORS = 8192


def append_newc_entry(archive: bytearray, name: str, data: bytes, inode: int) -> None:
    encoded_name = name.encode("ascii") + b"\0"
    fields = (
        inode,
        0o100555 if data else 0,
        0,
        0,
        1,
        0,
        len(data),
        0,
        0,
        0,
        0,
        len(encoded_name),
        0,
    )
    archive.extend(("070701" + "".join(f"{value:08x}" for value in fields)).encode("ascii"))
    archive.extend(encoded_name)
    archive.extend(b"\0" * (-len(archive) % 4))
    archive.extend(data)
    archive.extend(b"\0" * (-len(archive) % 4))


def make_initramfs(files: list[tuple[str, bytes]]) -> bytes:
    archive = bytearray()
    for inode, (name, data) in enumerate(files, start=1):
        append_newc_entry(archive, name, data, inode)
    append_newc_entry(archive, "TRAILER!!!", b"", len(files) + 1)
    return bytes(archive)


def make_fat16(files: list[tuple[str, bytes]]) -> bytes:
    root_sectors = (ROOT_ENTRIES * 32 + SECTOR_SIZE - 1) // SECTOR_SIZE
    data_start = 1 + FAT_COUNT * FAT_SECTORS + root_sectors
    cluster_count = TOTAL_SECTORS - data_start
    image = bytearray(TOTAL_SECTORS * SECTOR_SIZE)

    boot = memoryview(image)[:SECTOR_SIZE]
    boot[0:3] = b"\xeb\x3c\x90"
    boot[3:11] = b"THEKORN "
    struct.pack_into("<H", boot, 11, SECTOR_SIZE)
    boot[13] = 1
    struct.pack_into("<H", boot, 14, 1)
    boot[16] = FAT_COUNT
    struct.pack_into("<H", boot, 17, ROOT_ENTRIES)
    struct.pack_into("<H", boot, 19, TOTAL_SECTORS)
    boot[21] = 0xF8
    struct.pack_into("<H", boot, 22, FAT_SECTORS)
    struct.pack_into("<H", boot, 24, 63)
    struct.pack_into("<H", boot, 26, 255)
    boot[36] = 0x80
    boot[38] = 0x29
    struct.pack_into("<I", boot, 39, 0x544B4F53)
    boot[43:54] = b"THEKORN OS "
    boot[54:62] = b"FAT16   "
    boot[510:512] = b"\x55\xaa"

    fat = [0] * (FAT_SECTORS * SECTOR_SIZE // 2)
    fat[0] = 0xFFF8
    fat[1] = 0xFFFF
    next_cluster = 2
    root_offset = (1 + FAT_COUNT * FAT_SECTORS) * SECTOR_SIZE
    fixed_date = (1 << 5) | 1
    image[root_offset : root_offset + 11] = b"THEKORN OS "
    image[root_offset + 11] = 0x08
    struct.pack_into("<H", image, root_offset + 16, fixed_date)
    struct.pack_into("<H", image, root_offset + 18, fixed_date)
    struct.pack_into("<H", image, root_offset + 24, fixed_date)

    for index, (name, data) in enumerate(files):
        base, extension = name.split(".", maxsplit=1)
        short_name = f"{base:<8}{extension:<3}".encode("ascii")
        if len(short_name) != 11:
            raise ValueError(f"not an 8.3 name: {name}")
        needed = (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
        if needed == 0 or next_cluster + needed - 2 > cluster_count:
            raise ValueError(f"file does not fit FAT16 image: {name}")
        first_cluster = next_cluster
        for cluster_index in range(needed):
            cluster = next_cluster + cluster_index
            fat[cluster] = 0xFFFF if cluster_index + 1 == needed else cluster + 1
            source_start = cluster_index * SECTOR_SIZE
            destination_start = (data_start + cluster - 2) * SECTOR_SIZE
            image[destination_start : destination_start + SECTOR_SIZE] = data[
                source_start : source_start + SECTOR_SIZE
            ].ljust(SECTOR_SIZE, b"\0")
        entry = root_offset + (index + 1) * 32
        image[entry : entry + 11] = short_name
        image[entry + 11] = 0x20
        struct.pack_into("<H", image, entry + 16, fixed_date)
        struct.pack_into("<H", image, entry + 18, fixed_date)
        struct.pack_into("<H", image, entry + 24, fixed_date)
        struct.pack_into("<H", image, entry + 26, first_cluster)
        struct.pack_into("<I", image, entry + 28, len(data))
        next_cluster += needed

    encoded_fat = b"".join(struct.pack("<H", value) for value in fat)
    for index in range(FAT_COUNT):
        start = (1 + index * FAT_SECTORS) * SECTOR_SIZE
        image[start : start + len(encoded_fat)] = encoded_fat
    return bytes(image)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: make-user-storage.py USER1_ELF USER2_ELF INITRAMFS FAT_IMAGE"
        )
    files = [
        ("USER1.ELF", pathlib.Path(sys.argv[1]).read_bytes()),
        ("USER2.ELF", pathlib.Path(sys.argv[2]).read_bytes()),
    ]
    pathlib.Path(sys.argv[3]).write_bytes(make_initramfs(files))
    pathlib.Path(sys.argv[4]).write_bytes(make_fat16(files))


if __name__ == "__main__":
    main()
