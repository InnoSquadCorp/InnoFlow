package com.innosquad.innoflow.sample.android

import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import org.junit.Rule
import org.junit.Test

class RecreationTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun stateSurvivesRecreationAndBackgroundResume() {
        compose.onNodeWithText("Count: 0").assertExists()
        compose.onNodeWithText("Increase").performClick()
        compose.onNodeWithText("Count: 1").assertExists()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithText("Count: 1").assertExists()
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.onNodeWithText("Count: 1").assertExists()
        compose.onNodeWithText("Decrease").performClick()
        compose.onNodeWithText("Count: 0").assertExists()
    }
}
