# TDLibFramework rebuild (BoringSSL `BN_nnmod` crash)

## Why
Crash `SIGSEGV` in `BN_nnmod` ← `EC_GROUP_new_by_curve_name_ex` ←
`tls_process_server_certificate` ← `td::HttpConnectionBase::loop`.
It is OpenSSL's EC parser inside the prebuilt `TDLibFramework` binary. Version
1.8.69 has the same defect, and disabling the in-app proxy does not help, so the
only real fix is a rebuilt framework.

## Build
```bash
cd /Users/admin/Fignyagram
TAG=1.8.69-18d36ada ./Tools/rebuild_tdlib.sh
```
The script:
1. clones `Swiftgram/TDLibFramework` at `TAG` with submodules;
2. exports `-DOPENSSL_NO_ASM` / `OPENSSL_NO_ASM=1` so the portable C EC code is
   used instead of the arm64 assembly path where the crash happens;
3. runs upstream `build.sh`;
4. copies the produced `TDLibFramework.xcframework` to
   `ThirdParty/TDLibFramework-rebuilt.xcframework`.

Logs: `<work-dir>/build.log`. Requires Xcode CLI tools, cmake, git, ~20 GB.

## Wire into the app
The project consumes TDLib through the **local** package
`~/Downloads/TDLibKit-1.5.2-tdlib-1.8.68-7601cdfb`:

1. Replace the vendored binary:
   ```bash
   cp -R ThirdParty/TDLibFramework-rebuilt.xcframework \
     ~/Downloads/TDLibKit-1.5.2-tdlib-1.8.68-7601cdfb/TDLibFramework.xcframework
   ```
2. If `Package.swift` points to a remote TDLibFramework (`.exact("1.8.69-…")`),
   switch that target to a local `binaryTarget`:
   ```swift
   .binaryTarget(name: "TDLibFramework",
                 path: "TDLibFramework.xcframework")
   ```
3. Re-resolve and build:
   ```bash
   xcodebuild -scheme Fignyagram -sdk iphoneos \
     -derivedDataPath /tmp/FignyagramBuild -allowProvisioningUpdates \
     -resolvePackageDependencies
   xcodebuild -scheme Fignyagram -sdk iphoneos \
     -derivedDataPath /tmp/FignyagramBuild -allowProvisioningUpdates build
   ```
4. Verify the fix: launch, wait 60 s, place a call, check
   `Documents/fignyagram_crash.log` is empty apart from the launch header.

## Rollback
Keep a copy of the original framework before replacing:
```bash
cp -R ~/Downloads/TDLibKit-…/TDLibFramework.xcframework /tmp/TDLibFramework.orig
```
Restore it and re-resolve packages to roll back.

## Notes
- `-DOPENSSL_NO_ASM` is a conservative workaround; if the crash persists in the
  C path, pin OpenSSL in the build to a release that contains the EC fix.
- The script does not modify the Fignyagram sources; UI/Duo/watchOS stay intact.
