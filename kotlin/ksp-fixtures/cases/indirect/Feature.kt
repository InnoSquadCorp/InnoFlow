package fixture
import com.innosquad.innoflow.*
interface BaseFeature : FlowFeature<Int, Unit, Nothing>
@InnoFlow
object Feature : BaseFeature {
    override val initialState = 0
    override val reducer = Reducer<Int, Unit, Nothing> { state, _ -> transition(state) }
}
