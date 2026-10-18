package com.example.innoflow.consumer

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.innosquad.innoflow.*
import com.innosquad.innoflow.android.ownFlowStore
import com.innosquad.innoflow.compose.collectStateWithLifecycle

internal data class CounterState(val count: Int = 0)
@InnoFlow
internal object CounterFeature : FlowFeature<CounterState, Unit, Nothing> {
    override val initialState = CounterState()
    override val reducer = Reducer<CounterState, Unit, Nothing> { state, _ -> transition(state.copy(count = state.count + 1)) }
}
class ConsumerViewModel : ViewModel() {
    internal val store = ownFlowStore(CounterFeatureFlow.create(CounterFeature, viewModelScope))
}
class MainActivity : ComponentActivity() {
    private val model: ConsumerViewModel by viewModels()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by model.store.collectStateWithLifecycle()
            Button(onClick = { model.store.send(Unit) }) { Text("Count: ${state.count}") }
        }
    }
}
