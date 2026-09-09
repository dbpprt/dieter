import DieterAPI
import Foundation

package struct OptimisticCardMove: Equatable, Sendable {
    package init(operationID: UUID, lane: String, position: Int64, confirmsPosition: Bool) {
        self.operationID = operationID; self.lane = lane; self.position = position;
        self.confirmsPosition = confirmsPosition
    }
    package let operationID: UUID
    package var lane: String
    package var position: Int64
    package var confirmsPosition: Bool

    package func isConfirmed(by card: Dieter_V1_Card) -> Bool {
        card.lane == lane && (!confirmsPosition || card.position == position)
    }

    package func applying(to card: Dieter_V1_Card) -> Dieter_V1_Card {
        var card = card
        card.lane = lane
        card.position = position
        return card
    }
}

package struct OptimisticCardLabels: Equatable, Sendable {
    package init(operationID: UUID, labelIDs: [String]) { self.operationID = operationID; self.labelIDs = labelIDs }
    package let operationID: UUID
    package let labelIDs: [String]

    package func isConfirmed(by card: Dieter_V1_Card) -> Bool {
        card.labelIds == labelIDs
    }

    package func applying(to card: Dieter_V1_Card) -> Dieter_V1_Card {
        var card = card
        card.labelIds = labelIDs
        return card
    }
}

package struct OptimisticCardProjection {
    package let cards: [Dieter_V1_Card]
    package let moves: [String: OptimisticCardMove]
    package let labels: [String: OptimisticCardLabels]

    package static func reconcile(
        cards: [Dieter_V1_Card],
        moves: [String: OptimisticCardMove],
        labels: [String: OptimisticCardLabels]
    ) -> OptimisticCardProjection {
        var remainingMoves = moves
        var remainingLabels = labels
        let projected = cards.map { serverCard in
            var card = serverCard
            if let move = moves[card.id] {
                if move.isConfirmed(by: serverCard) {
                    remainingMoves.removeValue(forKey: card.id)
                } else {
                    card = move.applying(to: card)
                }
            }
            if let labelUpdate = labels[card.id] {
                if labelUpdate.isConfirmed(by: serverCard) {
                    remainingLabels.removeValue(forKey: card.id)
                } else {
                    card = labelUpdate.applying(to: card)
                }
            }
            return card
        }
        return .init(cards: projected, moves: remainingMoves, labels: remainingLabels)
    }
}

package struct OptimisticWorkspaceProjection {
    package static func reconcileBoards(
        _ serverBoards: [Dieter_V1_Board],
        pending: [String: Dieter_V1_Board]
    ) -> (boards: [Dieter_V1_Board], pending: [String: Dieter_V1_Board]) {
        var remaining = pending
        let boards = serverBoards.map { serverBoard in
            guard let expected = pending[serverBoard.id] else { return serverBoard }
            if serverBoard == expected {
                remaining.removeValue(forKey: serverBoard.id)
                return serverBoard
            }
            return expected
        }
        return (boards, remaining)
    }

    package static func reconcileProjects(
        _ serverProjects: [Dieter_V1_Project],
        pending: [String: Dieter_V1_Project]
    ) -> (projects: [Dieter_V1_Project], pending: [String: Dieter_V1_Project]) {
        var remaining = pending
        let projects = serverProjects.map { serverProject in
            guard let expected = pending[serverProject.id] else { return serverProject }
            if serverProject == expected {
                remaining.removeValue(forKey: serverProject.id)
                return serverProject
            }
            return expected
        }
        return (projects, remaining)
    }
}
