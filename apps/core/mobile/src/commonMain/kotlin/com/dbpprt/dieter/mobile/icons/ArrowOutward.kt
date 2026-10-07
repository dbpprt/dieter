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

public val Icons.Outlined.ArrowOutward: ImageVector
    get() {
        if (_arrowOutward != null) {
            return _arrowOutward!!
        }
        _arrowOutward =
            materialIcon(name = "Outlined.ArrowOutward") {
                materialPath {
                    moveTo(6.0f, 6.0f)
                    lineToRelative(0.0f, 2.0f)
                    lineToRelative(8.59f, 0.0f)
                    lineToRelative(-9.59f, 9.59f)
                    lineToRelative(1.41f, 1.41f)
                    lineToRelative(9.59f, -9.59f)
                    lineToRelative(0.0f, 8.59f)
                    lineToRelative(2.0f, 0.0f)
                    lineToRelative(0.0f, -12.0f)
                    close()
                }
            }
        return _arrowOutward!!
    }

private var _arrowOutward: ImageVector? = null
