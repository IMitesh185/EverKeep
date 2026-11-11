# ADR-0002: Preserved output goes to Photos; a vault comes later

- Status: Accepted by the owner
- Date: 2026-11-06

## Context

The constitution moves preserved media into a private vault and offers restoration. That takes
the item out of Photos, which breaks normal browsing, and adds a gallery, thumbnails, search,
encryption and key management. It saves no extra bytes when the preserved file is a standard
format that Photos can store. Lossy output also cannot be decoded back to the original, so
"restoration" can only be an export.

## Decision

A preserved item is written back into Photos by default. A private vault is a later, opt-in
destination, used only when the best output format cannot be stored in Photos. Check each
format's Photos support when that time comes.

## Consequences

- v1 has no vault, no restoration screen and no encryption or key management. Browsing stays in
  Photos.
- The seam is kept: a `DestinationPort` with `PhotosDestination` now and `VaultDestination`
  later, a `destination` column on `PreservedAsset`, and a reserved `Vaulted` lifecycle state.
- Until the vault exists, items whose best format would need it are `NOT_ELIGIBLE` with reason
  `FORMAT_NEEDS_VAULT`.
- Undo for an original is the iOS Recently Deleted window (Reported), not an Everkeep restore.
- Revisit if Experiment 0 shows a format Photos cannot store is needed to clear the savings bar.

## 2026-11-07 clarification

The owner accepted Photos-generated thumbnails from optimized replacements, provided browsing
quality is checked. Everkeep is an optimizer with selection/review previews, not a second gallery.
No independent original-thumbnail archive is retained. The candidate is imported into Photos,
native previews are checked, and only then is original deletion requested. Keeping both full
versions permanently is not the storage-saving design.

Replacement affects iCloud-synced libraries as well as this phone. Actual local reclamation depends
on Recently Deleted and the device's iCloud storage policy; the UI labels file-size reduction separately.
