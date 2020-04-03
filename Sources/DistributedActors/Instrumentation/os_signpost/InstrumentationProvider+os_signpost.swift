//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
/// Provider of Instrumentation instances which use `os_signpost`.
public struct OSSignpostInstrumentationProvider: ActorInstrumentationProvider {
    public var actorInstrumentation: ((AnyObject, ActorAddress) -> ActorInstrumentation)? {
        if #available(OSX 10.14, *) {
            // TODO: how to guard in iOS etc here?
            return OSSignpostActorInstrumentation.init
        } else {
            return nil
        }
    }

    public var actorTransportInstrumentation: (() -> ActorTransportInstrumentation)? {
        if #available(OSX 10.14, *) {
            return OSSignpostActorTransportInstrumentation.init
        } else {
            return nil
        }
    }
}
#endif