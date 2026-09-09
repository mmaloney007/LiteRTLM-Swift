# macOS framework identity repair

Base78b6a420abe418877f127a56cf08bb0c6a7cecd9. Six macOS framework identities and their intra-package references now resolve through framework paths. Existing valid versioned paths remain unchanged. The unused Swift runtime search path is removed only where measured header padding requires room; every dependency is checked against package identities or absolute system-library paths.

Implementation transforms a new package copy and preserves the original. All10iPhone/simulator slices are byte-identical, with file modes and symlink targets checked. Local ad-hoc signatures establish internal consistency; input revision/hash inventory records provenance, not vendor-signature endorsement.

Reproduce from a clean checkout of the base revision into an absent output directory:
`python3 scripts/repair-macos-frameworks.py /path/to/base-checkout /path/to/new-output evidence/macos_framework_repair/original_inventory.json`

Independent negative controls, exact committed revision verification and fresh app build remain owed. This checkpoint is not a release acceptance or inference claim. No release tag is created.

Independent checks identified a pre-existing CLiteRTLM signature seal mismatch for Headers/engine.h. Preserve the current pinned header bytes and reseal all seven macOS frameworks; strict verification now runs on all seven, not only the six install-name repairs. V2 transformation exit0 with unchanged original and ten non-macOS slices; independent supplemental output verification pending.

Independent supplemental V2 output verification passed: all seven macOS frameworks strict-signature valid; CLiteRTLM header bytes/mode unchanged; all ten non-macOS slices unchanged. Result recorded in independent_v2_results.json. Fresh app and committed dependency verification remain owed.
