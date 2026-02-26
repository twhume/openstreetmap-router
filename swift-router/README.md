# SwiftRouter

Swift port of the CSR graph and parent-pointer A* router for iOS. Provides shortest-path and novelty-weighted pedestrian routing over OpenStreetMap walk networks, with turn-by-turn navigation instructions.

## Architecture

```
swift-router/
├── Package.swift
└── Sources/
    ├── RouterLib/                        # Core library (iOS-ready, no UI dependencies)
    │   ├── Haversine.swift              # Great-circle distance + bearing
    │   ├── CompactGraph.swift           # CSR graph loader, KDTree, nearest-node, street names
    │   ├── Router.swift                 # A* shortest path, novelty routing, min-heap
    │   └── NavigationInstructions.swift # Turn-by-turn instruction generation
    └── RouterCLI/                        # CLI test harness
        └── main.swift                   # Runs 20 test routes across 4 phases
```

**RouterLib** is a pure Swift library with no external dependencies. It can be embedded directly in an iOS/macOS app.

## Binary graph format

The graph is stored as a flat binary file (`walk_graph.bin`, ~149 MB) exported from the Python pipeline via `export_graph.py`. The file is memory-mapped on load (`NSData` with `.mappedIfSafe`), so the graph doesn't need to be copied into RAM — the OS pages it in on demand.

### v1 layout (basic graph)

| Section | Type | Count |
|---------|------|-------|
| Header | `"CSRG"` magic, version u32, num_nodes u32, num_edges u32, 16 reserved | 32 bytes |
| node_ids | Int64 LE | num_nodes |
| node_lats | Float32 LE | num_nodes |
| node_lons | Float32 LE | num_nodes |
| adj_offsets | Int32 LE | num_nodes + 1 |
| adj_targets | Int32 LE | num_edges |
| adj_weights | Float32 LE | num_edges |

### v2 additions (street names + highway types)

| Section | Type | Count |
|---------|------|-------|
| edge_name_indices | UInt16 LE | num_edges |
| edge_highway_indices | UInt8 | num_edges |
| name_table | u32 count, then per string: u16 length + UTF-8 bytes | variable |
| highway_table | u32 count, then per string: u16 length + UTF-8 bytes | variable |

v1 binaries still load correctly — navigation instructions will be `nil`.

## Key types

### `CompactGraph`

Loads the binary graph and provides O(1) neighbor lookups via CSR offsets. Builds an OSM ID-to-index dictionary on init (~0.1s) and a KDTree lazily on first nearest-node query (~3.8s for 3.5M nodes).

For v2 graphs, provides street name and highway type lookups per edge.

```swift
let graph = try CompactGraph(contentsOf: url)
let (idx, meters) = graph.findNearestNode(lat: 37.79, lon: -122.41)
let (targets, weights) = graph.neighbors(idx)

// v2: street name data
if graph.hasNameData {
    let name = graph.edgeName(from: idx1, to: idx2)       // "Market Street" or nil
    let highway = graph.edgeHighway(from: idx1, to: idx2)  // "residential" or nil
}
```

### `shortestPath(_:source:target:)`

A* with haversine heuristic, parent-pointer path reconstruction, and a binary min-heap. Uses `Float` g-scores and `Int32` parent arrays for compact memory (~20 MB for 3.5M nodes).

```swift
if let result = shortestPath(graph, source: osmId1, target: osmId2) {
    print(result.path)      // [Int64] OSM node IDs
    print(result.distance)  // meters
}
```

### `noveltyRoute(_:source:target:walkedEdges:minNovelty:maxOverhead:)`

Finds paths that avoid previously-walked edges via penalty-based A* with binary search over penalty factors. Returns the best path meeting the novelty/overhead constraints, or falls back to the shortest path.

```swift
var walked = Set<EdgeKey>()
// ... populate from history ...
if let result = noveltyRoute(graph, source: src, target: tgt,
                              walkedEdges: walked,
                              minNovelty: 0.3, maxOverhead: 0.25) {
    print(result.novelty)   // fraction 0.0–1.0
    print(result.overhead)  // fraction, e.g. 0.05 = 5%
}
```

### `RouteResult`

Returned by both routing functions. Includes navigation instructions when the graph has street name data (v2).

```swift
public struct RouteResult {
    public let path: [Int64]
    public let edges: [EdgeKey]
    public let distance: Double
    public let shortestDistance: Double
    public let novelty: Double
    public let overhead: Double
    public let instructions: [NavigationStep]?  // nil for v1 graphs
}
```

### `NavigationStep` and `TurnDirection`

Turn-by-turn navigation instructions generated from route paths.

```swift
public enum TurnDirection {
    case start, straight, slightLeft, slightRight,
         left, right, sharpLeft, sharpRight, uTurn, arrive
}

public struct NavigationStep {
    public let instruction: String      // "Turn left onto Oak St"
    public let streetName: String?      // nil for unnamed ways
    public let streetDescription: String // "Oak St" or "footpath"
    public let distance: Double         // meters for this step
    public let turnDirection: TurnDirection
    public let turnAngle: Double        // degrees, negative=left
    public let startLat: Double
    public let startLon: Double
}
```

Instructions can also be generated directly:

```swift
if let steps = generateInstructions(path: osmIds, graph: graph) {
    for step in steps {
        print("\(step.instruction)  (\(Int(step.distance))m)")
    }
}
// Head southwest on footpath  (88m)
// Turn right onto pedestrian way  (405m)
// Turn right onto Commercial Street  (28m)
// Arrive at destination
```

Turn classification thresholds (angle from straight): <15° straight, 15-45° slight, 45-120° turn, 120-160° sharp, >160° U-turn.

### `EdgeKey`

Canonical undirected edge identifier (smaller OSM ID first). Used as the key in `Set<EdgeKey>` for walk history.

## Building and running

```bash
# Export the binary graph (one-time, from repo root)
source venv/bin/activate && python export_graph.py

# Build
cd swift-router && swift build -c release

# Run the 20-route test suite
.build/release/RouterCLI ../data/walk_graph.bin
```

## Performance

Measured on the Bay Area walk graph (3.5M nodes, 3.9M undirected edges):

| Operation | Time |
|-----------|------|
| Graph load + ID map | 0.7s |
| KDTree build (first nearest-node call) | ~3.8s |
| Shortest path (single query) | <0.01s |
| Novelty route (single query) | 0.01–0.25s |

The KDTree build is a one-time cost per graph load. On iOS, it can be triggered on a background thread during app startup.
