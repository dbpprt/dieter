/*
 * Copyright 2024 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.dbpprt.dieter.mobile.icons

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.materialIcon
import androidx.compose.material.icons.materialPath
import androidx.compose.ui.graphics.vector.ImageVector

public val Icons.Outlined.Timeline: ImageVector
    get() {
        if (_timeline != null) {
            return _timeline!!
        }
        _timeline =
            materialIcon(name = "Outlined.Timeline") {
                materialPath {
                    moveTo(23.0f, 8.0f)
                    curveToRelative(0.0f, 1.1f, -0.9f, 2.0f, -2.0f, 2.0f)
                    curveToRelative(-0.18f, 0.0f, -0.35f, -0.02f, -0.51f, -0.07f)
                    lineToRelative(-3.56f, 3.55f)
                    curveTo(16.98f, 13.64f, 17.0f, 13.82f, 17.0f, 14.0f)
                    curveToRelative(0.0f, 1.1f, -0.9f, 2.0f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(-2.0f, -0.9f, -2.0f, -2.0f)
                    curveToRelative(0.0f, -0.18f, 0.02f, -0.36f, 0.07f, -0.52f)
                    lineToRelative(-2.55f, -2.55f)
                    curveTo(10.36f, 10.98f, 10.18f, 11.0f, 10.0f, 11.0f)
                    curveToRelative(-0.18f, 0.0f, -0.36f, -0.02f, -0.52f, -0.07f)
                    lineToRelative(-4.55f, 4.56f)
                    curveTo(4.98f, 15.65f, 5.0f, 15.82f, 5.0f, 16.0f)
                    curveToRelative(0.0f, 1.1f, -0.9f, 2.0f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(-2.0f, -0.9f, -2.0f, -2.0f)
                    reflectiveCurveToRelative(0.9f, -2.0f, 2.0f, -2.0f)
                    curveToRelative(0.18f, 0.0f, 0.35f, 0.02f, 0.51f, 0.07f)
                    lineToRelative(4.56f, -4.55f)
                    curveTo(8.02f, 9.36f, 8.0f, 9.18f, 8.0f, 9.0f)
                    curveToRelative(0.0f, -1.1f, 0.9f, -2.0f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(2.0f, 0.9f, 2.0f, 2.0f)
                    curveToRelative(0.0f, 0.18f, -0.02f, 0.36f, -0.07f, 0.52f)
                    lineToRelative(2.55f, 2.55f)
                    curveTo(14.64f, 12.02f, 14.82f, 12.0f, 15.0f, 12.0f)
                    curveToRelative(0.18f, 0.0f, 0.36f, 0.02f, 0.52f, 0.07f)
                    lineToRelative(3.55f, -3.56f)
                    curveTo(19.02f, 8.35f, 19.0f, 8.18f, 19.0f, 8.0f)
                    curveToRelative(0.0f, -1.1f, 0.9f, -2.0f, 2.0f, -2.0f)
                    reflectiveCurveTo(23.0f, 6.9f, 23.0f, 8.0f)
                    close()
                }
            }
        return _timeline!!
    }

private var _timeline: ImageVector? = null
