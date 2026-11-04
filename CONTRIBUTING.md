# Contributing to Contrail

Thanks for helping! A few ground rules keep the project healthy.

## Clean room

Contrail is an independent, original project. Don't decompile, disassemble, or copy code, assets, icons, wording, or screenshots from any other cursor-trail app, commercial or otherwise. Describe ideas in your own words and build them from public documentation and your own observation of behavior.

## Getting started

1. Open `Contrail.xcodeproj` in Xcode 26 or later and press Run.
2. Run the core tests: `cd Packages/ContrailCore && swift test`.

Logic that doesn't need AppKit (trail model, geometry, settings) belongs in `Packages/ContrailCore` with tests. App, window and rendering code lives in `Contrail/`.

## Guidelines

- The trail must keep needing **no permissions**, and must use ~0% CPU when the cursor is still. Check Activity Monitor before and after your change.
- Keep the Swift 6 strict-concurrency build free of warnings.
- Settings are stored as versioned JSON (`TrailSettings`). New fields need a default so older settings still load.
- Rendering changes: run `Contrail.app/Contents/MacOS/Contrail --snapshot out.png [--preset cyan] [--matte]` and attach before/after images to your pull request.
- Keep pull requests small and focused, and explain the problem they solve.

By contributing, you agree that your contributions are licensed under the GPL-3.0.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Tag `vX.Y.Z` and push the tag. The release workflow:
   - builds the universal app
   - signs it ad hoc from the inside out
   - writes `appcast.xml`, signed with the `SPARKLE_ED_PRIVATE_KEY` secret
   - fills in `packaging/contrail.rb`
   - publishes everything as a GitHub release
3. Run `scripts/update-tap.sh X.Y.Z` to publish the cask to `Kiril-P/homebrew-tap`.

The Sparkle private key also lives in the maintainer's login keychain, under the account `contrail`. **Back it up.** Without it, existing installs can never be updated again.
