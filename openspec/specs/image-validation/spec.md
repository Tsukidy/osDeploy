# image-validation Specification

## Purpose
TBD - created by archiving change osdeploy-suite-design. Update Purpose after archive.

## Requirements

### Requirement: Multi-index image validation

The engine MUST validate that a Windows image contains both the Home and Pro indexes, and MUST reject the image if either index is missing or if architecture, language, release, or build compatibility is inconsistent. Exact index names and numbers MUST be recorded (Q47).

#### Scenario: Missing index rejects the image

- **WHEN** an image is validated that lacks either the Home or the Pro index
- **THEN** validation fails and the image is not promoted or used

#### Scenario: Inconsistent metadata rejects the image

- **WHEN** an image's architecture, language, release, or build compatibility is inconsistent with the target requirements
- **THEN** validation fails with the inconsistency identified

### Requirement: Temporary-download-then-promote lifecycle

An image update MUST download into a temporary file, validate hash, integrity, architecture, language, release, and both indexes, and only then atomically promote it to the permanent cache. Installation MUST use only the promoted cache, and invalid temporary content MUST be removed (Q48, Q51).

#### Scenario: Failed validation never touches the cache

- **WHEN** a downloaded temporary image fails validation
- **THEN** the temporary content is removed and the permanent cache is unchanged

#### Scenario: Promotion is atomic

- **WHEN** a temporary image passes validation and is promoted
- **THEN** the cache either fully contains the new image or fully retains the previous one, with no intermediate state

### Requirement: Existing cache retained until replacement validates

The existing validated cache MUST be retained until a replacement image has been fully validated and committed, and erasure MUST NOT occur during an incomplete update (Q48).

#### Scenario: Incomplete update preserves the cache

- **WHEN** a newer-image update is interrupted or fails validation
- **THEN** the previous validated cache remains installed and usable

### Requirement: Reopen and revalidate after promotion

After promotion, the image MUST be reopened and revalidated before installation begins (Q51).

#### Scenario: Promoted image is revalidated before install

- **WHEN** a newly promoted image is about to be used for installation
- **THEN** it is reopened and passes the full validation again, and a cache whose reopen fails is not used

### Requirement: No erasure without a validated source

Deployment Erase MUST NOT begin until a usable image source for the requested edition has been validated. When the requested edition is unavailable, the engine MUST offer Choose Another Edition, Use Saved Default Edition, or Cancel Recovery, and MUST NOT substitute silently (Q46).

#### Scenario: Unavailable edition offers choices

- **WHEN** the validated image does not contain the requested edition
- **THEN** the established choices are offered and no silent substitution occurs

### Requirement: Online-first acquisition with local fallback

When internet access is available, the engine MUST check Microsoft through the local OSDCloud instance for a newer compatible image before destructive work; when online acquisition is unavailable or fails, the validated local cache MUST be used (Q39, Q40, Q48, Q91).

#### Scenario: Offline run uses the cache

- **WHEN** no internet access is available and the local cache holds a validated image
- **THEN** the run proceeds from the cache without requiring connectivity
