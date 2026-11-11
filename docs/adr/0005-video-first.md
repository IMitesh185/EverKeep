# ADR-0005: Video first

- Status: Original video-only build scope amended by the owner on 2026-11-07. Experiments still gate shipping.
- Date: 2026-11-06

## Context

Photos are already efficient (HEIC), and the constitution itself lists "already efficient media"
as a recommendation. Video is where the bytes are.

## Decision

v1 recommends and processes video only. `ImageCompressionEngine` is deferred.

## Consequences

- Revisit once the lab has a photo branch that shows at least 15% savings at SSIM 0.98 or higher.
- Smaller v1 surface to test and to fail safely.

## 2026-11-07 amendment: photos and screenshots

The owner explicitly requested ordinary photos/screenshots as well as standard videos in the
implementation. ImageIO JPEG/PNG/HEIC processing is now included behind per-item choices and the
same prepare, validate, approve and Photos-replace transaction.

Screenshots/text-sensitive material gets gentler trials, including lossless PNG first for PNG
inputs. Alpha-bearing images stay PNG. Photo dimensions are retained even in Space first mode.
HDR/wide-colour, Live Photo pairing, RAW/depth and edited/special resources remain unchanged.

This expands what is built, not what is proven safe to ship. Photo savings, visual thresholds,
native previews and metadata fidelity still need calibration and Codemagic/device validation.
