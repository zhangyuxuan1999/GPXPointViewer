# Engine-label font/geometry probe

Run on macOS from any directory, using a new output path:

```sh
python3 Tests/probes/engine-labels/run.py /private/tmp/gpxpv-engine-labels-new
```

This extracts the actual `TrackStore.FillOverlay` EngineLabel extension from current ContentView.swift and compiles it with the production SwiftUI/AppKit font. Only the surrounding data type is stubbed. It does not launch GPXPointViewer, drive UI, alter preferences, call a model/API, or request routes.

The 24 cases compare real font-sized axis-aligned label rectangles, including vertical/horizontal/diagonal coincident paths, reversed headings, close parallel paths, crossing/curved paths, multiple collisions, unchanged noncolliding offsets, the exact 90pt gate, other statuses, degenerate paths and selection flags. Display and geometry share the same font and explicit outer frame. Counts/text/order stay part of the assertions.

The new evidence directory retains exact generated Swift source, production/check hashes, argv, full stdout/stderr and exit code. Use a different output path for every retry. A passing font/geometry probe does not replace the root agent's rebuilt-app screenshot review.
