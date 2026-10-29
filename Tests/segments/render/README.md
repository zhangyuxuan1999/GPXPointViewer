# Segment renderer: actual Swift + Metal regression

Run `python3 Tests/segments/render/run.py --current-core --output <NEW_EVIDENCE_DIRECTORY>` after integrating the core and renderer changes. `--current-core` compiles the live GPXParser/TrackData/GeoCompute; omit it to reproduce the frozen core snapshot used for independent acceptance. Every input hash, complete command/stdout/stderr and PNG is saved. No SDK, network or app window is used. Exit 77 means GPU unavailable, never a pass. A sandbox may need the task's explicit GPU-device permission.

The actual MetalPointRenderer.swift and Shaders.metal are always compiled/read from the containing source tree. The unrelated dependencies are actual P3 baseline copies so parallel gap/UI API changes cannot alter this isolated test; they are not stubs. The core snapshot is the final P4-A version. Product integration/Release/UI checks remain separate.

The suite compares actual GPU endpoint expansion to known source-input answers, renders the production line/fog encoding helpers to textures, checks actual old-shader negative controls, verifies implicit file masks and globe point shaders, holds old path/color versions behind shared-event gates, and records million-point plus 10,000-segment costs. Single identity lines use a dedicated fast vertex entry; multi-run lines use cached descriptors. Fog endpoints and partial tail edges are retained at arbitrary stride.

`fixtures/Shaders-before.metal` is the unchanged pre-P4 source used only as a negative control. `p3.swift` wraps the already validated 17-check immutable-color regression. GPU timing uses Metal command timestamps and alternating warm samples; it does not certify whole-app FPS or a worst-case memory bound.

Production diagnostic API: `renderer.topologyDrawStats` exposes cached segment/run/primitive counts, plan rebuilds and last actual draw-call counts. `LineParams.fileMask` defaults to all visible. Empty fileID means implicit file 0; line/fog normalize partial masks on CPU, globe uses flags bit 3 to avoid reading a two-byte placeholder. Main UI owners must pass their visibility mask and enable line UI where previously gated.
