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

public val Icons.Outlined.Commit: ImageVector
    get() {
        if (_commitOutlined != null) {
            return _commitOutlined!!
        }
        _commitOutlined =
            materialIcon(name = "Outlined.Commit") {
                materialPath {
                    moveTo(16.9f, 11.0f)
                    lineTo(16.9f, 11.0f)
                    curveToRelative(-0.46f, -2.28f, -2.48f, -4.0f, -4.9f, -4.0f)
                    reflectiveCurveToRelative(-4.44f, 1.72f, -4.9f, 4.0f)
                    horizontalLineToRelative(0.0f)
                    horizontalLineTo(2.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(5.1f)
                    horizontalLineToRelative(0.0f)
                    curveToRelative(0.46f, 2.28f, 2.48f, 4.0f, 4.9f, 4.0f)
                    reflectiveCurveToRelative(4.44f, -1.72f, 4.9f, -4.0f)
                    horizontalLineToRelative(0.0f)
                    horizontalLineTo(22.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineTo(16.9f)
                    close()
                    moveTo(12.0f, 15.0f)
                    curveToRelative(-1.66f, 0.0f, -3.0f, -1.34f, -3.0f, -3.0f)
                    reflectiveCurveToRelative(1.34f, -3.0f, 3.0f, -3.0f)
                    reflectiveCurveToRelative(3.0f, 1.34f, 3.0f, 3.0f)
                    reflectiveCurveTo(13.66f, 15.0f, 12.0f, 15.0f)
                    close()
                }
            }
        return _commitOutlined!!
    }

private var _commitOutlined: ImageVector? = null
