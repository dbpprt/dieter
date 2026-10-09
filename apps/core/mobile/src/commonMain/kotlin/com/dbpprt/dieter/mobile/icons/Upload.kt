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

public val Icons.Outlined.Upload: ImageVector
    get() {
        if (_uploadOutlined != null) {
            return _uploadOutlined!!
        }
        _uploadOutlined =
            materialIcon(name = "Outlined.Upload") {
                materialPath {
                    moveTo(9.0f, 16.0f)
                    horizontalLineToRelative(6.0f)
                    verticalLineToRelative(-6.0f)
                    horizontalLineToRelative(4.0f)
                    lineToRelative(-7.0f, -7.0f)
                    lineToRelative(-7.0f, 7.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(6.0f)
                    close()
                    moveTo(12.0f, 5.83f)
                    lineTo(14.17f, 8.0f)
                    lineTo(13.0f, 8.0f)
                    verticalLineToRelative(6.0f)
                    horizontalLineToRelative(-2.0f)
                    lineTo(11.0f, 8.0f)
                    lineTo(9.83f, 8.0f)
                    lineTo(12.0f, 5.83f)
                    close()
                    moveTo(5.0f, 18.0f)
                    horizontalLineToRelative(14.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(5.0f, 20.0f)
                    close()
                }
            }
        return _uploadOutlined!!
    }

private var _uploadOutlined: ImageVector? = null
