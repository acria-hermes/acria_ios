//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

use crate::core::util::CppObject;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
#[allow(dead_code)]
pub enum LogSeverity {
    Verbose,
    Info,
    Warn,
    Error,
    None,
}

extern "C" {
    #[allow(dead_code)]
    pub fn Rust_setLogger(cbs: CppObject, min_severity: LogSeverity);
}
