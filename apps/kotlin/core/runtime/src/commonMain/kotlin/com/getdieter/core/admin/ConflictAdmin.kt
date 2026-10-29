package com.getdieter.core.admin

import com.getdieter.api.v1.PeerRecord
import com.getdieter.api.v1.PeerRecordRef
import com.getdieter.api.v1.PutPeerRecordRequest
import okio.ByteString

/**
 * Shared-record conflicts: the competing versions the peer store kept for one register, and the
 * user's choice among them, on a machine that holds the record's project. Confined to the core
 * dispatcher.
 */
class ConflictAdmin internal constructor(private val calls: AdminCalls) {
    /**
     * The competing versions behind a conflict key such as `board/b_1.name`, read from a machine
     * with [projectId]; null when there is no conflict.
     */
    suspend fun read(projectId: String?, key: String): PeerRecord? {
        val kind = key.substringBefore('/')
        val id = key.substringAfter('/').substringBefore('.')
        val record =
            calls.call(AdminRoute.shared(projectId)) {
                it.GetPeerRecord().execute(PeerRecordRef(kind = kind, id = id))
            }
        return record.takeIf { it.versions.size > 1 }
    }

    /** Keeps one version (or the deletion) on a machine with [projectId]. */
    suspend fun resolve(
        projectId: String?,
        record: PeerRecord,
        valueJson: ByteString?,
        deleted: Boolean,
    ): PeerRecord =
        calls.call(AdminRoute.shared(projectId)) {
            it.PutPeerRecord()
                .execute(
                    PutPeerRecordRequest(
                        kind = record.kind,
                        id = record.id,
                        value_json =
                            if (deleted) ByteString.EMPTY else valueJson ?: ByteString.EMPTY,
                        deleted = deleted,
                        expected_revision = record.revision,
                    )
                )
        }
}
