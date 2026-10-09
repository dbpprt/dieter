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

public val Icons.Outlined.TaskAlt: ImageVector
    get() {
        if (_taskAltOutlined != null) {
            return _taskAltOutlined!!
        }
        _taskAltOutlined =
            materialIcon(name = "Outlined.TaskAlt") {
                materialPath {
                    moveTo(22.0f, 5.18f)
                    lineTo(10.59f, 16.6f)
                    lineToRelative(-4.24f, -4.24f)
                    lineToRelative(1.41f, -1.41f)
                    lineToRelative(2.83f, 2.83f)
                    lineToRelative(10.0f, -10.0f)
                    lineTo(22.0f, 5.18f)
                    close()
                    moveTo(19.79f, 10.22f)
                    curveTo(19.92f, 10.79f, 20.0f, 11.39f, 20.0f, 12.0f)
                    curveToRelative(0.0f, 4.42f, -3.58f, 8.0f, -8.0f, 8.0f)
                    reflectiveCurveToRelative(-8.0f, -3.58f, -8.0f, -8.0f)
                    curveToRelative(0.0f, -4.42f, 3.58f, -8.0f, 8.0f, -8.0f)
                    curveToRelative(1.58f, 0.0f, 3.04f, 0.46f, 4.28f, 1.25f)
                    lineToRelative(1.44f, -1.44f)
                    curveTo(16.1f, 2.67f, 14.13f, 2.0f, 12.0f, 2.0f)
                    curveTo(6.48f, 2.0f, 2.0f, 6.48f, 2.0f, 12.0f)
                    curveToRelative(0.0f, 5.52f, 4.48f, 10.0f, 10.0f, 10.0f)
                    reflectiveCurveToRelative(10.0f, -4.48f, 10.0f, -10.0f)
                    curveToRelative(0.0f, -1.19f, -0.22f, -2.33f, -0.6f, -3.39f)
                    lineTo(19.79f, 10.22f)
                    close()
                }
            }
        return _taskAltOutlined!!
    }

private var _taskAltOutlined: ImageVector? = null
