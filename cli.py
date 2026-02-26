#!/usr/bin/env python3
"""CLI entry point for the novelty-weighted pedestrian router."""

import json
import os
import sys

import click

from graph_builder import build_graph, find_nearest_node
from history import WalkHistory
from router import shortest_path, novelty_route, path_to_edges, _edge_key, generate_instructions


def _load_graph():
    """Load graph, building from PBF if needed."""
    from graph_builder import DEFAULT_GRAPH, DEFAULT_PBF
    if not os.path.exists(DEFAULT_GRAPH) and not os.path.exists(DEFAULT_PBF):
        click.echo("Error: No graph or PBF data found. Run download_data.py first.", err=True)
        sys.exit(1)
    return build_graph()


def _parse_latlon(s):
    """Parse 'lat,lon' string into (lat, lon) tuple."""
    try:
        parts = s.split(",")
        return float(parts[0].strip()), float(parts[1].strip())
    except (ValueError, IndexError):
        raise click.BadParameter(f"Invalid lat,lon format: {s!r}. Expected format: 37.7955,-122.3937")


@click.group()
def cli():
    """Novelty-weighted pedestrian router for San Francisco."""
    pass


@cli.command()
@click.option("--from", "from_", required=True, help="Start point as 'lat,lon'")
@click.option("--to", required=True, help="End point as 'lat,lon'")
@click.option("--min-novelty", default=0.3, type=float, help="Minimum novelty fraction (0.0-1.0)")
@click.option("--max-overhead", default=0.25, type=float, help="Maximum overhead vs shortest path (0.0-1.0)")
@click.option("--record/--no-record", default=False, help="Automatically record route as walked")
@click.option("--output", "-o", type=click.Path(), help="Save route to JSON file")
def route(from_, to, min_novelty, max_overhead, record, output):
    """Find a novelty-weighted walking route between two points."""
    start_lat, start_lon = _parse_latlon(from_)
    end_lat, end_lon = _parse_latlon(to)

    click.echo("Loading graph...")
    G = _load_graph()

    click.echo(f"Finding nearest nodes...")
    src_node, src_dist = find_nearest_node(G, start_lat, start_lon)
    tgt_node, tgt_dist = find_nearest_node(G, end_lat, end_lon)

    click.echo(f"  Start: node {src_node} ({src_dist:.0f}m from input)")
    click.echo(f"  End:   node {tgt_node} ({tgt_dist:.0f}m from input)")

    # Load walk history
    history = WalkHistory()
    walked = history.get_walked_edges()
    click.echo(f"  Walk history: {len(walked)} edges previously walked")

    # Find route
    click.echo(f"\nRouting (min_novelty={min_novelty}, max_overhead={max_overhead})...")

    if walked:
        result = novelty_route(G, src_node, tgt_node, walked,
                               min_novelty=min_novelty, max_overhead=max_overhead)
    else:
        # No history — just use shortest path
        path, dist = shortest_path(G, src_node, tgt_node)
        if path:
            result = {
                "path": path,
                "edges": path_to_edges(path),
                "distance": dist,
                "shortest_distance": dist,
                "novelty": 1.0,
                "overhead": 0.0,
            }
            if G.has_name_data():
                result["instructions"] = generate_instructions(path, G)
        else:
            result = None

    if result is None:
        click.echo("No route found!", err=True)
        history.close()
        sys.exit(1)

    # Display results
    click.echo(f"\nRoute found:")
    click.echo(f"  Distance:  {result['distance']:.0f}m ({result['distance'] / 1000:.2f}km)")
    click.echo(f"  Shortest:  {result['shortest_distance']:.0f}m")
    click.echo(f"  Overhead:  {result['overhead'] * 100:.1f}%")
    click.echo(f"  Novelty:   {result['novelty'] * 100:.1f}%")
    click.echo(f"  Edges:     {len(result['edges'])}")

    # Walking time estimate (assuming 5 km/h)
    walk_minutes = result["distance"] / 1000 / 5 * 60
    click.echo(f"  Est. time: {walk_minutes:.0f} min")

    # Turn-by-turn directions
    instructions = result.get("instructions")
    if instructions:
        click.echo(f"\nTurn-by-turn directions:")
        for i, step in enumerate(instructions):
            dist = step["distance"]
            if step["turn_direction"] == "arrive":
                click.echo(f"  {i + 1}. {step['instruction']}")
            else:
                click.echo(f"  {i + 1}. {step['instruction']}  ({dist:.0f}m)")

    # Build coordinate list
    coords = []
    for node_id in result["path"]:
        idx = G.idx_for_osm_id(node_id)
        coords.append({"lat": float(G.node_lats[idx]),
                        "lon": float(G.node_lons[idx]),
                        "node_id": node_id})

    # Output
    route_data = {
        "distance_m": round(result["distance"], 1),
        "shortest_distance_m": round(result["shortest_distance"], 1),
        "overhead_pct": round(result["overhead"] * 100, 1),
        "novelty_pct": round(result["novelty"] * 100, 1),
        "num_edges": len(result["edges"]),
        "coordinates": coords,
        "edges": [list(e) for e in result["edges"]],
    }

    if output:
        with open(output, "w") as f:
            json.dump(route_data, f, indent=2)
        click.echo(f"\nRoute saved to {output}")

    if record:
        history.record_walk(result["edges"])
        click.echo(f"Route recorded as walked ({len(result['edges'])} edges)")

    history.close()


@cli.command()
@click.argument("route_file", type=click.Path(exists=True))
def record(route_file):
    """Record a previously saved route as walked."""
    with open(route_file) as f:
        route_data = json.load(f)

    edges = [tuple(e) for e in route_data["edges"]]
    history = WalkHistory()
    history.record_walk(edges)
    click.echo(f"Recorded {len(edges)} edges as walked.")
    history.close()


@cli.command()
def stats():
    """Show walk history statistics."""
    history = WalkHistory()
    s = history.stats()

    click.echo("Walk History Statistics:")
    click.echo(f"  Unique edges walked:    {s['unique_edges_walked']}")
    click.echo(f"  Total edge traversals:  {s['total_edge_traversals']}")
    click.echo(f"  Avg walks per edge:     {s['avg_walks_per_edge']}")
    click.echo(f"  Max walks (single edge):{s['max_walks_single_edge']}")
    click.echo(f"  First walk:             {s['first_walk'] or 'N/A'}")
    click.echo(f"  Last walk:              {s['last_walk'] or 'N/A'}")

    history.close()


if __name__ == "__main__":
    cli()
