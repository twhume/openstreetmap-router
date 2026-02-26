#!/usr/bin/env python3
"""Parse OSM PBF file and build a walkable graph in CSR format.

The graph is stored as Compressed Sparse Row (CSR) numpy arrays in a
gzip-compressed .npz file. On load, only a node_id→index dict is built
(~1-2s for 3.5M nodes), avoiding the 13s NetworkX reconstruction.
"""

import math
import os

import networkx as nx
import numpy as np
import osmium
from scipy.spatial import KDTree

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
DEFAULT_PBF = os.path.join(DATA_DIR, "norcal-latest.osm.pbf")
DEFAULT_GRAPH = os.path.join(DATA_DIR, "walk_graph.npz")

# Highway types that are walkable
WALKABLE_HIGHWAYS = {
    "footway", "path", "pedestrian", "residential", "living_street",
    "tertiary", "secondary", "primary", "trunk", "steps", "cycleway",
    "unclassified", "service", "track", "tertiary_link", "secondary_link",
    "primary_link",
}

# Highway types to always exclude
EXCLUDED_HIGHWAYS = {"motorway", "motorway_link"}

# Bay Area bounding box
BAY_AREA_BBOX = {
    "min_lat": 37.20,
    "max_lat": 38.35,
    "min_lon": -122.65,
    "max_lon": -121.70,
}


def haversine(lat1, lon1, lat2, lon2):
    """Calculate distance in meters between two lat/lon points."""
    R = 6371000  # Earth radius in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def bearing(lat1, lon1, lat2, lon2):
    """Calculate initial bearing in degrees [0, 360) from point 1 to point 2."""
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dlam = math.radians(lon2 - lon1)
    y = math.sin(dlam) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dlam)
    degrees = math.degrees(math.atan2(y, x))
    return (degrees + 360) % 360


class CompactGraph:
    """CSR-based graph representation using flat numpy arrays.

    Arrays:
        node_ids[i]:      int64   — OSM ID for node at index i
        node_lats[i]:     float32 — latitude
        node_lons[i]:     float32 — longitude
        adj_offsets[i]:   int32   — start of node i's neighbors in adj_targets
        adj_targets[j]:   int32   — neighbor index for directed edge slot j
        adj_weights[j]:   float32 — distance in meters for edge slot j
    """

    def __init__(self, node_ids, node_lats, node_lons,
                 adj_offsets, adj_targets, adj_weights,
                 edge_name_indices=None, edge_highway_indices=None,
                 name_table=None, highway_table=None):
        self.node_ids = node_ids
        self.node_lats = node_lats
        self.node_lons = node_lons
        self.adj_offsets = adj_offsets
        self.adj_targets = adj_targets
        self.adj_weights = adj_weights
        self.edge_name_indices = edge_name_indices
        self.edge_highway_indices = edge_highway_indices
        self.name_table = name_table
        self.highway_table = highway_table

        # Build OSM ID → array index lookup
        self.node_id_to_idx = {int(osm_id): i for i, osm_id in enumerate(node_ids)}

        self._kdtree = None
        self._kdtree_cos_lat = None

    def neighbors(self, idx):
        """Return (target_indices, weights) slices for node at idx. Zero-copy."""
        start = self.adj_offsets[idx]
        end = self.adj_offsets[idx + 1]
        return self.adj_targets[start:end], self.adj_weights[start:end]

    def find_nearest_node(self, lat, lon):
        """Find the nearest graph node to a lat/lon coordinate.

        Returns:
            (index, distance_in_meters)
        """
        if self._kdtree is None:
            self._build_kdtree()

        cos_lat = self._kdtree_cos_lat
        q = np.array([
            math.radians(lat) * 6371000,
            math.radians(lon) * 6371000 * cos_lat,
        ])

        k = min(10, len(self.node_ids))
        _, idxs = self._kdtree.query(q, k=k)

        best_idx = None
        best_dist = float("inf")
        for idx in idxs:
            d = haversine(lat, lon,
                          float(self.node_lats[idx]), float(self.node_lons[idx]))
            if d < best_dist:
                best_dist = d
                best_idx = idx

        return best_idx, best_dist

    def idx_for_osm_id(self, osm_id):
        """Return array index for an OSM node ID."""
        return self.node_id_to_idx[osm_id]

    def number_of_nodes(self):
        return len(self.node_ids)

    def number_of_edges(self):
        # Each undirected edge is stored twice in CSR
        return len(self.adj_targets) // 2

    def edge_name(self, u_idx, v_idx):
        """Return street name for edge u_idx→v_idx, or None if no name data."""
        if self.edge_name_indices is None or self.name_table is None:
            return None
        start = self.adj_offsets[u_idx]
        end = self.adj_offsets[u_idx + 1]
        for j in range(start, end):
            if self.adj_targets[j] == v_idx:
                idx = int(self.edge_name_indices[j])
                name = self.name_table[idx]
                return name if name else None
        return None

    def edge_highway(self, u_idx, v_idx):
        """Return highway type for edge u_idx→v_idx, or None if no data."""
        if self.edge_highway_indices is None or self.highway_table is None:
            return None
        start = self.adj_offsets[u_idx]
        end = self.adj_offsets[u_idx + 1]
        for j in range(start, end):
            if self.adj_targets[j] == v_idx:
                idx = int(self.edge_highway_indices[j])
                hw = self.highway_table[idx]
                return hw if hw else None
        return None

    def has_name_data(self):
        """Return True if name/highway data is available."""
        return self.edge_name_indices is not None and self.name_table is not None

    def _build_kdtree(self):
        """Build KDTree lazily on first nearest-node call."""
        lats = self.node_lats
        lons = self.node_lons
        mean_lat = np.radians(np.mean(lats))
        cos_lat = np.cos(mean_lat)

        coords = np.column_stack([
            np.radians(lats) * 6371000,
            np.radians(lons) * 6371000 * cos_lat,
        ])

        self._kdtree = KDTree(coords)
        self._kdtree_cos_lat = cos_lat


class WayCollector(osmium.SimpleHandler):
    """First pass: collect walkable ways and their node references."""

    def __init__(self, bbox=None):
        super().__init__()
        self.ways = []
        self.needed_nodes = set()
        self.bbox = bbox

    def way(self, w):
        tags = {t.k: t.v for t in w.tags}
        highway = tags.get("highway")

        if not highway:
            return
        if highway in EXCLUDED_HIGHWAYS:
            return
        if highway not in WALKABLE_HIGHWAYS:
            return

        # Exclude private access or foot=no
        access = tags.get("access", "")
        foot = tags.get("foot", "")
        if access in ("private", "no") and foot not in ("yes", "designated", "permissive"):
            return
        if foot == "no":
            return

        node_ids = [n.ref for n in w.nodes]
        self.ways.append((node_ids, tags.get("name", ""), highway))
        self.needed_nodes.update(node_ids)


class NodeCollector(osmium.SimpleHandler):
    """Second pass: collect coordinates for needed nodes."""

    def __init__(self, needed_nodes, bbox=None):
        super().__init__()
        self.needed_nodes = needed_nodes
        self.node_coords = {}
        self.bbox = bbox

    def node(self, n):
        if n.id in self.needed_nodes:
            lat, lon = n.location.lat, n.location.lon
            if self.bbox:
                if not (self.bbox["min_lat"] <= lat <= self.bbox["max_lat"] and
                        self.bbox["min_lon"] <= lon <= self.bbox["max_lon"]):
                    return
            self.node_coords[n.id] = (lat, lon)


def _graph_to_compact(G):
    """Convert a NetworkX graph to CSR numpy arrays.

    Each undirected edge is stored twice (once per direction).
    Nodes are sorted by OSM ID for deterministic indexing.
    """
    # Sort nodes by OSM ID for deterministic ordering
    nodes = sorted(G.nodes(data=True), key=lambda n: n[0])
    num_nodes = len(nodes)

    node_ids = np.array([n[0] for n in nodes], dtype=np.int64)
    node_lats = np.array([n[1]["lat"] for n in nodes], dtype=np.float32)
    node_lons = np.array([n[1]["lon"] for n in nodes], dtype=np.float32)

    # Build OSM ID → index mapping
    osm_to_idx = {int(osm_id): i for i, osm_id in enumerate(node_ids)}

    # Build string tables for names and highway types
    name_set = {""}  # empty string always index 0
    highway_set = {""}
    for u, v, data in G.edges(data=True):
        name_set.add(data.get("name", ""))
        highway_set.add(data.get("highway", ""))

    # Sort for determinism, but keep "" at index 0
    name_list = [""] + sorted(name_set - {""})
    highway_list = [""] + sorted(highway_set - {""})
    name_to_idx = {s: i for i, s in enumerate(name_list)}
    highway_to_idx = {s: i for i, s in enumerate(highway_list)}

    # Count degrees (each undirected edge contributes 1 to each endpoint)
    degrees = np.zeros(num_nodes, dtype=np.int32)
    for u, v, data in G.edges(data=True):
        u_idx = osm_to_idx[u]
        v_idx = osm_to_idx[v]
        degrees[u_idx] += 1
        degrees[v_idx] += 1

    # Compute prefix-sum offsets
    adj_offsets = np.zeros(num_nodes + 1, dtype=np.int32)
    adj_offsets[1:] = np.cumsum(degrees)
    num_directed_edges = int(adj_offsets[-1])

    adj_targets = np.empty(num_directed_edges, dtype=np.int32)
    adj_weights = np.empty(num_directed_edges, dtype=np.float32)
    edge_name_indices = np.empty(num_directed_edges, dtype=np.uint16)
    edge_highway_indices = np.empty(num_directed_edges, dtype=np.uint8)

    # Fill adjacency lists using a write cursor per node
    cursor = adj_offsets[:-1].copy()
    for u, v, data in G.edges(data=True):
        u_idx = osm_to_idx[u]
        v_idx = osm_to_idx[v]
        w = data["weight"]
        ni = name_to_idx[data.get("name", "")]
        hi = highway_to_idx[data.get("highway", "")]

        adj_targets[cursor[u_idx]] = v_idx
        adj_weights[cursor[u_idx]] = w
        edge_name_indices[cursor[u_idx]] = ni
        edge_highway_indices[cursor[u_idx]] = hi
        cursor[u_idx] += 1

        adj_targets[cursor[v_idx]] = u_idx
        adj_weights[cursor[v_idx]] = w
        edge_name_indices[cursor[v_idx]] = ni
        edge_highway_indices[cursor[v_idx]] = hi
        cursor[v_idx] += 1

    # Sort each node's neighbors by target index for determinism
    for i in range(num_nodes):
        start = adj_offsets[i]
        end = adj_offsets[i + 1]
        if end - start > 1:
            order = np.argsort(adj_targets[start:end])
            adj_targets[start:end] = adj_targets[start:end][order]
            adj_weights[start:end] = adj_weights[start:end][order]
            edge_name_indices[start:end] = edge_name_indices[start:end][order]
            edge_highway_indices[start:end] = edge_highway_indices[start:end][order]

    # Encode string tables as newline-joined bytes
    name_table = "\n".join(name_list).encode("utf-8")
    highway_table = "\n".join(highway_list).encode("utf-8")

    return {
        "node_ids": node_ids,
        "node_lats": node_lats,
        "node_lons": node_lons,
        "adj_offsets": adj_offsets,
        "adj_targets": adj_targets,
        "adj_weights": adj_weights,
        "edge_name_indices": edge_name_indices,
        "edge_highway_indices": edge_highway_indices,
        "name_table": np.frombuffer(name_table, dtype=np.uint8),
        "highway_table": np.frombuffer(highway_table, dtype=np.uint8),
    }


def _save_graph(G, graph_path):
    """Save graph in CSR compressed numpy format."""
    print("  Converting to CSR format...")
    data = _graph_to_compact(G)
    print(f"  Saving compressed to {graph_path}...")
    np.savez_compressed(graph_path, **data)


def _load_graph(graph_path):
    """Load graph from CSR compressed numpy format. Returns CompactGraph."""
    data = np.load(graph_path)

    # Load name/highway data if present (graceful fallback for old .npz files)
    edge_name_indices = data["edge_name_indices"] if "edge_name_indices" in data else None
    edge_highway_indices = data["edge_highway_indices"] if "edge_highway_indices" in data else None

    if "name_table" in data:
        name_table = data["name_table"].tobytes().decode("utf-8").split("\n")
    else:
        name_table = None

    if "highway_table" in data:
        highway_table = data["highway_table"].tobytes().decode("utf-8").split("\n")
    else:
        highway_table = None

    return CompactGraph(
        node_ids=data["node_ids"],
        node_lats=data["node_lats"],
        node_lons=data["node_lons"],
        adj_offsets=data["adj_offsets"],
        adj_targets=data["adj_targets"],
        adj_weights=data["adj_weights"],
        edge_name_indices=edge_name_indices,
        edge_highway_indices=edge_highway_indices,
        name_table=name_table,
        highway_table=highway_table,
    )


def build_graph(pbf_path=DEFAULT_PBF, bbox=BAY_AREA_BBOX, graph_path=DEFAULT_GRAPH):
    """Build a walkable graph from an OSM PBF file.

    Args:
        pbf_path: Path to the .osm.pbf file
        bbox: Bounding box dict with min_lat, max_lat, min_lon, max_lon (or None for no filter)
        graph_path: Path to save the graph

    Returns:
        CompactGraph
    """
    if os.path.exists(graph_path):
        print(f"Loading cached graph from {graph_path}")
        G = _load_graph(graph_path)
        print(f"  {G.number_of_nodes()} nodes, {G.number_of_edges()} edges")
        return G

    print(f"Parsing ways from {pbf_path}...")
    way_collector = WayCollector(bbox=bbox)
    way_collector.apply_file(pbf_path)
    print(f"  Found {len(way_collector.ways)} walkable ways, {len(way_collector.needed_nodes)} node refs")

    print("Collecting node coordinates...")
    node_collector = NodeCollector(way_collector.needed_nodes, bbox=bbox)
    node_collector.apply_file(pbf_path, locations=True)
    print(f"  Found {len(node_collector.node_coords)} nodes within bounding box")

    print("Building graph...")
    nx_graph = nx.Graph()
    coords = node_collector.node_coords

    for node_ids, way_name, way_highway in way_collector.ways:
        for i in range(len(node_ids) - 1):
            n1, n2 = node_ids[i], node_ids[i + 1]
            if n1 in coords and n2 in coords:
                lat1, lon1 = coords[n1]
                lat2, lon2 = coords[n2]
                dist = haversine(lat1, lon1, lat2, lon2)

                if not nx_graph.has_node(n1):
                    nx_graph.add_node(n1, lat=lat1, lon=lon1)
                if not nx_graph.has_node(n2):
                    nx_graph.add_node(n2, lat=lat2, lon=lon2)

                # Use shorter distance if edge already exists (parallel ways)
                if nx_graph.has_edge(n1, n2):
                    if dist < nx_graph[n1][n2]["weight"]:
                        nx_graph[n1][n2]["weight"] = dist
                        nx_graph[n1][n2]["name"] = way_name
                        nx_graph[n1][n2]["highway"] = way_highway
                else:
                    nx_graph.add_edge(n1, n2, weight=dist,
                                      name=way_name, highway=way_highway)

    print(f"  Graph: {nx_graph.number_of_nodes()} nodes, {nx_graph.number_of_edges()} edges")

    os.makedirs(os.path.dirname(graph_path), exist_ok=True)
    _save_graph(nx_graph, graph_path)

    # Return as CompactGraph
    return _load_graph(graph_path)


# Backwards-compatible module-level function
def find_nearest_node(G, lat, lon):
    """Find the nearest graph node to a lat/lon coordinate.

    Returns:
        (osm_id, distance_in_meters)
    """
    idx, dist = G.find_nearest_node(lat, lon)
    return int(G.node_ids[idx]), dist


if __name__ == "__main__":
    G = build_graph()
    print(f"\nGraph summary: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges")
