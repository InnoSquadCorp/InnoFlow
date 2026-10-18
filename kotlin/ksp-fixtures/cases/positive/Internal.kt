package fixture
import com.innosquad.innoflow.*
import kotlinx.coroutines.CoroutineScope

internal data class InternalState(val count: Int = 0)
@InnoFlow
internal object InternalFeature : FlowFeature<InternalState, Unit, Nothing> {
    override val initialState = InternalState()
    override val reducer = Reducer<InternalState, Unit, Nothing> { state, _ -> transition(state.copy(count = state.count + 1)) }
}
internal fun internalConsumer(scope: CoroutineScope) = InternalFeatureFlow.create(InternalFeature, scope, actionCapacity = 8)

@InnoFlow
class PublicFeature : FlowFeature<Map<String, List<String?>>, Unit, String?> {
    override val initialState = emptyMap<String, List<String?>>()
    override val reducer = Reducer<Map<String, List<String?>>, Unit, String?> { state, _ -> transition(state) }
}
fun publicConsumer(scope: CoroutineScope) = PublicFeatureFlow.create(PublicFeature(), scope)
