import SwiftParser
import SwiftSyntax

public struct MigrationResult: Sendable {
  public let source: String
  public let changes: [String]
  public let blockers: [String]
  public var isChanged: Bool { !changes.isEmpty }
}

/// Syntax-only migration. An unresolved finding blocks the entire CLI write batch.
/// The parser determines every edit range; untouched bytes (including trivia) survive exactly.
public enum InnoFlowMigration {
  public static func migrate(_ source: String) -> MigrationResult {
    let file = Parser.parse(source: source)
    guard !file.hasError else {
      return .init(source: source, changes: [], blockers: ["Input contains syntax errors; no edits were planned."])
    }
    let visitor = MigrationVisitor(file: file)
    visitor.walk(file)
    let edits = visitor.edits.sorted { $0.start > $1.start }
    var bytes = Array(source.utf8)
    var previousStart = bytes.count + 1
    for edit in edits {
      guard edit.start >= 0, edit.start <= edit.end, edit.end <= previousStart else {
        return .init(source: source, changes: [], blockers: ["Overlapping edits require review; no edits were applied."])
      }
      bytes.replaceSubrange(edit.start..<edit.end, with: edit.replacement.utf8)
      previousStart = edit.start
    }
    let result = String(decoding: bytes, as: UTF8.self)
    guard !Parser.parse(source: result).hasError else {
      return .init(source: source, changes: [], blockers: ["Planned output did not parse; no edits were applied."])
    }
    return .init(source: result, changes: edits.reversed().map(\.reason), blockers: visitor.blockers)
  }
}

private struct Edit {
  let start: Int
  let end: Int
  let replacement: String
  let reason: String
}

private final class MigrationVisitor: SyntaxVisitor {
  var edits: [Edit] = []
  var blockers: [String] = []
  let importsTesting: Bool
  let importsFlow: Bool
  let locations: SourceLocationConverter

  init(file: SourceFileSyntax) {
    let imports = file.statements.compactMap { $0.item.as(ImportDeclSyntax.self)?.path.first?.name.text }
    importsTesting = imports.contains("InnoFlowTesting")
    importsFlow = imports.contains("InnoFlow") || imports.contains("InnoFlowCore") || importsTesting
    locations = .init(fileName: "", tree: file)
    super.init(viewMode: .sourceAccurate)
  }

  private func block(_ message: String, at node: some SyntaxProtocol) {
    let location = locations.location(for: node.positionAfterSkippingLeadingTrivia)
    blockers.append("\(location.line):\(location.column): \(message)")
  }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    // A generic typealias extension is not automatically restricted to the
    // alias's Never output. Bare EffectTask return annotations also stop
    // inheriting the nominal type's generic arguments. Neither changing them
    // to Self nor preserving them proves the helper's intended output contract.
    if (importsFlow || node.extendedType.is(MemberTypeSyntax.self)),
      isNamedType(node.extendedType, name: "EffectTask", modules: ["InnoFlow", "InnoFlowCore"])
        || namedClause(node.extendedType, name: "EffectTask") != nil {
      block("EffectTask extension requires manual review: the alias does not constrain extensions to Never, and bare EffectTask return types need generic arguments. Use an explicit ReducerEffect extension with Output == Never for output-free helpers, or deliberately support generic Output; review helper return types too.", at: node)
      return .skipChildren
    }
    return .visitChildren
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.attributes.contains(where: { element in
      guard let attribute = element.as(AttributeSyntax.self) else { return false }
      return isNamedType(attribute.attributeName, name: "InnoFlow", modules: ["InnoFlow"])
    }) else { return .visitChildren }

    // Resolving #if in nested declarations requires a compiler configuration.
    let conditional = ConditionalOutputVisitor()
    for member in node.memberBlock.members where member.decl.is(IfConfigDeclSyntax.self) { conditional.walk(member) }
    if conditional.hasOutput {
      block("Conditional nested Output needs a compiler-configuration decision; feature left unchanged.", at: node)
      return .visitChildren
    }
    if node.memberBlock.members.contains(where: { $0.decl.as(ActorDeclSyntax.self).map { logical($0.name.text) } == "Output" }) {
      block("Nested actor Output is outside the macro's recognized output declarations; confirm its intended contract manually.", at: node)
      return .visitChildren
    }
    let hasOutput = node.memberBlock.members.contains { namedDeclaration($0.decl) == "Output" }
    let output = hasOutput ? "Output" : "Never"
    let bodies = node.memberBlock.members.compactMap { $0.decl.as(VariableDeclSyntax.self) }.filter {
      $0.bindings.contains { $0.pattern.as(IdentifierPatternSyntax.self).map { logical($0.identifier.text) } == "body" }
    }
    let reduces = node.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }.filter {
      logical($0.name.text) == "reduce"
    }
    for function in reduces {
      guard bodies.isEmpty, reduces.count == 1 else {
        block("Explicit reduce with another body/reduce declaration requires manual composition.", at: function)
        continue
      }
      repairLegacyReduce(function, hasOutput: hasOutput)
    }
    for variable in bodies {
      guard variable.bindings.count == 1,
        let binding = variable.bindings.first,
        let opaque = binding.typeAnnotation?.type.as(SomeOrAnyTypeSyntax.self),
        opaque.someOrAnySpecifier.tokenKind == .keyword(.some),
        let clause = namedClause(opaque.constraint, name: "Reducer"),
        binding.accessorBlock != nil
      else {
        block("Unrecognized feature body signature; use explicit some Reducer<State, Action, \(output)>.", at: variable)
        continue
      }
      let arguments = Array(clause.arguments)
      guard [2, 3].contains(arguments.count),
        isFeatureType(arguments[0].argument, name: "State"),
        isFeatureType(arguments[1].argument, name: "Action")
      else {
        block("Reducer body uses noncanonical State/Action or arity; output cannot be inferred safely.", at: clause)
        continue
      }
      if arguments.count == 2 {
        edits.append(outputEdit(clause, output: output, reason: "Add explicit \(output) to \(logical(node.name.text)).body"))
      } else if !(hasOutput ? isFeatureType(arguments[2].argument, name: "Output") : isNever(arguments[2].argument)) {
        // The macro captures a direct nested Output. Fix the contract, never discard output.
        edits.append(replacement(arguments[2].argument, text: output, reason: "Repair \(logical(node.name.text)).body output to \(output)"))
      }
      let builders = BuilderVisitor(output: output)
      builders.walk(variable)
      edits.append(contentsOf: builders.edits)
      for finding in builders.blockers { block(finding, at: variable) }
    }
    return .visitChildren
  }

  private func repairLegacyReduce(_ function: FunctionDeclSyntax, hasOutput: Bool) {
    let parameters = Array(function.signature.parameterClause.parameters)
    let modifiers = function.modifiers.map { logical($0.name.text) }
    guard function.attributes.isEmpty,
      modifiers.allSatisfy({ ["public", "internal", "private", "fileprivate", "package"].contains($0) }),
      function.genericParameterClause == nil, function.genericWhereClause == nil,
      function.signature.effectSpecifiers == nil, parameters.count == 2,
      parameters[0].firstName.text == "into", parameters[0].secondName?.text == "state",
      parameters[0].type.trimmedDescription == "inout State",
      parameters[1].firstName.text == "action", parameters[1].secondName == nil,
      parameters[1].type.trimmedDescription == "Action",
      parameters.allSatisfy({ $0.defaultValue == nil && $0.attributes.isEmpty }),
      let resultType = function.signature.returnClause?.type,
      let effectOutput = legacyEffectOutput(resultType, hasOutput: hasOutput),
      let body = function.body, !body.statements.isEmpty,
      !hasComment(function.signature),
      !containsComment(function.funcKeyword.trailingTrivia.description), !hasComment(function.name)
    else {
      block("Explicit reduce is outside the canonical synchronous signature; preserve it for manual migration.", at: function)
      return
    }
    let unsafe = LegacyBodyVisitor()
    unsafe.walk(body)
    guard !unsafe.requiresReview else {
      block("Explicit reduce contains context-sensitive or recursive references; closure conversion needs review.", at: function)
      return
    }
    let output = hasOutput ? "Output" : "Never"
    let indent = String(function.leadingTrivia.description.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
      .prefix { $0 == " " || $0 == "\t" }
    let newline = function.description.contains("\r\n") ? "\r\n" : "\n"
    let promotion = hasOutput && effectOutput == "Never" ? "\(newline)\(indent)  .promoteOutput(to: Output.self)" : ""
    let header = "var body: some Reducer<State, Action, \(output)> {\(newline)\(indent)  Reduce<State, Action, \(effectOutput)> { state, action in"
    edits.append(.init(start: function.funcKeyword.positionAfterSkippingLeadingTrivia.utf8Offset,
                       end: body.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset,
                       replacement: header, reason: "Convert explicit reduce preserving \(effectOutput) effect output"))
    edits.append(.init(start: body.rightBrace.position.utf8Offset, end: body.rightBrace.position.utf8Offset,
                       replacement: "\(newline)\(indent)  }\(promotion)", reason: "Close reducer composition without reindenting source statements"))
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard importsFlow else { return .visitChildren }
    if calledName(node.calledExpression) == "FlowScope" {
      block("FlowScope construction requires an explicit lexical withFlowScope lifetime; escaping scope storage is not rewritten.", at: node)
    }
    if let member = node.calledExpression.as(MemberAccessExprSyntax.self), logical(member.declName.baseName.text) == "serial",
      let capacity = node.arguments.first(where: { $0.label?.text == "maxPending" }) {
      if !capacity.expression.is(IntegerLiteralExprSyntax.self) {
        block("serial(maxPending:) now takes UInt; prove range and ownership of this expression manually. No signed conversion was inserted.", at: capacity)
      }
    }
    if importsTesting, let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      logical(member.declName.baseName.text) == "advance", node.arguments.first?.label == nil,
      node.arguments.contains(where: { $0.label?.text == "by" }),
      !node.arguments.contains(where: { $0.label?.text == "onceSleepersReach" }),
      member.base == nil || member.base.map({ calledName($0, modules: ["InnoFlowTesting"]) == "TestStoreScenarioStep" }) == true {
      block("Scenario advance requires an explicit onceSleepersReach threshold; no sleeper count is guessed.", at: node)
    }
    guard importsTesting, let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      logical(member.declName.baseName.text) == "assertNoMoreActions"
    else { return .visitChildren }
    guard let receiver = member.base?.as(DeclReferenceExprSyntax.self) else {
      block("assertNoMoreActions receiver cannot be resolved to a local immutable TestStore.", at: node)
      return .visitChildren
    }
    let binding = localTestStoreBinding(receiver.baseName.text, before: node)
    if binding == .foreign { return .visitChildren }
    guard binding == .testStore else {
      block("assertNoMoreActions receiver is unresolved or mutable; confirm it is an InnoFlow TestStore.", at: node)
      return .visitChildren
    }
    let labels = node.arguments.map { $0.label?.text ?? "" }
    guard Set(labels).count == labels.count,
      labels.allSatisfy({ ["file", "line"].contains($0) }),
      node.trailingClosure == nil, node.additionalTrailingClosures.isEmpty,
      let context = terminalAsyncContext(node)
    else {
      block("assertNoMoreActions needs a terminal statement in an explicitly async function and supported file/line arguments; no async propagation is guessed.", at: node)
      return .visitChildren
    }
    edits.append(replacement(member.declName.baseName, text: "finish", reason: "Rename terminal TestStore.assertNoMoreActions to finish (source arguments preserved)"))
    if !context.awaited {
      edits.append(.init(start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                         end: node.positionAfterSkippingLeadingTrivia.utf8Offset,
                         replacement: "await ", reason: "Await finish in the existing async function"))
    }
    return .visitChildren
  }

  private enum Binding { case testStore, foreign, unresolved }

  private func localTestStoreBinding(_ name: String, before call: FunctionCallExprSyntax) -> Binding {
    var ancestor = call.parent
    while let node = ancestor {
      if let block = node.as(CodeBlockSyntax.self) {
        // Do not cross closures or scopes, and never infer from a later declaration.
        for item in block.statements.reversed() where item.position < call.position {
          guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
          for binding in variable.bindings where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
            guard variable.bindingSpecifier.tokenKind == .keyword(.let),
              let initializer = binding.initializer?.value.as(FunctionCallExprSyntax.self)
            else { return .unresolved }
            return calledName(initializer.calledExpression, modules: ["InnoFlowTesting"]) == "TestStore" ? .testStore : .foreign
          }
        }
        return .unresolved
      }
      if node.is(ClosureExprSyntax.self) { return .unresolved }
      ancestor = node.parent
    }
    return .unresolved
  }

  private func terminalAsyncContext(_ call: FunctionCallExprSyntax) -> (awaited: Bool, function: FunctionDeclSyntax)? {
    var current = Syntax(call)
    var awaited = false
    if let parent = current.parent, let expression = parent.as(AwaitExprSyntax.self) {
      guard expression.expression.id == current.id else { return nil }
      awaited = true
      current = parent
    }
    guard let item = current.parent?.as(CodeBlockItemSyntax.self), item.item.id == current.id,
      let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id,
      let block = list.parent?.as(CodeBlockSyntax.self),
      let function = block.parent?.as(FunctionDeclSyntax.self),
      function.signature.effectSpecifiers?.asyncSpecifier != nil
    else { return nil }
    return (awaited, function)
  }
}

private final class BuilderVisitor: SyntaxVisitor {
  let output: String
  var edits: [Edit] = []
  var blockers: [String] = []
  init(output: String) { self.output = output; super.init(viewMode: .sourceAccurate) }

  // A local helper, type or unrelated closure is a separate inference boundary.
  private func boundary(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
    let finder = UnresolvedBuilderVisitor()
    finder.walk(node)
    if finder.found { blockers.append("Two-argument reducer inside a helper/closure has an independent output context; migrate it manually.") }
    return .skipChildren
  }
  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { boundary(node) }
  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { boundary(node) }
  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { boundary(node) }
  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { boundary(node) }
  override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
    if let call = node.parent?.as(FunctionCallExprSyntax.self),
      let name = calledName(call.calledExpression), ["Reduce", "CombineReducers"].contains(name) { return .visitChildren }
    return boundary(node)
  }

  override func visit(_ node: GenericSpecializationExprSyntax) -> SyntaxVisitorContinueKind {
    guard let name = calledName(node.expression), ["Reduce", "CombineReducers"].contains(name) else { return .visitChildren }
    let arguments = Array(node.genericArgumentClause.arguments)
    guard [2, 3].contains(arguments.count) else { return .visitChildren }
    guard isFeatureType(arguments[0].argument, name: "State"), isFeatureType(arguments[1].argument, name: "Action") else {
      blockers.append("Review \(name) with foreign State/Action; enclosing feature cannot determine its output.")
      return .visitChildren
    }
    if arguments.count == 3 {
      if output == "Output", isNever(arguments[2].argument),
        let call = node.parent?.as(FunctionCallExprSyntax.self) {
        let adapter = call.parent?.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        if adapter != "promoteOutput" && adapter != "mapOutput" {
          blockers.append("Explicit Never reducer in a typed Output body needs a reviewed output promotion; existing three-argument contracts are not guessed.")
        }
      }
      return .visitChildren
    }
    // Builder closures use the surrounding body contract. Explicit EffectTask return
    // annotations have a stronger Never contract and must be lifted, not reinterpreted.
    if name == "Reduce", let call = node.parent?.as(FunctionCallExprSyntax.self),
      let returnType = call.trailingClosure?.signature?.returnClause?.type {
      guard let effectOutput = legacyEffectOutput(returnType, hasOutput: output == "Output") else {
        blockers.append("Reduce closure return annotation needs manual output migration.")
        return .visitChildren
      }
      edits.append(outputEdit(node.genericArgumentClause, output: effectOutput, reason: "Preserve annotated \(effectOutput) Reduce output"))
      if output == "Output" && effectOutput == "Never" {
        let end = call.endPositionBeforeTrailingTrivia.utf8Offset
        edits.append(.init(start: end, end: end, replacement: ".promoteOutput(to: Output.self)", reason: "Explicitly promote Never to the feature Output"))
      }
    } else {
      edits.append(outputEdit(node.genericArgumentClause, output: output, reason: "Add explicit \(output) output to \(name)"))
    }
    return .visitChildren
  }
}

private final class UnresolvedBuilderVisitor: SyntaxVisitor {
  var found = false
  init() { super.init(viewMode: .sourceAccurate) }
  override func visit(_ node: GenericSpecializationExprSyntax) -> SyntaxVisitorContinueKind {
    if let name = calledName(node.expression), ["Reduce", "CombineReducers"].contains(name),
      node.genericArgumentClause.arguments.count == 2 { found = true }
    return .visitChildren
  }
}

private final class ConditionalOutputVisitor: SyntaxVisitor {
  var hasOutput = false
  init() { super.init(viewMode: .sourceAccurate) }
  override func visit(_ node: MemberBlockItemSyntax) -> SyntaxVisitorContinueKind {
    if namedDeclaration(node.decl) == "Output" { hasOutput = true }
    // The container Output must be a feature member, not a nested State member.
    return node.decl.is(IfConfigDeclSyntax.self) ? .visitChildren : .skipChildren
  }
}

private final class LegacyBodyVisitor: SyntaxVisitor {
  var requiresReview = false
  init() { super.init(viewMode: .sourceAccurate) }
  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    if logical(node.baseName.text) == "reduce" { requiresReview = true }
    return .visitChildren
  }
  override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
    if ["function", "line", "column"].contains(node.macroName.text) { requiresReview = true }
    return .visitChildren
  }
}

private func replacement(_ node: some SyntaxProtocol, text: String, reason: String) -> Edit {
  .init(start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
        end: node.endPositionBeforeTrailingTrivia.utf8Offset, replacement: text, reason: reason)
}

private func outputEdit(_ clause: GenericArgumentClauseSyntax, output: String, reason: String) -> Edit {
  // Insert before trailing trivia so a line comment cannot swallow the new type.
  let last = clause.arguments.last!
  let position = last.trailingComma?.endPositionBeforeTrailingTrivia.utf8Offset
    ?? last.argument.endPositionBeforeTrailingTrivia.utf8Offset
  let separator = last.trailingComma == nil ? ", " : " "
  return .init(start: position, end: position, replacement: separator + output, reason: reason)
}

private func namedClause(_ type: TypeSyntax, name: String) -> GenericArgumentClauseSyntax? {
  if let identifier = type.as(IdentifierTypeSyntax.self), logical(identifier.name.text) == name {
    return identifier.genericArgumentClause
  }
  if let member = type.as(MemberTypeSyntax.self), logical(member.name.text) == name,
    let base = member.baseType.as(IdentifierTypeSyntax.self), ["InnoFlow", "InnoFlowCore"].contains(logical(base.name.text)),
    base.genericArgumentClause == nil { return member.genericArgumentClause }
  return nil
}

private func calledName(_ expression: ExprSyntax, modules: [String] = ["InnoFlow", "InnoFlowCore"]) -> String? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) { return logical(reference.baseName.text) }
  if let generic = expression.as(GenericSpecializationExprSyntax.self) { return calledName(generic.expression, modules: modules) }
  if let member = expression.as(MemberAccessExprSyntax.self),
    let base = member.base?.as(DeclReferenceExprSyntax.self), modules.contains(logical(base.baseName.text)) {
    return logical(member.declName.baseName.text)
  }
  return nil
}

private func isNamedType(_ type: TypeSyntax, name: String, modules: [String]) -> Bool {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return logical(identifier.name.text) == name && identifier.genericArgumentClause == nil }
  if let member = type.as(MemberTypeSyntax.self), logical(member.name.text) == name, member.genericArgumentClause == nil,
    let base = member.baseType.as(IdentifierTypeSyntax.self) { return modules.contains(logical(base.name.text)) && base.genericArgumentClause == nil }
  return false
}

private func isFeatureType(_ type: some SyntaxProtocol, name: String) -> Bool {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return logical(identifier.name.text) == name && identifier.genericArgumentClause == nil }
  if let member = type.as(MemberTypeSyntax.self), logical(member.name.text) == name, member.genericArgumentClause == nil,
    let base = member.baseType.as(IdentifierTypeSyntax.self) { return logical(base.name.text) == "Self" && base.genericArgumentClause == nil }
  return false
}

private func isNever(_ type: some SyntaxProtocol) -> Bool {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return logical(identifier.name.text) == "Never" && identifier.genericArgumentClause == nil }
  if let member = type.as(MemberTypeSyntax.self), logical(member.name.text) == "Never", member.genericArgumentClause == nil,
    let base = member.baseType.as(IdentifierTypeSyntax.self) { return logical(base.name.text) == "Swift" && base.genericArgumentClause == nil }
  return false
}

private func legacyEffectOutput(_ type: TypeSyntax, hasOutput: Bool) -> String? {
  if let clause = namedClause(type, name: "EffectTask"), clause.arguments.count == 1,
    let argument = clause.arguments.first, isFeatureType(argument.argument, name: "Action") { return "Never" }
  if let clause = namedClause(type, name: "ReducerEffect"), clause.arguments.count == 2 {
    let arguments = Array(clause.arguments)
    if isFeatureType(arguments[0].argument, name: "Action") {
      if isNever(arguments[1].argument) { return "Never" }
      if hasOutput && isFeatureType(arguments[1].argument, name: "Output") { return "Output" }
    }
  }
  return nil
}

private func namedDeclaration(_ declaration: DeclSyntax) -> String? {
  if let node = declaration.as(EnumDeclSyntax.self) { return logical(node.name.text) }
  if let node = declaration.as(StructDeclSyntax.self) { return logical(node.name.text) }
  if let node = declaration.as(ClassDeclSyntax.self) { return logical(node.name.text) }
  if let node = declaration.as(ActorDeclSyntax.self) { return logical(node.name.text) }
  if let node = declaration.as(TypeAliasDeclSyntax.self) { return logical(node.name.text) }
  return nil
}

private func containsComment(_ trivia: String) -> Bool { trivia.contains("//") || trivia.contains("/*") }

private func hasComment(_ node: some SyntaxProtocol) -> Bool {
  node.tokens(viewMode: .sourceAccurate).contains { token in
    containsComment(token.leadingTrivia.description + token.trailingTrivia.description)
  }
}

private func logical(_ text: String) -> String {
  text.hasPrefix("`") && text.hasSuffix("`") ? String(text.dropFirst().dropLast()) : text
}
