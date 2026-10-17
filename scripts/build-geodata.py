#!/usr/bin/env python3
"""Converts downloaded geo data into compact files the app ships in Resources/Geo.

  python3 -I scripts/build-geodata.py <ne_110m_land.geojson> <dbip-city-lite.mmdb> Resources/Geo
  compression_tool -encode -a lzfse -i Resources/Geo/ipcity.bin -o Resources/Geo/ipcity.bin.lzfse
  rm Resources/Geo/ipcity.bin

Sources: github.com/nvkelso/natural-earth-vector (geojson/ne_110m_land.geojson) and
github.com/wp-statistics/DbIP-City-lite (dbip-city-lite.mmdb.gz, gunzip first).

land.bin   — u32 polygon count; per polygon: u32 point count, then (f32 lon, f32 lat) pairs.
ipcity.bin — "NSGEO1\\0\\0"; u32 city count; per city: f32 lat, f32 lon, 2-byte country,
             u16 name length, UTF-8 name; u32 v4 count, u32 starts[], u32 city[];
             u32 v6 count, u64 starts (upper 64 bits, /48 granularity)[], u32 city[].
             city == 0xFFFFFFFF marks an unknown range. All little-endian.

Land: Natural Earth (public domain). IP data: DB-IP City Lite, CC BY 4.0 (https://db-ip.com).
"""
import json
import os
import struct
import sys

UNKNOWN = 0xFFFFFFFF


def build_land(src, dst):
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    rings = []
    for feature in data["features"]:
        geom = feature["geometry"]
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            rings.append(poly[0])  # outer ring; 1:110m land has no meaningful holes
    with open(dst, "wb") as out:
        out.write(struct.pack("<I", len(rings)))
        for ring in rings:
            out.write(struct.pack("<I", len(ring)))
            for lon, lat in ring:
                out.write(struct.pack("<ff", lon, lat))
    print(f"land: {len(rings)} polygons")


class MMDB:
    """Minimal MaxMind DB reader: enough to walk the whole tree."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.buf = f.read()
        marker = self.buf.rfind(b"\xab\xcd\xefMaxMind.com")
        meta, _ = self.decode(marker + 14, base=0)
        self.node_count = meta["node_count"]
        self.record_size = meta["record_size"]
        self.ip_version = meta["ip_version"]
        self.node_bytes = self.record_size * 2 // 8
        self.data_start = self.node_count * self.node_bytes + 16
        self.cache = {}

    def record(self, node, bit):
        off = node * self.node_bytes
        b = self.buf
        if self.record_size == 24:
            o = off + bit * 3
            return b[o] << 16 | b[o + 1] << 8 | b[o + 2]
        if self.record_size == 28:
            if bit == 0:
                return ((b[off + 3] & 0xF0) << 20) | b[off] << 16 | b[off + 1] << 8 | b[off + 2]
            return ((b[off + 3] & 0x0F) << 24) | b[off + 4] << 16 | b[off + 5] << 8 | b[off + 6]
        o = off + bit * 4
        return int.from_bytes(b[o:o + 4], "big")

    def decode(self, offset, base=None):
        base = self.data_start if base is None else base
        b = self.buf
        ctrl = b[offset]
        offset += 1
        kind = ctrl >> 5
        if kind == 1:  # pointer
            ss, vvv = (ctrl >> 3) & 3, ctrl & 7
            if ss == 0:
                p = vvv << 8 | b[offset]; offset += 1
            elif ss == 1:
                p = (vvv << 16 | b[offset] << 8 | b[offset + 1]) + 2048; offset += 2
            elif ss == 2:
                p = (vvv << 24 | b[offset] << 16 | b[offset + 1] << 8 | b[offset + 2]) + 526336; offset += 3
            else:
                p = int.from_bytes(b[offset:offset + 4], "big"); offset += 4
            value, _ = self.decode(base + p, base)
            return value, offset
        if kind == 0:
            kind = 7 + b[offset]
            offset += 1
        size = ctrl & 0x1F
        if size == 29:
            size = 29 + b[offset]; offset += 1
        elif size == 30:
            size = 285 + int.from_bytes(b[offset:offset + 2], "big"); offset += 2
        elif size == 31:
            size = 65821 + int.from_bytes(b[offset:offset + 3], "big"); offset += 3
        if kind == 2:
            return b[offset:offset + size].decode("utf-8", "replace"), offset + size
        if kind == 3:
            return struct.unpack(">d", b[offset:offset + 8])[0], offset + 8
        if kind == 15:
            return struct.unpack(">f", b[offset:offset + 4])[0], offset + 4
        if kind in (4,):
            return b[offset:offset + size], offset + size
        if kind in (5, 6, 9, 10, 8):
            return int.from_bytes(b[offset:offset + size], "big"), offset + size
        if kind == 7:
            out = {}
            for _ in range(size):
                k, offset = self.decode(offset, base)
                v, offset = self.decode(offset, base)
                out[k] = v
            return out, offset
        if kind == 11:
            out = []
            for _ in range(size):
                v, offset = self.decode(offset, base)
                out.append(v)
            return out, offset
        if kind == 14:
            return bool(size), offset
        raise ValueError(f"unknown type {kind} at {offset}")

    def data(self, record):
        if record not in self.cache:
            value, _ = self.decode(self.data_start + (record - self.node_count) - 16)
            self.cache[record] = value
        return self.cache[record]

    def node_at(self, bits):
        node = 0
        for bit in bits:
            if node >= self.node_count:
                return node
            node = self.record(node, bit)
        return node

    def walk(self, root, depth, skip=None):
        """Yields (start_prefix_int, prefix_len, record) in address order up to `depth` bits."""
        stack = [(root, 0, 0)]
        while stack:
            node, prefix, level = stack.pop()
            if node >= self.node_count or level == depth:
                while node < self.node_count:  # deeper than wanted: take the leftmost leaf
                    node = self.record(node, 0)
                yield prefix << (depth - level), level, node
                continue
            if skip is not None and node == skip and level > 0:
                continue
            for bit in (1, 0):  # push right first so left is processed first
                stack.append((self.record(node, bit), prefix << 1 | bit, level + 1))


def build_ip(src, dst):
    db = MMDB(src)
    cities = {}
    city_list = []

    def city_index(record):
        if record == db.node_count:
            return UNKNOWN
        data = db.data(record)
        loc = data.get("location") or {}
        lat, lon = loc.get("latitude"), loc.get("longitude")
        if lat is None or lon is None:
            return UNKNOWN
        names = (data.get("city") or {}).get("names") or {}
        country = (data.get("country") or {}).get("iso_code") or "--"
        name = names.get("en") or (data.get("country") or {}).get("names", {}).get("en") or country
        key = (country[:2], name)
        if key not in cities:
            cities[key] = len(city_list)
            city_list.append((country[:2], name, lat, lon))
        return cities[key]

    def ranges(root, depth, skip=None):
        out = []
        for start, _, record in db.walk(root, depth, skip):
            idx = city_index(record)
            if out and out[-1][1] == idx:
                continue
            if out and out[-1][0] == start:
                out[-1] = (start, idx)
            else:
                out.append((start, idx))
        return out

    v4_root = db.node_at([0] * 96)
    v4s = ranges(v4_root, 32)
    v6s = [(start << 16, idx) for start, idx in ranges(0, 48, skip=v4_root)]  # /48 is plenty for geolocation

    with open(dst, "wb") as out:
        out.write(b"NSGEO1\0\0")
        out.write(struct.pack("<I", len(city_list)))
        for country, name, lat, lon in city_list:
            encoded = name.encode("utf-8")[:255]
            out.write(struct.pack("<ff", lat, lon))
            out.write(country.encode("ascii", "replace")[:2].ljust(2, b"-"))
            out.write(struct.pack("<H", len(encoded)))
            out.write(encoded)
        out.write(struct.pack("<I", len(v4s)))
        out.write(struct.pack(f"<{len(v4s)}I", *(s for s, _ in v4s)))
        out.write(struct.pack(f"<{len(v4s)}I", *(i for _, i in v4s)))
        out.write(struct.pack("<I", len(v6s)))
        out.write(struct.pack(f"<{len(v6s)}Q", *(s for s, _ in v6s)))
        out.write(struct.pack(f"<{len(v6s)}I", *(i for _, i in v6s)))
    print(f"ip: {len(city_list)} cities, {len(v4s)} v4 ranges, {len(v6s)} v6 ranges, "
          f"{os.path.getsize(dst) / 1e6:.1f} MB")


if __name__ == "__main__":
    land_src, ip_src, out_dir = sys.argv[1:4]
    os.makedirs(out_dir, exist_ok=True)
    build_land(land_src, os.path.join(out_dir, "land.bin"))
    build_ip(ip_src, os.path.join(out_dir, "ipcity.bin"))
