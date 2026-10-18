package com.innosquad.innoflow.sample.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import com.innosquad.innoflow.FlowStore
import com.innosquad.innoflow.FlowInstrumentation
import com.innosquad.innoflow.android.ownFlowStore
import com.innosquad.innoflow.compose.collectStateWithLifecycle

public class MainActivity : ComponentActivity() {
    private val viewModel: CounterViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val state by viewModel.store.collectStateWithLifecycle()
            MaterialTheme {
                Column(
                    modifier = Modifier.padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Count: ${state.count}")
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(onClick = { viewModel.store.send(CounterAction.Decrement) }) {
                            Text("Decrease")
                        }
                        Button(onClick = { viewModel.store.send(CounterAction.Increment) }) {
                            Text("Increase")
                        }
                    }
                }
            }
        }
    }
}

public class CounterViewModel(private val savedState: SavedStateHandle) : ViewModel() {
    public val store: FlowStore<CounterState, CounterAction, Nothing> = ownFlowStore(
        CounterFeatureFlow.create(
            feature = CounterFeature(savedState["count"] ?: 0),
            scope = viewModelScope,
            instrumentation = object : FlowInstrumentation<CounterState, CounterAction, Nothing> {
                override fun actionReduced(action: CounterAction, oldState: CounterState, newState: CounterState) {
                    savedState["count"] = newState.count
                }
            },
        ),
    )
}
