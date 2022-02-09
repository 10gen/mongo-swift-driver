#if compiler(>=5.3)
import Atomics
import CLibMongoC
import Foundation

internal struct Server {
    internal let address: ServerAddress
    internal var operationCount: ManagedAtomic<Int>

    internal init(address: ServerAddress) {
        self.address = address
        self.operationCount = ManagedAtomic(0)
    }

    // Used by the selection within latency window tests.
    internal init(address: ServerAddress, operationCount: Int) {
        self.address = address
        self.operationCount = ManagedAtomic(operationCount)
    }
}

extension MongoClient {
    internal func selectServer(
        readPreference: ReadPreference = ReadPreference.primary,
        topology: TopologyDescription,
        servers: [ServerAddress: Server]
    ) throws -> Server {
        let startTime = Date()
        let serverSelectionTimeoutMS = self.connectionString.serverSelectionTimeoutMS
            ?? SDAMConstants.defaultServerSelectionTimeoutMS
        // A TimeInterval is measured in seconds, so serverSelectionTimeoutMS needs to be converted from milliseconds
        // to seconds.
        let endTime = Date(timeInterval: Double(serverSelectionTimeoutMS) / 1000.0, since: startTime)

        while Date() < endTime {
            if let (min, max) = topology.getWireVersionRange() {
                if min < SDAMConstants.minWireVersion {
                    throw MongoError.ServerSelectionError(
                        message: "Wire version incompatibility: a server in the topology has minWireVersion \(min) but"
                            + " the minimum supported wire version is \(SDAMConstants.minWireVersion)\nTopology:"
                            + " \(topology)"
                    )
                }
                if max > SDAMConstants.maxWireVersion {
                    throw MongoError.ServerSelectionError(
                        message: "Wire version incompatibility: a server in the topology has maxWireVersion \(max) but"
                            + " the maximum supported wire version is \(SDAMConstants.maxWireVersion)\nTopology:"
                            + " \(topology)"
                    )
                }
            }

            var suitableServers = try topology.findSuitableServers(
                readPreference: readPreference,
                heartbeatFrequencyMS: self.connectionString.heartbeatFrequencyMS
                    ?? SDAMConstants.defaultHeartbeatFrequencyMS
            )
            suitableServers.filterByLatency(localThresholdMS: self.connectionString.localThresholdMS)
            var inWindowServers = suitableServers.compactMap { servers[$0.address] }

            let selectedServer: Server
            if inWindowServers.isEmpty {
                // When pure Swift SDAM is implemented, this should instead block on a topology change occurring for
                // endTime - Date() seconds.
                // TODO: add an async sleep here once the driver has been updated to permit async/await on 10.15+
                continue
            } else if inWindowServers.count == 1 {
                selectedServer = inWindowServers[0]
            } else {
                // Remove the randomly chosen servers from the list to ensure that the same server is not chosen twice.
                let server1 = inWindowServers.remove(at: Int.random(in: 0..<inWindowServers.count))
                let server2 = inWindowServers.remove(at: Int.random(in: 0..<inWindowServers.count))

                if server1.operationCount.load(ordering: .sequentiallyConsistent)
                    <= server2.operationCount.load(ordering: .sequentiallyConsistent)
                {
                    selectedServer = server1
                } else {
                    selectedServer = server2
                }
            }

            selectedServer.operationCount.wrappingIncrement(ordering: .sequentiallyConsistent)
            return selectedServer
        }

        throw MongoError.ServerSelectionError(message: "Server selection timed out: no suitable servers found using"
            + " read preference: \(readPreference)\nTopology: \(topology)")
    }
}

extension Array where Element == ServerDescription {
    /// Filters servers according to their latency. A server is considered to be within the latency window if its
    /// `averageRoundTripTimeMS` is no more than `localThresholdMS` (or 15 by default) milliseconds greater than the
    /// smallest average RTT seen amongst the servers.
    internal mutating func filterByLatency(localThresholdMS: Int?) {
        guard let minAverageRoundTripTime = self.compactMap({ $0.averageRoundTripTimeMS }).min() else {
            // If there is no minimum average round trip time, there are no servers to filter.
            return
        }
        let maxAverageRoundTripTime = minAverageRoundTripTime
            + Double(localThresholdMS ?? SDAMConstants.defaultLocalThresholdMS)
        self.removeAll {
            guard let averageRoundTripTimeMS = $0.averageRoundTripTimeMS else {
                return false
            }
            return averageRoundTripTimeMS > maxAverageRoundTripTime
        }
    }
}

extension TopologyDescription {
    internal func findSuitableServers(
        readPreference: ReadPreference,
        heartbeatFrequencyMS: Int
    ) throws -> [ServerDescription] {
        try readPreference.validateMaxStalenessSeconds(
            heartbeatFrequencyMS: heartbeatFrequencyMS,
            topologyType: self.type
        )
        switch self.type._topologyType {
        case .unknown:
            return []
        case .single, .loadBalanced:
            return self.servers
        case .replicaSetNoPrimary, .replicaSetWithPrimary:
            switch readPreference.mode {
            case .secondary:
                return self.filterReplicaSetServers(
                    readPreference: readPreference,
                    heartbeatFrequencyMS: heartbeatFrequencyMS,
                    includePrimary: false
                )
            case .nearest:
                return self.filterReplicaSetServers(
                    readPreference: readPreference,
                    heartbeatFrequencyMS: heartbeatFrequencyMS,
                    includePrimary: true
                )
            case .secondaryPreferred:
                // If mode is 'secondaryPreferred', attempt the selection algorithm with mode 'secondary' and the
                // user's maxStalenessSeconds and tag_sets. If no server matches, select the primary.
                let secondaryMatches = self.filterReplicaSetServers(
                    readPreference: readPreference,
                    heartbeatFrequencyMS: heartbeatFrequencyMS,
                    includePrimary: false
                )
                return secondaryMatches.isEmpty ? self.servers.filter { $0.type == .rsPrimary } : secondaryMatches
            case .primaryPreferred:
                // If mode is 'primaryPreferred' or a readPreference is not provided, select the primary if it is known,
                // otherwise attempt the selection algorithm with mode 'secondary' and the user's
                // maxStalenessSeconds and tag_sets.
                let primaries = self.servers.filter { $0.type == .rsPrimary }
                if !primaries.isEmpty {
                    return primaries
                }
                return self.filterReplicaSetServers(
                    readPreference: readPreference,
                    heartbeatFrequencyMS: heartbeatFrequencyMS,
                    includePrimary: false
                )
            case .primary:
                return self.servers.filter { $0.type == .rsPrimary }
            }
        case .sharded:
            return self.servers.filter { $0.type == .mongos }
        }
    }

    /// Filters the replica set servers in this topology first by max staleness and then by tag sets.
    private func filterReplicaSetServers(
        readPreference: ReadPreference?,
        heartbeatFrequencyMS: Int,
        includePrimary: Bool
    ) -> [ServerDescription] {
        // The initial set of servers from which to filter. Only include the secondaries unless includePrimary is true.
        var servers = self.servers.filter { ($0.type == .rsPrimary && includePrimary) || $0.type == .rsSecondary }

        // Filter by max staleness. If maxStalenessSeconds is not configured as a positive number, all servers are
        // eligible.
        if let maxStalenessSeconds = readPreference?.maxStalenessSeconds, maxStalenessSeconds > 0 {
            let primary = self.servers.first { $0.type == .rsPrimary }
            let maxLastWriteDate = self.getMaxLastWriteDate()
            servers.removeAll {
                guard let staleness = $0.calculateStalenessSeconds(
                    primary: primary,
                    maxLastWriteDate: maxLastWriteDate,
                    heartbeatFrequencyMS: heartbeatFrequencyMS
                ) else {
                    return false
                }
                return staleness > maxStalenessSeconds
            }
        }

        // Filter by tag sets.
        guard let tagSets = readPreference?.tagSets else {
            return servers
        }
        for tagSet in tagSets {
            let matches = servers.filter { server in tagSet.allSatisfy { server.tags[$0.key] == $0.value.stringValue } }
            if !matches.isEmpty {
                return matches
            }
        }

        // If no matches were found during tag set filtering, return an empty list.
        return []
    }

    /// Returns a `Date` representing the latest `lastWriteDate` configured on a secondary in the topology, or `nil`
    /// if none is found.
    private func getMaxLastWriteDate() -> Date? {
        let secondaryLastWriteDates = self.servers.compactMap {
            $0.type == .rsSecondary ? $0.lastWriteDate : nil
        }
        return secondaryLastWriteDates.max()
    }

    fileprivate func getWireVersionRange() -> (Int, Int)? {
        guard let min = self.servers.map({ $0.minWireVersion }).min() else {
            return nil
        }
        guard let max = self.servers.map({ $0.maxWireVersion }).max() else {
            return nil
        }
        return (min, max)
    }
}

extension ServerDescription {
    /// Calculates the staleness of this server. If the server is not a secondary, the staleness is 0. Otherwise,
    /// compare against the primary if one is present, or the maximum last write date seen in the topology if present.
    /// If staleness cannot be calculated due to an absence of values, `nil` is returned.
    fileprivate func calculateStalenessSeconds(
        primary: ServerDescription?,
        maxLastWriteDate: Date?,
        heartbeatFrequencyMS: Int
    ) -> Int? {
        guard self.type == .rsSecondary else {
            return 0
        }
        guard let lastWriteDate = self.lastWriteDate else {
            return nil
        }
        if let primary = primary {
            guard let primaryLastWriteDate = primary.lastWriteDate else {
                return nil
            }
            let selfInterval = self.lastUpdateTime.timeIntervalSince(lastWriteDate)
            let primaryInterval = primary.lastUpdateTime.timeIntervalSince(primaryLastWriteDate)
            // timeIntervalSince returns a TimeInterval in seconds, so heartbeatFrequencyMS needs to be converted from
            // milliseconds to seconds.
            let stalenessSeconds = selfInterval - primaryInterval + Double(heartbeatFrequencyMS) / 1000.0
            return Int(stalenessSeconds.rounded(.up))
        } else {
            guard let maxLastWriteDate = maxLastWriteDate else {
                return nil
            }
            let interval = maxLastWriteDate.timeIntervalSince(lastWriteDate)
            let stalenessSeconds = interval + Double(heartbeatFrequencyMS) / 1000.0
            return Int(stalenessSeconds.rounded(.up))
        }
    }
}

extension ReadPreference {
    fileprivate func validateMaxStalenessSeconds(
        heartbeatFrequencyMS: Int,
        topologyType: TopologyDescription.TopologyType
    ) throws {
        if let maxStalenessSeconds = self.maxStalenessSeconds {
            if self.mode == .primary && maxStalenessSeconds > 0 {
                throw MongoError.InvalidArgumentError(
                    message: "A positive maxStalenessSeconds cannot be specified when the read preference mode is"
                        + " primary"
                )
            }
            if topologyType == .replicaSetWithPrimary || topologyType == .replicaSetNoPrimary {
                if maxStalenessSeconds * 1000 < heartbeatFrequencyMS + SDAMConstants.idleWritePeriodMS {
                    throw MongoError.InvalidArgumentError(
                        message: "maxStalenessSeconds must be at least the sum of the heartbeatFrequencyMS configured"
                            + " on the client (\(heartbeatFrequencyMS)) and the idleWritePeriodMS"
                            + " (\(SDAMConstants.idleWritePeriodMS))"
                    )
                }
                if maxStalenessSeconds < SDAMConstants.smallestMaxStalenessSeconds {
                    throw MongoError.InvalidArgumentError(
                        message: "The maxStalenessSeconds configured for a replica set must be at least"
                            + " \(SDAMConstants.smallestMaxStalenessSeconds)"
                    )
                }
            }
        }
    }
}

extension ServerDescription {
    internal mutating func updateAverageRoundTripTime(roundTripTime: Double) {
        if let oldAverageRTT = self.averageRoundTripTimeMS {
            let alpha = 0.2
            self.averageRoundTripTimeMS = alpha * roundTripTime + (1 - alpha) * oldAverageRTT
        } else {
            self.averageRoundTripTimeMS = roundTripTime
        }
    }
}
#endif