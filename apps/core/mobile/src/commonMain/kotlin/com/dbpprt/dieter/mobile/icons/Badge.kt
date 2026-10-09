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

public val Icons.Outlined.Badge: ImageVector
    get() {
        if (_badgeOutlined != null) {
            return _badgeOutlined!!
        }
        _badgeOutlined =
            materialIcon(name = "Outlined.Badge") {
                materialPath {
                    moveTo(14.0f, 12.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(1.5f)
                    horizontalLineToRelative(-4.0f)
                    close()
                }
                materialPath {
                    moveTo(14.0f, 15.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(1.5f)
                    horizontalLineToRelative(-4.0f)
                    close()
                }
                materialPath {
                    moveTo(20.0f, 7.0f)
                    horizontalLineToRelative(-5.0f)
                    verticalLineTo(4.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    horizontalLineToRelative(-2.0f)
                    curveTo(9.9f, 2.0f, 9.0f, 2.9f, 9.0f, 4.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineTo(4.0f)
                    curveTo(2.9f, 7.0f, 2.0f, 7.9f, 2.0f, 9.0f)
                    verticalLineToRelative(11.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(16.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineTo(9.0f)
                    curveTo(22.0f, 7.9f, 21.1f, 7.0f, 20.0f, 7.0f)
                    close()
                    moveTo(11.0f, 7.0f)
                    verticalLineTo(4.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(3.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineTo(7.0f)
                    close()
                    moveTo(20.0f, 20.0f)
                    horizontalLineTo(4.0f)
                    verticalLineTo(9.0f)
                    horizontalLineToRelative(5.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(2.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineTo(20.0f)
                    close()
                }
                materialPath {
                    moveTo(9.0f, 13.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                materialPath {
                    moveTo(11.08f, 16.18f)
                    curveTo(10.44f, 15.9f, 9.74f, 15.75f, 9.0f, 15.75f)
                    reflectiveCurveToRelative(-1.44f, 0.15f, -2.08f, 0.43f)
                    curveTo(6.36f, 16.42f, 6.0f, 16.96f, 6.0f, 17.57f)
                    verticalLineTo(18.0f)
                    horizontalLineToRelative(6.0f)
                    verticalLineToRelative(-0.43f)
                    curveTo(12.0f, 16.96f, 11.64f, 16.42f, 11.08f, 16.18f)
                    close()
                }
            }
        return _badgeOutlined!!
    }

private var _badgeOutlined: ImageVector? = null
