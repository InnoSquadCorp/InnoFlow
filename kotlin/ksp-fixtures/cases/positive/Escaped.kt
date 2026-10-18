package fixture.`when`
import com.innosquad.innoflow.*
import kotlinx.coroutines.CoroutineScope
@InnoFlow
object `class` : FlowFeature<List<*>, Unit, Nothing> {
    override val initialState: List<*> = emptyList<String>()
    override val reducer = Reducer<List<*>, Unit, Nothing> { state, _ -> transition(state) }
}
fun escapedConsumer(scope: CoroutineScope) = `classFlow`.create(`class`, scope)
