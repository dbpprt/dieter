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

public val Icons.Outlined.DriveFileRenameOutline: ImageVector
    get() {
        if (_driveFileRenameOutlineOutlined != null) {
            return _driveFileRenameOutlineOutlined!!
        }
        _driveFileRenameOutlineOutlined =
            materialIcon(name = "Outlined.DriveFileRenameOutline") {
                materialPath {
                    moveTo(15.0f, 16.0f)
                    lineToRelative(-4.0f, 4.0f)
                    lineToRelative(10.0f, 0.0f)
                    lineToRelative(0.0f, -4.0f)
                    close()
                }
                materialPath {
                    moveTo(12.06f, 7.19f)
                    lineTo(3.0f, 16.25f)
                    verticalLineTo(20.0f)
                    horizontalLineToRelative(3.75f)
                    lineToRelative(9.06f, -9.06f)
                    lineTo(12.06f, 7.19f)
                    close()
                    moveTo(5.92f, 18.0f)
                    horizontalLineTo(5.0f)
                    verticalLineToRelative(-0.92f)
                    lineToRelative(7.06f, -7.06f)
                    lineToRelative(0.92f, 0.92f)
                    lineTo(5.92f, 18.0f)
                    close()
                }
                materialPath {
                    moveTo(18.71f, 8.04f)
                    curveToRelative(0.39f, -0.39f, 0.39f, -1.02f, 0.0f, -1.41f)
                    lineToRelative(-2.34f, -2.34f)
                    curveTo(16.17f, 4.09f, 15.92f, 4.0f, 15.66f, 4.0f)
                    curveToRelative(-0.25f, 0.0f, -0.51f, 0.1f, -0.7f, 0.29f)
                    lineToRelative(-1.83f, 1.83f)
                    lineToRelative(3.75f, 3.75f)
                    lineTo(18.71f, 8.04f)
                    close()
                }
            }
        return _driveFileRenameOutlineOutlined!!
    }

private var _driveFileRenameOutlineOutlined: ImageVector? = null
