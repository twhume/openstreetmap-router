#!/usr/bin/env python3
"""Export CSR graph from .npz to flat binary format for Swift consumption.

Binary format v2:
  Header (32 bytes):
    magic: "CSRG" (4 bytes ASCII)
    version: uint32 LE (2)
    num_nodes: uint32 LE
    num_directed_edges: uint32 LE
    reserved: 16 bytes (zeros)

  Data (sequential, tightly packed, little-endian):
    node_ids:             Int64   x num_nodes
    node_lats:            Float32 x num_nodes
    node_lons:            Float32 x num_nodes
    adj_offsets:          Int32   x (num_nodes + 1)
    adj_targets:          Int32   x num_directed_edges
    adj_weights:          Float32 x num_directed_edges

  v2 additions:
    edge_name_indices:    UInt16  x num_directed_edges
    edge_highway_indices: UInt8   x num_directed_edges
    name_table:           u32 count, then per string: u16 length + UTF-8 bytes
    highway_table:        u32 count, then per string: u16 length + UTF-8 bytes
"""

import os
import struct
import numpy as np

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
NPZ_PATH = os.path.join(DATA_DIR, "walk_graph.npz")
BIN_PATH = os.path.join(DATA_DIR, "walk_graph.bin")


def _write_string_table(f, table_bytes):
    """Write a string table: u32 count, then per string: u16 length + UTF-8 bytes."""
    strings = table_bytes.tobytes().decode("utf-8").split("\n")
    f.write(struct.pack("<I", len(strings)))
    for s in strings:
        encoded = s.encode("utf-8")
        f.write(struct.pack("<H", len(encoded)))
        f.write(encoded)


def export():
    print(f"Loading {NPZ_PATH}...")
    data = np.load(NPZ_PATH)

    node_ids = data["node_ids"].astype("<i8")       # Int64 LE
    node_lats = data["node_lats"].astype("<f4")      # Float32 LE
    node_lons = data["node_lons"].astype("<f4")      # Float32 LE
    adj_offsets = data["adj_offsets"].astype("<i4")   # Int32 LE
    adj_targets = data["adj_targets"].astype("<i4")   # Int32 LE
    adj_weights = data["adj_weights"].astype("<f4")   # Float32 LE

    num_nodes = len(node_ids)
    num_directed_edges = len(adj_targets)

    # Check for v2 data
    has_names = "edge_name_indices" in data
    version = 2 if has_names else 1

    if has_names:
        edge_name_indices = data["edge_name_indices"].astype("<u2")   # UInt16 LE
        edge_highway_indices = data["edge_highway_indices"].astype("u1")  # UInt8
        name_table = data["name_table"]
        highway_table = data["highway_table"]

    print(f"  {num_nodes} nodes, {num_directed_edges} directed edges (version {version})")

    with open(BIN_PATH, "wb") as f:
        # Header: magic, version, num_nodes, num_directed_edges, reserved
        f.write(b"CSRG")
        f.write(struct.pack("<III", version, num_nodes, num_directed_edges))
        f.write(b"\x00" * 16)

        # Data arrays (same as v1)
        f.write(node_ids.tobytes())
        f.write(node_lats.tobytes())
        f.write(node_lons.tobytes())
        f.write(adj_offsets.tobytes())
        f.write(adj_targets.tobytes())
        f.write(adj_weights.tobytes())

        # v2 additions
        if has_names:
            f.write(edge_name_indices.tobytes())
            f.write(edge_highway_indices.tobytes())
            _write_string_table(f, name_table)
            _write_string_table(f, highway_table)

    size_mb = os.path.getsize(BIN_PATH) / (1024 * 1024)
    print(f"  Written {BIN_PATH} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    export()
