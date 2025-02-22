//===------------------------ Node.swift ----------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic

// MARK: - ModuleDependencyGraph.Node
extension ModuleDependencyGraph {
  
  /// A node in the per-module (i.e. the driver) dependency graph
  /// Each node represents a `Decl` from the frontend.
  /// If a file references a `Decl` we haven't seen yet, the node's `dependencySource` will be nil,
  /// otherwise it will hold the name of the dependencySource file from which the node was read.
  /// A dependency is represented by an arc, in the `usesByDefs` map.
  /// (Cargo-culted and modified from the legacy driver.)
  ///
  /// Use a class, not a struct because otherwise it would be duplicated for each thing it uses
  ///
  /// Neither the `fingerprint`, nor the `isTraced` value is part of the node's identity.
  /// Neither of these must be considered for equality testing or hashing because their
  /// value is subject to change during integration and tracing.

  public final class Node {

    /*@_spi(Testing)*/ public typealias Graph = ModuleDependencyGraph

    /// Hold these where an invariant can be checked.
    /// Must be able to change the fingerprint
    private(set) var keyAndFingerprint: KeyAndFingerprintHolder

    /*@_spi(Testing)*/ public var key: DependencyKey { keyAndFingerprint.key }
    /*@_spi(Testing)*/ public var fingerprint: InternedString? { keyAndFingerprint.fingerprint }

    /// The dependencySource file that holds this entity iff the entities .swiftdeps (or in future, .swiftmodule) is known.
    /// If more than one source file has the same DependencyKey, then there
    /// will be one node for each in the driver, distinguished by this field.
    /// Nodes can move from file to file when the driver reads the result of a
    /// compilation.
    /// Nil represents a node with no known residance
    @_spi(Testing) public let dependencySource: DependencySource?
    var isExpat: Bool { dependencySource == nil }

    /// When integrating a change, the driver finds untraced nodes so it can kick off jobs that have not been
    /// kicked off yet. (Within any one driver invocation, compiling a source file is idempotent.)
    /// When reading a serialized, prior graph, *don't* recover this state, since it will be a new driver
    /// invocation that has not kicked off any compiles yet.
    @_spi(Testing) public private(set) var isTraced: Bool = false

    private let cachedHash: Int

    /// This dependencySource is the file where the swiftDeps, etc. was read, not necessarily anything in the
    /// SourceFileDependencyGraph or the DependencyKeys
    init(key: DependencyKey, fingerprint: InternedString?,
         dependencySource: DependencySource?) {
      self.keyAndFingerprint = try! KeyAndFingerprintHolder(key, fingerprint)
      self.dependencySource = dependencySource
      self.cachedHash = Self.computeHash(key, dependencySource)
    }
  }
}

// MARK: - Setting fingerprint
extension ModuleDependencyGraph.Node {
  func setFingerprint(_ newFP: InternedString?) {
    keyAndFingerprint = try! KeyAndFingerprintHolder(key, newFP)
  }
}

// MARK: - trace status
extension ModuleDependencyGraph.Node {
  var isUntraced: Bool { !isTraced }
  func setTraced() { isTraced = true }
  @_spi(Testing) public func setUntraced() { isTraced = false }
}

// MARK: - comparing, hashing
extension ModuleDependencyGraph.Node: Equatable, Hashable {
  public static func ==(lhs: ModuleDependencyGraph.Node, rhs: ModuleDependencyGraph.Node) -> Bool {
    lhs.keyAndFingerprint.key == rhs.keyAndFingerprint.key &&
    lhs.dependencySource == rhs.dependencySource
  }
  static private func computeHash(_ key: DependencyKey, _ source: DependencySource?) -> Int {
    var h = Hasher()
    h.combine(key)
    h.combine(source)
    return h.finalize()
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(cachedHash)
  }
}

/// May not be used today, but will be needed if we ever need to deterministically order nodes.
/// For example, when following def-use links in ``ModuleDependencyGraph/Tracer``
public func isInIncreasingOrder(
  _ lhs: ModuleDependencyGraph.Node, _ rhs: ModuleDependencyGraph.Node,
  in holder: InternedStringTableHolder
)-> Bool {
  if lhs.key != rhs.key {
    return isInIncreasingOrder(lhs.key, rhs.key, in: holder)
  }
  guard let rds = rhs.dependencySource else {return false}
  guard let lds = lhs.dependencySource else {return true}
  guard lds == rds else {return lds < rds}
  guard let rf = rhs.fingerprint else {return false}
  guard let lf = lhs.fingerprint else {return true}
  return isInIncreasingOrder(lf, rf, in: holder)
}

extension ModuleDependencyGraph.Node {
  public func description(in holder: InternedStringTableHolder) -> String {
    "\(key.description(in: holder)) \( dependencySource.map { "in \($0.description)" } ?? "<expat>" )"
  }
}

extension ModuleDependencyGraph.Node {
  public func verify() {
    verifyExpatsHaveNoFingerprints()
    key.verify()
  }
  
  public func verifyExpatsHaveNoFingerprints() {
    if isExpat && fingerprint != nil {
      fatalError(#function)
    }
  }
}
