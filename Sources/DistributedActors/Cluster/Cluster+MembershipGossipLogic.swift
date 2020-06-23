//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Gossip Logic

final class MembershipGossipLogic: GossipLogic, CustomStringConvertible {
    typealias Envelope = Cluster.Gossip
    typealias Acknowledgement = Cluster.Gossip // TODO: GossipAck instead, a more minimal one; just the peers status

    private let context: Context
    internal lazy var localNode: UniqueNode = self.context.system.cluster.node

    internal var latestGossip: Cluster.Gossip
    private let notifyOnGossipRef: ActorRef<Cluster.Gossip>

    /// We store and use a shuffled yet stable order for gossiping peers.
    /// See `updateActivePeers` for details.
    private var peers: [AddressableActorRef] = []

    /// During 1:1 gossip interactions, update this table, which means "we definitely know the specific node has seen our version VV at ..."
    ///
    /// See `updateActivePeers` and `receiveGossip` for details.
    // TODO: This can be optimized and it's enough if we keep a digest of the gossips; this way ACKs can just send the digest as well saving space.
    private var lastGossipFrom: [AddressableActorRef: Cluster.Gossip] = [:]

    init(_ context: Context, notifyOnGossipRef: ActorRef<Cluster.Gossip>) {
        self.context = context
        self.notifyOnGossipRef = notifyOnGossipRef
        self.latestGossip = .init(ownerNode: context.system.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    // TODO: implement better, only peers which are "behind"
    func selectPeers(peers _peers: [AddressableActorRef]) -> [AddressableActorRef] {
        // how many peers we select in each gossip round,
        // we could for example be dynamic and notice if we have 10+ nodes, we pick 2 members to speed up the dissemination etc.
        let n = 1

        self.updateActivePeers(peers: _peers)
        var selectedPeers: [AddressableActorRef] = []
        selectedPeers.reserveCapacity(min(n, self.peers.count))

        /// Trust the order of peers in gossipPeers for the selection; see `updateActivePeers` for logic of the ordering.
        for peer in self.peers where selectedPeers.count < n {
            if self.shouldGossipWith(peer) {
                selectedPeers.append(peer)
            }
        }

        return selectedPeers
    }

    private func updateActivePeers(peers: [AddressableActorRef]) {
        if let changed = Self.peersChanged(known: self.peers, current: peers) {
            // 1) remove any peers which are no longer active
            //    - from the peers list
            //    - from their gossip storage, we'll never gossip with them again after all
            if !changed.removed.isEmpty {
                let removedPeers = Set(changed.removed)
                self.peers = self.peers.filter { !removedPeers.contains($0) }
                changed.removed.forEach { removedPeer in
                    _ = self.lastGossipFrom.removeValue(forKey: removedPeer)
                }
            }

            for peer in changed.added {
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                //
                // This is adopted from the SWIM membership implementation and related papers.
                let insertIndex = Int.random(in: self.peers.startIndex ... self.peers.endIndex)
                self.peers.insert(peer, at: insertIndex)
            }
        }
    }

    func makePayload(target: AddressableActorRef) -> Cluster.Gossip? {
        // today we don't trim payloads at all
        // TODO: trim some information?
        self.latestGossip
    }

    func receiveAcknowledgement(from peer: AddressableActorRef, acknowledgement: Acknowledgement, confirmsDeliveryOf envelope: Cluster.Gossip) {
        // 1) store the direct gossip we got from this peer; we can use this to know if there's no need to gossip to that peer by inspecting seen table equality
        self.lastGossipFrom[peer] = acknowledgement

        // 2) use this to move forward the gossip as well
        self.mergeInbound(gossip: acknowledgement)
    }

    /// True if the peers is "behind" in terms of information it has "seen" (as determined by comparing our and its seen tables).
    private func shouldGossipWith(_ peer: AddressableActorRef) -> Bool {
        guard let remoteNode = peer.address.node else {
            // targets should always be remote peers; one not having a node should not happen, let's ignore it as a gossip target
            return false
        }

        guard let lastSeenGossipFromPeer = self.lastGossipFrom[peer] else {
            // it's a peer we have not gotten any gossip from yet
            return true
        }

//    pprint("\(self.localNode.node.systemName) = self.latestGossip.version = \(pretty: self.latestGossip)")
//    pprint("\(self.localNode.node.systemName) = lastSeenGossipFromPeer[\(peer.address.node!.node.systemName)]    = \(pretty: lastSeenGossipFromPeer)")

        // TODO: can be replaced by a digest comparison
        return self.latestGossip.seen != lastSeenGossipFromPeer.seen
    }

    // TODO: may also want to return "these were removed" if we need to make any internal cleanup
    static func peersChanged(known: [AddressableActorRef], current: [AddressableActorRef]) -> PeersChanged? {
        // TODO: a bit lazy implementation
        let knownSet = Set(known)
        let currentSet = Set(current)

        let added = currentSet.subtracting(knownSet)
        let removed = knownSet.subtracting(currentSet)

        if added.isEmpty, removed.isEmpty {
            return nil
        } else {
            return PeersChanged(
                added: added,
                removed: removed
            )
        }
    }

    struct PeersChanged {
        let added: Set<AddressableActorRef>
        let removed: Set<AddressableActorRef>

        init(added: Set<AddressableActorRef>, removed: Set<AddressableActorRef>) {
            assert(!added.isEmpty || !removed.isEmpty, "PeersChanged yet both added/removed are empty!")
            self.added = added
            self.removed = removed
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    func receiveGossip(gossip: Envelope, from peer: AddressableActorRef) -> Acknowledgement? {
        // 1) mark that from that specific peer, we know it observed at least that version
        self.lastGossipFrom[peer] = gossip

        // 2) move forward the gossip we store
        self.mergeInbound(gossip: gossip)

        // 3) notify listeners
        self.notifyOnGossipRef.tell(self.latestGossip)

        // FIXME: optimize ack reply; this can contain only rows of seen tables where we are "ahead" (and always "our" row)
        // no need to send back the entire tables if it's the same up to date ones as we just received
        return self.latestGossip
    }

    func localGossipUpdate(gossip: Cluster.Gossip) {
        self.mergeInbound(gossip: gossip)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Side-channel

    enum SideChannelMessage {
        case localUpdate(Envelope)
    }

    func receiveSideChannelMessage(message: Any) throws {
        guard let sideChannelMessage = message as? SideChannelMessage else {
            self.context.system.deadLetters.tell(DeadLetter(message, recipient: self.context.gossiperAddress))
            return
        }

        switch sideChannelMessage {
        case .localUpdate(let gossip):
            self.mergeInbound(gossip: gossip)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utilities

    private func mergeInbound(gossip: Cluster.Gossip) {
        _ = self.latestGossip.mergeForward(incoming: gossip)
        // effects are signalled via the ClusterShell, not here (it will also perform a merge) // TODO: a bit duplicated, could we maintain it here?
    }

    var description: String {
        "MembershipGossipLogic(\(self.localNode))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Gossip Logic Control

let MembershipGossipIdentifier: StringGossipIdentifier = "membership"

extension GossipControl where GossipEnvelope == Cluster.Gossip {
    func update(payload: GossipEnvelope) {
        self.update(MembershipGossipIdentifier, payload: payload)
    }

    func remove() {
        self.remove(MembershipGossipIdentifier)
    }

    func sideChannelTell(message: Any) {
        self.sideChannelTell(MembershipGossipIdentifier, message: message)
    }
}
