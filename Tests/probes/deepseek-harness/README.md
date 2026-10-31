# Build attribution and malformed GPU column probes

`python3 Tests/probes/deepseek-harness/test_harness.py` uses temporary fake source trees and fake bundles. It exercises the real manifest, explicit target selection, and suite coordinator with mocked subprocess/UI boundaries. It never runs the 25 UI scripts, xcodebuild, open, pkill, or a real app.

`python3 Tests/probes/deepseek-harness/run_metal_contract.py --output /ABS/NEW_DIRECTORY` compiles the actual MetalPointRenderer with the existing isolated render dependencies. Only the test copy of TrackData changes column immutability to permit malformed fixtures; the actual renderer is unchanged by the probe. CPU validation runs with no Metal device; available GPU checks validate rejection and clearing without a window or draw submission. The recorded result distinguishes GPU unavailable from passed GPU checks. This is a buffer contract probe, not the renderer's pixel/performance suite or whole-app validation.

`--build-only` compiles without running. To fill only a missing GPU-evidence gap, run the already compiled binary as `metal-contract /ABS/Shaders.metal /ABS/NEW-result.json --gpu-only`; it skips all previously completed CPU checks.
