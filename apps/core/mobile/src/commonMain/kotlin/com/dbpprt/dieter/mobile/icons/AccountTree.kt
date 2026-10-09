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

public val Icons.Outlined.AccountTree: ImageVector
    get() {
        if (_accountTree != null) {
            return _accountTree!!
        }
        _accountTree =
            materialIcon(name = "Outlined.AccountTree") {
                materialPath {
                    moveTo(22.0f, 11.0f)
                    verticalLineTo(3.0f)
                    horizontalLineToRelative(-7.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineTo(9.0f)
                    verticalLineTo(3.0f)
                    horizontalLineTo(2.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(7.0f)
                    verticalLineTo(8.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(10.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineToRelative(7.0f)
                    verticalLineToRelative(-8.0f)
                    horizontalLineToRelative(-7.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineTo(8.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineTo(22.0f)
                    close()
                    moveTo(7.0f, 9.0f)
                    horizontalLineTo(4.0f)
                    verticalLineTo(5.0f)
                    horizontalLineToRelative(3.0f)
                    verticalLineTo(9.0f)
                    close()
                    moveTo(17.0f, 15.0f)
                    horizontalLineToRelative(3.0f)
                    verticalLineToRelative(4.0f)
                    horizontalLineToRelative(-3.0f)
                    verticalLineTo(15.0f)
                    close()
                    moveTo(17.0f, 5.0f)
                    horizontalLineToRelative(3.0f)
                    verticalLineToRelative(4.0f)
                    horizontalLineToRelative(-3.0f)
                    verticalLineTo(5.0f)
                    close()
                }
            }
        return _accountTree!!
    }

private var _accountTree: ImageVector? = null
