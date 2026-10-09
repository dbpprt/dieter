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

public val Icons.Outlined.ViewKanban: ImageVector
    get() {
        if (_viewKanban != null) {
            return _viewKanban!!
        }
        _viewKanban =
            materialIcon(name = "Outlined.ViewKanban") {
                materialPath {
                    moveTo(7.0f, 7.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(10.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                }
                materialPath {
                    moveTo(11.0f, 7.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(5.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                }
                materialPath {
                    moveTo(15.0f, 7.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                }
                materialPath {
                    moveTo(19.0f, 3.0f)
                    horizontalLineTo(5.0f)
                    curveTo(3.9f, 3.0f, 3.0f, 3.9f, 3.0f, 5.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineTo(5.0f)
                    curveTo(21.0f, 3.9f, 20.1f, 3.0f, 19.0f, 3.0f)
                    close()
                    moveTo(19.0f, 19.0f)
                    horizontalLineTo(5.0f)
                    verticalLineTo(5.0f)
                    horizontalLineToRelative(14.0f)
                    verticalLineTo(19.0f)
                    close()
                }
            }
        return _viewKanban!!
    }

private var _viewKanban: ImageVector? = null
