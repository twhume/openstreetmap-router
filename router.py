#!/usr/bin/env python3
"""Shortest path and novelty-weighted pedestrian routing.

Uses parent-pointer A* with int32 array indices for O(V) memory
instead of O(V^2) path copies in every queue entry.
"""

import heapq
import math

import numpy as np

from graph_builder import haversine, bearing


def _heuristic_idx(G, idx, target_lat, target_lon):
    """A* heuristic: straight-line distance from node index to target coords."""
    return haversine(float(G.node_lats[idx]), float(G.node_lons[idx]),
                     target_lat, target_lon)


def _reconstruct_path(came_from, src_idx, tgt_idx):
    """Walk parent pointers from target back to source. Returns list of indices."""
    path = []
    cur = tgt_idx
    while cur != -1:
        path.append(cur)
        if cur == src_idx:
            break
        cur = int(came_from[cur])
    path.reverse()
    return path


def _path_distance(G, path_indices):
    """Sum edge weights along a path of node indices."""
    total = 0.0
    for i in range(len(path_indices) - 1):
        u = path_indices[i]
        targets, weights = G.neighbors(u)
        v = path_indices[i + 1]
        # Find the edge to v
        mask = targets == v
        total += float(weights[mask][0])
    return total


def shortest_path(G, source_osm, target_osm):
    """Find shortest path using A* with haversine heuristic.

    Args:
        G: CompactGraph
        source_osm: Source node OSM ID
        target_osm: Target node OSM ID

    Returns:
        (path, distance) where path is a list of OSM node IDs and distance is in meters.
        Returns (None, None) if no path exists.
    """
    if source_osm == target_osm:
        return [source_osm], 0.0

    src_idx = G.idx_for_osm_id(source_osm)
    tgt_idx = G.idx_for_osm_id(target_osm)

    target_lat = float(G.node_lats[tgt_idx])
    target_lon = float(G.node_lons[tgt_idx])
    num_nodes = G.number_of_nodes()

    came_from = np.full(num_nodes, -1, dtype=np.int32)
    g_score = np.full(num_nodes, np.inf, dtype=np.float64)
    g_score[src_idx] = 0.0

    counter = 0
    # Priority queue: (f_score, g_score, counter, node_idx)
    open_set = [(0.0, 0.0, counter, src_idx)]

    while open_set:
        f, g, _, current = heapq.heappop(open_set)

        if current == tgt_idx:
            path_indices = _reconstruct_path(came_from, src_idx, tgt_idx)
            path_osm = [int(G.node_ids[i]) for i in path_indices]
            return path_osm, g

        if g > g_score[current]:
            continue

        targets, weights = G.neighbors(current)
        for j in range(len(targets)):
            neighbor = int(targets[j])
            new_g = g + float(weights[j])

            if new_g < g_score[neighbor]:
                g_score[neighbor] = new_g
                came_from[neighbor] = current
                h = _heuristic_idx(G, neighbor, target_lat, target_lon)
                counter += 1
                heapq.heappush(open_set, (new_g + h, new_g, counter, neighbor))

    return None, None


def path_to_edges(path):
    """Convert a node path to a list of edge tuples (OSM IDs)."""
    return [(path[i], path[i + 1]) for i in range(len(path) - 1)]


def _edge_key(n1, n2):
    """Canonical edge key for undirected lookup."""
    return (min(n1, n2), max(n1, n2))


def novelty_route(G, source, target, walked_edges, min_novelty=0.3, max_overhead=0.25):
    """Find a route that maximizes novel (unwalked) edges.

    Args:
        G: CompactGraph
        source: Start node OSM ID
        target: End node OSM ID
        walked_edges: Set of (min_node, max_node) edge keys that have been walked
        min_novelty: Minimum fraction of edges that should be novel (0.0 - 1.0)
        max_overhead: Maximum allowed overhead vs shortest path (0.0 - 1.0)

    Returns:
        dict with keys: path, distance, novelty, overhead, shortest_distance, edges
    """
    # Phase 1: Get baseline shortest path
    base_path, base_dist = shortest_path(G, source, target)
    if base_path is None:
        return None

    base_edges = path_to_edges(base_path)
    base_novel = _compute_novelty(base_edges, walked_edges)

    if base_novel >= min_novelty:
        return _build_result(base_path, base_dist, base_dist, walked_edges, G)

    if not walked_edges:
        return _build_result(base_path, base_dist, base_dist, walked_edges, G)

    # Phase 2: Iterative penalty search
    best_result = None
    best_novelty = base_novel

    lo_penalty = 1.0
    hi_penalty = 10.0

    for _ in range(5):
        path, dist = _penalized_astar(G, source, target, walked_edges, hi_penalty)
        if path is None:
            hi_penalty = (lo_penalty + hi_penalty) / 2
            continue
        edges = path_to_edges(path)
        novelty = _compute_novelty(edges, walked_edges)
        if novelty >= min_novelty:
            break
        hi_penalty *= 2
        if hi_penalty > 100:
            break

    for _ in range(10):
        mid_penalty = (lo_penalty + hi_penalty) / 2
        path, dist = _penalized_astar(G, source, target, walked_edges, mid_penalty)

        if path is None:
            hi_penalty = mid_penalty
            continue

        edges = path_to_edges(path)
        novelty = _compute_novelty(edges, walked_edges)
        overhead = (dist - base_dist) / base_dist if base_dist > 0 else 0

        if overhead <= max_overhead and novelty > best_novelty:
            best_novelty = novelty
            best_result = _build_result(path, dist, base_dist, walked_edges, G)

        if novelty < min_novelty:
            lo_penalty = mid_penalty
        elif overhead > max_overhead:
            hi_penalty = mid_penalty
        else:
            lo_penalty = mid_penalty

    if best_result is None or best_result["novelty"] < min_novelty:
        for penalty in [1.5, 2.0, 3.0, 5.0, 8.0]:
            path, dist = _penalized_astar(G, source, target, walked_edges, penalty)
            if path is None:
                continue
            edges = path_to_edges(path)
            novelty = _compute_novelty(edges, walked_edges)
            overhead = (dist - base_dist) / base_dist if base_dist > 0 else 0

            if overhead <= max_overhead and novelty > best_novelty:
                best_novelty = novelty
                best_result = _build_result(path, dist, base_dist, walked_edges, G)

    if best_result is None:
        best_result = _build_result(base_path, base_dist, base_dist, walked_edges, G)

    return best_result


def _penalized_astar(G, source_osm, target_osm, walked_edges, penalty_factor):
    """A* search with penalty on walked edges. Uses parent pointers."""
    if source_osm == target_osm:
        return [source_osm], 0.0

    src_idx = G.idx_for_osm_id(source_osm)
    tgt_idx = G.idx_for_osm_id(target_osm)

    target_lat = float(G.node_lats[tgt_idx])
    target_lon = float(G.node_lons[tgt_idx])
    num_nodes = G.number_of_nodes()

    came_from = np.full(num_nodes, -1, dtype=np.int32)
    g_score = np.full(num_nodes, np.inf, dtype=np.float64)
    g_score[src_idx] = 0.0

    counter = 0
    open_set = [(0.0, 0.0, counter, src_idx)]

    while open_set:
        f, g, _, current = heapq.heappop(open_set)

        if current == tgt_idx:
            # Reconstruct path and compute actual (unpenalized) distance
            path_indices = _reconstruct_path(came_from, src_idx, tgt_idx)
            path_osm = [int(G.node_ids[i]) for i in path_indices]
            actual_dist = _path_distance(G, path_indices)
            return path_osm, actual_dist

        if g > g_score[current]:
            continue

        current_osm = int(G.node_ids[current])
        targets, weights = G.neighbors(current)
        for j in range(len(targets)):
            neighbor = int(targets[j])
            edge_weight = float(weights[j])

            # Apply penalty to walked edges (using OSM IDs)
            neighbor_osm = int(G.node_ids[neighbor])
            ek = _edge_key(current_osm, neighbor_osm)
            effective_weight = edge_weight
            if ek in walked_edges:
                effective_weight *= penalty_factor

            new_g = g + effective_weight

            if new_g < g_score[neighbor]:
                g_score[neighbor] = new_g
                came_from[neighbor] = current
                h = _heuristic_idx(G, neighbor, target_lat, target_lon)
                counter += 1
                heapq.heappush(open_set, (new_g + h, new_g, counter, neighbor))

    return None, None


def _compute_novelty(edges, walked_edges):
    """Compute fraction of edges that are novel (not walked)."""
    if not edges:
        return 1.0
    novel = sum(1 for e in edges if _edge_key(*e) not in walked_edges)
    return novel / len(edges)


def _build_result(path, distance, base_distance, walked_edges, G=None):
    """Build a route result dictionary."""
    edges = path_to_edges(path)
    novelty = _compute_novelty(edges, walked_edges)
    overhead = (distance - base_distance) / base_distance if base_distance > 0 else 0

    result = {
        "path": path,
        "edges": edges,
        "distance": distance,
        "shortest_distance": base_distance,
        "novelty": novelty,
        "overhead": overhead,
    }

    if G is not None and G.has_name_data():
        result["instructions"] = generate_instructions(path, G)

    return result


# Highway type fallback descriptions
_HIGHWAY_DESCRIPTIONS = {
    "footway": "footpath",
    "path": "path",
    "pedestrian": "pedestrian way",
    "steps": "steps",
    "cycleway": "cycleway",
    "residential": "road",
    "living_street": "road",
    "tertiary": "road",
    "tertiary_link": "road",
    "secondary": "road",
    "secondary_link": "road",
    "primary": "road",
    "primary_link": "road",
    "trunk": "road",
    "service": "service road",
    "track": "track",
    "unclassified": "road",
}


def _compass_direction(bearing_deg):
    """Convert bearing in degrees to compass direction string."""
    dirs = ["north", "northeast", "east", "southeast",
            "south", "southwest", "west", "northwest"]
    idx = int((bearing_deg + 22.5) % 360 / 45) % 8
    return dirs[idx]


def _classify_turn(angle):
    """Classify turn from signed angle (negative=left, positive=right)."""
    abs_angle = abs(angle)
    if abs_angle < 15:
        return "straight"
    elif abs_angle < 45:
        return "slight_left" if angle < 0 else "slight_right"
    elif abs_angle < 120:
        return "left" if angle < 0 else "right"
    elif abs_angle < 160:
        return "sharp_left" if angle < 0 else "sharp_right"
    else:
        return "u_turn"


_TURN_PREFIXES = {
    "start": "Head",
    "straight": "Continue",
    "slight_left": "Turn slight left",
    "slight_right": "Turn slight right",
    "left": "Turn left",
    "right": "Turn right",
    "sharp_left": "Turn sharp left",
    "sharp_right": "Turn sharp right",
    "u_turn": "Make a U-turn",
    "arrive": "Arrive",
}


def generate_instructions(path, G):
    """Generate turn-by-turn navigation instructions from a route path.

    Args:
        path: List of OSM node IDs
        G: CompactGraph with name data

    Returns:
        List of instruction dicts, or None if no name data
    """
    if not G.has_name_data():
        return None
    if len(path) < 2:
        return None

    # Convert to indices
    indices = [G.idx_for_osm_id(osm_id) for osm_id in path]

    # For each edge: compute bearing, look up name/highway, compute distance
    edges = []
    for i in range(len(indices) - 1):
        u_idx = indices[i]
        v_idx = indices[i + 1]

        lat1 = float(G.node_lats[u_idx])
        lon1 = float(G.node_lons[u_idx])
        lat2 = float(G.node_lats[v_idx])
        lon2 = float(G.node_lons[v_idx])

        b = bearing(lat1, lon1, lat2, lon2)
        d = haversine(lat1, lon1, lat2, lon2)

        name = G.edge_name(u_idx, v_idx)
        highway = G.edge_highway(u_idx, v_idx)

        # Effective name: street name if present, else fallback
        if name:
            effective_name = name
        elif highway:
            effective_name = _HIGHWAY_DESCRIPTIONS.get(highway, "road")
        else:
            effective_name = "road"

        edges.append({
            "bearing": b, "distance": d, "name": name,
            "highway": highway, "effective_name": effective_name,
            "start_idx": i,
        })

    if not edges:
        return None

    # Group consecutive edges with the same effective name
    groups = []
    group_start = 0
    while group_start < len(edges):
        group_end = group_start + 1
        while (group_end < len(edges) and
               edges[group_end]["effective_name"] == edges[group_start]["effective_name"]):
            group_end += 1

        total_dist = sum(edges[j]["distance"] for j in range(group_start, group_end))
        groups.append({
            "effective_name": edges[group_start]["effective_name"],
            "street_name": edges[group_start]["name"],
            "total_distance": total_dist,
            "entry_bearing": edges[group_start]["bearing"],
            "exit_bearing": edges[group_end - 1]["bearing"],
            "start_idx": edges[group_start]["start_idx"],
        })
        group_start = group_end

    # Generate instructions
    steps = []
    for i, group in enumerate(groups):
        node_idx = indices[group["start_idx"]]
        lat = float(G.node_lats[node_idx])
        lon = float(G.node_lons[node_idx])

        if i == 0:
            compass = _compass_direction(group["entry_bearing"])
            instruction = f"Head {compass} on {group['effective_name']}"
            turn_direction = "start"
            turn_angle = 0.0
        else:
            prev_exit = groups[i - 1]["exit_bearing"]
            this_entry = group["entry_bearing"]
            angle = this_entry - prev_exit
            # Normalize to [-180, 180]
            while angle > 180:
                angle -= 360
            while angle < -180:
                angle += 360

            turn_angle = angle
            turn_direction = _classify_turn(angle)
            prefix = _TURN_PREFIXES[turn_direction]
            if turn_direction == "straight":
                instruction = f"{prefix} on {group['effective_name']}"
            else:
                instruction = f"{prefix} onto {group['effective_name']}"

        steps.append({
            "instruction": instruction,
            "street_name": group["street_name"],
            "street_description": group["effective_name"],
            "distance": group["total_distance"],
            "turn_direction": turn_direction,
            "turn_angle": turn_angle,
            "start_lat": lat,
            "start_lon": lon,
        })

    # Final arrive step
    last_idx = indices[-1]
    steps.append({
        "instruction": "Arrive at destination",
        "street_name": None,
        "street_description": "",
        "distance": 0,
        "turn_direction": "arrive",
        "turn_angle": 0,
        "start_lat": float(G.node_lats[last_idx]),
        "start_lon": float(G.node_lons[last_idx]),
    })

    return steps
