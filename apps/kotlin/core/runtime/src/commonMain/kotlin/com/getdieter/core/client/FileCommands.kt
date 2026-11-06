package com.getdieter.core.client

import com.getdieter.client.v1.FileTreeCommand
import com.getdieter.client.v1.FilesCommand
import com.getdieter.client.v1.Result
import com.getdieter.core.files.FileTree
import com.getdieter.core.files.Files

/** The result is the surface after [command], or the saved document. */
internal suspend fun Files.execute(command: FilesCommand): Result {
    // A save while one runs, or without a text document, is ignored.
    command.save?.let { request ->
        save(request.text, revision = request.revision)?.let {
            return Result(file_document = it)
        }
    }
    command.overwrite?.let { request ->
        save(request.text, overwrite = true)?.let {
            return Result(file_document = it)
        }
    }
    command.refresh?.let { refresh(it.document_key, it.revision, it.dirty) }
    command.bind?.let { bind(filesTarget(it)) }
    command.load?.let { load(it.path.ifEmpty { view.value.directory }) }
    command.navigate?.let { navigate(it.path) }
    command.back?.let { goBack() }
    command.forward?.let { goForward() }
    command.parent?.let { parent() }
    command.show_hidden?.let { setShowHidden(it.on) }
    command.open_?.let { open(it.path) }
    command.reload?.let { reload() }
    command.create?.let { create(it.name, it.directory) }
    command.move?.let { move(it.source, it.destination) }
    command.delete?.let { delete(it.path, it.recursive) }
    command.close?.let { close() }
    return Result(files = filesSlice(view.value, documentUnchanged = false))
}

internal suspend fun FileTree.execute(command: FileTreeCommand): Result {
    command.bind?.let { bind(filesTarget(it)) }
    command.load?.let { load(it.path) }
    command.toggle?.let { toggle(it.path) }
    command.reveal?.let { reveal(it.path) }
    command.refresh?.let { refresh() }
    command.show_hidden?.let { setShowHidden(it.on) }
    return Result(file_tree = fileTreeSlice(view.value))
}
