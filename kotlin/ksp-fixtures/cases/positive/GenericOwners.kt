package fixture.owners

import com.innosquad.innoflow.*
import kotlinx.coroutines.CoroutineScope

class Owner<T>(val value: T) {
    inner class Inner<U>(val value: U)
    inner class NoArguments
    inner class Middle<U>(val value: U) {
        inner class Leaf<V>(val value: V)
    }
    class StaticNested<U>(val value: U) {
        inner class Inner<V>(val value: V)
    }
}

class PairOwner<K, V>(val key: K, val value: V) {
    inner class PairInner<A, B>(val first: A, val second: B)
}

@InnoFlow
object OwnerFeature : FlowFeature<Owner<String>.Inner<Int>, Owner<Long>.Inner<String>, Owner<List<Boolean?>>.NoArguments?> {
    override val initialState = Owner("owner").Inner(1)
    override val reducer = Reducer<Owner<String>.Inner<Int>, Owner<Long>.Inner<String>, Owner<List<Boolean?>>.NoArguments?> { state, _ -> transition(state) }
}
fun ownerConsumer(scope: CoroutineScope): FlowStore<Owner<String>.Inner<Int>, Owner<Long>.Inner<String>, Owner<List<Boolean?>>.NoArguments?> =
    OwnerFeatureFlow.create(OwnerFeature, scope)

@InnoFlow
object DeepOwnerFeature : FlowFeature<Owner<String>.Middle<Int>.Leaf<List<Boolean?>>?, Unit, Nothing> {
    override val initialState: Owner<String>.Middle<Int>.Leaf<List<Boolean?>>? = null
    override val reducer = Reducer<Owner<String>.Middle<Int>.Leaf<List<Boolean?>>?, Unit, Nothing> { state, _ -> transition(state) }
}
fun deepConsumer(scope: CoroutineScope): FlowStore<Owner<String>.Middle<Int>.Leaf<List<Boolean?>>?, Unit, Nothing> =
    DeepOwnerFeatureFlow.create(DeepOwnerFeature, scope)

@InnoFlow
object MultipleArgumentsFeature : FlowFeature<PairOwner<String, Long>.PairInner<Int, Double>, Unit, Nothing> {
    override val initialState = PairOwner("key", 1L).PairInner(2, 3.0)
    override val reducer = Reducer<PairOwner<String, Long>.PairInner<Int, Double>, Unit, Nothing> { state, _ -> transition(state) }
}
fun pairConsumer(scope: CoroutineScope): FlowStore<PairOwner<String, Long>.PairInner<Int, Double>, Unit, Nothing> =
    MultipleArgumentsFeatureFlow.create(MultipleArgumentsFeature, scope)

@InnoFlow
object StaticBoundaryFeature : FlowFeature<Owner.StaticNested<Int>.Inner<String>, Unit, Nothing> {
    override val initialState = Owner.StaticNested(1).Inner("inner")
    override val reducer = Reducer<Owner.StaticNested<Int>.Inner<String>, Unit, Nothing> { state, _ -> transition(state) }
}
fun staticConsumer(scope: CoroutineScope): FlowStore<Owner.StaticNested<Int>.Inner<String>, Unit, Nothing> =
    StaticBoundaryFeatureFlow.create(StaticBoundaryFeature, scope)

typealias AliasedState = Owner<String>.Inner<Int>
@InnoFlow
object AliasedStateFeature : FlowFeature<AliasedState, Unit, Nothing> {
    override val initialState: AliasedState = Owner("alias").Inner(1)
    override val reducer = Reducer<AliasedState, Unit, Nothing> { state, _ -> transition(state) }
}
fun aliasConsumer(scope: CoroutineScope): FlowStore<AliasedState, Unit, Nothing> =
    AliasedStateFeatureFlow.create(AliasedStateFeature, scope)

@InnoFlow
object ProjectedOwnerFeature : FlowFeature<List<Owner<*>.Inner<*>>, Unit, Nothing> {
    override val initialState: List<Owner<*>.Inner<*>> = emptyList()
    override val reducer = Reducer<List<Owner<*>.Inner<*>>, Unit, Nothing> { state, _ -> transition(state) }
}
fun projectedConsumer(scope: CoroutineScope): FlowStore<List<Owner<*>.Inner<*>>, Unit, Nothing> =
    ProjectedOwnerFeatureFlow.create(ProjectedOwnerFeature, scope)

@InnoFlow
object SuspendStateFeature : FlowFeature<suspend (Int) -> String, Unit, Nothing> {
    override val initialState: suspend (Int) -> String = { it.toString() }
    override val reducer = Reducer<suspend (Int) -> String, Unit, Nothing> { state, _ -> transition(state) }
}
fun suspendConsumer(scope: CoroutineScope): FlowStore<suspend (Int) -> String, Unit, Nothing> =
    SuspendStateFeatureFlow.create(SuspendStateFeature, scope)
