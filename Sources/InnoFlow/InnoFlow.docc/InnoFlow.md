# ``InnoFlow``

InnoFlow is a reducer-first state management framework for SwiftUI.

## Overview

Use InnoFlow when you want:

- Explicit `State` and `Action` modeling
- Deterministic effect handling
- Testable reducer behavior
- Clear ownership of business state transitions

InnoFlow is the right layer for **domain and feature lifecycle** in the InnoSquad stack.
Navigation transitions belong in InnoRouter, transport/session lifecycle belongs in
InnoNetwork, and dependency graph validation belongs in InnoDI.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:PhaseDrivenModeling>

### Core Symbols

- ``Store``
- ``Reducer``
- ``PhaseTransition``
- ``PhaseTransitionGraph``
