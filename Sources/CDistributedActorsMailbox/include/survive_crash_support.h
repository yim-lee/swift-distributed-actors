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
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef SACT_SURVIVE_CRASH_SUPPORT_H
#define SACT_SURVIVE_CRASH_SUPPORT_H

#include "c_mailbox_phase.h"
#include <setjmp.h>

typedef struct {
    char** backtrace;
    int backtrace_length;

    CMailboxRunPhase run_phase;
} CCrashDetails;

void sact_enable_fault_handling(void);
void sact_disable_fault_handling(void);

int sact_install_swift_crash_handler(void);

jmp_buf* sact_get_error_jmp_buf(void);

CCrashDetails* sact_get_crash_details(void);

#endif // SACT_SURVIVE_CRASH_SUPPORT_H