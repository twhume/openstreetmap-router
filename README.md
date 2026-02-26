# OpenStreetMap Novelty Router

A pedestrian router that prefers streets you haven't walked before. Given a start and end point in the Bay Area, it finds walking routes that maximise novelty (unwalked edges) while staying within a configurable overhead of the shortest path.

There are two implementations: a Python CLI for desktop use, and a Swift library designed for embedding in iOS apps.

## How it works

1. **Graph** — OpenStreetMap data is parsed into a walkable street graph stored as Compressed Sparse Row (CSR) arrays. The Bay Area graph has ~3.5M nodes and ~3.9M undirected edges.
2. **Shortest path** — A* with a haversine heuristic finds the baseline route.
3. **Novelty routing** — A penalty-based A* applies a multiplier to previously-walked edges, then binary-searches over penalty factors to find the best route meeting the novelty and overhead constraints.
4. **Walk history** — A SQLite database tracks which edges you've walked. Each time you record a route, future routing avoids those edges.
5. **Turn-by-turn directions** — Street names and highway types from OSM are used to generate navigation instructions.

## Prerequisites

- Python 3.10+
- Swift 5.9+ (only needed for the Swift router)
- ~1GB free disk space for the OSM data and generated graph files

## Setup

```bash
# Create a virtual environment and install dependencies
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Building the data files

The graph files are not checked in (they're ~850MB total). Rebuild them from scratch:

```bash
# 1. Download the NorCal OSM extract from Geofabrik (~700MB)
python download_data.py

# 2. Build the walkable graph (parses the PBF, outputs data/walk_graph.npz)
#    Takes a few minutes; filters to the Bay Area bounding box.
python graph_builder.py

# 3. (Optional) Export to flat binary format for the Swift router
python export_graph.py
```

After this you'll have:
- `data/norcal-latest.osm.pbf` — raw OSM data
- `data/walk_graph.npz` — compressed CSR graph for Python (~61MB)
- `data/walk_graph.bin` — flat binary graph for Swift (~149MB)

## Usage (Python CLI)

```bash
source venv/bin/activate

# Find a route between two lat,lon points
python cli.py route --from "37.7955,-122.3937" --to "37.7596,-122.4269"

# With novelty constraints and auto-record
python cli.py route \
  --from "37.7955,-122.3937" \
  --to "37.7596,-122.4269" \
  --min-novelty 0.3 \
  --max-overhead 0.25 \
  --record

# Save route to a JSON file
python cli.py route --from "37.7955,-122.3937" --to "37.7596,-122.4269" -o route.json

# Record a previously saved route as walked
python cli.py record route.json

# View walk history statistics
python cli.py stats
```

### CLI options

| Option | Default | Description |
|--------|---------|-------------|
| `--min-novelty` | 0.3 | Minimum fraction of edges that should be new (0.0–1.0) |
| `--max-overhead` | 0.25 | Maximum extra distance vs shortest path (0.0–1.0) |
| `--record` / `--no-record` | off | Automatically record the route as walked |
| `-o` / `--output` | — | Save route coordinates and metadata to JSON |

## Swift router

The `swift-router/` directory contains a Swift package with a library (`RouterLib`) and a CLI test harness. RouterLib is a pure Swift library with no external dependencies, suitable for embedding in an iOS/macOS app.

```bash
# Build (requires the binary graph from step 3 above)
cd swift-router && swift build -c release

# Run the test suite
.build/release/RouterCLI ../data/walk_graph.bin
```

See [swift-router/README.md](swift-router/README.md) for API details and performance numbers.

## Running the test suite

The Python test suite runs 20 route pairs across San Francisco, testing shortest path reliability, novelty behaviour, and overhead compliance:

```bash
python test_routes.py
```

This requires the graph to be built first (steps 1–2 above).

## Project structure

```
├── cli.py              # CLI entry point (click-based)
├── router.py           # A* shortest path and novelty routing
├── graph_builder.py    # OSM PBF parsing and CSR graph construction
├── export_graph.py     # Convert .npz graph to flat binary for Swift
├── download_data.py    # Download OSM data from Geofabrik
├── history.py          # SQLite walk history tracking
├── test_routes.py      # 20-route reliability test suite
├── requirements.txt    # Python dependencies
└── swift-router/       # Swift implementation
    ├── Package.swift
    └── Sources/
        ├── RouterLib/  # Core library (iOS-ready)
        └── RouterCLI/  # CLI test harness
```
