"""A small Minecraft NBT and Anvil (.mca) reader using only the Python standard library.

Written from the published format descriptions (minecraft.wiki: NBT format, Region file format); it reads
Java Edition 1.20.1 worlds. Nothing here writes to a world.

  read_nbt(bytes)            -> (name, value)            gzip, zlib or raw NBT
  Region(path)               -> .chunk(cx, cz) -> NBT root compound of that chunk, or None
  chunk_blocks(chunk_nbt)    -> iterator of (lx, y, lz, palette_entry) for every non-air block
Compounds come back as dicts, lists as lists, arrays as lists of ints, strings as str, numbers as int/float.
"""
import gzip
import io
import os
import struct
import zlib

TAG_END, TAG_BYTE, TAG_SHORT, TAG_INT, TAG_LONG, TAG_FLOAT, TAG_DOUBLE, TAG_BYTE_ARRAY, TAG_STRING, TAG_LIST, \
    TAG_COMPOUND, TAG_INT_ARRAY, TAG_LONG_ARRAY = range(13)


class _Reader:
    def __init__(self, data):
        self.d = data
        self.p = 0

    def take(self, n):
        b = self.d[self.p:self.p + n]
        if len(b) != n:
            raise ValueError("NBT ends early")
        self.p += n
        return b

    def unpack(self, fmt):
        size = struct.calcsize(fmt)
        return struct.unpack(fmt, self.take(size))[0]

    def string(self):
        n = self.unpack(">H")
        return self.take(n).decode("utf-8", errors="replace")

    def payload(self, tag):
        if tag == TAG_BYTE:
            return self.unpack(">b")
        if tag == TAG_SHORT:
            return self.unpack(">h")
        if tag == TAG_INT:
            return self.unpack(">i")
        if tag == TAG_LONG:
            return self.unpack(">q")
        if tag == TAG_FLOAT:
            return self.unpack(">f")
        if tag == TAG_DOUBLE:
            return self.unpack(">d")
        if tag == TAG_BYTE_ARRAY:
            n = self.unpack(">i")
            return list(struct.unpack(f">{n}b", self.take(n)))
        if tag == TAG_STRING:
            return self.string()
        if tag == TAG_LIST:
            inner = self.unpack(">b")
            n = self.unpack(">i")
            return [self.payload(inner) for _ in range(n)]
        if tag == TAG_COMPOUND:
            out = {}
            while True:
                t = self.unpack(">b")
                if t == TAG_END:
                    return out
                name = self.string()
                out[name] = self.payload(t)
        if tag == TAG_INT_ARRAY:
            n = self.unpack(">i")
            return list(struct.unpack(f">{n}i", self.take(n * 4)))
        if tag == TAG_LONG_ARRAY:
            n = self.unpack(">i")
            return list(struct.unpack(f">{n}q", self.take(n * 8)))
        raise ValueError(f"unknown NBT tag {tag}")


def read_nbt(data):
    """Parse NBT bytes (gzip, zlib or uncompressed). Returns (root name, root value)."""
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    elif data[:1] == b"\x78":
        data = zlib.decompress(data)
    r = _Reader(data)
    tag = r.unpack(">b")
    if tag != TAG_COMPOUND:
        raise ValueError("NBT root is not a compound")
    return r.string(), r.payload(TAG_COMPOUND)


def read_nbt_file(path):
    with open(path, "rb") as f:
        return read_nbt(f.read())[1]


class Region:
    """One r.<x>.<z>.mca file. Chunks are 32x32; compression 2 (zlib) and 1 (gzip) are handled."""

    def __init__(self, path):
        self.path = path
        base = os.path.basename(path).split(".")
        self.rx, self.rz = int(base[1]), int(base[2])
        with open(path, "rb") as f:
            self.data = f.read()

    def chunk(self, cx, cz):
        if len(self.data) < 8192:  # an empty or cut-off region file has no chunks
            return None
        index = (cx % 32) + (cz % 32) * 32
        entry = struct.unpack(">I", self.data[index * 4:index * 4 + 4])[0]
        offset, sectors = entry >> 8, entry & 0xFF
        if offset == 0 or sectors == 0:
            return None
        start = offset * 4096
        length, compression = struct.unpack(">IB", self.data[start:start + 5])
        raw = self.data[start + 5:start + 4 + length]
        if compression == 2:
            raw = zlib.decompress(raw)
        elif compression == 1:
            raw = gzip.decompress(raw)
        elif compression == 3:
            pass
        else:
            raise ValueError(f"unsupported chunk compression {compression}")
        return read_nbt(raw)[1]

    def present(self):
        """All (cx, cz) chunks that exist in this region, in world chunk coordinates."""
        out = []
        if len(self.data) < 8192:
            return out
        for i in range(1024):
            if struct.unpack(">I", self.data[i * 4:i * 4 + 4])[0] != 0:
                out.append((self.rx * 32 + i % 32, self.rz * 32 + i // 32))
        return out


AIR = {"minecraft:air", "minecraft:cave_air", "minecraft:void_air"}


def _bits_for(palette_len):
    return max(4, (palette_len - 1).bit_length())


def section_indices(section):
    """The 4096 palette indices of a section's block_states (index = y*256 + z*16 + x), or None if it is a single block."""
    bs = section.get("block_states")
    if not bs:
        return None
    palette = bs.get("palette", [])
    data = bs.get("data")
    if len(palette) <= 1 or not data:
        return None
    bits = _bits_for(len(palette))
    per_long = 64 // bits
    mask = (1 << bits) - 1
    out = [0] * 4096
    for i in range(4096):
        word = data[i // per_long] & 0xFFFFFFFFFFFFFFFF
        out[i] = (word >> ((i % per_long) * bits)) & mask
    return out


def chunk_blocks(chunk):
    """Yield (lx, y, lz, palette_entry) for every non-air block of a chunk. palette_entry is a dict with 'Name'
    and, when the block has any, 'Properties'."""
    for section in chunk.get("sections", []):
        sy = section.get("Y", 0)
        bs = section.get("block_states")
        if not bs:
            continue
        palette = bs.get("palette", [])
        if not palette:
            continue
        idx = section_indices(section)
        if idx is None:
            entry = palette[0]
            if entry["Name"] in AIR:
                continue
            for i in range(4096):
                yield i & 15, sy * 16 + (i >> 8), (i >> 4) & 15, entry
            continue
        for i, p in enumerate(idx):
            entry = palette[p]
            if entry["Name"] in AIR:
                continue
            yield i & 15, sy * 16 + (i >> 8), (i >> 4) & 15, entry
