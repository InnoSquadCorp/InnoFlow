## Summary

<!-- What changed and why? -->

## Contract Impact

<!-- Does this alter source/API/runtime/docs/CI contracts? If yes, list each surface updated. -->

## Verification

<!-- Paste the commands you ran and the result. -->

- [ ] `swift format lint --strict --recursive Sources Tests Examples`
- [ ] `swift test --package-path . -Xswiftc -warnings-as-errors`
- [ ] `swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1 -Xswiftc -warnings-as-errors`
- [ ] `./scripts/principle-gates.sh`

## Notes

<!-- Follow-up work, known limitations, or release notes. -->
