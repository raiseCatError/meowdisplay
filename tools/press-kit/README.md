# Rebuilding the press kit

Run `python3 tools/press-kit/build.py` from the app repository. It verifies every approved file against its reviewed SHA-256 and requires live-capture provenance before creating `press.html` and `press-kit/MeowDisplay-Press-Kit.zip`.

The approved inventory contains final exports only. Raw screenshots, XCTest results, device identifiers, private metadata and capture tooling must stay outside Git. Review new exports at full resolution before updating their review record and hash. Apply native orientation before stripping metadata. Keep official screenshots separate from promotional compositions.

The live website is maintained separately in the private `raiseCatError/MeowDisplayWebsite` repository. Copy the generated `press.html` and `press-kit/` there on a feature branch; run its validate/package scripts. Production is not deployed by this builder.

Artwork sources: `iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png` and `press-kit/Brand/MeowDisplay-Logo-512.png`. Provenance: the logo is byte-identical to `public/logo.png` at tag `v2.0.0`, from which it was verified; that file was later removed with the legacy landing page and is not a current source. See the capture notes inside the kit for screenshot provenance. No original vector or dark/light variant was verified.
