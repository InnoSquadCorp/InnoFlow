package com.innosquad.innoflow.ksp

import com.google.devtools.ksp.processing.CodeGenerator
import com.google.devtools.ksp.processing.Dependencies
import com.google.devtools.ksp.processing.KSPLogger
import com.google.devtools.ksp.processing.Resolver
import com.google.devtools.ksp.processing.SymbolProcessor
import com.google.devtools.ksp.processing.SymbolProcessorEnvironment
import com.google.devtools.ksp.processing.SymbolProcessorProvider
import com.google.devtools.ksp.symbol.KSAnnotated
import com.google.devtools.ksp.symbol.KSClassDeclaration
import com.google.devtools.ksp.symbol.KSType
import com.google.devtools.ksp.symbol.KSTypeArgument
import com.google.devtools.ksp.symbol.ClassKind
import com.google.devtools.ksp.symbol.Nullability
import com.google.devtools.ksp.symbol.Variance
import com.google.devtools.ksp.symbol.Modifier
import com.google.devtools.ksp.validate

public class InnoFlowProcessorProvider : SymbolProcessorProvider {
    override fun create(environment: SymbolProcessorEnvironment): SymbolProcessor =
        InnoFlowProcessor(environment.codeGenerator, environment.logger)
}

private class InnoFlowProcessor(
    private val codeGenerator: CodeGenerator,
    private val logger: KSPLogger,
) : SymbolProcessor {
    private val generated = mutableSetOf<String>()
    override fun process(resolver: Resolver): List<KSAnnotated> {
        val symbols = resolver
            .getSymbolsWithAnnotation("com.innosquad.innoflow.InnoFlow")
            .toList()
        val deferred = symbols.filterNot(KSAnnotated::validate)

        symbols.filter(KSAnnotated::validate).forEach { symbol ->
            val declaration = symbol as? KSClassDeclaration
            if (declaration == null) {
                logger.error("@InnoFlow can only be applied to a class or object", symbol)
                return@forEach
            }
            generateFactory(declaration)
        }
        return deferred
    }

    private fun generateFactory(declaration: KSClassDeclaration) {
        if (declaration.classKind != ClassKind.CLASS && declaration.classKind != ClassKind.OBJECT) {
            logger.error("@InnoFlow can only be applied to a concrete class or object", declaration)
            return
        }
        if (declaration.parentDeclaration != null) {
            logger.error("@InnoFlow 1.0 requires a top-level declaration", declaration)
            return
        }
        if (declaration.typeParameters.isNotEmpty()) {
            logger.error("@InnoFlow 1.0 does not support generic feature declarations", declaration)
            return
        }
        if (Modifier.PRIVATE in declaration.modifiers || Modifier.PROTECTED in declaration.modifiers) {
            logger.error("@InnoFlow requires public or internal visibility", declaration)
            return
        }
        if (Modifier.ABSTRACT in declaration.modifiers) {
            logger.error("@InnoFlow requires a concrete class or object", declaration)
            return
        }

        val featureType = declaration.superTypes
            .map { it.resolve() }
            .firstOrNull { type ->
                type.declaration.qualifiedName?.asString() ==
                    "com.innosquad.innoflow.FlowFeature"
            }

        if (featureType == null || featureType.arguments.size != 3) {
            logger.error(
                "@InnoFlow types must directly implement FlowFeature<State, Action, Output>",
                declaration,
            )
            return
        }

        val qualifiedName = declaration.qualifiedName?.asString()
        val simpleName = declaration.simpleName.asString()
        if (qualifiedName == null) {
            logger.error("@InnoFlow does not support local declarations", declaration)
            return
        }
        if (!generated.add(qualifiedName)) return
        val visibility = if (Modifier.INTERNAL in declaration.modifiers) "internal" else "public"

        val types = featureType.arguments.map { argument ->
            val resolved = argument.type?.resolve()
            if (resolved == null || resolved.isError) null else resolved.render()
        }
        if (types.any { it == null }) {
            logger.error("Unable to resolve FlowFeature generic arguments", declaration)
            return
        }

        val packageName = declaration.packageName.asString()
        val file = codeGenerator.createNewFile(
            dependencies = Dependencies(
                aggregating = false,
                sources = listOfNotNull(declaration.containingFile).toTypedArray(),
            ),
            packageName = packageName,
            fileName = "${simpleName}Flow",
        )

        val state = requireNotNull(types[0])
        val action = requireNotNull(types[1])
        val output = requireNotNull(types[2])
        file.bufferedWriter().use { writer ->
            if (packageName.isNotEmpty()) writer.appendLine("package ${packageName.escaped()}")
            writer.appendLine()
            writer.appendLine("import com.innosquad.innoflow.FlowInstrumentation")
            writer.appendLine("import com.innosquad.innoflow.FlowStore")
            writer.appendLine("import kotlinx.coroutines.CoroutineScope")
            writer.appendLine()
            writer.appendLine("$visibility object `${simpleName}Flow` {")
            writer.appendLine("    $visibility fun create(")
            writer.appendLine("        feature: ${qualifiedName.escaped()},")
            writer.appendLine("        scope: CoroutineScope,")
            writer.appendLine(
                "        instrumentation: FlowInstrumentation<$state, $action, $output> = FlowInstrumentation.none(),",
            )
            writer.appendLine("        actionCapacity: Int = 1024,")
            writer.appendLine("    ): FlowStore<$state, $action, $output> = FlowStore(")
            writer.appendLine("        initialState = feature.initialState,")
            writer.appendLine("        reducer = feature.reducer,")
            writer.appendLine("        scope = scope,")
            writer.appendLine("        instrumentation = instrumentation,")
            writer.appendLine("        actionCapacity = actionCapacity,")
            writer.appendLine("    )")
            writer.appendLine("}")
        }
    }

    private fun KSType.render(): String {
        val name = (declaration as? KSClassDeclaration)?.renderClass(arguments)
            ?: ((declaration.qualifiedName?.asString() ?: declaration.simpleName.asString()).escaped() +
                arguments.renderArguments())
        val nullable = if (nullability == Nullability.NULLABLE) "?" else ""
        return "$name$nullable"
    }

    private fun KSClassDeclaration.renderClass(arguments: List<KSTypeArgument>): String {
        val owner = parentDeclaration as? KSClassDeclaration
        if (Modifier.INNER in modifiers && owner != null) {
            // KSP orders inner arguments before captured owner arguments.
            // Rebuild one declaration at a time; static nested classes stop
            // capture, while multiple inner levels keep their own generics.
            val ownCount = typeParameters.size
            return owner.renderClass(arguments.drop(ownCount)) + "." +
                simpleName.asString().escaped() + arguments.take(ownCount).renderArguments()
        }
        return (qualifiedName?.asString() ?: simpleName.asString()).escaped() +
            arguments.renderArguments()
    }

    private fun List<KSTypeArgument>.renderArguments(): String {
        if (isEmpty()) return ""
        return joinToString(prefix = "<", postfix = ">") { argument ->
            if (argument.variance == Variance.STAR) "*" else {
                val type = argument.type?.resolve()?.render() ?: "*"
                when (argument.variance) {
                    Variance.COVARIANT -> "out $type"
                    Variance.CONTRAVARIANT -> "in $type"
                    else -> type
                }
            }
        }
    }

    private fun String.escaped(): String = split('.').joinToString(".") { "`$it`" }
}
