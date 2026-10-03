# Optional TCA comparison

This Apple-only Swift 6.4 package pins TCA exactly to 1.26.2 (verified tag object 377da4061db10d26337a71bb279c506bb951f50f). It is outside InnoFlow's root dependency graph. It has not been Apple-built or measured by the Linux implementation task; source presence is not comparison evidence. Commit the resolved transitive pins from the first approved Apple validation before publishing a reproducible result.

S1/S2/S3/S5/S6 use matching action counts, collection cardinality, observation registration, result checks, and setup-excluded intervals. S4 uses TCA ViewStore as its retained derived read-model counterpart to InnoFlow SelectedStore; its Combine implementation differs and must be disclosed. Do not collapse that result into a universal framework ranking. S5 uses an ordinary explicit SwiftUI binding over observable TCA state. No library internals or private SPI are benchmarked.

Run both executables on the same idle Apple-silicon host/toolchain with alternating order. Preserve raw output and exact sources. TCA 2.0 beta is outside this reproducible public-source comparison. Supplied prior-session numbers and subjective scores are not fresh evidence.
