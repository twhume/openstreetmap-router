#!/usr/bin/env python3
"""
Reliability test suite for the novelty-weighted pedestrian router.

Tests 20 route pairs across San Francisco at varying distances (1-10km),
evaluating routing success, performance, novelty behavior, and overhead compliance.
"""

import json
import os
import sys
import time
import tempfile

from graph_builder import build_graph, find_nearest_node, haversine
from router import shortest_path, novelty_route, path_to_edges, _edge_key
from history import WalkHistory

# 20 test route pairs across San Francisco, grouped by approximate distance
# Format: (name, start_lat, start_lon, end_lat, end_lon, approx_km)
TEST_ROUTES = [
    # ~1km routes
    ("Ferry Building to Embarcadero Center",
     37.7955, -122.3937, 37.7946, -122.4010, 1.0),
    ("Castro to Dolores Park",
     37.7609, -122.4350, 37.7596, -122.4269, 1.0),
    ("North Beach to Chinatown",
     37.8005, -122.4102, 37.7941, -122.4068, 1.0),

    # ~2km routes
    ("Union Square to Civic Center",
     37.7879, -122.4074, 37.7793, -122.4193, 2.0),
    ("Marina to Fisherman's Wharf",
     37.8010, -122.4370, 37.8080, -122.4177, 2.0),
    ("Mission to Potrero Hill",
     37.7599, -122.4148, 37.7614, -122.3929, 2.0),

    # ~3km routes
    ("UCSF to Twin Peaks",
     37.7631, -122.4586, 37.7544, -122.4477, 3.0),
    ("Haight to SoMa",
     37.7692, -122.4481, 37.7785, -122.4055, 3.0),
    ("Noe Valley to Mission Bay",
     37.7502, -122.4337, 37.7706, -122.3930, 3.5),

    # ~4-5km routes
    ("Golden Gate Park East to Ferry Building",
     37.7694, -122.4530, 37.7955, -122.3937, 5.0),
    ("Sunset District to Haight-Ashbury",
     37.7535, -122.4900, 37.7692, -122.4481, 4.0),
    ("Presidio to Marina",
     37.7989, -122.4662, 37.8010, -122.4370, 4.0),

    # ~5-6km routes
    ("Richmond to North Beach",
     37.7800, -122.4650, 37.8005, -122.4102, 5.5),
    ("Bayview to Mission",
     37.7340, -122.3920, 37.7599, -122.4148, 5.0),
    ("Glen Park to Castro",
     37.7340, -122.4330, 37.7609, -122.4350, 5.0),

    # ~7-8km routes
    ("Ocean Beach to Embarcadero",
     37.7604, -122.5097, 37.7946, -122.4010, 8.0),
    ("Presidio to Mission Dolores",
     37.7989, -122.4662, 37.7596, -122.4269, 7.0),

    # ~9-10km routes
    ("Golden Gate Bridge to Dogpatch",
     37.8078, -122.4750, 37.7578, -122.3870, 10.0),
    ("Lands End to AT&T Park",
     37.7867, -122.5054, 37.7786, -122.3893, 10.0),
    ("Outer Sunset to Embarcadero",
     37.7535, -122.5050, 37.7946, -122.4010, 10.0),
]


def run_test_suite():
    """Run the full test suite and produce a reliability report."""
    print("=" * 80)
    print("NOVELTY-WEIGHTED PEDESTRIAN ROUTER - RELIABILITY TEST SUITE")
    print("=" * 80)

    # Load graph
    print("\nLoading graph...")
    t0 = time.time()
    G = build_graph()
    graph_load_time = time.time() - t0
    print(f"Graph loaded in {graph_load_time:.1f}s: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges\n")

    # Use a temporary database for testing
    tmp_db = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    tmp_db.close()

    results = []

    # ===== PHASE 1: Shortest path reliability =====
    print("=" * 80)
    print("PHASE 1: SHORTEST PATH RELIABILITY")
    print("=" * 80)
    print(f"{'#':<3} {'Route':<45} {'Snap(m)':<10} {'Dist(m)':<10} {'Edges':<7} {'Time(s)':<8} {'OK'}")
    print("-" * 95)

    for i, (name, slat, slon, elat, elon, approx_km) in enumerate(TEST_ROUTES):
        t0 = time.time()

        src_node, src_snap = find_nearest_node(G, slat, slon)
        tgt_node, tgt_snap = find_nearest_node(G, elat, elon)
        snap_dist = max(src_snap, tgt_snap)

        path, dist = shortest_path(G, src_node, tgt_node)
        elapsed = time.time() - t0

        success = path is not None
        result = {
            "name": name,
            "approx_km": approx_km,
            "src_snap_m": round(src_snap, 1),
            "tgt_snap_m": round(tgt_snap, 1),
            "snap_max_m": round(snap_dist, 1),
            "shortest_path_found": success,
            "shortest_dist_m": round(dist, 1) if dist else None,
            "shortest_edges": len(path) - 1 if path else 0,
            "shortest_time_s": round(elapsed, 2),
            "src_node": src_node,
            "tgt_node": tgt_node,
            "shortest_path": path,
        }

        status = "OK" if success else "FAIL"
        dist_str = f"{dist:.0f}" if dist else "N/A"
        edges_str = str(len(path) - 1) if path else "N/A"
        print(f"{i+1:<3} {name:<45} {snap_dist:<10.0f} {dist_str:<10} {edges_str:<7} {elapsed:<8.2f} {status}")

        results.append(result)

    # ===== PHASE 2: Novelty routing (fresh history) =====
    print("\n" + "=" * 80)
    print("PHASE 2: NOVELTY ROUTING (NO HISTORY - SHOULD MATCH SHORTEST)")
    print("=" * 80)
    print(f"{'#':<3} {'Route':<45} {'Novel%':<8} {'Overhead%':<10} {'Time(s)':<8} {'Match'}")
    print("-" * 85)

    history = WalkHistory(tmp_db.name)

    for i, r in enumerate(results):
        if not r["shortest_path_found"]:
            print(f"{i+1:<3} {r['name']:<45} {'SKIP (no shortest path)'}")
            r["novelty_fresh_ok"] = None
            continue

        t0 = time.time()
        walked = history.get_walked_edges()
        nr = novelty_route(G, r["src_node"], r["tgt_node"], walked)
        elapsed = time.time() - t0

        matches_shortest = (
            nr is not None and
            abs(nr["distance"] - r["shortest_dist_m"]) < 1.0
        )

        r["novelty_fresh_novelty"] = round(nr["novelty"] * 100, 1) if nr else None
        r["novelty_fresh_overhead"] = round(nr["overhead"] * 100, 1) if nr else None
        r["novelty_fresh_time_s"] = round(elapsed, 2)
        r["novelty_fresh_ok"] = matches_shortest

        if nr:
            match_str = "YES" if matches_shortest else "NO"
            print(f"{i+1:<3} {r['name']:<45} {nr['novelty']*100:<8.1f} {nr['overhead']*100:<10.1f} {elapsed:<8.2f} {match_str}")
        else:
            print(f"{i+1:<3} {r['name']:<45} {'FAIL'}")

    # ===== PHASE 3: Record all shortest paths, then re-route =====
    print("\n" + "=" * 80)
    print("PHASE 3: NOVELTY ROUTING AFTER RECORDING SHORTEST PATHS")
    print("=" * 80)

    # Record all shortest paths as walked
    recorded_count = 0
    for r in results:
        if r["shortest_path_found"] and r["shortest_path"]:
            edges = path_to_edges(r["shortest_path"])
            history.record_walk(edges)
            recorded_count += len(edges)

    walked = history.get_walked_edges()
    print(f"Recorded {recorded_count} edge traversals ({len(walked)} unique edges in history)\n")

    print(f"{'#':<3} {'Route':<40} {'ShortD':<8} {'NovelD':<8} {'Novel%':<8} {'Over%':<7} {'Time(s)':<8} {'Meets'}")
    print("-" * 95)

    for i, r in enumerate(results):
        if not r["shortest_path_found"]:
            print(f"{i+1:<3} {r['name']:<40} {'SKIP'}")
            r["novelty_walked_ok"] = None
            continue

        t0 = time.time()
        nr = novelty_route(G, r["src_node"], r["tgt_node"], walked,
                           min_novelty=0.3, max_overhead=0.25)
        elapsed = time.time() - t0

        if nr is None:
            print(f"{i+1:<3} {r['name']:<40} {'FAIL - no route found'}")
            r["novelty_walked_ok"] = False
            r["novelty_walked_time_s"] = round(elapsed, 2)
            continue

        meets_novelty = nr["novelty"] >= 0.3
        meets_overhead = nr["overhead"] <= 0.25
        meets_both = meets_novelty and meets_overhead
        changed = abs(nr["distance"] - r["shortest_dist_m"]) > 1.0

        r["novelty_walked_dist_m"] = round(nr["distance"], 1)
        r["novelty_walked_novelty"] = round(nr["novelty"] * 100, 1)
        r["novelty_walked_overhead"] = round(nr["overhead"] * 100, 1)
        r["novelty_walked_time_s"] = round(elapsed, 2)
        r["novelty_walked_changed"] = changed
        r["novelty_walked_meets_novelty"] = meets_novelty
        r["novelty_walked_meets_overhead"] = meets_overhead
        r["novelty_walked_meets_both"] = meets_both
        r["novelty_walked_ok"] = True  # Route was found
        r["novelty_walked_edges"] = len(nr["edges"])

        constraint = "BOTH" if meets_both else ("NOV" if meets_novelty else ("OVH" if meets_overhead else "NONE"))
        print(f"{i+1:<3} {r['name']:<40} {r['shortest_dist_m']:<8.0f} {nr['distance']:<8.0f} "
              f"{nr['novelty']*100:<8.1f} {nr['overhead']*100:<7.1f} {elapsed:<8.2f} {constraint}")

    # ===== PHASE 4: Record novelty routes, re-route again (double walk) =====
    print("\n" + "=" * 80)
    print("PHASE 4: RE-ROUTING AFTER RECORDING NOVELTY ROUTES (2ND WALK)")
    print("=" * 80)

    # Record novelty routes
    for r in results:
        if r.get("novelty_walked_ok") and r.get("novelty_walked_dist_m"):
            # Re-route to get edges (we didn't store them)
            nr = novelty_route(G, r["src_node"], r["tgt_node"], walked,
                               min_novelty=0.3, max_overhead=0.25)
            if nr:
                history.record_walk(nr["edges"])

    walked2 = history.get_walked_edges()
    print(f"History now has {len(walked2)} unique walked edges\n")

    print(f"{'#':<3} {'Route':<40} {'Novel%':<8} {'Over%':<7} {'Changed':<8} {'Time(s)':<8} {'Meets'}")
    print("-" * 85)

    for i, r in enumerate(results):
        if not r["shortest_path_found"]:
            print(f"{i+1:<3} {r['name']:<40} {'SKIP'}")
            continue

        t0 = time.time()
        nr = novelty_route(G, r["src_node"], r["tgt_node"], walked2,
                           min_novelty=0.3, max_overhead=0.25)
        elapsed = time.time() - t0

        if nr is None:
            print(f"{i+1:<3} {r['name']:<40} {'FAIL'}")
            r["novelty_2nd_ok"] = False
            continue

        prev_dist = r.get("novelty_walked_dist_m", r["shortest_dist_m"])
        changed = abs(nr["distance"] - prev_dist) > 1.0
        meets_novelty = nr["novelty"] >= 0.3
        meets_overhead = nr["overhead"] <= 0.25
        meets_both = meets_novelty and meets_overhead

        r["novelty_2nd_novelty"] = round(nr["novelty"] * 100, 1)
        r["novelty_2nd_overhead"] = round(nr["overhead"] * 100, 1)
        r["novelty_2nd_changed"] = changed
        r["novelty_2nd_meets_both"] = meets_both
        r["novelty_2nd_time_s"] = round(elapsed, 2)

        constraint = "BOTH" if meets_both else ("NOV" if meets_novelty else ("OVH" if meets_overhead else "NONE"))
        changed_str = "YES" if changed else "NO"
        print(f"{i+1:<3} {r['name']:<40} {nr['novelty']*100:<8.1f} {nr['overhead']*100:<7.1f} "
              f"{changed_str:<8} {elapsed:<8.2f} {constraint}")

    history.close()

    # ===== SUMMARY REPORT =====
    print("\n" + "=" * 80)
    print("SUMMARY REPORT")
    print("=" * 80)

    total = len(results)
    sp_found = sum(1 for r in results if r["shortest_path_found"])
    sp_failed = total - sp_found

    print(f"\n1. SHORTEST PATH RELIABILITY")
    print(f"   Routes tested:     {total}")
    print(f"   Paths found:       {sp_found}/{total} ({sp_found/total*100:.0f}%)")
    if sp_failed:
        print(f"   Paths NOT found:   {sp_failed}")
        for r in results:
            if not r["shortest_path_found"]:
                print(f"     - {r['name']}")

    # Snap distance analysis
    snap_dists = [r["snap_max_m"] for r in results]
    print(f"\n   Node snap distance (max of src/tgt):")
    print(f"     Mean:  {sum(snap_dists)/len(snap_dists):.0f}m")
    print(f"     Max:   {max(snap_dists):.0f}m")
    print(f"     >100m: {sum(1 for d in snap_dists if d > 100)}")

    # Timing
    sp_times = [r["shortest_time_s"] for r in results]
    print(f"\n   Shortest path timing:")
    print(f"     Mean:  {sum(sp_times)/len(sp_times):.2f}s")
    print(f"     Max:   {max(sp_times):.2f}s")
    print(f"     Min:   {min(sp_times):.2f}s")

    # Shortest distance vs expected
    print(f"\n   Distance accuracy (actual vs crow-flies approx):")
    for r in results:
        if r["shortest_path_found"]:
            ratio = r["shortest_dist_m"] / (r["approx_km"] * 1000) if r["approx_km"] > 0 else 0
            r["distance_ratio"] = ratio

    ratios = [r.get("distance_ratio", 0) for r in results if r.get("distance_ratio")]
    if ratios:
        print(f"     Mean ratio (actual/approx): {sum(ratios)/len(ratios):.2f}")
        print(f"     Min ratio:  {min(ratios):.2f}")
        print(f"     Max ratio:  {max(ratios):.2f}")

    # Phase 2 - fresh novelty
    fresh_tested = [r for r in results if r.get("novelty_fresh_ok") is not None]
    fresh_match = sum(1 for r in fresh_tested if r["novelty_fresh_ok"])
    print(f"\n2. NOVELTY ROUTING (NO HISTORY)")
    print(f"   Routes tested:     {len(fresh_tested)}")
    print(f"   Matched shortest:  {fresh_match}/{len(fresh_tested)} ({fresh_match/len(fresh_tested)*100:.0f}% - should be 100%)")

    # Phase 3 - walked novelty
    walked_tested = [r for r in results if r.get("novelty_walked_ok") is not None]
    walked_ok = sum(1 for r in walked_tested if r.get("novelty_walked_ok"))
    walked_both = sum(1 for r in walked_tested if r.get("novelty_walked_meets_both"))
    walked_novelty_only = sum(1 for r in walked_tested if r.get("novelty_walked_meets_novelty"))
    walked_overhead_only = sum(1 for r in walked_tested if r.get("novelty_walked_meets_overhead"))
    walked_changed = sum(1 for r in walked_tested if r.get("novelty_walked_changed"))

    print(f"\n3. NOVELTY ROUTING (AFTER 1ST WALK)")
    print(f"   Routes tested:     {len(walked_tested)}")
    print(f"   Routes found:      {walked_ok}/{len(walked_tested)}")
    print(f"   Route changed:     {walked_changed}/{walked_ok} ({walked_changed/walked_ok*100:.0f}% - should be high)" if walked_ok else "")
    print(f"   Meets BOTH:        {walked_both}/{walked_ok} ({walked_both/walked_ok*100:.0f}%)" if walked_ok else "")
    print(f"   Meets novelty:     {walked_novelty_only}/{walked_ok} ({walked_novelty_only/walked_ok*100:.0f}%)" if walked_ok else "")
    print(f"   Meets overhead:    {walked_overhead_only}/{walked_ok} ({walked_overhead_only/walked_ok*100:.0f}%)" if walked_ok else "")

    if walked_ok:
        novelties = [r["novelty_walked_novelty"] for r in results if r.get("novelty_walked_novelty") is not None]
        overheads = [r["novelty_walked_overhead"] for r in results if r.get("novelty_walked_overhead") is not None]
        times = [r["novelty_walked_time_s"] for r in results if r.get("novelty_walked_time_s") is not None]
        print(f"\n   Novelty % (after 1st walk):")
        print(f"     Mean:  {sum(novelties)/len(novelties):.1f}%")
        print(f"     Min:   {min(novelties):.1f}%")
        print(f"     Max:   {max(novelties):.1f}%")
        print(f"\n   Overhead % (after 1st walk):")
        print(f"     Mean:  {sum(overheads)/len(overheads):.1f}%")
        print(f"     Min:   {min(overheads):.1f}%")
        print(f"     Max:   {max(overheads):.1f}%")
        print(f"\n   Novelty routing timing:")
        print(f"     Mean:  {sum(times)/len(times):.2f}s")
        print(f"     Max:   {max(times):.2f}s")

    # Phase 4 - 2nd walk
    walk2_tested = [r for r in results if r.get("novelty_2nd_meets_both") is not None]
    walk2_both = sum(1 for r in walk2_tested if r["novelty_2nd_meets_both"])
    walk2_changed = sum(1 for r in walk2_tested if r.get("novelty_2nd_changed"))

    print(f"\n4. NOVELTY ROUTING (AFTER 2ND WALK)")
    print(f"   Routes tested:     {len(walk2_tested)}")
    print(f"   Meets BOTH:        {walk2_both}/{len(walk2_tested)} ({walk2_both/len(walk2_tested)*100:.0f}%)" if walk2_tested else "")
    print(f"   Route changed:     {walk2_changed}/{len(walk2_tested)} ({walk2_changed/len(walk2_tested)*100:.0f}%)" if walk2_tested else "")

    if walk2_tested:
        novelties2 = [r["novelty_2nd_novelty"] for r in results if r.get("novelty_2nd_novelty") is not None]
        overheads2 = [r["novelty_2nd_overhead"] for r in results if r.get("novelty_2nd_overhead") is not None]
        print(f"\n   Novelty % (after 2nd walk):")
        print(f"     Mean:  {sum(novelties2)/len(novelties2):.1f}%")
        print(f"     Min:   {min(novelties2):.1f}%")
        print(f"     Max:   {max(novelties2):.1f}%")

    # Overall assessment
    print(f"\n{'=' * 80}")
    print("OVERALL ASSESSMENT")
    print(f"{'=' * 80}")

    issues = []
    if sp_failed > 0:
        issues.append(f"- {sp_failed} shortest path(s) failed to find a route")
    if fresh_match < len(fresh_tested):
        issues.append(f"- {len(fresh_tested) - fresh_match} route(s) didn't match shortest path with empty history")
    if walked_ok and walked_both < walked_ok:
        issues.append(f"- {walked_ok - walked_both} route(s) failed to meet both novelty+overhead constraints after 1st walk")
    if walked_ok and walked_changed < walked_ok:
        issues.append(f"- {walked_ok - walked_changed} route(s) didn't change after recording walk history")
    if any(t > 30 for t in sp_times):
        issues.append(f"- Some shortest path queries took >30s")
    if any(r.get("novelty_walked_time_s", 0) > 60 for r in results):
        issues.append(f"- Some novelty routing queries took >60s")
    if max(snap_dists) > 200:
        issues.append(f"- Maximum node snap distance was {max(snap_dists):.0f}m (graph coverage gap)")

    if not issues:
        print("\nAll tests passed with no issues detected.")
    else:
        print(f"\nIssues found ({len(issues)}):")
        for issue in issues:
            print(f"  {issue}")

    # Cleanup
    os.unlink(tmp_db.name)

    # Save full results
    results_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "test_results.json")
    # Strip non-serializable fields
    for r in results:
        r.pop("shortest_path", None)
        r.pop("src_node", None)
        r.pop("tgt_node", None)
    with open(results_file, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nDetailed results saved to {results_file}")


if __name__ == "__main__":
    run_test_suite()
