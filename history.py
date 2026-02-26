#!/usr/bin/env python3
"""SQLite-backed edge traversal history."""

import os
import sqlite3
from datetime import datetime

DEFAULT_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "walk_history.db")


def _edge_key(n1, n2):
    """Return a canonical edge key (smaller node ID first) for undirected consistency."""
    return (min(n1, n2), max(n1, n2))


class WalkHistory:
    """Track which edges have been walked and how many times."""

    def __init__(self, db_path=DEFAULT_DB):
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        self.conn = sqlite3.connect(db_path)
        self._init_db()

    def _init_db(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS edge_history (
                edge_start INTEGER NOT NULL,
                edge_end INTEGER NOT NULL,
                walk_count INTEGER NOT NULL DEFAULT 1,
                last_walked TEXT NOT NULL,
                PRIMARY KEY (edge_start, edge_end)
            )
        """)
        self.conn.commit()

    def record_walk(self, route_edges):
        """Record a list of edges as walked.

        Args:
            route_edges: List of (node_a, node_b) tuples
        """
        now = datetime.now().isoformat()
        for n1, n2 in route_edges:
            start, end = _edge_key(n1, n2)
            self.conn.execute("""
                INSERT INTO edge_history (edge_start, edge_end, walk_count, last_walked)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(edge_start, edge_end)
                DO UPDATE SET walk_count = walk_count + 1, last_walked = ?
            """, (start, end, now, now))
        self.conn.commit()

    def get_walked_edges(self):
        """Return set of all walked edge keys."""
        cursor = self.conn.execute("SELECT edge_start, edge_end FROM edge_history")
        return {(row[0], row[1]) for row in cursor}

    def is_walked(self, n1, n2):
        """Check if a specific edge has been walked."""
        start, end = _edge_key(n1, n2)
        cursor = self.conn.execute(
            "SELECT walk_count FROM edge_history WHERE edge_start = ? AND edge_end = ?",
            (start, end),
        )
        row = cursor.fetchone()
        return row is not None

    def get_walk_count(self, n1, n2):
        """Get the number of times an edge has been walked."""
        start, end = _edge_key(n1, n2)
        cursor = self.conn.execute(
            "SELECT walk_count FROM edge_history WHERE edge_start = ? AND edge_end = ?",
            (start, end),
        )
        row = cursor.fetchone()
        return row[0] if row else 0

    def stats(self):
        """Return summary statistics about walk history."""
        cursor = self.conn.execute("""
            SELECT
                COUNT(*) as total_edges,
                SUM(walk_count) as total_walks,
                AVG(walk_count) as avg_walks_per_edge,
                MAX(walk_count) as max_walks,
                MIN(last_walked) as first_walk,
                MAX(last_walked) as last_walk
            FROM edge_history
        """)
        row = cursor.fetchone()
        return {
            "unique_edges_walked": row[0],
            "total_edge_traversals": row[1] or 0,
            "avg_walks_per_edge": round(row[2], 2) if row[2] else 0,
            "max_walks_single_edge": row[3] or 0,
            "first_walk": row[4],
            "last_walk": row[5],
        }

    def close(self):
        self.conn.close()
