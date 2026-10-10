# Sample App Setup Guide

Requires Swift 6.3 or newer (Swift 6 language mode), with Xcode/SDK support for
the destination. The sample consumes this checkout through a local path; it does
not prove a remotely installed release. See [version boundaries](../docs/DOCUMENTATION.md).

## Run the Canonical Sample

1. Open:

```text
Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcworkspace
```

2. Select the `InnoFlowSampleApp` scheme.
3. Run on an iOS 18 or newer simulator or device.

Important:
- Open the `.xcworkspace`, not the `.xcodeproj`.
- Most feature code lives in `InnoFlowSampleAppPackage`, not in the app shell target.

## Project Structure

```text
InnoFlowSampleApp/
├── InnoFlowSampleApp.xcworkspace
├── InnoFlowSampleApp.xcodeproj
├── InnoFlowSampleApp/
│   ├── InnoFlowSampleAppApp.swift
│   └── InnoFlowSampleApp.xctestplan
├── InnoFlowSampleAppPackage/
│   ├── Package.swift
│   ├── Sources/InnoFlowSampleAppFeature/
│   └── Tests/InnoFlowSampleAppFeatureTests/
└── InnoFlowSampleAppUITests/
```

## Troubleshooting

### No such module `InnoFlow`

1. In Xcode, run `File > Packages > Reset Package Caches`
2. Run `File > Packages > Resolve Package Versions`
3. Clean the project with `Product > Clean Build Folder`
4. Rebuild

### Local package path issues

Check [`Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Package.swift`](./InnoFlowSampleApp/InnoFlowSampleAppPackage/Package.swift).

The canonical sample uses one local path dependency:

- `../../../` (from `InnoFlowSampleAppPackage` to this checkout's root)

### CLI verification

```bash
swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1
```

## Checklist

1. The workspace opens successfully
2. `InnoFlowSampleAppFeature` resolves as a package product
3. The demo hub shows the ten demos listed in [the sample README](InnoFlowSampleApp/README.md)
4. Package tests pass
