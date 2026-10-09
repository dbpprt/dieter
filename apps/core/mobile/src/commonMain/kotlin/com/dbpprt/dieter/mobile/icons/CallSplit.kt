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

public val Icons.Outlined.CallSplit: ImageVector
    get() {
        if (_callSplitOutlined != null) {
            return _callSplitOutlined!!
        }
        _callSplitOutlined =
            materialIcon(name = "Outlined.CallSplit") {
                materialPath {
                    moveTo(14.0f, 4.0f)
                    lineToRelative(2.29f, 2.29f)
                    lineToRelative(-2.88f, 2.88f)
                    lineToRelative(1.42f, 1.42f)
                    lineToRelative(2.88f, -2.88f)
                    lineTo(20.0f, 10.0f)
                    lineTo(20.0f, 4.0f)
                    horizontalLineToRelative(-6.0f)
                    close()
                    moveTo(10.0f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    verticalLineToRelative(6.0f)
                    lineToRelative(2.29f, -2.29f)
                    lineToRelative(4.71f, 4.7f)
                    lineTo(11.0f, 20.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-8.41f)
                    lineToRelative(-5.29f, -5.3f)
                    lineTo(10.0f, 4.0f)
                    close()
                }
            }
        return _callSplitOutlined!!
    }

private var _callSplitOutlined: ImageVector? = null
