package fixture
import com.innosquad.innoflow.*
class Owner {
    @InnoFlow
    object Feature : FlowFeature<Int, Unit, Nothing> {
        override val initialState = 0
        override val reducer = Reducer<Int, Unit, Nothing> { state, _ -> transition(state) }
    }
}
