package com.innosquad.innoflow.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.innosquad.innoflow.FlowStore
import kotlinx.coroutines.flow.collect

/** Collects store state only while the current lifecycle is active. */
@Composable
public fun <FlowState, Action, Output> FlowStore<FlowState, Action, Output>.collectStateWithLifecycle(
    minActiveState: Lifecycle.State = Lifecycle.State.STARTED,
): State<FlowState> = states.collectAsStateWithLifecycle(minActiveState = minActiveState)

/** Delivers ephemeral outputs only while the current lifecycle is active. */
@Composable
public fun <FlowState, Action, Output> FlowStore<FlowState, Action, Output>.CollectOutputsWithLifecycle(
    minActiveState: Lifecycle.State = Lifecycle.State.STARTED,
    onOutput: (Output) -> Unit,
) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentHandler by rememberUpdatedState(onOutput)

    LaunchedEffect(this, lifecycleOwner, minActiveState) {
        lifecycleOwner.repeatOnLifecycle(minActiveState) {
            outputs.collect { output -> currentHandler(output) }
        }
    }
}
